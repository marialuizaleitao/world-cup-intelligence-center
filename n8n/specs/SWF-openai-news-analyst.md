# SWF - OpenAI News Analyst

**Versão:** 1.0.0 | **Sprint:** 4 | **Status:** Produção  
**Arquivo:** `n8n/subworkflows/SWF-openai-news-analyst.json`  
**Nodes:** 5 | **Tipo:** Sub-workflow reutilizável  
**Callers:** WF-03 News Intelligence

---

## Objetivo

Agente GPT-4o especializado em análise de artigos jornalísticos sobre a Copa do Mundo 2026. Recebe o conteúdo bruto de um artigo e retorna um JSON estruturado com: resumo executivo, score de impacto, tipo de impacto, sentimento, insight principal, tags livres, tópicos estruturados, times e jogadores mencionados. É o único ponto de integração com a OpenAI API para análise de notícias no sistema.

---

## Trigger

| Parâmetro | Valor |
|---|---|
| Tipo | Execute Workflow Trigger |
| Chamadores | WF-03 (síncrono - `waitForSubWorkflow: true`) |
| Modo | Síncrono - caller aguarda retorno antes de prosseguir |

---

## Entradas

```typescript
{
  news_id:     string,   // UUID da wcic.news - obrigatório
  title:       string,   // Título do artigo - obrigatório
  description: string?,  // Lead/subtítulo
  content:     string?,  // Corpo do artigo (truncado em 3000 chars)
  source:      string,   // Nome da fonte (ESPN, BBC, etc.)
  language:    string,   // 'pt' | 'en' | 'es' | 'fr' - afeta idioma do resumo
  url:         string?,  // URL original para referência
}
```

---

## Saídas

### Sucesso

```typescript
{
  news_id:             string,   // Passthrough do input
  summary:             string,   // 2-3 frases no idioma da notícia
  impact_score:        number,   // 0.0 – 1.0
  impact_type:         string,   // tactical|injury|form|controversy|lineup|suspension|weather|other
  sentiment:           string,   // positive|negative|neutral|very_positive|very_negative
  key_insight:         string,   // Frase mais importante do artigo
  tags:                string[], // Palavras-chave livres
  topics:              string[], // Categorias estruturadas (injury, tactics, lineup...)
  affected_teams:      string[], // Nomes dos times mencionados
  affected_players:    string[], // Nomes dos jogadores mencionados
  relevance_to_wc2026: number,   // 0.0 – 1.0
  raw_gpt_response:    object,   // Resposta JSON completa do GPT (para auditoria)
  // Metadados de auditoria
  ai_model:        string,       // ex: 'gpt-4o-2024-08-06'
  prompt_version:  string,       // 'v1.0'
  tokens_used:     number,
  processing_ms:   number,
  finished_at:     string,       // ISO timestamp
}
```

### Erro GPT

```typescript
{
  news_id:       string,
  gpt_error:     true,
  error_message: string,
  processing_ms: number,
}
```

---

## Fluxo Completo

```
Execute Workflow Trigger
  └─► Prepare Prompt
        [Valida news_id e title - lança Error se ausentes]
        [Monta articleText: TÍTULO + RESUMO + CONTEÚDO (max 3000 chars)]
        [Constrói systemPrompt com critérios de scoring e JSON schema]
        [Instrução de idioma baseada em input.language]
        [Registra started_at]
        └─► Call OpenAI GPT-4o
              [POST https://api.openai.com/v1/chat/completions]
              [model: gpt-4o]
              [max_tokens: 800]
              [temperature: 0.2 - baixo para consistência de classificação]
              [response_format: { type: 'json_object' }]
              [timeout: 30.000ms]
              │
              ├─ SUCCESS ──► Parse GPT Response
              │               [Remove backticks markdown se presentes]
              │               [JSON.parse da resposta]
              │               [Valida campos obrigatórios: summary, impact_score, impact_type, sentiment, key_insight]
              │               [Sanitiza impact_score para [0.0, 1.0]]
              │               [Valida impact_type contra VALID_IMPACT_TYPES]
              │               [Valida sentiment contra VALID_SENTIMENTS]
              │               [Filtra topics contra VALID_TOPICS]
              │               [Calcula processing_ms]
              │               [Retorna objeto estruturado]
              │
              └─ ERROR ────► Handle GPT Error
                              [Loga erro com news_id no console]
                              [Retorna { gpt_error: true, error_message, processing_ms }]
```

---

## Dependências

| Dependência | Obrigatória | Impacto se ausente |
|---|---|---|
| Credencial `WCIC OpenAI` (openAiApi) no n8n | ✅ Sim | HTTP 401 na chamada GPT |
| `news_id` no payload de entrada | ✅ Sim | Throw no `Prepare Prompt` |
| `title` no payload de entrada | ✅ Sim | Throw no `Prepare Prompt` |

---

## Integrações Externas

### OpenAI API

- **Endpoint:** `POST https://api.openai.com/v1/chat/completions`
- **Autenticação:** Bearer token via credencial `WCIC OpenAI` (tipo `openAiApi`)
- **Modelo:** `gpt-4o`
- **Parâmetros críticos:**
  - `temperature: 0.2` - respostas consistentes e determinísticas para classificação
  - `max_tokens: 800` - suficiente para o JSON estruturado; controla custo
  - `response_format: { type: 'json_object' }` - força JSON puro; elimina markdown
- **Timeout:** 30.000ms
- **Custo estimado:** ~$0.01 por análise (800 tokens output × $0.0125/1K = $0.01)

---

## Redis Utilizado

Nenhum. O rate limiting é gerenciado pelo WF-03 caller antes de acionar este SWF.

---

## Tabelas Impactadas

Nenhuma. Este SWF apenas retorna dados - a persistência é responsabilidade do caller (WF-03).

---

## Prompt do Sistema (v1.0)

```
Você é um analista especializado em futebol da Copa do Mundo 2026.
Analise o artigo fornecido e retorne EXCLUSIVAMENTE um JSON válido conforme a estrutura abaixo.
Não adicione texto antes ou depois do JSON. Não use markdown. Retorne apenas JSON puro.
[Instrução de idioma]

{
  "summary": "resumo objetivo em 2-3 frases",
  "impact_score": <0.0 a 1.0>,
  "impact_type": "<tactical|injury|form|controversy|lineup|suspension|weather|other>",
  "sentiment": "<positive|negative|neutral|very_positive|very_negative>",
  "key_insight": "o insight mais importante em uma frase",
  "tags": ["palavras-chave livres"],
  "topics": ["<injury|suspension|lineup|tactics|controversy|transfer|performance|weather|venue|historical>"],
  "affected_teams": ["nomes dos times"],
  "affected_players": ["nomes dos jogadores"],
  "relevance_to_wc2026": <0.0 a 1.0>
}

Critérios de impact_score:
0.9-1.0: lesão de titular confirmada, expulsão, mudança de escalação oficial
0.7-0.8: mudança tática significativa, controvérsia séria, suspensão
0.5-0.6: declarações de treinador, análise tática, estatísticas relevantes
0.3-0.4: cobertura geral, histórico, curiosidades
0.0-0.2: conteúdo tangencialmente relacionado à Copa
```

---

## Estratégia de Retry

Este SWF não implementa retry interno. Se a chamada GPT falhar:
- O node `Handle GPT Error` retorna `{ gpt_error: true }` ao caller
- O WF-03 trata o erro marcando o artigo como `failed`
- Retry é responsabilidade da próxima execução do cron ou do WF-10

---

## Estratégia de Observabilidade

- `tokens_used` retornado no output → WF-03 persiste em `news_analysis.tokens_used`
- `processing_ms` calculado internamente → persiste em `news_analysis.processing_ms`
- `ai_model` capturado da resposta real (não hardcoded) → permite tracking de upgrades de modelo
- `prompt_version: 'v1.0'` → permite A/B testing e reprocessamento quando prompt muda
- `raw_gpt_response` preserva resposta completa → debugging quando parse falha

---

## Métricas

Métricas são expostas pelo caller WF-03 via `workflow_logs`. Este SWF não persiste logs próprios.

| Dado rastreável | Onde persiste |
|---|---|
| Tokens consumidos | `news_analysis.tokens_used` |
| Tempo de processamento | `news_analysis.processing_ms` |
| Modelo usado | `news_analysis.ai_model` |
| Versão do prompt | `news_analysis.prompt_version` |
| Erros GPT | `news.processing_status = 'failed'` |

---

## Possíveis Falhas

| Falha | Causa | Comportamento | Resolução |
|---|---|---|---|
| GPT retorna HTML de erro | OpenAI em manutenção | `Handle GPT Error` captura; caller marca `failed` | Aguardar disponibilidade da API |
| GPT ignora `json_object` mode | Bug raro em versões antigas | Parse falha; exception no node | Atualizar para versão recente do modelo |
| Campo obrigatório ausente na resposta | Prompt pouco claro | Exception no `Parse GPT Response` | Revisar prompt v1.0 → bump para v1.1 |
| `impact_score` fora de [0,1] | GPT retornou > 1.0 | Sanitizado automaticamente via `Math.min/Max` | Nenhuma ação necessária |
| `topics` contém valores inválidos | GPT inventou categoria | Filtrado contra `VALID_TOPICS` array | Nenhuma ação necessária |
| Timeout (> 30s) | OpenAI lento | `onError: continueErrorOutput` → `Handle GPT Error` | Verificar status.openai.com |

---

## Critérios de Sucesso

- ≥ 95% das chamadas retornam JSON válido com todos os campos obrigatórios
- `impact_score` sempre dentro de [0.0, 1.0]
- `sentiment` sempre um dos 5 valores válidos
- `processing_ms` médio < 5.000ms
- Zero exceções de parse em modo normal de operação
