# SWF - OpenAI Sentiment Analyst

**Versão:** 1.0.0 | **Sprint:** 4 | **Status:** Produção  
**Arquivo:** `n8n/subworkflows/SWF-openai-sentiment-analyst.json`  
**Nodes:** 5 | **Tipo:** Sub-workflow reutilizável  
**Callers:** WF-04 Sentiment Analyzer

---

## Objetivo

Agente GPT-4o especializado em análise de sentimento sobre times e jogadores de futebol. Recebe um array de textos (summaries de notícias ou posts de redes sociais) e retorna uma análise estruturada com ratios de sentimento, intensidade, tópicos em tendência e sinais incomuns. É o único ponto de integração com a OpenAI API para análise de sentimento no sistema.

---

## Trigger

| Parâmetro | Valor |
|---|---|
| Tipo | Execute Workflow Trigger |
| Chamadores | WF-04 (síncrono - `waitForSubWorkflow: true`) |
| Modo | Síncrono - caller aguarda retorno |

---

## Entradas

```typescript
{
  entity_type:  'team' | 'player' | 'match',  // obrigatório
  entity_id:    string,   // UUID da entidade - obrigatório
  entity_name:  string?,  // Nome para contexto no prompt
  source:       string,   // 'newsapi' | 'twitter' | 'reddit' | 'combined'
  language:     string,   // 'pt' | 'en' | 'es' - afeta idioma da análise
  posts: [                // array - mínimo 1 item - obrigatório
    {
      text:     string,   // Texto do post (truncado internamente a 200 chars)
      likes?:   number,
      shares?:  number,
      platform: string,   // 'newsapi' | 'twitter' | 'reddit'
    }
  ]
}
```

---

## Saídas

### Sucesso

```typescript
{
  entity_type:        string,   // Passthrough
  entity_id:          string,   // Passthrough
  entity_name:        string?,
  source:             string,
  positive_ratio:     number,   // 0.000 – 1.000 (3 casas decimais)
  negative_ratio:     number,   // 0.000 – 1.000
  neutral_ratio:      number,   // 0.000 – 1.000
  // soma dos 3 ratios = 1.000 (renormalizado automaticamente se divergir < 5%)
  dominant_sentiment: string,   // very_positive|positive|neutral|negative|very_negative
  intensity:          string,   // high|medium|low
  volume:             number,   // Número de posts analisados
  trending_topics:    string[], // Top 5 tópicos mencionados
  key_concerns:       string[], // Até 3 preocupações (se negativo)
  key_positives:      string[], // Até 3 pontos positivos (se positivo)
  ai_summary:         string,   // Análise narrativa em 2-3 frases
  unusual_signals:    string?,  // Padrão incomum ou null
  confidence:         number,   // 0.0 – 1.0 (< 0.5 se posts.length < 5)
  // Metadados de auditoria
  ai_model:           string,
  prompt_version:     string,   // 'v1.0'
  tokens_used:        number,
  processing_ms:      number,
}
```

### Erro GPT

```typescript
{
  gpt_error:     true,
  entity_id:     string,
  error_message: string,
}
```

---

## Fluxo Completo

```
Execute Workflow Trigger
  +-? Prepare Sentiment Prompt
        [Valida entity_type, entity_id - lança Error se ausentes]
        [Valida posts.length >= 1 - lança Error se vazio]
        [Formata posts: slice(0,50), trunca cada texto em 200 chars]
        [Adiciona contagem de likes ao texto formatado se disponível]
        [Constrói systemPrompt com regras de normalização e critérios de confidence]
        [Instrução de idioma de resposta]
        [Registra started_at]
        +-? Call OpenAI GPT-4o
              [POST https://api.openai.com/v1/chat/completions]
              [model: gpt-4o]
              [max_tokens: 600]
              [temperature: 0.1 - muito baixo para classificações numéricas estáveis]
              [response_format: { type: 'json_object' }]
              [timeout: 25.000ms]
              ¦
              +- SUCCESS --? Parse Sentiment Response
              ¦               [Remove backticks se presentes]
              ¦               [JSON.parse]
              ¦               [Extrai e valida ratios: pos, neg, neu cada em [0,1]]
              ¦               [Verifica soma: se |soma - 1.0| > 0.05 ? renormaliza]
              ¦               [toFixed(3) para precisão de 3 casas decimais]
              ¦               [Valida dominant_sentiment contra VALID_DOM_SENT]
              ¦               [Valida intensity contra VALID_INTENSITY]
              ¦               [Calcula processing_ms, tokens_used]
              ¦               [Retorna objeto estruturado]
              ¦
              +- ERROR ----? Handle GPT Error
                              [Loga com entity_id]
                              [Retorna { gpt_error: true, entity_id, error_message }]
```

---

## Dependências

| Dependência | Obrigatória | Impacto se ausente |
|---|---|---|
| Credencial `WCIC OpenAI` (openAiApi) no n8n | ? Sim | HTTP 401 |
| `entity_type` no payload | ? Sim | Throw no `Prepare Sentiment Prompt` |
| `entity_id` no payload | ? Sim | Throw no `Prepare Sentiment Prompt` |
| `posts` array não vazio | ? Sim | Throw no `Prepare Sentiment Prompt` |

---

## Integrações Externas

### OpenAI API

- **Endpoint:** `POST https://api.openai.com/v1/chat/completions`
- **Autenticação:** Bearer token via credencial `WCIC OpenAI`
- **Modelo:** `gpt-4o`
- **Parâmetros críticos:**
  - `temperature: 0.1` - mais baixo que o News Analyst; ratios numéricos requerem máxima estabilidade
  - `max_tokens: 600` - JSON de sentimento é menor que análise de notícia
  - `response_format: { type: 'json_object' }` - elimina markdown da resposta
- **Timeout:** 25.000ms
- **Custo estimado:** ~$0.007 por análise de entidade (600 tokens output)

---

## Redis Utilizado

Nenhum. Rate limiting gerenciado pelo WF-04 caller.

---

## Tabelas Impactadas

Nenhuma. Persistência é responsabilidade do WF-04.

---

## Prompt do Sistema (v1.0)

```
Você é um especialista em análise de sentimento de mídias sociais sobre futebol.
Analise os posts fornecidos sobre {entity_type} "{entity_name}" e retorne EXCLUSIVAMENTE um JSON válido.
Não adicione texto antes ou depois do JSON. Retorne apenas JSON puro.
[Instrução de idioma]

{
  "positive_ratio": <0.0 a 1.0>,
  "negative_ratio": <0.0 a 1.0>,
  "neutral_ratio": <0.0 a 1.0>,
  "dominant_sentiment": "<very_positive|positive|neutral|negative|very_negative>",
  "intensity": "<high|medium|low>",
  "trending_topics": ["array dos 5 tópicos mais mencionados"],
  "key_concerns": ["até 3 preocupações principais se sentimento negativo"],
  "key_positives": ["até 3 pontos positivos se sentimento positivo"],
  "ai_summary": "análise narrativa em 2-3 frases",
  "unusual_signals": "qualquer padrão incomum detectado, ou null",
  "confidence": <0.0 a 1.0>
}

REGRAS:
- positive_ratio + negative_ratio + neutral_ratio deve somar exatamente 1.0
- intensity=high se a maioria dos posts tem engajamento elevado ou linguagem forte
- Se volume de posts < 5, confidence deve ser < 0.5
- unusual_signals: detectar bots, coordenação, mudança abrupta de tom
```

---

## Estratégia de Retry

Mesmo padrão do SWF News Analyst: sem retry interno. Erros retornam `{ gpt_error: true }` para o caller tratar.

---

## Estratégia de Observabilidade

- `confidence < 0.5` indica análise de baixa qualidade (poucos posts) - caller pode optar por não persistir
- `unusual_signals != null` é sinalizado como alerta operacional pelo WF-04
- `tokens_used` e `processing_ms` persistidos pelo caller em `sentiment_snapshots`

---

## Possíveis Falhas

| Falha | Causa | Comportamento | Resolução |
|---|---|---|---|
| Ratios não somam 1.0 | GPT impreciso em arredondamento | Renormalização automática se delta < 5% | Nenhuma ação |
| Ratios somam muito diferente de 1.0 | Resposta malformada | Exception no parse | GPT retry na próxima execução |
| `dominant_sentiment` inválido | GPT usou valor não mapeado | Fallback para `'neutral'` | Nenhuma ação |
| Posts todos com texto vazio | Dados de entrada inválidos | Análise inútil (confidence ˜ 0) | Validar `posts[].text.length > 10` no WF-04 antes de chamar |
| Timeout > 25s | OpenAI lento | `Handle GPT Error` retorna erro | Verificar status.openai.com |

---

## Critérios de Sucesso

- Ratios sempre somam 1.000 (após renormalização se necessário)
- `dominant_sentiment` sempre um dos 5 valores válidos
- `confidence` reflete corretamente o volume: `< 0.5` quando `posts.length < 5`
- `processing_ms` médio < 4.000ms
- = 95% das chamadas retornam JSON válido
