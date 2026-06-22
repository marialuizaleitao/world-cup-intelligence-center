# WF-04 - Sentiment Analyzer

**Versão:** 1.0.0 | **Sprint:** 4 | **Status:** Produção  
**Arquivo:** `n8n/workflows/WF-04-sentiment-analyzer.json`  
**Nodes:** 22  
**Sub-workflow:** `SWF - OpenAI Sentiment Analyst`

---

## Objetivo

Calcular e persistir snapshots de sentimento público por seleção nacional, derivado das análises de notícias já processadas pelo WF-03. Detecta mudanças bruscas de sentimento negativo (> 60%) e aciona alertas via WF-07. Armazena snapshots na hypertable `wcic.sentiment_snapshots` com cache Redis de 30 minutos para consumo por dashboards e API.

**Fonte de dados na Sprint 4:** summaries de `wcic.news_analysis` (proxy via notícias).  
**Fonte planejada para Sprint 5+:** Twitter API v2 e Reddit API (posts diretos de redes sociais).

---

## Trigger

| Parâmetro | Valor |
|---|---|
| Tipo | Cron Schedule |
| Expressão | `*/30 * * * *` (a cada 30 minutos) |
| Timezone | `America/Sao_Paulo` |

---

## Entradas

| Fonte | Tipo | Dado |
|---|---|---|
| PostgreSQL `wcic.teams` + `wcic.news_analysis` | SELECT com JOIN | Times com ≥ 2 notícias nas últimas 6h com impact_score ≥ 0.3 |
| Redis `wcic:rl:wf04:openai` | GET | Contador de chamadas OpenAI no minuto atual |

---

## Saídas

| Destino | Operação | Dado |
|---|---|---|
| PostgreSQL `wcic.sentiment_snapshots` | INSERT | Snapshot de sentimento por entidade |
| Redis `wcic:cache:sentiment:{type}:{id}` | SET TTL=1800s | Cache de sentimento mais recente por entidade |
| WF-07 | Execute Workflow (async) | Alerta quando `negative_ratio > 0.60` |
| PostgreSQL `wcic.workflow_logs` | INSERT | Log de execução |

---

## Fluxo Completo

```
Schedule Trigger (*/30 min)
  └─► Init
        [gera correlationId, startedAt, executionId, sourceType='newsapi', lookbackHours=6]
        └─► Load Teams with Recent News
              [SELECT teams com news_analysis.affected_team_ids recentes]
              [GROUP BY team, exige COUNT >= 2 e avg_impact >= 0.3]
              [LIMIT 20 times por execução]
              └─► Has Entities? (Code node - verifica se array não vazio)
                    └─► Has Entities? (IF node)
                          │
                          ├─ FALSE ──► Log No Entities (workflow_logs reason=no_entities)
                          │
                          └─ TRUE ───► Split by Entity (batch=1)
                                          └─► Prepare Sentiment Input
                                                [Converte news_summaries[] → posts[{text, platform:'newsapi'}]]
                                                [Máx 50 summaries por entidade]
                                                └─► Skip? (IF: skip=true se posts.length=0)
                                                      │
                                                      ├─ SKIP ──► Log Success
                                                      │
                                                      └─ OK ─────► Check OpenAI Rate Limit
                                                                      [GET wcic:rl:wf04:openai]
                                                                      └─► Rate Limit Decision
                                                                            [current >= 30 → rate_limited]
                                                                            └─► Rate Limit Gate (IF)
                                                                                  │
                                                                                  ├─ LIMITED ──► Log Success [throttled]
                                                                                  │
                                                                                  └─ OK ────────► Call Sentiment Analyst (SWF)
                                                                                                    [waitForSubWorkflow: true]
                                                                                                    └─► Increment Rate Limit
                                                                                                          [INCR wcic:rl:wf04:openai]
                                                                                                          └─► Set RL TTL (60s)
                                                                                                                └─► Check Sentiment Result
                                                                                                                      [gpt_error? → persist=false]
                                                                                                                      └─► Persist Sentiment Snapshot
                                                                                                                            [INSERT sentiment_snapshots]
                                                                                                                            └─► Cache Sentiment (30min)
                                                                                                                                  [SET wcic:cache:sentiment:{type}:{id} TTL=1800]
                                                                                                                                  └─► Detect Sentiment Shift
                                                                                                                                        [negative_ratio > 0.60 || unusual_signals != null]
                                                                                                                                        └─► Alert Shift? (IF)
                                                                                                                                              │
                                                                                                                                              ├─ TRUE ──► Alert via WF-07 (async)
                                                                                                                                              └─ FALSE ─► Log Success
```

---

## Dependências

| Dependência | Obrigatória | Impacto se ausente |
|---|---|---|
| `wcic.sentiment_snapshots` (migration 001) | ✅ Sim | INSERT falha |
| `wcic.sentiment_snapshots` como hypertable (migration 004) | ✅ Sim | TimescaleDB não particiona; performance degradada em alto volume |
| Constraint `source CHECK` atualizado (migration 007) | ✅ Sim | INSERT com `source='newsapi'` viola constraint antiga |
| WF-03 executado com sucesso antes | ✅ Sim | `news_analysis.affected_team_ids` vazio → nenhuma entidade carregada |
| SWF Sentiment Analyst importado e ativo | ✅ Sim | `Call Sentiment Analyst` lança exceção |
| Redis disponível | ✅ Sim | Cache não funciona; rate limiting desabilitado |
| WF-07 importado e ativo | ⚠️ Alertas | Alertas de sentimento negativo não enviados |

---

## Integrações Externas

### OpenAI GPT-4o (via SWF-openai-sentiment-analyst)

- Chamada indireta - o WF-04 delega ao SWF
- **Rate limit interno:** 30 chamadas/minuto por worker (conservador; OpenAI permite mais)
- **Modelo:** `gpt-4o` via credencial `WCIC OpenAI`
- **Input:** array de summaries de notícias tratados como "posts" para análise

### Fontes planejadas (Sprint 5+)

- Twitter API v2 - `GET /2/tweets/search/recent?query={team} worldcup`
- Reddit API - `GET /r/soccer/search?q={team}&t=day`

---

## Redis Utilizado

| Chave | Tipo | TTL | Propósito |
|---|---|---|---|
| `wcic:rl:wf04:openai` | STRING (counter) | 60s | Rate limiting OpenAI (max 30/min) |
| `wcic:cache:sentiment:team:{uuid}` | STRING (JSON) | 1800s | Cache de último snapshot por time |
| `wcic:cache:sentiment:player:{uuid}` | STRING (JSON) | 1800s | Cache de último snapshot por jogador |

---

## Tabelas Impactadas

| Tabela | Operação | Condição |
|---|---|---|
| `wcic.teams` | SELECT (via JOIN) | A cada execução |
| `wcic.news_analysis` | SELECT (affected_team_ids, summary) | A cada execução |
| `wcic.news` | SELECT (JOIN via news_analysis) | A cada execução |
| `wcic.sentiment_snapshots` | INSERT | Por entidade com análise bem-sucedida |
| `wcic.workflow_logs` | INSERT | A cada execução |

---

## Estratégia de Retry

| Camada | Comportamento |
|---|---|
| GPT retornou erro | `persist=false`; sem retry automático; próxima execução tentará novamente se dados ainda disponíveis |
| GPT retornou ratios inválidos (soma ≠ 1.0) | SWF renormaliza automaticamente se divergência < 5%; caso contrário lança exception |
| Rate limit OpenAI atingido | Entidade pulada silenciosamente; próxima execução (30 min) tenta novamente |
| PostgreSQL timeout | n8n retry nativo 3x antes de falhar |
| Nenhum time com news recentes | Log `reason=no_entities`; encerra normalmente sem erro |

---

## Estratégia de Observabilidade

- **Correlation ID:** propagado do Init para o SWF via payload
- **Cache hit ratio:** comparar `SCARD` no Redis vs INSERT no PostgreSQL
- **Trend detection:** cada INSERT com `negative_ratio > 0.60` gera entrada em `notifications`
- **TimescaleDB:** queries de trend por janela temporal via `time_bucket()` nas views `sentiment_hourly`

---

## Métricas

| Métrica | Tipo | Fonte |
|---|---|---|
| `wcic_wf04_executions_total{status}` | Counter | `workflow_logs` |
| `wcic_wf04_snapshots_total{entity_type}` | Counter | `sentiment_snapshots` |
| `wcic_wf04_entities_analyzed_total` | Counter | `workflow_logs.items_processed` |
| `wcic_wf04_negative_alerts_total` | Counter | `notifications WHERE type='sentiment_alert'` |
| `wcic_wf04_avg_sentiment_by_team` | Gauge | `AVG(positive_ratio)` por time nas últimas 24h |
| `wcic_wf04_openai_tokens_total` | Counter | `sentiment_snapshots.tokens_used` |

---

## Possíveis Falhas

| Falha | Causa | Impacto | Detecção | Resolução |
|---|---|---|---|---|
| Nenhuma entidade carregada | WF-03 não rodou ou sem news recentes | Zero snapshots gerados | `workflow_logs.output_summary.reason = 'no_entities'` | Garantir WF-03 ativo antes do WF-04 |
| `source` violando constraint | Migration 007 não aplicada | INSERT de newsapi falha | Erro no `Persist Sentiment Snapshot` | Aplicar migration 007 |
| `affected_team_ids` mal populado | WF-03 não fez match de times corretamente | Teams sem snapshots | `news_analysis WHERE affected_team_ids = '{}'` count alto | Revisar lógica de team matching no WF-03 |
| Sentimento sempre neutro | Posts insuficientes (< 2 summaries) | Análise pouco confiável | `volume < 2` nos snapshots | Aumentar `lookbackHours` de 6 para 12 no Init |
| Cache Redis sobrescreve sem persistir | SET antes do INSERT confirmar | Cache com dados não persistidos | Monitorar discrepância cache vs banco | O fluxo atual: INSERT primeiro, depois SET cache - ordem correta |

---

## Runbook Operacional

### Ver snapshots recentes por time

```sql
SELECT
  t.name, ss.positive_ratio, ss.negative_ratio,
  ss.dominant_sentiment, ss.intensity, ss.volume,
  ss.captured_at
FROM wcic.sentiment_snapshots ss
JOIN wcic.teams t ON t.id = ss.entity_id
WHERE ss.entity_type = 'team'
  AND ss.captured_at > NOW() - INTERVAL '6 hours'
ORDER BY ss.captured_at DESC;
```

### Verificar trend de sentimento de um time

```sql
SELECT
  time_bucket('1 hour', captured_at) AS hour,
  AVG(positive_ratio) AS avg_positive,
  AVG(negative_ratio) AS avg_negative,
  SUM(volume) AS total_volume
FROM wcic.sentiment_snapshots
WHERE entity_id = '{TEAM_UUID}'::uuid
  AND captured_at > NOW() - INTERVAL '24 hours'
GROUP BY 1
ORDER BY 1;
```

### Verificar cache Redis de um time

```bash
redis-cli -a $REDIS_PASSWORD GET "wcic:cache:sentiment:team:{TEAM_UUID}"
```

### Forçar reexecução manual

```bash
# Via n8n UI: WF-04 → Execute → Test workflow
# Ou via API:
curl -X POST -u admin:$N8N_PASS \
  "http://localhost:5678/api/v1/workflows/{WF04_ID}/run"
```

---

## Critérios de Sucesso

- `wcic.sentiment_snapshots` recebe ≥ 1 snapshot por time ativo a cada 30 minutos durante a Copa
- Cache Redis atualizado após cada snapshot inserido
- Alertas disparados via WF-07 quando `negative_ratio > 0.60`
- `workflow_logs` registra 100% das execuções com `status = 'success'`
- Zero violações de constraint `source` na tabela `sentiment_snapshots`
