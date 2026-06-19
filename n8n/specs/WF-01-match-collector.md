# WF-01 — Match Collector

**Versão:** 1.2.0  
**Sprint:** 2 — Data Collection  
**Status:** Implementado  
**Arquivo de workflow:** `../workflows/WF-01-match-collector.json`  
**Última revisão:** 2026-06

---

## Objetivo

Coletar e persistir dados de todas as partidas da Copa do Mundo 2026 a partir da Football-Data API, mantendo `wcic.matches` sempre atualizada com status, placar e metadados. É o workflow fundacional do sistema: todos os outros dependem dos dados gerados por ele.

---

## Responsabilidades

| Responsabilidade | Detalhe |
|---|---|
| Coleta periódica | Busca todas as partidas da competição a cada 30 minutos |
| Normalização | Converte o schema da API para o schema `wcic.matches` |
| Deduplicação | Garante idempotência via UPSERT + deduplicação Redis |
| Sincronização de times | Atualiza `teams.external_id` na primeira execução |
| Detecção de estado | Mantém `wcic:active_matches` no Redis com jogos ao vivo |
| Auditoria | Registra cada execução em `wcic.workflow_logs` |
| Circuit breaking | Detecta falhas da API primária e ativa fallback |
| Propagação | Publica `match.updated` no Redis Pub/Sub para workflows downstream |

---

## Trigger

| Parâmetro | Valor |
|---|---|
| Tipo | Cron Schedule |
| Expressão | `*/30 * * * *` |
| Timezone | `America/Sao_Paulo` |
| Execução manual | Permitida via UI do n8n |

---

## APIs Utilizadas

### Primária — Football-Data.org v4

| Parâmetro | Valor |
|---|---|
| Base URL | `https://api.football-data.org/v4` |
| Credencial n8n | `Football Data API` (HTTP Header Auth) |
| Header | `X-Auth-Token` |
| Endpoint | `GET /competitions/WC/matches?season=2026` |
| Rate limit | 10 req/min |
| Timeout | 15 segundos |

### Fallback — API-Football (RapidAPI)

| Parâmetro | Valor |
|---|---|
| Credencial n8n | `RapidAPI Football` (HTTP Header Auth) |
| Ativação | Quando circuit breaker Football-Data está OPEN |

---

## Fluxo de Nodes

```
[1] Schedule Trigger
      │
      ▼
[2] Function: Init — correlation_id, log início
      │
      ▼
[3] Redis GET: circuit breaker state
      │
      ├── OPEN ────────────────────► [4b] HTTP: API-Football (fallback)
      │
      └── CLOSED ──► [4a] HTTP: Football-Data API
                          │
                ┌─────────┤
                │ OK      │ Erro
                │         ▼
                │   [5e] Incrementa erros Redis
                │         │
                │         ├── < 5 ──► [4b] Fallback
                │         └── ≥ 5 ──► Circuit OPEN + Alerta WF-07
                │
[5a] Reset error counter
      │
      ▼
[5b] Function: Normalizar payload
      │
      ▼
[6] Split in Batches (10 por lote)
      │
      ▼
[7] Redis GET: cache match
      │
      ├── HIT (sem mudança) ──► SKIP
      │
      └── MISS / mudou ──► [8] PostgreSQL UPSERT
                                │
                           [9] Redis SET cache TTL=35min
                                │
                           [10] Switch: status
                                │
                           ┌────┴────┐
                          live     finished
                           │         │
                     SADD active  SREM active
                                  + WF-11 trigger
      │
      ▼ (fim dos batches)
[14] Redis PUBLISH: match.updated
      │
      ▼
[15] PostgreSQL UPDATE: workflow_logs (success)
```

---

## Transformações

### Status Map (Football-Data → wcic ENUM)

| API value | wcic ENUM |
|---|---|
| `SCHEDULED`, `TIMED` | `scheduled` |
| `IN_PLAY` | `live` |
| `PAUSED` | `halftime` |
| `FINISHED` | `finished` |
| `POSTPONED` | `postponed` |
| `CANCELLED` | `cancelled` |
| `SUSPENDED` | `suspended` |

### Stage Map (Football-Data → wcic ENUM)

| API stage | API group | wcic ENUM |
|---|---|---|
| `GROUP_STAGE` | `Group A` | `group_a` |
| `GROUP_STAGE` | `Group B` | `group_b` |
| ... | ... | ... |
| `LAST_32` | — | `round_of_32` |
| `LAST_16` | — | `round_of_16` |
| `QUARTER_FINALS` | — | `quarter_final` |
| `SEMI_FINALS` | — | `semi_final` |
| `THIRD_PLACE` | — | `third_place` |
| `FINAL` | — | `final` |

---

## Regras de Deduplicação

**Camada 1 — Redis (best-effort):**
- Chave: `wcic:cache:match:{external_id}`
- TTL: 35 minutos
- Lógica: hash dos campos mutáveis (status, scores) — skip UPSERT se idêntico

**Camada 2 — PostgreSQL (garantia):**
```sql
INSERT INTO wcic.matches (...) VALUES (...)
ON CONFLICT (external_id) DO UPDATE SET
    status = EXCLUDED.status, ...
WHERE
    matches.status IS DISTINCT FROM EXCLUDED.status OR
    matches.home_score IS DISTINCT FROM EXCLUDED.home_score OR
    matches.away_score IS DISTINCT FROM EXCLUDED.away_score OR
    matches.winner_team_id IS DISTINCT FROM EXCLUDED.winner_team_id;
```
A cláusula `WHERE` garante que `updated_at` só muda quando dados realmente mudam.

---

## Tratamento de Erros

| Cenário | Comportamento |
|---|---|
| HTTP timeout (>15s) | Retry 1×, depois fallback |
| HTTP 429 | Aguarda `Retry-After`, nova tentativa |
| HTTP 401 | Falha permanente + alerta P1 |
| HTTP 5xx | Incrementa counter → circuit breaker |
| Stage desconhecido | Exception, pula partida, alerta P2 |
| team_id não mapeado | Warning, pula partida, log |
| Redis indisponível | Degrada graciosamente, continua sem cache |
| PostgreSQL timeout | Backoff 2s/4s/8s, alerta P1 se persistir |

### Circuit Breaker (TTL-based via Redis)

```
CLOSED → 5 erros em 10min → OPEN (TTL 10min) → expira → CLOSED
```

---

## Credenciais Necessárias no n8n

| Nome | Tipo |
|---|---|
| `Football Data API` | HTTP Header Auth (`X-Auth-Token`) |
| `RapidAPI Football` | HTTP Header Auth (`X-RapidAPI-Key`) |
| `WCIC PostgreSQL` | PostgreSQL |
| `WCIC Redis` | Redis |

---

## Métricas

| Métrica | Tipo |
|---|---|
| `wcic_wf01_executions_total{status}` | Counter |
| `wcic_wf01_matches_upserted_total` | Counter |
| `wcic_wf01_matches_skipped_total` | Counter |
| `wcic_wf01_api_latency_ms{api}` | Histogram |
| `wcic_wf01_circuit_breaker_open` | Gauge |
| `wcic_wf01_active_matches_count` | Gauge |

---

## Dependências

| Dependência | Obrigatória | Impacto se ausente |
|---|---|---|
| `wcic.teams` populada | ✅ Sim | Impossível mapear team IDs |
| `wcic.venues` populada | ⚠️ Recomendada | venue_id será NULL |
| Redis disponível | ⚠️ Degradável | Mais writes no PG, risco de duplicatas |
| Migration 005 aplicada | ✅ Sim | `last_sync_at` e UNIQUE em `match_events` |
