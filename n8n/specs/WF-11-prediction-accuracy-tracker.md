# WF-11 - Prediction Accuracy Tracker

**Versão:** 1.0.0 | **Sprint:** 5 | **Status:** Produção  
**Arquivo:** `n8n/workflows/WF-11-prediction-accuracy-tracker.json`  
**Nodes:** 16 | **Conexões:** 14

---

## Objetivo

Avaliar retroativamente todas as previsões geradas pelo WF-05 que ainda não foram pontuadas, calcular métricas de accuracy (acerto binário + Brier Score contínuo) e agregar resultados por dia, estágio e seleção na tabela `wcic.prediction_accuracy`. É o componente de feedback loop do sistema preditivo - sem ele, não há como medir a qualidade do modelo ao longo da Copa.

---

## Trigger

| Parâmetro | Valor |
|---|---|
| Tipo | Cron Schedule |
| Expressão | `*/10 * * * *` (a cada 10 minutos) |
| Timezone | `America/Sao_Paulo` |
| Motivo da frequência | Partidas terminam a qualquer hora; 10min garante avaliação rápida pós-jogo |

---

## Entradas

| Fonte | Operação | Dado |
|---|---|---|
| PostgreSQL `wcic.predictions` JOIN `wcic.matches` | SELECT | Previsões `pre_match` com `was_correct IS NULL` para partidas `finished` |
| Resultado calculado internamente | Código JavaScript | Brier Score e accuracy_score derivados das probabilidades e do resultado real |

---

## Saídas

| Destino | Operação | Dado |
|---|---|---|
| PostgreSQL `wcic.predictions` | UPDATE | `actual_outcome`, `was_correct`, `brier_score`, `accuracy_score`, `actual_home_score`, `actual_away_score` |
| PostgreSQL `wcic.prediction_accuracy` | UPSERT por `period_type='daily'` | Métricas agregadas por dia |
| PostgreSQL `wcic.prediction_accuracy` | UPSERT por `period_type='stage'` | Métricas agregadas por fase |
| PostgreSQL `wcic.prediction_accuracy` | UPSERT por `period_type='team'` | Métricas por seleção (home + away separados) |
| Redis `wcic:cache:accuracy:overall` | SET TTL=600 | Invalida cache do dashboard após atualização |
| PostgreSQL `wcic.workflow_logs` | INSERT | Log de execução |

---

## Fluxo Completo

```
Schedule Trigger (*/10 min)
  └─► Init
        [gera correlationId, startedAt, executionId]
        └─► Load Pending Evaluations
              [SELECT predictions WHERE was_correct IS NULL
               AND matches.status = 'finished'
               AND home_score IS NOT NULL
               LIMIT 50]
              └─► Check Pending
                    └─► Has Pending? (IF)
                          │
                          ├─ FALSE ──► Log No Pending (reason: no_pending_evaluations)
                          │
                          └─ TRUE ───► Split by Prediction (batch=1)
                                          └─► Calculate Accuracy Metrics
                                                [Determina actual_outcome: home|draw|away]
                                                [Determina predicted_outcome: argmax(probs)]
                                                [was_correct = predicted == actual]
                                                [Brier Score = Σ(p_i - I_i)²]
                                                [accuracy_score = 1 - BS/2]
                                                [Se actual_outcome é NULL → skip=true]
                                                └─► Skip? (IF)
                                                      │
                                                      ├─ TRUE ──► Log Success [skipped]
                                                      │
                                                      └─ FALSE ─► Update Prediction
                                                                    [UPDATE predictions SET
                                                                     actual_outcome, was_correct,
                                                                     brier_score, accuracy_score,
                                                                     actual_home_score, actual_away_score]
                                                                    └─► Upsert Daily Accuracy
                                                                          [INSERT/UPDATE prediction_accuracy
                                                                           period_type='daily']
                                                                          └─► Upsert Stage Accuracy
                                                                                [INSERT/UPDATE por stage]
                                                                                └─► Upsert Home Team Accuracy
                                                                                │     [INSERT/UPDATE por time home]
                                                                                └─► Upsert Away Team Accuracy
                                                                                      [INSERT/UPDATE por time away]
                                                                                      └─► Invalidate Accuracy Cache
                                                                                            [SET wcic:cache:accuracy:overall TTL=600]
                                                                                            └─► Log Success
```

---

## Cálculo de Métricas

### Brier Score

```
BS = (p_home - I_home)² + (p_draw - I_draw)² + (p_away - I_away)²

Onde I_outcome = 1 se aquele outcome ocorreu, 0 caso contrário

Exemplo: previsão home=0.60, draw=0.25, away=0.15 → jogo terminou home win
  BS = (0.60-1)² + (0.25-0)² + (0.15-0)²
     = 0.16 + 0.0625 + 0.0225
     = 0.245 ← bom (quanto menor, melhor)

Range: [0.0, 2.0]
  0.000 = previsão perfeita (100% de certeza no outcome correto)
  0.667 = modelo "honesto" sem informação (33.3% para cada outcome)
  2.000 = pior caso (100% de certeza no outcome errado)
```

### Accuracy Score (contínuo)

```
accuracy_score = 1 - brier_score / 2

Range: [0.0, 1.0]
  1.00 = BS=0 (perfeito)
  0.67 = BS=0.667 (sem informação)
  0.00 = BS=2 (pior caso)
```

### Predicted Outcome (para was_correct binário)

```
predicted_outcome = argmax(home_win_prob, draw_prob, away_win_prob)
was_correct = (predicted_outcome == actual_outcome)
```

---

## Dependências

| Dependência | Obrigatória | Impacto se ausente |
|---|---|---|
| Migration 008 aplicada | ✅ Sim | Colunas `brier_score`, `actual_home_score`, `brier_score_avg`, `team_id` ausentes em predictions/prediction_accuracy |
| WF-05 executado com previsões geradas | ✅ Sim | Sem `predictions` com `was_correct IS NULL` → sempre `no_pending` |
| `wcic.matches` com `status='finished'` e placar | ✅ Sim | JOIN retorna vazio |
| Constraint `prediction_accuracy_unique` (migration 008) | ✅ Sim | UPSERT falha sem a constraint |
| Redis disponível | ⚠️ Degradável | Cache não invalidado - aceitar; dados do banco estão corretos |

---

## Redis Utilizado

| Chave | Tipo | TTL | Propósito |
|---|---|---|---|
| `wcic:cache:accuracy:overall` | STRING JSON | 600s | Sinaliza ao dashboard que há novos dados de accuracy |

O WF-11 **não lê** do Redis - apenas escreve para invalidar o cache do dashboard.

---

## Tabelas Impactadas

| Tabela | Operação | Volume estimado |
|---|---|---|
| `wcic.predictions` | SELECT | Até 50 por execução |
| `wcic.predictions` | UPDATE | 1 por previsão avaliada |
| `wcic.prediction_accuracy` | UPSERT (3 registros por previsão: daily + stage + 2 teams) | ~4 por partida avaliada |
| `wcic.workflow_logs` | INSERT | 1 por execução |

---

## Estratégia de Retries

| Camada | Comportamento |
|---|---|
| Partida sem `actual_outcome` determinável | `skip=true` no Calculate - sem UPDATE; tentará novamente em 10min |
| PostgreSQL timeout no UPDATE | n8n retry nativo 3x, 5s interval |
| UPSERT de accuracy com constraint violation | ON CONFLICT DO UPDATE garante idempotência - safe para reexecução |
| Execução interrompida no meio | Próxima execução processa as restantes (LIMIT 50 prioriza mais recentes) |

---

## Estratégia de Observabilidade

- **Idempotência:** `was_correct IS NULL` na query inicial garante que cada previsão é avaliada exatamente uma vez
- **UPSERT de accuracy:** ON CONFLICT recalcula com todos os dados do período - sem drift acumulado
- **Cache invalidation:** `wcic:cache:accuracy:overall` é atualizado após cada avaliação - dashboard sempre reflete estado atual

---

## Métricas

| Métrica | Tipo | Fonte |
|---|---|---|
| `wcic_wf11_executions_total{status}` | Counter | `workflow_logs` |
| `wcic_wf11_predictions_evaluated_total` | Counter | `predictions WHERE was_correct IS NOT NULL` |
| `wcic_overall_accuracy_pct` | Gauge | `prediction_accuracy WHERE period_type='overall'` |
| `wcic_overall_brier_score` | Gauge | `AVG(brier_score) FROM predictions` |
| `wcic_accuracy_by_stage{stage}` | Gauge | `prediction_accuracy WHERE period_type='stage'` |

---

## Possíveis Falhas

| Falha | Causa | Impacto | Detecção | Resolução |
|---|---|---|---|---|
| `actual_outcome IS NULL` para partida finished | Empate em fase eliminatória (sem empate permitido) | skip correto - aceitar | `skip=true` no log | WF-01 deve atualizar `winner_team_id` corretamente em prorrogação |
| `prediction_accuracy_unique` violation | Migration 008 não aplicada | UPSERT falha com exception | Erro no `workflow_logs` | Aplicar migration 008 |
| Avaliação de previsões com placar parcial | `home_score` preenchido mas jogo ainda em andamento | `was_correct` calculado com placar errado | `matches.status != 'finished'` - query exclui corretamente | Garantir WF-01 atualiza status para `finished` ao fim do jogo |
| LIMIT 50 não processa todas as pendentes | Muitas partidas terminaram ao mesmo tempo | Avaliações atrasadas | Crescimento de `predictions WHERE was_correct IS NULL` | O cron de 10min garante processamento gradual; aceitar |

---

## Runbook Operacional

### Ver accuracy geral

```sql
SELECT period_type, period_label, total_predictions, correct_predictions,
       accuracy_pct, avg_confidence, brier_score_avg
FROM wcic.prediction_accuracy
WHERE prediction_type = 'pre_match' AND team_id IS NULL
ORDER BY period_type, calculated_at DESC;
```

### Ver accuracy por seleção

```sql
SELECT t.name AS team, pa.total_predictions, pa.correct_predictions,
       pa.accuracy_pct, pa.brier_score_avg
FROM wcic.prediction_accuracy pa
JOIN wcic.teams t ON t.id = pa.team_id
WHERE pa.period_type = 'team'
ORDER BY pa.accuracy_pct DESC NULLS LAST;
```

### Ver previsões pendentes de avaliação

```sql
SELECT COUNT(*) AS pending
FROM wcic.predictions p
JOIN wcic.matches m ON m.id = p.match_id
WHERE p.was_correct IS NULL
  AND m.status = 'finished'
  AND m.home_score IS NOT NULL;
```

### Forçar reavaliação de uma previsão (correção manual)

```sql
-- Reseta para reavaliação
UPDATE wcic.predictions
SET was_correct = NULL, brier_score = NULL, accuracy_score = NULL
WHERE id = '{UUID}'::uuid;
-- Próxima execução do WF-11 reavaliará automaticamente
```

---

## Critérios de Sucesso

- `predictions.was_correct IS NULL` = 0 para todas as partidas `finished` após 20 minutos do fim do jogo
- `prediction_accuracy` contém 1 registro `daily` por dia com jogos
- `prediction_accuracy` contém 1 registro `stage` por fase do torneio
- `brier_score` calculado corretamente: `SUM(probs) = 1.000` implica `BS ∈ [0, 2]`
- `workflow_logs` registra 100% das execuções
