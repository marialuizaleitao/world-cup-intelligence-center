# WF-07 - Notification Hub

**Versão:** 1.0.0 | **Sprint:** 3 | **Status:** Produção  
**Arquivo:** `n8n/workflows/WF-07-notification-hub.json`  
**Nodes:** 19 | **Conexões:** 17  
**Tipo de trigger:** Sub-workflow (Execute Workflow Trigger)

---

## Objetivo

Centralizar o roteamento, formatação, envio e persistência de todas as notificações do sistema. É o único ponto de saída para canais externos (Telegram, Slack, Webhooks). Garante deduplicação de notificações, rate limiting por canal, rastreabilidade via `correlation_id` e persistência auditável em `wcic.notifications`.

---

## Trigger

| Parâmetro | Valor |
|---|---|
| Tipo | Execute Workflow Trigger |
| Chamadores atuais | WF-02 (eventos ao vivo), WF-01 (alertas operacionais) |
| Chamadores planejados | WF-03, WF-05, WF-06 (Sprints 4–5) |
| Modo de chamada | Assíncrono (`waitForSubWorkflow: false`) - callers não aguardam resposta |

---

## Schema do Payload de Entrada

```typescript
{
  type: 'goal_alert' | 'own_goal_alert' | 'penalty_alert' |
        'red_card_alert' | 'second_yellow_alert' | 'var_alert' |
        'match_start' | 'match_end' | 'match_halftime' | 'operational_alert',
  priority: 'critical' | 'high' | 'medium' | 'low',
  channel: 'telegram' | 'slack' | 'email' | 'webhook',
  correlation_id: string,  // UUID - obrigatório
  match_id?: string,       // UUID - para eventos de partida
  event_type?: string,     // Tipo do evento (para dedup key)
  event_minute?: number,   // Minuto do evento (para dedup key)
  content: {
    title?: string,
    body: string,           // Obrigatório - usado como fallback
    metadata: {
      chat_id?: string,     // Para Telegram
      webhook_url?: string, // Para canal webhook
      caller_workflow?: string,
      // Campos de contexto para templates
      home_team?: string,   away_team?: string,
      home_code?: string,   away_code?: string,
      home_score?: number,  away_score?: number,
      minute?: number,      scorer?: string,
      assist?: string,      player?: string,
      team?: string,        detail?: string,
      venue?: string,       winner?: string,
    }
  }
}
```

---

## Entradas

| Fonte | Tipo | Dado |
|---|---|---|
| Caller (WF-02, WF-01...) | Execute Workflow | Payload conforme schema acima |
| Redis `wcic:rl:notify:{channel}:{correlation_id}` | GET | Estado do rate limiter |

---

## Saídas

| Destino | Operação | Dado |
|---|---|---|
| Telegram API | POST `/sendMessage` | Mensagem formatada em Markdown |
| Slack Incoming Webhook | POST | Mensagem formatada |
| Webhook externo | POST JSON | Payload estruturado |
| PostgreSQL `wcic.notifications` | INSERT ON CONFLICT (event_dedup_key) DO UPDATE | Log de cada tentativa |
| Redis `wcic:rl:notify:{channel}:{correlation_id}` | SET TTL variável | Rate limit key |
| Redis `wcic:queue:dlq:wf07` | RPUSH | Payload para retry (apenas priority=critical/high) |
| PostgreSQL `wcic.workflow_logs` | INSERT | Log de execução |

---

## Fluxo de Execução

```
Execute Workflow Trigger
  └─► Validate Payload
        [Verifica campos obrigatórios, tipos válidos, channels válidos]
        [Gera event_dedup_key via base64(match_id|event_type|minute|channel)]
        │
        [Se inválido → throw Error → execução falha e é logada pelo n8n]
        │
        └─► Check Rate Limit
              [GET wcic:rl:notify:{channel}:{correlation_id}]
              └─► Rate Limit Decision
                    └─► Is Rate Limited? (IF)
                          │
                          ├─ TRUE ──► Log Rate Limited
                          │           [console.log, retorna [] - encerra silenciosamente]
                          │
                          └─ FALSE ─► Format Message
                                        [Switch por notification.type]
                                        [10 templates: goal, own_goal, penalty, red_card,]
                                        [second_yellow, var, match_start, halftime, end, ops]
                                        [Inclui FLAG_MAP para 24 países com emojis de bandeira]
                                        └─► Route by Channel (Switch)
                                              │
                                              ├─ telegram ──► Send Telegram
                                              │               [chatId da metadata ou env TELEGRAM_LIVE_CHAT_ID]
                                              │               [parse_mode: Markdown, no web preview]
                                              │
                                              ├─ slack ─────► Send Slack
                                              │               [POST env.SLACK_WEBHOOK_URL]
                                              │
                                              ├─ email ─────► [output 3, sem node - reservado Sprint 4]
                                              │
                                              └─ webhook ───► Send Webhook
                                                              [POST content.metadata.webhook_url]
                                                              [JSON: type, priority, content, match_id, correlation_id, ts]
                                              │
                                              └─► Evaluate Send Result
                                                    [Determina send_success (true/false)]
                                                    [Extrai error message se falhou]
                                                    └─► Persist Notification
                                                          [INSERT ON CONFLICT (event_dedup_key) DO UPDATE]
                                                          [Incrementa attempts em conflito]
                                                          [Status: sent | failed | retry por lógica de max_attempts]
                                                          └─► Prepare Rate Limit Key
                                                                [TTL: critical/high=60s, medium=300s, low=600s]
                                                                └─► Set Rate Limit Key
                                                                      [SET wcic:rl:notify:{channel}:{correlation_id} TTL]
                                                                      └─► Send Failed? (IF)
                                                                            │
                                                                            ├─ TRUE ──► Prepare Retry
                                                                            │           [Avalia se priority = critical/high]
                                                                            │           └─► Push to DLQ
                                                                            │                [RPUSH wcic:queue:dlq:wf07]
                                                                            │                └─► Log Execution
                                                                            │
                                                                            └─ FALSE ─► Log Execution
                                                                                         [INSERT workflow_logs: success/error]
```

---

## Templates de Mensagem Telegram

### `goal_alert`
```
⚽ *GOL!* - 45'
🇧🇷 *Brazil* 1–0 *Argentina* 🇦🇷

🎯 *Neymar*
🎁 Assistência: Vinicius Jr
📋 Cabeçada

#Copa2026 #BRA #ARG
```

### `red_card_alert`
```
🟥 *CARTÃO VERMELHO!* - 67'
🇫🇷 *France* 1–1 *England* 🏴󠁧󠁢󠁥󠁮󠁧󠁿

❌ *Bellingham* (England)

#Copa2026 #FRA #ENG
```

### `match_start`
```
🟢 *INÍCIO DE JOGO!*
🇩🇪 *Germany* 0–0 *Spain* 🇪🇸

🏟️ MetLife Stadium
🕐 Horário local: 15:00

#Copa2026 #GER #ESP
```

### `operational_alert`
```
⚠️ *ALERTA OPERACIONAL*

*Circuit Breaker Aberto*
Football-Data API indisponível após 5 erros consecutivos

🕐 2026-06-15T18:32:11.000Z
```

---

## Dependências

| Dependência | Obrigatória | Impacto se ausente |
|---|---|---|
| `wcic.notifications` (migration 001) | ✅ Sim | INSERT falha; execução com erro |
| Coluna `event_dedup_key` (migration 006) | ✅ Sim | ON CONFLICT não funciona; duplicatas possíveis |
| Índice `idx_notifications_event_dedup` (migration 006) | ✅ Sim | ON CONFLICT DO UPDATE sem índice causa erro |
| Credencial `WCIC Telegram Bot` no n8n | ✅ Para Telegram | Channel telegram falha com erro de credencial |
| Credencial `WCIC PostgreSQL` no n8n | ✅ Sim | Impossível persistir; impossível logar |
| Credencial `WCIC Redis` no n8n | ✅ Sim | Rate limiting desabilitado |
| Variável `TELEGRAM_LIVE_CHAT_ID` acessível | ⚠️ Telegram | Fallback para `content.metadata.chat_id` |
| Variável `SLACK_WEBHOOK_URL` acessível | ⚠️ Slack | Channel slack falha |

---

## Integrações Externas

### Telegram Bot API

- **Endpoint:** `POST https://api.telegram.org/bot{TOKEN}/sendMessage`
- **Autenticação:** Token no path via credencial `WCIC Telegram Bot`
- **Parâmetros:** `chat_id`, `text` (Markdown), `parse_mode=Markdown`, `disable_web_page_preview=true`
- **Limite Telegram:** 30 mensagens/segundo por bot; 1 mensagem/segundo por chat específico
- **Rate limiting interno:** TTL 60s por `(channel, correlation_id)` previne flood no mesmo evento

### Slack Incoming Webhook

- **Endpoint:** URL configurada em `SLACK_WEBHOOK_URL`
- **Método:** POST com `{ text: formattedBody }`
- **Timeout:** 10.000ms

### Webhooks externos

- **Endpoint:** Dinâmico - `content.metadata.webhook_url`
- **Método:** POST com JSON estruturado
- **Timeout:** 10.000ms

---

## Estratégia de Retries

| Camada | Comportamento |
|---|---|
| Rate limited | Encerra silenciosamente (não é falha, é comportamento esperado) |
| Send falhou (critical/high) | RPUSH em `wcic:queue:dlq:wf07` para WF-10 reprocessar |
| Send falhou (medium/low) | Loga como `failed` em `notifications`, sem retry |
| ON CONFLICT em `notifications` | Incrementa `attempts`; muda status para `retry` ou `failed` se atingiu `max_attempts` (3) |
| Payload inválido | Throw no `Validate Payload` → execução falha e é registrada pelo n8n |

**DLQ key:** `wcic:queue:dlq:wf07` (LIST Redis) - consumida pelo WF-10 (Sprint 6).

---

## Estratégia de Deduplicação

**Nível 1 - Rate limit Redis (janela temporal):**
```
Chave: wcic:rl:notify:{channel}:{correlation_id}
TTL:   critical/high → 60s | medium → 300s | low → 600s
Protege: contra re-envio da mesma cadeia de evento no mesmo canal
```

**Nível 2 - event_dedup_key (garantia permanente):**
```
Valor: base64(match_id|event_type|minute|channel)[0:128]
Protege: contra duplicatas mesmo após restart do Redis
Persiste: em wcic.notifications para sempre
```

Dois workers executando o WF-07 para o mesmo gol ao mesmo tempo:
- Worker A insere → sucesso, `status=sent`
- Worker B tenta → ON CONFLICT → incrementa `attempts`, mantém `status=sent`

---

## Estratégia de Observabilidade

- **Toda notificação** (enviada, bloqueada por rate limit ou falha) é registrada em `wcic.workflow_logs`
- **Toda tentativa** (sucesso, falha, duplicata) é registrada em `wcic.notifications`
- **Rate limited:** logado apenas via `console.log` - não persiste (intencional, volume alto)
- **DLQ depth:** `LLEN wcic:queue:dlq:wf07` como métrica de backlog de falhas

---

## Métricas

| Métrica | Tipo | Fonte |
|---|---|---|
| `wcic_wf07_executions_total{status}` | Counter | `workflow_logs` |
| `wcic_wf07_notifications_sent_total{channel,type}` | Counter | `notifications WHERE status='sent'` |
| `wcic_wf07_notifications_failed_total{channel}` | Counter | `notifications WHERE status='failed'` |
| `wcic_wf07_rate_limited_total` | Counter | `console.log` parse (ou via Redis key count) |
| `wcic_wf07_dlq_depth` | Gauge | `LLEN wcic:queue:dlq:wf07` |
| `wcic_wf07_duration_ms` | Histogram | `workflow_logs.duration_ms` |

---

## Possíveis Falhas

| Falha | Causa | Impacto | Detecção | Resolução |
|---|---|---|---|---|
| Telegram 429 (flood control) | > 1 msg/s no mesmo chat | Mensagem não enviada | `notifications.status = 'failed'`, `error_message` contém "429" | Rate limiter TTL 60s já previne; se persistir, aumentar TTL |
| `content.body` vazio | Caller não passou body | Throw no Validate Payload | `workflow_logs.status = 'error'`, `error_message` | Corrigir o caller |
| `event_dedup_key` nulo | Evento sem match_id/minute | Dedup desabilitada para este item | ON CONFLICT não atua; duplicatas possíveis | Normalizar: sempre passar `match_id` e `event_minute` |
| Chat ID inválido | Bot não é membro do chat | Telegram retorna 400 | `notifications.error_message` contém "chat not found" | Verificar bot membership no chat |
| Webhook externo timeout | URL lenta ou inacessível | Notificação não entregue | `notifications.status = 'failed'` | Verificar URL; payload vai para DLQ se critical/high |

---

## Runbook Operacional

### Ver notificações recentes

```sql
SELECT notification_type, channel, status, attempts, sent_at, error_message, created_at
FROM wcic.notifications
ORDER BY created_at DESC
LIMIT 20;
```

### Ver falhas nas últimas 24h

```sql
SELECT notification_type, channel, error_message, COUNT(*) as failures
FROM wcic.notifications
WHERE status = 'failed' AND created_at > NOW() - INTERVAL '24 hours'
GROUP BY notification_type, channel, error_message
ORDER BY failures DESC;
```

### Verificar backlog da DLQ

```bash
redis-cli -a $REDIS_PASSWORD LLEN wcic:queue:dlq:wf07
```

### Verificar rate limit ativo

```bash
redis-cli -a $REDIS_PASSWORD --scan --pattern "wcic:rl:notify:*" | head -20
```

### Reprocessar item da DLQ manualmente

```bash
# Inspeciona o próximo item sem remover
redis-cli -a $REDIS_PASSWORD LINDEX wcic:queue:dlq:wf07 0
# Remove e reprocessa via n8n UI (Execute Workflow manual com o payload)
redis-cli -a $REDIS_PASSWORD LPOP wcic:queue:dlq:wf07
```

---

## Critérios de Sucesso

- 100% dos `goal_alert` e `red_card_alert` chegam ao Telegram em < 90 segundos do evento
- Zero notificações duplicadas para o mesmo evento no mesmo canal
- `wcic.notifications` contém registro de cada tentativa (enviada ou não)
- Rate limiting bloqueia corretamente a segunda chamada para o mesmo `(channel, correlation_id)` em < 60s
- DLQ vazia ou crescendo < 5 itens/hora em operação normal
EOF
echo "WF-07 spec ok"
