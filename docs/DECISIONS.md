# Architecture Decision Records (ADR)

**Projeto:** World Cup Intelligence Center (WCIC)  
**Formato:** Baseado em [Michael Nygard's ADR template](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)  
**Status possíveis:** Proposto | Aceito | Depreciado | Substituído

---

## ADR-001 — n8n como orquestrador de workflows

**Status:** Aceito  
**Data:** 2026-06  
**Autor:** Arquitetura WCIC

### Contexto

O WCIC precisa orquestrar integrações com 8+ APIs externas, transformar dados entre formatos, acionar agentes de IA, persistir em banco de dados e distribuir notificações por múltiplos canais. O sistema precisa ser auditável, resiliente a falhas de APIs externas e operável por equipes sem background exclusivo em engenharia de software.

### Problema

Qual ferramenta utilizar para orquestrar os fluxos de integração de forma que seja: visualmente rastreável, self-hosted, escalável horizontalmente, com suporte nativo a retry e error handling, e integrável com as APIs externas necessárias?

### Alternativas avaliadas

| Alternativa | Prós | Contras |
|---|---|---|
| **n8n** | Queue Mode para escala, 400+ integrações nativas, self-hosted, UI visual para auditoria | JavaScript funcional (não tipado), exportação JSON difícil de revisar em PRs |
| Apache Airflow | Maduro, Python, ideal para pipelines ETL | Voltado a processamento batch, não a integrações em tempo real; curva operacional alta |
| Temporal.io | Workflows duráveis, muito robusto | Curva de aprendizado alta, overkill para este escopo, sem UI de monitoramento integrada |
| Node.js custom | Controle total, tipagem via TypeScript | 5-10x mais tempo de desenvolvimento, sem UI de debug/monitoramento, sem integrações nativas |
| Make (Integromat) | Extremamente simples | Não self-hosted, custo por operação, sem Queue Mode, vendor lock-in |
| Prefect | Moderno, Python, bom UI | Voltado a data pipelines, não integrações de API em tempo real |

### Decisão

**n8n com Queue Mode ativado.**

### Motivo

- **Queue Mode** resolve escala horizontal sem mudança de código — apenas adicionar workers
- **UI visual** é um ativo real: permite debugging, auditoria e demonstração do sistema em entrevistas
- **Self-hosted** elimina custo por execução e dependência de vendor
- **400+ integrações nativas** reduzem código custom para casos padrão (Telegram, Slack, PostgreSQL, Redis, HTTP)
- **Error Trigger** nativo por workflow simplifica o circuito de recuperação (WF-10)
- **Execute Workflow** permite composição e reuso de lógica entre workflows

### Consequências

- Lógica de transformação complexa fica em nodes `Function` (JavaScript não tipado) — documentar via specs em `n8n/specs/`
- JSON de exportação não é legível para code review — solução: specs em Markdown paralelas
- Dependência de Redis para Queue Mode — já justificada no ADR-003
- Versionamento de workflows requer export manual ou via API do n8n

---

## ADR-002 — PostgreSQL 15 como banco de dados principal

**Status:** Aceito  
**Data:** 2026-06

### Contexto

O sistema persiste dados estruturados com relacionamentos claros (partidas → times, eventos → partidas, previsões → partidas) e dados semiestruturados (payloads brutos de APIs, saídas JSON de agentes IA). Algumas tabelas terão volume e frequência de escrita elevados (eventos ao vivo, logs de workflow, snapshots de sentimento).

### Problema

Qual banco de dados relacional utiliza para atender os requisitos de: queries analíticas, armazenamento de dados semiestruturados, séries temporais, busca textual e extensibilidade?

### Alternativas avaliadas

| Alternativa | Prós | Contras |
|---|---|---|
| **PostgreSQL + TimescaleDB** | JSONB, arrays nativos, extensível, suporte a TimescaleDB | Mais configuração que MySQL |
| MongoDB | Flexível para dados não estruturados | Sem JOINs reais, consistência eventual dificulta relatórios, JSONB do PG já resolve a necessidade |
| MySQL 8 | Amplamente conhecido, simples | Sem JSONB nativo eficiente, sem arrays, TimescaleDB não disponível |
| ClickHouse | Excelente para analytics OLAP | Não adequado para alta frequência de INSERTs individuais, setup complexo |
| SQLite | Zero configuração | Não suporta concorrência, sem extensões, inadequado para produção |

### Decisão

**PostgreSQL 15 com extensão TimescaleDB.**

### Motivo

- **JSONB** permite armazenar `raw_payload` das APIs e `feature_snapshot` de previsões sem schema rígido, mantendo auditabilidade completa
- **Arrays nativos** (`UUID[]`, `TEXT[]`) simplificam relacionamentos many-to-many simples (tags, teams afetados) sem tabelas de junção extras
- **TimescaleDB** resolve eficientemente queries de séries temporais em `match_events`, `sentiment_snapshots` e `workflow_logs`
- **pg_trgm** habilita busca textual em títulos de notícias sem Elasticsearch adicional
- **Materialized Views** com `REFRESH CONCURRENTLY` resolvem performance de dashboards sem impacto em writes
- **UPSERT** (`INSERT ... ON CONFLICT DO UPDATE`) garante idempotência nas integrações

### Consequências

- TimescaleDB deve ser instalado antes das migrations — imagem `timescale/timescaledb:latest-pg15` resolve isso
- Hypertables requerem que o campo de particionamento faça parte de todos os índices únicos compostos
- `REFRESH MATERIALIZED VIEW CONCURRENTLY` requer índice único na view — criado em `003_views.sql`
- Múltiplos databases no mesmo cluster (n8n, wcic, metabase, grafana) exigem usuários isolados com senhas distintas

---

## ADR-003 — TimescaleDB para dados de séries temporais

**Status:** Aceito  
**Data:** 2026-06

### Contexto

Três tabelas do WCIC têm natureza de séries temporais com volume elevado: `match_events` (~300 eventos/min durante jogos), `sentiment_snapshots` (~288 snapshots/dia) e `workflow_logs` (~500 execuções/dia). Queries frequentes filtram por intervalos de tempo recentes.

### Problema

Como armazenar e consultar eficientemente dados de séries temporais sem adicionar um sistema de banco de dados separado?

### Alternativas avaliadas

| Alternativa | Prós | Contras |
|---|---|---|
| **TimescaleDB** | Extensão do PostgreSQL, sem nova stack, compressão automática, continuous aggregates | Versão gratuita tem limitações de clustering |
| InfluxDB | Nativo para séries temporais | Stack adicional, linguagem Flux diferente de SQL, integração com n8n mais complexa |
| PostgreSQL puro com particionamento manual | Zero dependência extra | Particionamento manual é trabalhoso, sem compressão automática, sem continuous aggregates |
| Prometheus para todas as séries | Ideal para métricas | Não adequado para dados de negócio (eventos de partida, sentimento) |

### Decisão

**TimescaleDB como extensão do PostgreSQL existente.**

### Motivo

- Zero stack adicional — é uma extensão do PostgreSQL já escolhido
- Particionamento automático por tempo (chunks) sem manutenção manual
- Compressão automática de chunks históricos (reduz armazenamento em 90%+)
- Continuous aggregates materializam queries frequentes incrementalmente
- SQL padrão — sem nova linguagem a aprender
- Políticas de retenção automáticas (`add_retention_policy`)

### Consequências

- Hypertable requer que `created_at` faça parte da PRIMARY KEY composta
- Continuous aggregates têm limitação de funções suportadas (sem todas as window functions)
- Compressão desabilita UPDATE/DELETE em chunks comprimidos — adequado pois eventos históricos são imutáveis

---

## ADR-004 — Redis 7 para cache, filas e estado efêmero

**Status:** Aceito  
**Data:** 2026-06

### Contexto

O sistema precisa de: cache de respostas de API com TTL (evitar rate limit), deduplicação de eventos duplicados entre fontes, controle de rate limiting próprio, filas de processamento para o n8n Queue Mode, circuit breaker state e Pub/Sub para event-driven entre workflows.

### Problema

Como implementar cache, filas e estado efêmero sem adicionar múltiplos sistemas especializados?

### Alternativas avaliadas

| Alternativa | Prós | Contras |
|---|---|---|
| **Redis** | Ultra-rápido, TTL por chave, estruturas nativas (SET, LIST, SORTED SET, PubSub), exigido pelo n8n Queue Mode | In-memory (custo de RAM), consistência eventual em cluster |
| Memcached | Simples, rápido | Sem TTL por chave em estruturas complexas, sem Pub/Sub, sem listas |
| PostgreSQL como fila | Já existe na stack | Latência muito maior, polling necessário, sem TTL nativo |
| RabbitMQ | Robusto para mensageria | Stack adicional, complexidade operacional, n8n Queue Mode já usa Redis |
| Kafka | Excelente para event streaming | Overkill para este volume, setup complexo, latência adicional |

### Decisão

**Redis 7 com persistência `appendonly yes`.**

### Motivo

- n8n Queue Mode **exige** Redis (Bull/BullMQ) — não adiciona dependência nova
- `EXPIRE` nativo resolve TTL para cache e deduplicação em O(1)
- `INCR` + `EXPIRE` implementa rate limiting de forma atômica e eficiente
- `SET` com `SISMEMBER` resolve deduplicação em O(1)
- `PUBLISH`/`SUBSCRIBE` permite desacoplamento event-driven entre workflows
- Namespace padronizado (`wcic:{categoria}:{recurso}:{id}`) mantém organização

### Consequências

- Estado de circuit breakers é efêmero — perdido em restart do Redis (aceitável, circuito fecha sozinho em 10min)
- `allkeys-lru` remove chaves quando memória cheia — namespace de filas deve usar databases separados ou monitoramento de memória
- Autenticação com `requirepass` obrigatória — exposto apenas na rede interna Docker

---

## ADR-005 — n8n Queue Mode em vez de modo padrão

**Status:** Aceito  
**Data:** 2026-06

### Contexto

O n8n por padrão executa workflows na mesma instância que serve a UI e os webhooks. Em volume alto (100 jogos simultâneos × múltiplos workflows), uma execução lenta pode bloquear o agendamento de outras.

### Problema

Como garantir que o volume de execuções não degrada a UI, os webhooks e o agendamento de triggers?

### Alternativas avaliadas

| Alternativa | Prós | Contras |
|---|---|---|
| **Queue Mode (Bull + Redis)** | Desacoplamento total scheduler/executor, escala horizontal real, workers independentes | Requer Redis, configuração adicional |
| Modo padrão (single process) | Zero configuração extra | Uma execução lenta bloqueia tudo, sem escala horizontal real |
| Múltiplas instâncias n8n independentes | Isolamento | Workflows duplicados, gerenciamento complexo, sem fila compartilhada |

### Decisão

**Queue Mode com 2 workers iniciais, escalável para N.**

### Motivo

- Workers são stateless — escala horizontal adicionando containers
- Main instance mantém UI e webhooks responsivos independentemente da carga
- Cada worker processa 20 execuções paralelas (configurável via `N8N_CONCURRENCY_PRODUCTION_LIMIT`)
- Fila persistida no Redis — jobs não são perdidos em restart de worker

### Consequências

- Requer Redis operacional antes de iniciar n8n
- Credentials e encryption key devem ser idênticos entre main e todos os workers
- Debugging de execuções requer verificar logs do worker específico (não apenas da main instance)

---

## ADR-006 — OpenAI GPT-4o com agentes especializados

**Status:** Aceito  
**Data:** 2026-06

### Contexto

O sistema precisa analisar textos de notícias (múltiplos idiomas), processar sentimento de posts de redes sociais, gerar previsões probabilísticas fundamentadas e produzir relatórios narrativos. A qualidade e consistência dos outputs são críticas para credibilidade da plataforma.

### Problema

Qual modelo de IA utilizar e como estruturar os prompts para garantir outputs consistentes, auditáveis e de alta qualidade?

### Alternativas avaliadas

| Alternativa | Prós | Contras |
|---|---|---|
| **GPT-4o (OpenAI)** | Qualidade superior em múltiplos idiomas, JSON mode nativo, integração n8n simples via HTTP | Custo por token, dependência de vendor externo |
| Claude Sonnet (Anthropic) | Qualidade comparável, contexto maior | Sem integração nativa no n8n, requer HTTP Request — mesma complexidade |
| Gemini Pro (Google) | Multimodal, custo menor | Qualidade de análise textual ligeiramente inferior para idiomas europeus |
| Llama 3 (self-hosted via Ollama) | Zero custo por token, privacidade | Qualidade significativamente inferior para análise multilíngue, requer GPU |
| Prompt único genérico | Simplicidade | Outputs inconsistentes, difícil de otimizar por caso de uso, debug complexo |
| **Agentes especializados (escolhido)** | Prompts otimizados, outputs tipados, debug isolado | Múltiplos prompts para manter |

### Decisão

**OpenAI GPT-4o com 4 agentes especializados via HTTP Request no n8n, outputs em JSON Schema.**

### Motivo

- Agentes especializados produzem outputs de qualidade consistentemente superior a um prompt genérico
- JSON Schema como output elimina parsing frágil e garante tipagem
- `prompt_version` versionado na tabela permite A/B testing e reprocessamento
- Custo controlável com `OPENAI_DAILY_BUDGET_USD` e rastreamento de tokens no Prometheus
- HTTP Request direto no n8n dá visibilidade total do payload — sem abstração oculta

### Consequências

- Custo real estimado: ~$0,01 por análise de notícia, ~$0,05 por previsão, ~$0,20 por digest diário
- Fallback necessário: se OpenAI indisponível, marcar como `pending_analysis` e reprocessar
- `max_tokens` definido por agente para controle de custo
- Rate limiting gerenciado via Redis token bucket (90.000 tokens/min)

---

## ADR-007 — Grafana para observabilidade operacional

**Status:** Aceito  
**Data:** 2026-06

### Contexto

O sistema distribui execuções em múltiplos workers, integra com APIs externas instáveis e processa dados em tempo real. A equipe de operações precisa de visibilidade sobre saúde do sistema, latência de APIs e comportamento de workflows sem consultar logs manualmente.

### Problema

Qual ferramenta utilizar para dashboards operacionais, alertas e correlação de métricas?

### Alternativas avaliadas

| Alternativa | Prós | Contras |
|---|---|---|
| **Grafana + Prometheus** | Self-hosted, maduro, alertas integrados, datasources múltiplos | Setup inicial mais trabalhoso |
| Datadog | Muito completo, fácil setup | Custo alto ($15-23/host/mês), vendor lock-in |
| New Relic | Similar ao Datadog | Mesmo problema de custo |
| Kibana + Elasticsearch | Bom para logs | Stack pesada (ELK), overkill para métricas, custo de RAM |
| Metabase apenas | Já na stack | Não adequado para métricas técnicas em tempo real, sem alertas |

### Decisão

**Grafana com Prometheus como datasource principal.**

### Motivo

- Self-hosted elimina custo de vendor
- Provisioning automático via arquivos YAML — dashboards e datasources versionados em Git
- Alertas integrados com múltiplos canais (Telegram, email, Slack)
- Suporte nativo a PostgreSQL como datasource adicional (para métricas de negócio)
- Amplamente adotado em produção — competência transferível

### Consequências

- Dois sistemas de métricas: Prometheus (técnico) + PostgreSQL via Grafana (negócio)
- Dashboards versionados em `docker/grafana/provisioning/dashboards/`
- `postgres-exporter` e `redis-exporter` necessários como sidecars

---

## ADR-008 — Docker Compose para orquestração local e staging

**Status:** Aceito  
**Data:** 2026-06

### Contexto

O projeto precisa de um ambiente reproduzível que funcione identicamente em desenvolvimento local (Linux, macOS, WSL2) e em um servidor de staging. A stack tem 10+ serviços com dependências entre si.

### Problema

Como garantir reprodutibilidade do ambiente sem a complexidade de Kubernetes ou a inflexibilidade de scripts manuais?

### Alternativas avaliadas

| Alternativa | Prós | Contras |
|---|---|---|
| **Docker Compose** | Simples, declarativo, healthchecks nativos, `depends_on` com condições | Não adequado para produção com alta disponibilidade |
| Kubernetes (k8s) | Produção real, auto-healing, rolling deploys | Complexidade enorme para um projeto de portfólio, overkill |
| Docker Swarm | Mais simples que k8s | Menos features, comunidade menor, futuro incerto |
| Scripts bash manuais | Máximo controle | Não declarativo, difícil de manter, sem healthchecks |
| Vagrant + Ansible | Reproduzível | Muito mais lento, overhead de VM |

### Decisão

**Docker Compose v3.8 para desenvolvimento e staging. Arquivo `docker-compose.prod.yml` (futuro) para produção com ajustes de segurança.**

### Motivo

- Curva de aprendizado zero para quem conhece Docker
- `healthcheck` + `depends_on: condition: service_healthy` garante ordem correta de boot
- Arquivo único versionável em Git descreve toda a stack
- Volumes nomeados garantem persistência de dados entre restarts
- Rede bridge isolada impede acesso externo não autorizado entre serviços

### Consequências

- Não adequado para alta disponibilidade em produção — futuro: migrar para k8s ou managed services
- Secrets via arquivo `.env` — em produção usar Docker Secrets ou Vault
- Um único host — sem distribuição geográfica

---

## ADR-009 — API REST própria em Node.js/Express

**Status:** Aceito  
**Data:** 2026-06

### Contexto

O WCIC precisa expor dados processados para consumidores externos (clientes, parceiros, casas de apostas) via REST API autenticada. A opção mais simples seria usar o WF-12 (Webhook do n8n) para tudo. A opção mais robusta seria um serviço dedicado.

### Problema

Como expor endpoints REST com baixa latência, autenticação robusta, rate limiting e documentação OpenAPI sem comprometer a disponibilidade do n8n?

### Alternativas avaliadas

| Alternativa | Prós | Contras |
|---|---|---|
| **Express.js** | Simples, amplo ecossistema, rápido de implementar | Menos estruturado que frameworks opinionados |
| Fastify | Mais rápido que Express, schema validation nativo | Menos familiar, ecossistema menor |
| NestJS | Estruturado, TypeScript, módulos | Complexidade alta, overkill para este escopo |
| n8n Webhook (WF-12) apenas | Zero serviço adicional | Latência de fila, sem documentação OpenAPI nativa, n8n não é um servidor HTTP |
| Hasura (GraphQL) | Auto-gerado a partir do PG | GraphQL vs REST, dependência adicional, over-fetching em casos simples |

### Decisão

**Express.js como serviço dedicado (`services/api`), com n8n Webhook apenas para integrações internas.**

### Motivo

- Leituras da API não passam pelo n8n — latência p50 < 50ms vs ~200ms via Webhook
- Express com `express-prometheus-middleware` expõe métricas ao Prometheus nativamente
- Permite documentação OpenAPI/Swagger independente do n8n
- Recrutadores valorizam ver um serviço backend real — demonstra stack completa
- Autenticação JWT e rate limiting implementados uma vez, reutilizados por todos os endpoints

### Consequências

- Dois pontos de entrada para dados externos (n8n webhooks + API Express)
- API Express mantém sua própria connection pool para PostgreSQL
- Deployment de nova versão da API requer rebuild do container

---

## ADR-010 — Estratégia de Observabilidade em três pilares

**Status:** Aceito  
**Data:** 2026-06

### Contexto

Um sistema distribuído com 12 workflows, 2 workers, 8+ APIs externas e processamento de IA precisa de observabilidade em múltiplas camadas para debugging eficiente e detecção proativa de problemas.

### Problema

Como garantir que qualquer falha — desde um timeout de API até uma degradação silenciosa do modelo de IA — seja detectável, rastreável e alertada em tempo adequado?

### Decisão

**Três pilares complementares:**

**Pilar 1 — Métricas (Prometheus + Grafana)**  
Dados quantitativos em tempo real: execuções por segundo, latência de API, profundidade de fila, uso de tokens, acurácia do modelo. Alertas baseados em thresholds.

**Pilar 2 — Logs estruturados (PostgreSQL `workflow_logs`)**  
Cada execução de workflow gera um registro com: `execution_id`, `correlation_id`, `status`, `duration_ms`, `error_message`, `error_node`. Permite auditoria completa e debugging de casos específicos.

**Pilar 3 — Correlation IDs (rastreabilidade end-to-end)**  
Um UUID gerado no início de cada cadeia de eventos é propagado por todos os sub-workflows. Permite reconstruir a cadeia completa: `WF-01 → WF-07 → Telegram` a partir de qualquer ponto.

### Motivo

Os três pilares são complementares e cobrem casos que os outros não cobrem:
- Métricas detectam degradação gradual (latência aumentando); logs não detectam sem query
- Logs permitem debugging de casos específicos; métricas dão apenas agregados
- Correlation IDs permitem rastrear uma cadeia específica; os outros dois não têm esse contexto

### Consequências

- `workflow_logs` cresce ~500 registros/dia — retenção de 90 dias configurada via TimescaleDB
- Correlation ID deve ser gerado em cada trigger (WF-01, WF-02, WF-03...) e passado explicitamente para sub-workflows
- Custo adicional de storage estimado em ~50MB/mês para `workflow_logs`
