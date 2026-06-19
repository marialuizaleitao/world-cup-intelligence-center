# API Provider Decision - Fonte de Dados Esportivos

**Projeto:** World Cup Intelligence Center (WCIC)  
**Decisão:** Escolha do provider de dados para Copa do Mundo 2026  
**Data:** 2026-06  
**Status:** Aceito

---

## Contexto

O WF-01 (Match Collector) e o WF-02 (Live Event Monitor) dependem de uma API externa como fonte primária de dados de partidas, eventos ao vivo, equipes e jogadores. A escolha do provider impacta diretamente a confiabilidade, o custo de operação e a velocidade de desenvolvimento.

---

## Providers Avaliados

### 1. Football-Data.org

**URL:** https://www.football-data.org  
**Plano gratuito:** Sim (tier "Free")

| Critério | Avaliação | Detalhe |
|---|---|---|
| Cobertura da Copa 2026 | ✅ Alta | Competição WC2026 já mapeada como `WC` |
| Plano gratuito | ✅ Generoso | 10 req/min, sem limite diário explícito |
| Documentação | ✅ Excelente | Docs claras, exemplos reais, changelog público |
| Autenticação | ✅ Simples | Header `X-Auth-Token` |
| Formato de resposta | ✅ Limpo | JSON consistente, IDs estáveis entre chamadas |
| Endpoints necessários | ✅ Todos | `/competitions/WC/matches`, `/matches/{id}` |
| Latência de atualização | ⚠️ ~1-2 min | Não é streaming — polling necessário |
| Eventos ao vivo granulares | ⚠️ Limitado | Eventos disponíveis mas sem granularidade de segundo |
| Rate limit free | ⚠️ 10/min | Suficiente para polling de 104 jogos com lógica de batch |
| Comunidade e estabilidade | ✅ Alta | API ativa desde 2015, amplamente usada em projetos open source |

**Endpoints críticos disponíveis no plano free:**
- `GET /v4/competitions/WC/matches` — todas as partidas da Copa
- `GET /v4/matches/{id}` — detalhes de uma partida específica
- `GET /v4/competitions/WC/teams` — times participantes
- `GET /v4/competitions/WC/standings` — classificação

---

### 2. API-Football (RapidAPI)

**URL:** https://rapidapi.com/api-sports/api/api-football  
**Plano gratuito:** Sim (tier "Basic")

| Critério | Avaliação | Detalhe |
|---|---|---|
| Cobertura da Copa 2026 | ✅ Alta | Cobertura completa prevista |
| Plano gratuito | ⚠️ Restritivo | 100 req/dia total — insuficiente para polling |
| Documentação | ⚠️ Inconsistente | Boa referência, mas exemplos desatualizados frequentemente |
| Autenticação | ⚠️ Dupla | Headers RapidAPI + API key própria |
| Formato de resposta | ⚠️ Verboso | Muitos campos aninhados, estrutura muda entre versões |
| Endpoints necessários | ✅ Todos | `/fixtures`, `/fixtures/events`, `/standings` |
| Latência de atualização | ✅ ~30-60s | Mais rápido que Football-Data |
| Eventos granulares | ✅ Completo | Gols, cartões, substituições com minuto e jogador |
| Rate limit free | ❌ Bloqueador | 100/dia não sustenta polling de jogos ao vivo |
| Custo para produção | ⚠️ $15/mês | Pro plan necessário para qualquer uso real |

**Problema crítico:** 100 requisições/dia no plano free. Um único jogo ao vivo com polling a cada 60s consome 90 req em 90 minutos. Inviável para portfólio sem custo.

---

### 3. Sportmonks

**URL:** https://www.sportmonks.com  
**Plano gratuito:** Sim (trial 14 dias, depois pago)

| Critério | Avaliação | Detalhe |
|---|---|---|
| Cobertura da Copa 2026 | ✅ Alta | Cobertura completa com livescore |
| Plano gratuito | ❌ Inexistente | Trial de 14 dias, depois mínimo €29/mês |
| Documentação | ✅ Excelente | Melhor documentação dos três, SDK oficial |
| Autenticação | ✅ Simples | API token no header |
| Formato de resposta | ✅ Muito limpo | Include system (eager loading flexível) |
| Endpoints necessários | ✅ Todos | Fixtures, livescores, events, standings |
| Latência de atualização | ✅ Excelente | ~15-30s, push disponível no plano Enterprise |
| Eventos granulares | ✅ Excelente | O mais completo dos três |
| Rate limit free | ❌ N/A | Não aplicável — não há plano free permanente |
| Custo para portfólio | ❌ Bloqueador | €29/mês mínimo elimina para uso em portfólio |

---

## Tabela Comparativa

| Critério | Peso | Football-Data | API-Football | Sportmonks |
|---|---|---|---|---|
| Plano gratuito funcional | 30% | ✅ 10/10 | ⚠️ 4/10 | ❌ 0/10 |
| Cobertura Copa 2026 | 25% | ✅ 9/10 | ✅ 9/10 | ✅ 10/10 |
| Qualidade da documentação | 15% | ✅ 8/10 | ⚠️ 6/10 | ✅ 9/10 |
| Facilidade de integração n8n | 15% | ✅ 9/10 | ⚠️ 7/10 | ✅ 8/10 |
| Estabilidade / uptime histórico | 10% | ✅ 9/10 | ✅ 8/10 | ✅ 9/10 |
| Granularidade de eventos ao vivo | 5% | ⚠️ 6/10 | ✅ 9/10 | ✅ 10/10 |
| **Score ponderado** | | **8,65** | **6,70** | **6,35** |

---

## Decisão

**Football-Data.org como provider primário.**  
**API-Football (RapidAPI) como fallback.**

---

## Justificativa

### Por que Football-Data.org

**1. Plano gratuito sustentável para portfólio.**  
10 req/min são suficientes para cobrir todos os casos de uso do WCIC com estratégia de batch. O WF-01 roda a cada 30 minutos e precisa de 1 chamada para buscar todas as partidas do dia — menos de 1% do rate limit. O WF-02 usa 1 chamada por jogo ao vivo a cada 60s, batched em grupos de 10 — viável dentro do limite.

**2. Autenticação trivial para n8n.**  
Um único header `X-Auth-Token: {{$credentials.footballDataApiKey}}` — credencial configurada uma vez no n8n Credentials Manager e reutilizada em todos os HTTP Request nodes. Sem OAuth, sem refresh token, sem headers duplos.

**3. Formato de resposta previsível.**  
IDs de competição e times são estáveis (não mudam entre chamadas). O campo `status` mapeia diretamente para o ENUM `match_status` do schema com uma função de normalização simples. O campo `score.fullTime.home` nunca muda de posição entre versões v3 e v4.

**4. Documentação que serve de contrato.**  
O changelog público da API documenta breaking changes com antecedência. Para um projeto de portfólio, isso significa que o workflow não vai quebrar silenciosamente em produção.

**5. Amplamente conhecida em projetos open source.**  
Recrutadores que avaliam o portfólio reconhecem a API — a escolha demonstra julgamento técnico, não apenas capacidade de conectar qualquer API.

### Por que API-Football como fallback

O circuit breaker no WF-01 (WF-10) desvia automaticamente para API-Football quando Football-Data falha por mais de 5 tentativas consecutivas. O schema de resposta é diferente mas a função de normalização do WF-01 cobre ambos os formatos com mapeamento condicional baseado em `source_api`.

### Por que Sportmonks foi descartado

Custo bloqueador (€29/mês) sem plano free permanente elimina a opção para qualquer projeto de portfólio. A qualidade técnica é superior, mas irrelevante sem acesso gratuito.

---

## Mapeamento de Endpoints

| Necessidade | Football-Data Endpoint | Frequência WF |
|---|---|---|
| Todas as partidas da Copa | `GET /v4/competitions/WC/matches?season=2026` | WF-01 a cada 30min |
| Partida específica (ao vivo) | `GET /v4/matches/{id}` | WF-02 a cada 60s por jogo |
| Times participantes | `GET /v4/competitions/WC/teams?season=2026` | WF-01 uma vez no setup |
| Classificação por grupo | `GET /v4/competitions/WC/standings?season=2026` | WF-08 a cada 5min |

---

## Configuração no n8n

**Credential type:** HTTP Header Auth  
**Nome da credencial:** `Football Data API`  
**Header name:** `X-Auth-Token`  
**Header value:** `{{ seu token do football-data.org }}`

**Base URL:** `https://api.football-data.org/v4`

**Headers adicionais necessários:** nenhum.

---

## Limitações Conhecidas e Mitigações

| Limitação | Impacto | Mitigação |
|---|---|---|
| Eventos ao vivo não são granulares (sem timestamp de segundo) | Feed de eventos usa `minute` como resolução | Aceito para portfólio — WF-02 registra `created_at` do processamento |
| 10 req/min no plano free | Requer batching cuidadoso no WF-02 | Split in Batches de 5 jogos por lote com delay de 6s entre lotes |
| API pode ter downtime (histórico < 99.5%) | WF-01 pode falhar | Circuit breaker + fallback API-Football + cache Redis TTL=35min |
| Dados de escalação não disponíveis no plano free | WF-05 não tem dados de escalação | Usa forma recente e head-to-head como features principais |
