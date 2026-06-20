# WF-01 - Match Collector

**Versão:** 1.2.0 | **Sprint:** 2 | **Status:** Produção  
**Arquivo:** `n8n/workflows/WF-01-match-collector.json`  
**Nodes:** 34 | **Conexões:** 32

---

## Objetivo

Coletar e persistir dados de todas as partidas da Copa do Mundo 2026 a partir da Football-Data API, mantendo `wcic.matches` sincronizado com status, placar e metadados. É o workflow fundacional do sistema: popula `wcic:active_matches` no Redis, que é consumido por WF-02.

---

## Trigger

| Parâmetro | Valor |
|---|---|
| Tipo | Cron Schedule |
| Expressão | `*/30 * * * *` |
| Timezone | `America/Sao_Paulo` |
| Concorrência | 1 execução por vez (Queue Mode serializa por worker) |

---

## Entradas

| Fonte | Tipo | Dado |
|---|---|---|
| Football-Data API v4 | `GET /competitions/WC/matches?season=2026` | Todas as partidas da Copa |
| RapidAPI Football v3 | `GET /fixtures?league=1&season=2026` | Fallback quando circuit aberto |
| Redis | `GET wcic:circuit:wf01:football-data` | Estado do circuit breaker |
| Redis | `GET wcic:cache:team-id-map` | Mapa external_id → UUID interno (TTL 24h) |
| Redis | `GET wcic:cache:match:{external_id}` | Cache de hash dos dados (TTL 35min) |
| PostgreSQL `wcic.teams` | SELECT | Mapa de times quando cache miss |

---

## Saídas

| Destino | Operação | Dado |
|---|---|---|
| PostgreSQL `wcic.matches` | UPSERT ON CONFLICT (external_id) | Partida normalizada |
| Redis `wcic:cache:match:{external_id}` | SET TTL=2100s | Hash de campos mutáveis |
| Redis `wcic:cache:team-id-map` | SET TTL=86400s | Mapa de times atualizado |
| Redis `wcic:active_matches` | SADD / SREM | Partidas ao vivo |
| Redis `wcic:pub:match.updated` | PUBLISH | Evento de atualização |
| PostgreSQL `wcic.workflow_logs` | INSERT | Log de execução |
| WF-11 | Execute Workflow | Quando `status` muda para `finished` |
| WF-07 | Execute Workflow | Quando circuit breaker abre (alerta ops) |

---

## Fluxo de Execução

```
Schedule Trigger (*/30 * * * *)
  └─► Init
        [gera correlationId UUID, registra startedAt, executionId]
        └─► Log Start to Redis
              [SET wcic:{correlationId} TTL=3600]
              └─► Check Circuit Breaker
                    [GET wcic:circuit:wf01:football-data]
                    └─► Circuit Open? (IF)
                          │
                          ├─ TRUE ──► Fetch RapidAPI (Fallback)
                          │
                          └─ FALSE ─► Fetch Football-Data API
                                        │
                                        ├─ SUCCESS ──► Reset Error Counter
                                        │              [DEL wcic:errors:wf01:football-data]
                                        │              └─► Normalize Payload
                                        │
                                        └─ ERROR ───► Handle Primary Error
                                                       └─► Increment Error Counter
                                                             [INCR wcic:errors:wf01:football-data]
                                                             └─► Set Error Counter TTL (600s)
                                                                   └─► Error Threshold Reached? (≥5)
                                                                         │
                                                                         ├─ TRUE ──► Open Circuit Breaker
                                                                         │           [SET wcic:circuit:wf01:football-data = OPEN TTL=600]
                                                                         │           └─► Log Execution Error
                                                                         │
                                                                         └─ FALSE ─► Fetch RapidAPI (Fallback)
                                                                                       └─► Normalize Payload

Normalize Payload
  [Converte schema da API → wcic.matches, suporta ambos os formatos]
  └─► Get Team ID Map from Cache
        [GET wcic:cache:team-id-map]
        └─► Resolve Team IDs
              └─► Needs DB Fetch? (IF)
                    │
                    ├─ TRUE ──► Fetch Team IDs from DB
                    │           └─► Build Team Map
                    │                 └─► Cache Team Map (24h)
                    │                       └─► Prepare Matches for Batch
                    │
                    └─ FALSE ─► Prepare Matches for Batch
                                  [Aplica teamIdMap, filtra inválidos, retorna itens individuais]
                                  └─► Split in Batches (10)
                                        └─► Check Match Cache
                                              [GET wcic:cache:match:{external_id}]
                                              └─► Detect Changes
                                                    [Compara hash status|scores]
                                                    └─► Has Changed? (IF)
                                                          │
                                                          ├─ FALSE ─► [SKIP - volta ao Split]
                                                          │
                                                          └─ TRUE ──► Upsert Match
                                                                        [INSERT ... ON CONFLICT DO UPDATE WHERE IS DISTINCT FROM]
                                                                        └─► Update Match Cache
                                                                              [SET wcic:cache:match:{id} TTL=2100]
                                                                              └─► Is Live or Halftime? (IF)
                                                                                    │
                                                                                    ├─ TRUE ──► Add to Active Matches
                                                                                    │           [SADD wcic:active_matches]
                                                                                    │
                                                                                    └─ FALSE ─► Is Finished? (IF)
                                                                                                  │
                                                                                                  ├─ TRUE ──► Remove from Active Matches
                                                                                                  │           [SREM wcic:active_matches]
                                                                                                  │
                                                                                                  └─ FALSE ─► [continua]

                                                                              └─► Publish match.updated
                                                                                    [PUBLISH wcic:pub:match.updated]
                                                                                    └─► Log Execution Success
```

---

## Dependências

| Dependência | Obrigatória | Impacto se ausente |
|---|---|---|
| `wcic.teams` com dados (seeds) | ✅ Sim | Team ID map vazio → nenhum match inserido |
| `wcic.venues` com dados (seeds) | ⚠️ Não | `venue_id` fica NULL - aceitável |
| Redis disponível | ⚠️ Degradável | Sem cache/dedup; mais writes no PG; risco de duplicatas concorrentes |
| Migration 005 aplicada | ✅ Sim | Coluna `last_sync_at` e índice UNIQUE em `match_events` ausentes |
| Migration 006 aplicada | ✅ Sim | Grupos I-L no ENUM `match_stage` ausentes |
| Credencial `Football Data API` no n8n | ✅ Sim | Sem API primária, depende 100% do fallback |
| Credencial `WCIC PostgreSQL` no n8n | ✅ Sim | Impossível persistir dados |
| Credencial `WCIC Redis` no n8n | ✅ Sim | Impossível operar cache e circuit breaker |

---

## Integrações Externas

### Football-Data.org v4 (primária)

- **Endpoint:** `GET https://api.football-data.org/v4/competitions/WC/matches?season=2026`
- **Autenticação:** Header `X-Auth-Token` via credencial `Football Data API`
- **Timeout:** 15.000ms
- **Rate limit:** 10 req/min (plano free)
- **Retorno:** Array `matches[]` com status, placar, times, árbitro

### API-Football / RapidAPI (fallback)

- **Endpoint:** `GET https://api-football-v1.p.rapidapi.com/v3/fixtures?league=1&season=2026`
- **Autenticação:** Header `X-RapidAPI-Key` via credencial `RapidAPI Football`
- **Timeout:** 15.000ms
- **Ativação:** Apenas quando circuit breaker Football-Data está OPEN

---

## Estratégia de Retries

| Camada | Configuração | Comportamento |
|---|---|---|
| n8n HTTP Request node | `onError: continueErrorOutput` | Captura erro e roteia para branch de erro |
| Circuit breaker Redis | 5 erros em 10min → OPEN por 10min | Desvia para fallback automaticamente |
| Erro de PostgreSQL | n8n retry nativo (3x, intervalo 5s) | Configurado nas settings do node |
| Falha total (ambas APIs) | Circuit OPEN + Log Execution Error | Alerta ops via WF-07 |

**Não há retry em loop neste workflow.** A resiliência vem do circuit breaker + fallback + próxima execução do cron em 30 min.

---

## Estratégia de Deduplicação

**Camada 1 - Redis (velocidade):**
```
Chave: wcic:cache:match:{external_id}
Valor: { status, home_score, away_score, home_score_ht, away_score_ht }
TTL:   2100s (35 min - superior ao intervalo do cron de 30 min)
Lógica: hash dos campos mutáveis. Cache HIT com hash igual → skip UPSERT
```

**Camada 2 - PostgreSQL (garantia):**
```sql
ON CONFLICT (external_id) DO UPDATE SET ... 
WHERE matches.status IS DISTINCT FROM EXCLUDED.status OR ...
```
A cláusula `WHERE IS DISTINCT FROM` impede atualização de `updated_at` sem mudança real de dados.

---

## Estratégia de Observabilidade

- **Log de início:** Redis SET `wcic:{correlationId}` com metadados da execução
- **Log de fim:** INSERT em `wcic.workflow_logs` com `status`, `duration_ms`, `items_processed`
- **Correlation ID:** UUID gerado no node `Init`, propagado para WF-11 e WF-07
- **Circuit breaker visível:** Redis key `wcic:circuit:wf01:football-data` monitorável via Redis Exporter → Prometheus

---

## Métricas

| Métrica | Tipo | Fonte |
|---|---|---|
| `wcic_wf01_executions_total{status}` | Counter | `workflow_logs` |
| `wcic_wf01_duration_ms` | Histogram | `workflow_logs.duration_ms` |
| `wcic_wf01_matches_processed` | Counter | `workflow_logs.items_processed` |
| `wcic_wf01_circuit_open` | Gauge | Redis key `wcic:circuit:wf01:football-data` |
| `wcic_wf01_cache_hit_ratio` | Gauge | Diferença entre `items_processed` e UPSERTs reais |
| `wcic_active_matches_count` | Gauge | `SCARD wcic:active_matches` |

---

## Possíveis Falhas

| Falha | Causa | Impacto | Detecção | Resolução |
|---|---|---|---|---|
| Teams sem `external_id` | Seeds aplicados mas sem sync da API | Nenhum match inserido (team ID null) | `workflow_logs.output_summary.skipped > 0` | Forçar execução manual; API deve ter atualizado os IDs |
| Circuit breaker permanentemente OPEN | Ambas as APIs fora | Sem dados por até 10 min | Alerta ops via WF-07 | Verificar conectividade; `DEL wcic:circuit:wf01:football-data` manualmente |
| Stage desconhecido da API | Copa adiciona fase nova | Match pulado, log de erro | `workflow_logs.error_message` contém "Unknown stage" | Atualizar `STAGE_MAP` no node `Normalize Payload` |
| PostgreSQL lento | Alta carga durante jogos | UPSERT timeout, retry automático | `workflow_logs.duration_ms` alto | Verificar conexões; reindexar se necessário |
| Cache Redis TTL expirado entre batches | TTL 35min vs cron 30min com atraso | Possível UPSERT desnecessário | Normal - apenas leve impacto de performance | Nenhuma ação necessária |

---

## Runbook Operacional

### Verificar saúde da última execução

```sql
SELECT status, duration_ms, items_processed, error_message, started_at
FROM wcic.workflow_logs
WHERE workflow_name = 'WF-01-match-collector'
ORDER BY started_at DESC
LIMIT 5;
```

### Verificar circuit breaker

```bash
redis-cli -a $REDIS_PASSWORD GET wcic:circuit:wf01:football-data
# Se retornar "OPEN": circuit aberto
# Forçar reset:
redis-cli -a $REDIS_PASSWORD DEL wcic:circuit:wf01:football-data
redis-cli -a $REDIS_PASSWORD DEL wcic:errors:wf01:football-data
```

### Verificar partidas ativas

```bash
redis-cli -a $REDIS_PASSWORD SMEMBERS wcic:active_matches
```

### Forçar resync de todos os times

```bash
redis-cli -a $REDIS_PASSWORD DEL wcic:cache:team-id-map
# Próxima execução buscará do banco e reconstruirá o cache
```

### Verificar dados no banco

```sql
SELECT
  COUNT(*) AS total,
  COUNT(CASE WHEN status = 'live' THEN 1 END) AS live,
  COUNT(CASE WHEN status = 'finished' THEN 1 END) AS finished,
  COUNT(CASE WHEN status = 'scheduled' THEN 1 END) AS scheduled,
  MAX(last_sync_at) AS ultimo_sync
FROM wcic.matches;
```

---

## Critérios de Sucesso

- `wcic.matches` contém 104 partidas após execução completa
- Nenhum registro com `home_team_id IS NULL`
- `last_sync_at` atualizado a cada execução para todas as partidas não finalizadas
- `workflow_logs` registra cada execução com `status = 'success'`
- `wcic:active_matches` contém apenas IDs de partidas com status `live` ou `halftime`
- Duas execuções consecutivas não criam duplicatas (`SELECT external_id, COUNT(*) GROUP BY 1 HAVING COUNT(*) > 1` retorna vazio)
EOF
echo "WF-01 spec ok"
