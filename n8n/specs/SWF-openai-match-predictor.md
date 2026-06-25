# SWF - OpenAI Match Predictor

**Versão:** 1.0.0 | **Sprint:** 5 | **Status:** Produção  
**Arquivo:** `n8n/subworkflows/SWF-openai-match-predictor.json`  
**Nodes:** 5 | **Tipo:** Sub-workflow síncrono  
**Caller:** WF-05 AI Prediction Engine

---

## Objetivo

Agente GPT-4o especializado em previsão probabilística de partidas da Copa do Mundo 2026. Recebe um feature set completo (forma recente, H2H, estatísticas do torneio, notícias, sentimento) e retorna probabilidades calibradas para os três outcomes possíveis (home/draw/away), placar previsto, nível de confiança e justificativa auditável em texto.

---

## Trigger

| Parâmetro | Valor |
|---|---|
| Tipo | Execute Workflow Trigger |
| Chamador | WF-05 (síncrono - `waitForSubWorkflow: true`) |

---

## Entradas

```typescript
{
  match_id:      string,        // UUID - obrigatório
  home_team:     string,        // Nome do time da casa - obrigatório
  away_team:     string,        // Nome do time visitante - obrigatório
  stage?:        string,        // "group_a" | "quarter_final" | etc.
  scheduled_at?: string,        // ISO timestamp da partida
  stats: {                      // Objeto match_stats do banco
    home_form:              string[],   // ['W','D','L','W','W']
    away_form:              string[],
    home_form_pts:          number,
    away_form_pts:          number,
    home_goals_scored_avg:  number,
    home_goals_conceded_avg: number,
    away_goals_scored_avg:  number,
    away_goals_conceded_avg: number,
    h2h_home_wins:          number,
    h2h_draws:              number,
    h2h_away_wins:          number,
    h2h_home_goals_avg:     number,
    h2h_away_goals_avg:     number,
    home_goals_in_tournament:   number,
    home_matches_in_tournament: number,
    away_goals_in_tournament:   number,
    away_matches_in_tournament: number,
    home_has_injury_news:   boolean,
    away_has_injury_news:   boolean,
    home_suspended_count:   number,
    away_suspended_count:   number,
    home_sentiment_score?:  number,
    away_sentiment_score?:  number,
  },
  news_context?: Array<{
    key_insight: string,
    impact_score: number,
    source: string,
    title: string,
  }>,
  sentiment_context?: {
    home?: { positive_ratio, negative_ratio, dominant_sentiment },
    away?: { positive_ratio, negative_ratio, dominant_sentiment },
  }
}
```

---

## Saídas

### Sucesso

```typescript
{
  match_id:              string,
  home_win_prob:         number,   // 0.000 – 1.000 (renormalizado para somar 1.000)
  draw_prob:             number,
  away_win_prob:         number,
  predicted_home_score:  number,   // 0 – 9
  predicted_away_score:  number,
  confidence:            number,   // 0.00 – 1.00
  key_factors:           string[], // 3 fatores principais
  risk_factors:          string[], // 1-3 riscos de incerteza
  justification:         string,   // Mínimo 20 chars - análise narrativa
  over_under_2_5:        'over' | 'under' | null,
  both_teams_score:      boolean | null,
  raw_gpt_response:      object,   // JSON completo do GPT
  ai_model:              string,
  prompt_version:        string,   // 'v1.0'
  tokens_used:           number,
  processing_ms:         number,
  finished_at:           string,
}
```

### Erro GPT

```typescript
{
  gpt_error:     true,
  match_id:      string,
  error_message: string,
  processing_ms: number,
}
```

---

## Fluxo Completo

```
Execute Workflow Trigger
  └─► Prepare Predictor Prompt
        [Valida match_id, home_team, away_team]
        [Formata forma recente como string: 'WWDLW']
        [Formata notícias por impacto (max 5)]
        [Formata sentimento de ambos os times]
        [Constrói systemPrompt com regras de calibração]
        [Constrói userContent com todos os dados quantitativos]
        └─► Call OpenAI GPT-4o
              [POST /v1/chat/completions]
              [model: gpt-4o, temp: 0.15, max_tokens: 1000]
              [response_format: json_object]
              [timeout: 35.000ms]
              │
              ├─ SUCCESS ──► Parse Prediction
              │               [Parse JSON, remove markdown]
              │               [Extrai home/draw/away probs]
              │               [Normaliza para somar 1.000 exato]
              │               [Aplica floor 0.001 e ceil 0.998 por prob]
              │               [Valida justification.length >= 20]
              │               [Clamp predicted scores [0,9]]
              │               [Retorna objeto estruturado]
              │
              └─ ERROR ────► Handle GPT Error
                              [Retorna { gpt_error: true }]
```

---

## Dependências

| Dependência | Obrigatória | Impacto se ausente |
|---|---|---|
| Credencial `WCIC OpenAI` no n8n | ✅ Sim | HTTP 401 |
| `match_id` no payload | ✅ Sim | Exception |
| `home_team` e `away_team` no payload | ✅ Sim | Exception |

---

## Integrações Externas

### OpenAI GPT-4o

- **Temperatura:** 0.15 - muito baixa para estabilidade de probabilidades numéricas
- **max_tokens:** 1000 - maior que os outros SWFs porque justification é mais longa
- **Custo estimado:** ~$0.015 por previsão (1000 tokens output)

---

## Prompt do Sistema (v1.0)

```
Você é um estatístico esportivo especializado em previsão de resultados de Copa do Mundo.
[Schema JSON obrigatório com todos os campos]

REGRAS OBRIGATÓRIAS:
- home_win_prob + draw_prob + away_win_prob = 1.000 (exatamente)
- confidence < 0.40 se dados históricos insuficientes (< 3 jogos)
- confidence < 0.50 se lesões/suspensões críticas de titulares
- Justificativa deve citar ao menos 2 fatores quantitativos dos dados
- NÃO fabricar estatísticas não presentes nos dados
```

---

## Renormalização de Probabilidades

O node `Parse Prediction` aplica renormalização em duas etapas:

1. **Floor/Ceil individual:** cada prob é clamped para [0.001, 0.998] - evita 0% ou 100%
2. **Divisão pelo total:** `p_i / (p_home + p_draw + p_away)` - garante soma = 1.0
3. **Ajuste de floating point:** `away = 1.0 - home - draw` em toFixed(3) - elimina erros de arredondamento

Se após normalização `|soma - 1.0| > 0.004` → exceção (resposta inutilizável).

---

## Possíveis Falhas

| Falha | Causa | Comportamento | Resolução |
|---|---|---|---|
| GPT retorna probs que somam 0 | Erro de formato | Exception no parse | Retry na próxima execução do WF-05 |
| Justification com < 20 chars | GPT deu resposta truncada | Exception intencional | Verificar max_tokens |
| Timeout > 35s | OpenAI lento | `Handle GPT Error` | Verificar status.openai.com |
| Probabilidade > 1.0 | GPT usou %, não decimal | Renormalização corrige automaticamente | Nenhuma ação |

---

## Critérios de Sucesso

- `home_win_prob + draw_prob + away_win_prob = 1.000` em 100% das previsões
- `confidence` sempre em [0.00, 1.00]
- `justification.length >= 50` chars na média
- `processing_ms` < 10.000ms em p95
- ≥ 95% de chamadas retornam sem `gpt_error`
