# test-live-events.sh - Documentação

**Arquivo:** `scripts/test-live-events.sh`  
**Tipo:** Shell script (bash)  
**Compatibilidade:** Linux, macOS, WSL2

---

## Objetivo

Testar o pipeline completo de eventos ao vivo sem precisar de um jogo real acontecendo. Simula um gol, valida a cadeia completa: Redis → PostgreSQL (com deduplicação) → Pub/Sub → Telegram (opcional). Mede a latência de cada etapa.

---

## Pré-requisitos

| Requisito | Verificação |
|---|---|
| Stack completa rodando | `docker-compose ps` - todos healthy |
| Migration 006 aplicada | `SELECT 1 FROM schema_migrations WHERE filename='006_fix_sprint3.sql'` |
| WF-07 importado (para teste Telegram completo) | n8n UI |
| `python3` instalado | `which python3` |

---

## Variáveis Utilizadas

| Variável | Obrigatória | Uso |
|---|---|---|
| `POSTGRES_ROOT_PASSWORD` | ✅ | Acesso ao container via psql |
| `REDIS_PASSWORD` | ✅ | Operações Redis (SADD, SREM, GET, PUBLISH) |
| `WEBHOOK_URL` | ✅ | Verificação de saúde do n8n |
| `N8N_BASIC_AUTH_USER` | ✅ | Health check n8n |
| `N8N_BASIC_AUTH_PASSWORD` | ✅ | Health check n8n |
| `TELEGRAM_BOT_TOKEN` | ⚠️ Opcional | Envio real de mensagem Telegram |
| `TELEGRAM_LIVE_CHAT_ID` | ⚠️ Opcional | Chat destino da mensagem de teste |

---

## Fluxo de Execução

```
Seção 1: Pré-condições
  - PostgreSQL respondendo
  - Redis respondendo
  - n8n respondendo (WARN se não, continua)
  - Migration 006 aplicada
  - Coluna event_dedup_key existe

Seção 2: Preparar partida de teste
  - Se --match-id fornecido: valida que existe no banco
  - Se não: busca primeira partida disponível
  - Se banco vazio: cria partida sintética com 2 times do seed

Seção 3: Configurar Redis
  - SADD wcic:active_matches {matchId}
  - DEL wcic:live:cursor:{matchId} (garante reprocessamento)

Seção 4: Simular gol
  - INSERT em match_events com external_id único baseado em timestamp
  - ON CONFLICT DO NOTHING para idempotência

Seção 5: Testar deduplicação
  - Tenta inserir o mesmo external_id → deve retornar vazio
  - Conta registros: deve ser exatamente 1

Seção 6: Publicar no Pub/Sub
  - PUBLISH wcic:pub:events.live com payload JSON
  - Reporta número de subscribers

Seção 7: Simular notificação WF-07
  - INSERT direto em notifications com event_dedup_key
  - Testa ON CONFLICT na notifications
  - Conta registros: deve ser exatamente 1

Seção 8: Telegram (se configurado)
  - Envia mensagem real via Bot API
  - Mede latência HTTP

Seção 9: Latência estimada

Seção 10: Limpeza
  - SREM wcic:active_matches {matchId}
```

---

## Opções de Linha de Comando

| Flag | Comportamento |
|---|---|
| (nenhuma) | Execução completa com Telegram |
| `--skip-telegram` | Pula o envio real ao Telegram |
| `--match-id=UUID` | Usa uma partida específica |

---

## Exemplo de Uso

```bash
# Teste completo com Telegram
./scripts/test-live-events.sh

# Sem Telegram (CI/CD)
./scripts/test-live-events.sh --skip-telegram

# Testar partida específica
./scripts/test-live-events.sh --match-id=550e8400-e29b-41d4-a716-446655440000
```

---

## Saída Esperada

```
  ╔═══════════════════════════════════════════════════╗
  ║   WCIC - Live Event Pipeline Test                 ║
  ╚═══════════════════════════════════════════════════╝

  ▶ 1. Verificando pré-condições

  [OK  ] PostgreSQL respondendo
  [OK  ] Redis respondendo
  [OK  ] n8n respondendo
  [OK  ] Migration 006 aplicada
  [OK  ] Coluna event_dedup_key existe em notifications

  ▶ 4. Simulando evento de gol

  [OK  ] Evento de gol inserido - id: abc123...

  ▶ 5. Testando deduplicação

  [OK  ] Deduplicação funcionando - inserção duplicada silenciada corretamente
  [OK  ] Exatamente 1 registro para external_id='test-goal-...'

  ▶ 8. Teste Telegram

  [OK  ] Mensagem enviada ao Telegram (latência: 423ms)
  [OK  ] Latência Telegram dentro do SLA (423ms < 3000ms)

  ═══════════════════════════════════════════════════
   Relatório Final
  ═══════════════════════════════════════════════════
   Total    : 12 verificações
   Passaram  : 12
   Avisos    : 0
   Falhas    : 0

   Status: APROVADO - pipeline de eventos ao vivo operacional
```

---

## Possíveis Erros

| Item | Causa | Solução |
|---|---|---|
| `[FAIL] Coluna event_dedup_key ausente` | Migration 006 não aplicada | `./scripts/setup-database.sh` |
| `[FAIL] Deduplicação FALHOU` | Índice UNIQUE ausente ou migration 005 não aplicada | Verificar `idx_match_events_external_id_unique` |
| `[WARN] Banco sem times` | Seeds não executados | `./scripts/setup-database.sh` |
| `[FAIL] Telegram falhou: chat not found` | Bot não é membro do chat | Adicionar o bot ao canal/grupo |
| `[FAIL] Falha ao criar partida sintética` | Constraint violada ou schema incorreto | Verificar migration 006 e seeds |

---

## Dados Gerados pelo Teste

O script cria dados reais no banco que permanecem para auditoria:
- 1 registro em `wcic.match_events` com `raw_payload.test = true`
- 1 registro em `wcic.notifications` com `metadata.test = true`

Para limpar após os testes:
```sql
DELETE FROM wcic.match_events WHERE raw_payload->>'test' = 'true';
DELETE FROM wcic.notifications WHERE metadata->>'test' = 'true';
```
EOF
echo "test-live-events.md ok"
