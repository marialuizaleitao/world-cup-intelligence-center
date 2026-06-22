# WF-03 - News Intelligence

**Versão:** 1.0.0 | **Sprint:** 4 | **Status:** Produção  
**Arquivo:** `n8n/workflows/WF-03-news-intelligence.json`  
**Nodes:** 30 | **Conexões:** 28  
**Sub-workflow:** `SWF - OpenAI News Analyst`

---

## Objetivo

Coletar artigos de notícias esportivas relacionadas à Copa do Mundo 2026 a partir de múltiplas fontes (NewsAPI + feeds RSS multilíngues), deduplicar por URL hash, persistir na tabela `wcic.news` e acionar o agente GPT-4o para análise de impacto, classificação temática e extração de entidades. Artigos com `impact_score >= 0.7` disparam notificação via WF-07.

---

## Trigger

| Parâmetro | Valor |
|---|---|
| Tipo | Cron Schedule |
| Expressão | `*/15 * * * *` (a cada 15 minutos) |
| Timezone | `America/Sao_Paulo` |
| Concorrência | Queue Mode - múltiplos artigos processados em paralelo por workers |

---

## Entradas

| Fonte | Tipo | Dado |
|---|---|---|
| PostgreSQL `wcic.news_sources` | SELECT | Lista de fontes ativas com URL, tipo e configuração |
| NewsAPI v2 | `GET /v2/everything` | Artigos por query template (`FIFA World Cup 2026`) |
| RSS Feeds | HTTP GET + parse XML→JSON | Artigos de ESPN, BBC Sport, UOL Esporte, L'Équipe |
| Redis SET `wcic:dedup:news` | SMEMBERS | Hashes de URLs já processadas (TTL 7 dias) |
| Redis `wcic:rl:wf03:openai` | GET | Contador de chamadas OpenAI no minuto atual |

---

## Saídas

| Destino | Operação | Dado |
|---|---|---|
| PostgreSQL `wcic.news` | INSERT ON CONFLICT (url_hash) DO NOTHING | Artigo normalizado |
| PostgreSQL `wcic.news_analysis` | INSERT ON CONFLICT (news_id) DO UPDATE | Análise GPT estruturada |
| PostgreSQL `wcic.news` | UPDATE `processing_status` | `processed` ou `failed` após análise |
| Redis SET `wcic:dedup:news` | SADD + EXPIRE 7d | URL hash marcado como processado |
| Redis LIST `wcic:queue:news_analysis` | RPUSH | Artigos enfileirados quando rate limit OpenAI atingido |
| Redis `wcic:rl:wf03:openai` | INCR + EXPIRE 60s | Contador de rate limit |
| WF-07 | Execute Workflow (async) | Alerta de notícia de alto impacto (score ≥ 0.7) |
| PostgreSQL `wcic.workflow_logs` | INSERT | Log de cada execução com correlation_id |

---

## Fluxo Completo

```
Schedule Trigger (*/15 min)
  └─► Init
        [gera correlationId UUID, startedAt, executionId]
        └─► Load Active Sources
              [SELECT * FROM wcic.news_sources WHERE is_active=true ORDER BY priority DESC]
              └─► Split by Source (batch=1 - processa fonte por fonte)
                    └─► Route by Source Type (IF: source_type = 'newsapi')
                          │
                          ├─ newsapi ──► Fetch NewsAPI
                          │              [GET /v2/everything?q={query_template}&language={lang}]
                          │              │
                          │              ├─ OK ──► Normalize NewsAPI Articles
                          │              │          [Mapeia campos, gera url_hash via Buffer hex]
                          │              └─ ERR ─► [continueErrorOutput - fonte pulada silenciosamente]
                          │
                          └─ rss ──────► Fetch RSS Feed
                                          [GET feed URL, n8n converte XML→JSON automaticamente]
                                          │
                                          ├─ OK ──► Normalize RSS Articles
                                          │          [Limpa tags HTML, extrai campos, gera url_hash]
                                          └─ ERR ─► [continueErrorOutput]

[Após normalização de qualquer fonte]
  └─► Get Dedup Set
        [SMEMBERS wcic:dedup:news - set completo de hashes processados]
        └─► Deduplicate Articles
              [Filtra artigos cujo url_hash já está no SET Redis]
              [Remove duplicatas internas no batch (mesmo url_hash)]
              └─► Insert News (por artigo)
                    [INSERT INTO wcic.news ON CONFLICT (url_hash) DO NOTHING]
                    └─► Post Insert Check
                          [was_inserted = (RETURNING retornou linha)]
                          └─► Mark as Processed
                                [SADD wcic:dedup:news {url_hash}]
                                └─► Set Dedup TTL (7 days)
                                      [EXPIRE wcic:dedup:news 604800]
                                      └─► Should Analyze? (IF: should_analyze=true)
                                            │
                                            ├─ FALSE ─► Log Success [skip]
                                            │
                                            └─ TRUE ──► Check OpenAI Rate Limit
                                                          [GET wcic:rl:wf03:openai]
                                                          └─► Rate Limit Decision
                                                                [current >= 50 → rate_limited=true]
                                                                └─► Rate Limit Gate (IF)
                                                                      │
                                                                      ├─ LIMITED ──► Queue for Later Analysis
                                                                      │               [RPUSH wcic:queue:news_analysis]
                                                                      │
                                                                      └─ OK ────────► Call News Analyst (SWF)
                                                                                        [waitForSubWorkflow: true]
                                                                                        └─► Increment Rate Limit
                                                                                              [INCR wcic:rl:wf03:openai]
                                                                                              └─► Set RL TTL (60s)
                                                                                                    └─► Check Analysis Result
                                                                                                          [gpt_error? → persist=false]
                                                                                                          └─► Persist Analysis
                                                                                                                [INSERT/UPDATE news_analysis]
                                                                                                                └─► Update News Status
                                                                                                                      [UPDATE news SET processing_status=...]
                                                                                                                      └─► High Impact?
                                                                                                                            [impact_score >= 0.7]
                                                                                                                            └─► Should Notify? (IF)
                                                                                                                                  │
                                                                                                                                  ├─ TRUE ──► Call WF-07 (async)
                                                                                                                                  └─► Log Success
```

---

## Dependências

| Dependência | Obrigatória | Impacto se ausente |
|---|---|---|
| `wcic.news` (migration 001) | ✅ Sim | INSERT falha |
| `wcic.news_analysis` (migration 001) | ✅ Sim | Análise não persiste |
| `wcic.news_sources` (migration 007) | ✅ Sim | Nenhuma fonte carregada → zero artigos |
| Coluna `topics` em `news_analysis` (migration 007) | ✅ Sim | INSERT falha (campo NOT NULL via array) |
| Coluna `raw_gpt_response` em `news_analysis` (migration 007) | ✅ Sim | INSERT falha |
| Índice `idx_news_pending_analysis` (migration 007) | ⚠️ Perf | Sem índice, queries de pendentes são full scan |
| SWF News Analyst importado e ativo | ✅ Sim | `Call News Analyst` lança exceção |
| WF-07 importado e ativo | ⚠️ Notif | Notificações de alto impacto silenciosas |
| `NEWSAPI_KEY` configurado no n8n ou `.env` | ✅ Para NewsAPI | Fontes NewsAPI retornam 401 |
| Redis disponível | ✅ Sim | Deduplicação e rate limiting desabilitados; duplicatas possíveis |

---

## Integrações Externas

### NewsAPI v2

- **Endpoint:** `GET https://newsapi.org/v2/everything`
- **Autenticação:** Query param `apiKey` (referenciado de `$env.NEWSAPI_KEY`)
- **Plano free:** 100 req/dia - WF-03 executa 96x/dia; usar com moderação
- **Parâmetros:** `q`, `language`, `sortBy=publishedAt`, `pageSize=20`
- **Retorno:** `{ articles: [{ title, url, description, content, author, publishedAt }] }`

### RSS Feeds (ESPN, BBC, UOL, L'Équipe)

- **Formato:** XML convertido automaticamente para JSON pelo n8n HTTP Request
- **Sem autenticação** - feeds públicos
- **Estrutura variável por fonte** - `Normalize RSS Articles` trata os casos: `items`, `channel.item`, `rss.channel.item`

---

## Redis Utilizado

| Chave | Tipo | TTL | Propósito |
|---|---|---|---|
| `wcic:dedup:news` | SET | 7 dias | URLs já processadas - bloom filter |
| `wcic:rl:wf03:openai` | STRING (counter) | 60s | Rate limiting OpenAI (max 50/min) |
| `wcic:queue:news_analysis` | LIST | sem TTL | Fila de artigos quando rate limit atingido |

---

## Tabelas Impactadas

| Tabela | Operação | Condição |
|---|---|---|
| `wcic.news_sources` | SELECT | A cada execução |
| `wcic.news` | INSERT ON CONFLICT DO NOTHING | Por artigo novo |
| `wcic.news` | UPDATE `processing_status` | Após análise GPT |
| `wcic.news_analysis` | INSERT ON CONFLICT DO UPDATE | Por artigo analisado com sucesso |
| `wcic.workflow_logs` | INSERT | A cada execução |

---

## Estratégia de Retry

| Camada | Comportamento |
|---|---|
| Falha de fonte HTTP (NewsAPI/RSS) | `onError: continueErrorOutput` - fonte pulada, outras continuam |
| Rate limit OpenAI atingido | Artigo vai para `wcic:queue:news_analysis` - processado pelo WF-10 (Sprint 6) |
| GPT retornou erro | `processing_status = 'failed'`; artigo reenfileirado se for retry manual |
| GPT retornou JSON inválido | SWF lança exception → `processing_status = 'failed'` |
| PostgreSQL timeout | n8n retry nativo (3x, 5s interval) no node de INSERT |

Não há retry em loop dentro da execução. A resiliência vem da fila Redis e da próxima execução do cron em 15 min.

---

## Estratégia de Observabilidade

- **Correlation ID:** UUID gerado no Init, propagado para SWF e WF-07
- **Log por execução:** INSERT em `wcic.workflow_logs` com `items_processed = count(new articles)`
- **Status do artigo:** `wcic.news.processing_status` reflete cada etapa: `pending → processing → processed | failed`
- **Rate limit visível:** Redis key `wcic:rl:wf03:openai` monitorável via Redis Exporter
- **Fila de backlog:** `LLEN wcic:queue:news_analysis` como métrica de lag

---

## Métricas

| Métrica | Tipo | Fonte |
|---|---|---|
| `wcic_wf03_executions_total{status}` | Counter | `workflow_logs` |
| `wcic_wf03_articles_collected_total{source}` | Counter | `news` por `source` |
| `wcic_wf03_articles_deduplicated_total` | Counter | Diferença entre coletados e inseridos |
| `wcic_wf03_articles_analyzed_total{status}` | Counter | `news` por `processing_status` |
| `wcic_wf03_high_impact_total` | Counter | `news_analysis WHERE impact_score >= 0.7` |
| `wcic_wf03_openai_rl_queue_depth` | Gauge | `LLEN wcic:queue:news_analysis` |
| `wcic_wf03_avg_impact_score` | Gauge | `AVG(impact_score)` nas últimas 24h |

---

## Possíveis Falhas

| Falha | Causa | Impacto | Detecção | Resolução |
|---|---|---|---|---|
| NewsAPI 429 | 100 req/dia esgotados | Fonte NewsAPI fora por ~24h | `news_sources.last_fetched_at` + logs de erro | Reduzir frequência de cron ou upgrade de plano |
| RSS feed mudou estrutura | Provedor alterou XML | Artigos não normalizados (array vazio) | `items_processed = 0` no log | Atualizar node `Normalize RSS Articles` |
| GPT retorna HTML em vez de JSON | Resposta de erro do OpenAI | Parse falha, artigo marcado `failed` | `processing_error` em `news` | Verificar status da OpenAI API |
| `affected_team_ids` vazio sempre | Times sem match por nome | Análise sem FK para teams | SELECT de `news_analysis WHERE affected_team_ids = '{}'` | Melhorar matching no node `Persist Analysis` (usar pg `similarity()`) |
| Dedup set Redis muito grande | 7 dias de URLs acumuladas | Consumo de memória Redis | `SCARD wcic:dedup:news` | Reduzir TTL ou usar Bloom Filter dedicado |
| `news_sources` vazia | Seed da migration 007 não rodou | Zero artigos coletados | `items_processed = 0` em todo log | `./scripts/setup-database.sh` |

---

## Runbook Operacional

### Verificar artigos nas últimas 2 horas

```sql
SELECT source, processing_status, COUNT(*)
FROM wcic.news
WHERE created_at > NOW() - INTERVAL '2 hours'
GROUP BY source, processing_status
ORDER BY COUNT(*) DESC;
```

### Ver artigos de alto impacto hoje

```sql
SELECT n.title, n.source, na.impact_score, na.impact_type, na.key_insight
FROM wcic.news n
JOIN wcic.news_analysis na ON na.news_id = n.id
WHERE na.impact_score >= 0.7 AND n.created_at > NOW() - INTERVAL '24 hours'
ORDER BY na.impact_score DESC;
```

### Verificar backlog de análise pendente

```bash
redis-cli -a $REDIS_PASSWORD LLEN wcic:queue:news_analysis
# Processar manualmente 1 item do backlog:
redis-cli -a $REDIS_PASSWORD LPOP wcic:queue:news_analysis
```

### Forçar reprocessamento de artigos com falha

```sql
UPDATE wcic.news SET processing_status = 'pending' WHERE processing_status = 'failed';
```

### Resetar deduplicação (usar com cautela)

```bash
redis-cli -a $REDIS_PASSWORD DEL wcic:dedup:news
# Próxima execução reprocessará todos os artigos dos últimos 7 dias
```

---

## Critérios de Sucesso

- `wcic.news` recebe ≥ 5 novos artigos por execução durante a Copa
- `wcic.news_analysis` contém análise para ≥ 90% dos artigos inseridos
- Zero artigos com `url_hash` duplicado na tabela `news`
- Artigos com `impact_score >= 0.7` geram entrada em `wcic.notifications` via WF-07
- `workflow_logs` registra 100% das execuções
- Rate limit OpenAI não excede 50 chamadas/minuto (monitorado via Redis)
