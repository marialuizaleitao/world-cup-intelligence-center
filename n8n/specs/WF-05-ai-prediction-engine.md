# WF-05 - AI Prediction Engine

**Versão:** 1.0.0 | **Sprint:** 5 | **Status:** Produção  
**Arquivo:** `n8n/workflows/WF-05-ai-prediction-engine.json`  
**Nodes:** 23 | **Conexões:** 21  
**Sub-workflow:** `SWF - OpenAI Match Predictor`

---

## Objetivo

Gerar previsões probabilísticas pré-jogo para partidas da Copa do Mundo 2026 nas 2 horas que antecedem o apito inicial. Agrega forma recente, head-to-head, estatísticas do torneio, notícias de impacto e sentimento público em um feature set estruturado, persiste em `wcic.match_stats`, envia ao SWF Match Predictor (GPT-4o) e armazena a previsão em `wcic.predictions` com cache Redis de 1 hora.

---

## Trigger

| Parâmetro | Valor |
|---|---|
| Tipo | Cron Schedule |
| Expressão | `*/30 * * * *` (a cada 30 minutos) |
| Timezone | `America/Sao_Paulo` |
| Janela de elegibilidade | Partidas com `scheduled_at BETWEEN NOW() AND NOW() + 2h` |
| Deduplicação | Não gera previsão se já existe `pre_match` nas últimas 6h para o jogo |

---

## Entradas

| Fonte | Operação | Dado |
|---|---|---|
| PostgreSQL `wcic.matches` | SELECT | Partidas scheduled nas próximas 2h sem previsão recente |
| PostgreSQL `wcic.matches` (auto-join) | CTE recursiva | Forma recente (últimos 5 jogos de cada time) |
| PostgreSQL `wcic.matches` | CTE H2H | Head-to-head (últimos 10 encontros entre os dois times) |
| PostgreSQL `wcic.news_analysis` | SELECT | Notícias de impacto das últimas 24h para os dois times |
| PostgreSQL `wcic.sentiment_snapshots` | SELECT | Último snapshot de sentimento das últimas 6h por time |
| Redis `wcic:rl:wf05:openai` | GET | Rate limit OpenAI (max 20 previsões/minuto) |

---

## Saídas

| Destino | Operação | Dado |
|---|---|---|
| PostgreSQL `wcic.match_stats` | UPSERT ON CONFLICT (match_id) | Feature set computado |
| PostgreSQL `wcic.predictions` | INSERT | Previsão com probabilidades e justificativa |
| Redis `wcic:cache:prediction:{match_id}` | SET TTL=3600 | Cache da previsão para API |
| Redis `wcic:pub:predictions.new` | PUBLISH | Evento para consumers downstream |
| Redis `wcic:rl:wf05:openai` | INCR + EXPIRE 60s | Rate limit counter |
| PostgreSQL `wcic.workflow_logs` | INSERT | Log de execução |

---

## Fluxo Completo

```
Schedule Trigger (*/30 min)
  └─► Init
        [gera correlationId, startedAt, executionId]
        └─► Load Upcoming Matches
              [SELECT partidas scheduled nas próximas 2h sem prediction pre_match recente]
              └─► Check Upcoming Matches
                    └─► Has Matches? (IF)
                          │
                          ├─ FALSE ──► Log No Matches (reason: no_upcoming_matches)
                          │
                          └─ TRUE ───► Split by Match (batch=1)
                                          │
                                          ├─► Fetch Match Stats
                                          │     [CTE: home_form, away_form, h2h, tournament]
                                          │
                                          ├─► Fetch News Context
                                          │     [SELECT news_analysis com affected_team_ids]
                                          │     [das últimas 24h, ORDER BY impact_score DESC LIMIT 8]
                                          │
                                          ├─► Fetch Sentiment Context
                                          │     [SELECT sentiment_snapshots das últimas 6h por time]
                                          │
                                          └─► Aggregate Feature Set
                                                [Calcula form_pts, detecta injury news]
                                                [Organiza sentimento por team_id]
                                                [Calcula avg news impact por time]
                                                └─► Persist Match Stats
                                                      [UPSERT wcic.match_stats]
                                                      └─► Check OpenAI Rate Limit
                                                            [GET wcic:rl:wf05:openai]
                                                            └─► Rate Limit Decision
                                                                  [>= 20 → rate_limited]
                                                                  └─► Rate Limit Gate (IF)
                                                                        │
                                                                        ├─ LIMITED ──► Log Success [throttled]
                                                                        │
                                                                        └─ OK ────────► Call Match Predictor (SWF)
                                                                                          [waitForSubWorkflow: true]
                                                                                          └─► Increment Rate Limit
                                                                                                └─► Set RL TTL (60s)
                                                                                                      └─► Check Prediction Result
                                                                                                            [gpt_error? → skip]
                                                                                                            └─► Persist Prediction
                                                                                                                  [INSERT predictions]
                                                                                                                  └─► Cache Prediction (1h)
                                                                                                                        [SET wcic:cache:prediction:{id} TTL=3600]
                                                                                                                        └─► Publish Prediction Event
                                                                                                                              [PUBLISH wcic:pub:predictions.new]
                                                                                                                              └─► Log Success
```

---

## Dependências

| Dependência | Obrigatória | Impacto se ausente |
|---|---|---|
| Migration 008 aplicada | ✅ Sim | `match_stats`, `raw_gpt_response`, `brier_score` ausentes |
| `wcic.teams` populada (seeds) | ✅ Sim | JOIN falha |
| `wcic.matches` com partidas scheduled | ✅ Sim | Nenhuma partida elegível |
| SWF Match Predictor importado e ativo | ✅ Sim | `Call Match Predictor` lança exception |
| WF-03 executado recentemente | ⚠️ Recomendado | `news_context` vazio - previsão sem contexto de notícias |
| WF-04 executado recentemente | ⚠️ Recomendado | `sentiment_context` vazio - previsão sem dados de sentimento |
| Redis disponível | ✅ Sim | Cache e rate limiting desabilitados |
| Credencial `WCIC OpenAI` no n8n | ✅ Sim | SWF falha com HTTP 401 |

---

## Redis Utilizado

| Chave | Tipo | TTL | Propósito |
|---|---|---|---|
| `wcic:rl:wf05:openai` | STRING counter | 60s | Rate limit (max 20 previsões/min) |
| `wcic:cache:prediction:{match_id}` | STRING JSON | 3600s | Cache da previsão para API REST |
| `wcic:pub:predictions.new` | CHANNEL | - | Pub/Sub para consumers downstream |

---

## Tabelas Impactadas

| Tabela | Operação | Condição |
|---|---|---|
| `wcic.matches` | SELECT (múltiplos CTEs) | A cada execução |
| `wcic.news_analysis` | SELECT | A cada execução |
| `wcic.sentiment_snapshots` | SELECT | A cada execução |
| `wcic.match_stats` | UPSERT | Por partida elegível |
| `wcic.predictions` | INSERT | Por previsão gerada com sucesso |
| `wcic.workflow_logs` | INSERT | A cada execução |

---

## Estratégia de Retries

| Camada | Comportamento |
|---|---|
| GPT retornou erro | `persist=false`; próxima execução do cron (30min) tenta novamente |
| Rate limit OpenAI atingido | Partida skipada; próxima execução tentará (rate limit expirou em 60s) |
| PostgreSQL timeout | n8n retry nativo 3x, 5s interval |
| Previsão já existe (< 6h) | Query não retorna a partida - idempotência garantida pela query |

---

## Estratégia de Observabilidade

- **Correlation ID:** gerado no Init, propagado para o log
- **`match_stats`:** preserva o feature set exato usado na previsão para backtesting
- **`feature_snapshot` em `predictions`:** cópia JSON do stats no momento - auditoria completa
- **Redis Pub/Sub:** `wcic:pub:predictions.new` permite que outros sistemas consumam novas previsões em tempo real

---

## Métricas

| Métrica | Tipo | Fonte |
|---|---|---|
| `wcic_wf05_executions_total{status}` | Counter | `workflow_logs` |
| `wcic_wf05_predictions_generated_total` | Counter | `predictions WHERE prediction_type='pre_match'` |
| `wcic_wf05_avg_confidence` | Gauge | `AVG(confidence)` últimas 24h |
| `wcic_wf05_throttled_total` | Counter | Execuções sem previsão por rate limit |
| `wcic_wf05_openai_tokens_total` | Counter | `SUM(tokens_used)` em predictions |
| `wcic_wf05_matches_without_prediction` | Gauge | Jogos nas próximas 2h sem previsão |

---

## Possíveis Falhas

| Falha | Causa | Impacto | Detecção | Resolução |
|---|---|---|---|---|
| Nenhuma partida elegível | Copa não iniciada ou todas as partidas já têm previsão | Execução normal - log com reason | `workflow_logs.output_summary.reason = 'no_upcoming_matches'` | Verificar `matches.status` e janela de 2h |
| Stats vazios (sem histórico) | Times estreantes sem jogos no banco | Previsão gerada com `confidence` baixa | `match_stats.home_form = '{}'` | Aceitar - GPT calibra confidence automaticamente |
| Previsão duplicada | Race condition entre dois workers | ON CONFLICT não existe em predictions | Dois registros para o mesmo match | Adicionar UNIQUE (match_id, prediction_type) - item para migration 009 |
| Feature set de notícias vazio | WF-03 não rodou ou sem notícias | Previsão sem contexto de notícias | `news_context = []` no feature_snapshot | Garantir WF-03 ativo |

---

## Runbook Operacional

### Ver previsões geradas hoje

```sql
SELECT
  ht.name AS home, at.name AS away,
  p.home_win_prob, p.draw_prob, p.away_win_prob,
  p.predicted_home, p.predicted_away,
  p.confidence, m.scheduled_at
FROM wcic.predictions p
JOIN wcic.matches m ON m.id = p.match_id
JOIN wcic.teams ht ON ht.id = m.home_team_id
JOIN wcic.teams at ON at.id = m.away_team_id
WHERE p.prediction_type = 'pre_match'
  AND p.created_at > NOW() - INTERVAL '24 hours'
ORDER BY m.scheduled_at;
```

### Verificar cache de previsão

```bash
redis-cli -a $REDIS_PASSWORD GET "wcic:cache:prediction:{MATCH_UUID}"
```

### Forçar reprocessamento de um jogo (limpa cache)

```bash
redis-cli -a $REDIS_PASSWORD DEL "wcic:cache:prediction:{MATCH_UUID}"
# Marcar previsão existente como inválida no banco (opcional):
# UPDATE wcic.predictions SET confidence = 0 WHERE match_id = '{UUID}'::uuid;
```

### Verificar feature set de uma partida

```sql
SELECT home_form, away_form, h2h_home_wins, h2h_draws, h2h_away_wins,
       home_news_impact_avg, away_news_impact_avg, computed_at
FROM wcic.match_stats
WHERE match_id = '{UUID}'::uuid;
```

---

## Critérios de Sucesso

- Toda partida com `status='scheduled'` e `scheduled_at` dentro de 2h tem uma previsão `pre_match` gerada
- `wcic.match_stats` populada antes de cada previsão
- `feature_snapshot` em `predictions` contém dados quantitativos reais (não nulos)
- Cache Redis atualizado para cada previsão gerada
- `workflow_logs` registra 100% das execuções
- Zero previsões com `home_win_prob + draw_prob + away_win_prob` fora de `0.995..1.005`
