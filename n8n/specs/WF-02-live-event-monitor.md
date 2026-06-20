# WF-02 - Live Event Monitor

**Versão:** 1.0.0 | **Sprint:** 3 | **Status:** Produção  
**Arquivo:** `n8n/workflows/WF-02-live-event-monitor.json`  
**Nodes:** 28 | **Conexões:** 25

---

## Objetivo

Monitorar eventos em tempo real de todas as partidas ao vivo, persistir cada evento em `wcic.match_events`, publicar no Redis Pub/Sub e acionar WF-07 para notificações críticas (gols, cartões vermelhos, VAR). É o workflow de maior frequência do sistema: executa a cada 60 segundos.

---

## Trigger

| Parâmetro | Valor |
|---|---|
| Tipo | Cron Schedule |
| Expressão | `* * * * *` (60 segundos) |
| Timezone | `America/Sao_Paulo` |
| Otimização | Se `wcic:active_matches` vazio → termina imediatamente sem API calls |

---

## Entradas

| Fonte | Tipo | Dado |
|---|---|---|
| Redis SET `wcic:active_matches` | SMEMBERS | UUIDs das partidas ao vivo |
| Redis `wcic:live:cursor:{matchId}` | GET | Cursor de eventos já processados (TTL 4h) |
| Football-Data API v4 | `GET /matches/{id}` | Eventos, placar e status da partida |

---

## Saídas

| Destino | Operação | Dado |
|---|---|---|
| PostgreSQL `wcic.match_events` | INSERT ON CONFLICT DO NOTHING | Evento normalizado |
| Redis `wcic:live:cursor:{matchId}` | SET TTL=14400 | Cursor atualizado com IDs processados |
| Redis `wcic:pub:events.live` | PUBLISH | Evento ao vivo para consumers downstream |
| WF-07 | Execute Workflow | Para gols, cartões vermelhos, VAR (async, `waitForSubWorkflow: false`) |
| Redis `wcic:errors:wf02:{matchId}` | INCR TTL=300 | Contador de erros por partida |
| Redis `wcic:active_matches` | SREM | Remove partida com ≥3 erros consecutivos |
| PostgreSQL `wcic.workflow_logs` | INSERT | Log de cada execução |

---

## Fluxo de Execução

```
Schedule Trigger (* * * * *)
  └─► Init
        [gera correlationId, startedAt, executionId]
        └─► Get Active Matches
              [SMEMBERS wcic:active_matches]
              └─► Check Active Matches
                    [Normaliza resultado Redis, filtra nulos]
                    └─► Has Active Matches? (IF)
                          │
                          ├─ FALSE ──► Log No Active Matches
                          │            [INSERT workflow_logs: status=success, items=0]
                          │            └─► [FIM]
                          │
                          └─ TRUE ───► Expand Match IDs
                                        [Converte array em itens individuais]
                                        └─► Split in Batches (5)
                                              └─► Get Event Cursor
                                                    [GET wcic:live:cursor:{matchId}]
                                                    └─► Prepare API Call
                                                          [Parse cursor JSON, monta URL da API]
                                                          └─► Fetch Match Events
                                                                [GET /v4/matches/{id}, timeout=12s]
                                                                │
                                                                ├─ SUCCESS ──► Parse & Filter Events
                                                                │              [Normaliza goals/cards/subs]
                                                                │              [Filtra por processedIds no cursor]
                                                                │              └─► Update Cursor
                                                                │                    [SET wcic:live:cursor:{id} TTL=14400]
                                                                │                    └─► Has New Events? (IF)
                                                                │                          │
                                                                │                          ├─ FALSE ─► [volta ao Split]
                                                                │                          │
                                                                │                          └─ TRUE ──► Expand Events
                                                                │                                        [Itens individuais]
                                                                │                                        └─► Insert Event
                                                                │                                              [INSERT ON CONFLICT DO NOTHING]
                                                                │                                              └─► Publish Event
                                                                │                                                    [PUBLISH wcic:pub:events.live]
                                                                │                                                    └─► Should Notify?
                                                                │                                                          [Decide por event_type + was_inserted]
                                                                │                                                          └─► Notify? (IF)
                                                                │                                                                │
                                                                │                                                                ├─ FALSE ─► Log Success
                                                                │                                                                │
                                                                │                                                                └─ TRUE ──► Fetch Match Context
                                                                │                                                                              [SELECT times, placar do PG]
                                                                │                                                                              └─► Build Notification Payload
                                                                │                                                                                    └─► Call WF-07
                                                                │                                                                                          [async, sem await]
                                                                │                                                                                          └─► Log Success
                                                                │
                                                                └─ ERROR ────► Handle API Error
                                                                               └─► Increment Error Count
                                                                                     [INCR wcic:errors:wf02:{matchId} TTL=300]
                                                                                     └─► Set Error TTL
                                                                                           └─► 3+ Errors? (IF)
                                                                                                 │
                                                                                                 ├─ TRUE ──► Remove from Active (Error)
                                                                                                 │           [SREM wcic:active_matches]
                                                                                                 │
                                                                                                 └─ FALSE ─► [volta ao Split]
```

---

## Dependências

| Dependência | Obrigatória | Impacto se ausente |
|---|---|---|
| WF-01 em execução | ✅ Sim | `wcic:active_matches` vazio → WF-02 termina sem processar |
| `wcic.match_events` criada (migration 001) | ✅ Sim | INSERT falha |
| Índice UNIQUE `idx_match_events_external_id_unique` (migration 005) | ✅ Sim | ON CONFLICT DO NOTHING não funciona sem o índice |
| WF-07 importado e ativo | ✅ Sim | `Call WF-07` falha silenciosamente (async) |
| Redis disponível | ✅ Sim | Sem cursor → reprocessa todos os eventos a cada execução |
| Credencial `Football Data API` no n8n | ✅ Sim | API calls falham |
| `wcic.teams` com `external_id` preenchido | ✅ Sim | `team_id` fica NULL no INSERT |
| `wcic.players` com `external_id` preenchido | ⚠️ Não | `player_id` fica NULL - aceitável para MVP |

---

## Integrações Externas

### Football-Data.org v4 (única fonte)

- **Endpoint:** `GET https://api.football-data.org/v4/matches/{id}`
- **Autenticação:** Header `X-Auth-Token`
- **Timeout:** 12.000ms
- **Rate limit:** 10 req/min - máximo 10 partidas simultâneas no plano free
- **Retorno:** Objeto com `goals[]`, `bookings[]`, `substitutions[]`, `score`, `status`
- **Campos mapeados:**

| API field | `match_events` column |
|---|---|
| `goals[].id` | `external_id` |
| `goals[].type` | `event_type` (`GOAL`→`goal`, `OWN_GOAL`→`own_goal`, `PENALTY`→`penalty_scored`) |
| `goals[].minute.regular` | `minute` |
| `goals[].minute.injury` | `extra_minute` |
| `goals[].team.id` | `team_id` (via lookup) |
| `goals[].scorer.id` | `player_id` (via lookup) |
| `goals[].assist.id` | `assist_player_id` (via lookup) |
| `bookings[].card` | `event_type` (`RED_CARD`, `YELLOW_RED_CARD`, `YELLOW_CARD`) |
| `substitutions[].playerIn.id` | `player_id` |
| `substitutions[].playerOut.id` | `player_out_id` |

---

## Estratégia de Retries

**Por partida individualmente (não por execução inteira):**

| Cenário | Comportamento |
|---|---|
| HTTP timeout | `onError: continueErrorOutput` → branch de erro |
| 1–2 erros consecutivos | Incrementa contador Redis, continua outras partidas |
| 3+ erros em 5 min | Remove partida de `wcic:active_matches` |
| Counter expira (TTL 300s) | Partida volta a ser monitorada na próxima execução |

**Não há retry dentro da execução corrente.** Falha em uma partida não afeta o processamento das demais no batch.

---

## Estratégia de Deduplicação

**Camada 1 - Cursor Redis (filtro de velocidade):**
```
Chave: wcic:live:cursor:{matchId}
Valor: { processedIds: [id1, id2, ...], lastMinute: N, updatedAt: ISO }
TTL:   14400s (4 horas)
Limite: mantém apenas os últimos 200 IDs para evitar crescimento indefinido
Lógica: Set de external_ids já processados → filtra antes de qualquer INSERT
```

**Camada 2 - PostgreSQL (garantia absoluta):**
```sql
INSERT INTO wcic.match_events (..., external_id, ...)
ON CONFLICT (match_id, external_id)
WHERE external_id IS NOT NULL
DO NOTHING
```
Índice `idx_match_events_external_id_unique` (migration 005) garante unicidade por `(match_id, external_id)`.

**Flag `was_inserted`:** o node `Should Notify?` verifica se o INSERT retornou uma linha. Se `ON CONFLICT DO NOTHING` silenciou o insert (duplicata), `was_inserted = false` e a notificação é suprimida.

---

## Eventos que Geram Notificações

| `event_type` | Notificação | Prioridade WF-07 |
|---|---|---|
| `goal` | `goal_alert` | `critical` |
| `own_goal` | `own_goal_alert` | `critical` |
| `penalty_scored` | `penalty_alert` | `critical` |
| `red_card` | `red_card_alert` | `high` |
| `second_yellow` | `second_yellow_alert` | `high` |
| `var_overturned` | `var_alert` | `high` |
| `yellow_card` | - | (sem notificação) |
| `substitution` | - | (sem notificação) |
| `var_review` | - | (sem notificação) |

---

## Estratégia de Observabilidade

- **Log de execução:** INSERT em `wcic.workflow_logs` em todo ciclo, mesmo sem partidas ativas
- **Motivo de encerramento antecipado:** `output_summary.reason = "no_active_matches"` quando set vazio
- **Correlation ID:** Propagado para WF-07 via `content.metadata.caller_workflow`
- **Contadores de erro por partida:** `wcic:errors:wf02:{matchId}` monitorável via Redis Exporter

---

## Métricas

| Métrica | Tipo | Fonte |
|---|---|---|
| `wcic_wf02_executions_total{status}` | Counter | `workflow_logs` |
| `wcic_wf02_events_inserted_total{event_type}` | Counter | `workflow_logs.items_processed` |
| `wcic_wf02_active_matches` | Gauge | `SCARD wcic:active_matches` |
| `wcic_wf02_polling_duration_ms` | Histogram | `workflow_logs.duration_ms` |
| `wcic_wf02_api_errors_by_match` | Counter | `wcic:errors:wf02:*` via Redis scan |
| `wcic_wf02_notifications_dispatched` | Counter | Chamadas ao WF-07 |

---

## Possíveis Falhas

| Falha | Causa | Impacto | Detecção | Resolução |
|---|---|---|---|---|
| Cursor corrompido no Redis | Restart Redis sem persistência | Reprocessa todos os eventos do jogo | `match_events` com duplicatas (mitigado pelo ON CONFLICT) | Limpar cursor: `DEL wcic:live:cursor:{id}` |
| Partida removida de `active_matches` prematuramente | 3+ erros de API | Para de monitorar partida ao vivo | Verificar erros de API no log | `SADD wcic:active_matches {match_id}` manualmente |
| Rate limit Football-Data atingido | > 10 partidas simultâneas no free tier | Algumas partidas sem polling | Erros 429 nos logs | Aumentar batch interval ou fazer upgrade do plano |
| WF-07 não encontrado | Workflow não importado ou inativo | Notificações não enviadas (silencioso pois é async) | `workflow_logs` do WF-07 ausentes | Importar e ativar WF-07 |
| `external_id` nulo na API | API retornou evento sem ID | Evento não inserido (ON CONFLICT não protege NULL) | Eventos faltando no banco | Reportar ao suporte da API; workaround: gerar ID sintético no Normalize |

---

## Runbook Operacional

### Verificar partidas sendo monitoradas

```bash
redis-cli -a $REDIS_PASSWORD SMEMBERS wcic:active_matches
redis-cli -a $REDIS_PASSWORD SCARD wcic:active_matches
```

### Verificar cursor de uma partida

```bash
redis-cli -a $REDIS_PASSWORD GET wcic:live:cursor:{MATCH_UUID}
```

### Adicionar partida manualmente ao monitoramento

```bash
redis-cli -a $REDIS_PASSWORD SADD wcic:active_matches {MATCH_UUID}
```

### Verificar erros de uma partida

```bash
redis-cli -a $REDIS_PASSWORD GET wcic:errors:wf02:{MATCH_UUID}
```

### Contar eventos por tipo nas últimas 2 horas

```sql
SELECT event_type, COUNT(*) 
FROM wcic.match_events 
WHERE created_at > NOW() - INTERVAL '2 hours'
GROUP BY event_type 
ORDER BY COUNT(*) DESC;
```

### Verificar última execução

```sql
SELECT status, duration_ms, items_processed, output_summary, started_at
FROM wcic.workflow_logs
WHERE workflow_name = 'WF-02-live-event-monitor'
ORDER BY started_at DESC
LIMIT 10;
```

---

## Critérios de Sucesso

- Execuções com `no_active_matches` em `output_summary` quando não há jogos (comportamento esperado)
- Gol acontece na API → evento inserido em `match_events` em < 60 segundos
- Nenhuma duplicata em `match_events` após 100 execuções consecutivas com a mesma partida
- WF-07 acionado para 100% dos `goal` e `red_card` events inseridos
- `workflow_logs` registra 100% das execuções (mesmo as de "no active matches")
EOF
echo "WF-02 spec ok"
Saída
