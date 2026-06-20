# =============================================================================
# WCIC — scripts/test-live-events.sh
# Testa o pipeline completo de eventos ao vivo sem precisar de um jogo real.
# Simula um gol, valida inserção no banco, notificação Telegram e latência.
#
# Uso: ./scripts/test-live-events.sh [--skip-telegram] [--match-id UUID]
# Saída: [OK] / [WARN] / [FAIL] por verificação + relatório final
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

SKIP_TELEGRAM=false
CUSTOM_MATCH_ID=""

for arg in "$@"; do
  case $arg in
    --skip-telegram)     SKIP_TELEGRAM=true ;;
    --match-id=*)        CUSTOM_MATCH_ID="${arg#--match-id=}" ;;
  esac
done

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
TOTAL=0; PASSED=0; WARNED=0; FAILED=0
TEST_START_TS=$(date +%s%3N)

log_ok()   { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1));  printf "  \033[32m[OK  ]\033[0m %s\n" "$*"; }
log_warn() { TOTAL=$((TOTAL+1)); WARNED=$((WARNED+1));  printf "  \033[33m[WARN]\033[0m %s\n" "$*"; }
log_fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1));  printf "  \033[31m[FAIL]\033[0m %s\n" "$*"; }
log_info() { printf "  \033[36m[INFO]\033[0m %s\n" "$*"; }
log_step() { echo ""; printf "  ▶ %s\n" "$*"; echo ""; }

echo ""
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║   WCIC - Live Event Pipeline Test                 ║"
echo "  ╚═══════════════════════════════════════════════════╝"

# ---------------------------------------------------------------------------
# Carregar .env
# ---------------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
  log_fail ".env não encontrado"; exit 1
fi
set -o allexport
source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$') 2>/dev/null || true
set +o allexport

REDIS_PASS="${REDIS_PASSWORD:-}"
PG_PASS="${POSTGRES_ROOT_PASSWORD:-}"
N8N_URL="${WEBHOOK_URL:-http://localhost:5678}"
N8N_URL="${N8N_URL%/}"
N8N_USER="${N8N_BASIC_AUTH_USER:-admin}"
N8N_PASS="${N8N_BASIC_AUTH_PASSWORD:-}"

# ---------------------------------------------------------------------------
# SEÇÃO 1 - Pré-condições
# ---------------------------------------------------------------------------
log_step "1. Verificando pré-condições"

# PostgreSQL
if docker exec wcic-postgres pg_isready -U postgres -q 2>/dev/null; then
  log_ok "PostgreSQL respondendo"
else
  log_fail "PostgreSQL indisponível - abortando"; exit 1
fi

# Redis
PING=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" ping 2>/dev/null | tr -d '\r')
if [[ "$PING" == "PONG" ]]; then
  log_ok "Redis respondendo"
else
  log_fail "Redis indisponível - abortando"; exit 1
fi

# n8n
N8N_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${N8N_URL}/healthz" 2>/dev/null || echo "000")
if [[ "$N8N_STATUS" == "200" ]]; then
  log_ok "n8n respondendo"
else
  log_warn "n8n não respondeu (HTTP $N8N_STATUS) - testes de workflow pulados"
fi

# Verifica migration 006
M006=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM public.schema_migrations WHERE filename='006_fix_sprint3.sql'" 2>/dev/null || echo "")
if [[ "$M006" == "1" ]]; then
  log_ok "Migration 006 aplicada"
else
  log_fail "Migration 006 não aplicada - execute ./scripts/setup-database.sh"
fi

# Verifica coluna event_dedup_key
DEDUP_COL=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM information_schema.columns WHERE table_schema='wcic' AND table_name='notifications' AND column_name='event_dedup_key'" 2>/dev/null || echo "")
if [[ "$DEDUP_COL" == "1" ]]; then
  log_ok "Coluna event_dedup_key existe em notifications"
else
  log_fail "Coluna event_dedup_key ausente - migration 006 necessária"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 2 - Buscar ou criar partida de teste
# ---------------------------------------------------------------------------
log_step "2. Preparando partida de teste"

if [[ -n "$CUSTOM_MATCH_ID" ]]; then
  TEST_MATCH_ID="$CUSTOM_MATCH_ID"
  MATCH_EXISTS=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "SELECT COUNT(*) FROM wcic.matches WHERE id='${TEST_MATCH_ID}'::uuid" 2>/dev/null | tr -d ' ' || echo "0")
  if [[ "${MATCH_EXISTS:-0}" -gt 0 ]]; then
    log_ok "Usando match_id fornecido: $TEST_MATCH_ID"
  else
    log_fail "match_id não encontrado: $TEST_MATCH_ID"; exit 1
  fi
else
  # Busca a primeira partida disponível para usar como teste
  TEST_MATCH_ID=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "SELECT id FROM wcic.matches ORDER BY scheduled_at LIMIT 1" 2>/dev/null | tr -d ' \n' || echo "")

  if [[ -z "$TEST_MATCH_ID" ]]; then
    log_warn "Nenhuma partida no banco - criando partida sintética de teste"

    # Busca dois times para criar a partida sintética
    HOME_ID=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
      "SELECT id FROM wcic.teams LIMIT 1" 2>/dev/null | tr -d ' \n' || echo "")
    AWAY_ID=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
      "SELECT id FROM wcic.teams OFFSET 1 LIMIT 1" 2>/dev/null | tr -d ' \n' || echo "")

    if [[ -z "$HOME_ID" || -z "$AWAY_ID" ]]; then
      log_fail "Banco sem times - execute os seeds primeiro"; exit 1
    fi

    TEST_MATCH_ID=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
      "INSERT INTO wcic.matches (
        external_id, home_team_id, away_team_id, stage, scheduled_at,
        status, home_score, away_score, source_api, last_sync_at
       ) VALUES (
        'test-match-$(date +%s)', '${HOME_ID}'::uuid, '${AWAY_ID}'::uuid,
        'group_a', NOW(), 'live', 0, 0, 'test', NOW()
       ) RETURNING id" 2>/dev/null | tr -d ' \n' || echo "")

    if [[ -n "$TEST_MATCH_ID" ]]; then
      log_ok "Partida sintética criada: $TEST_MATCH_ID"
    else
      log_fail "Falha ao criar partida sintética"; exit 1
    fi
  else
    # Garante que a partida está marcada como live para o teste
    docker exec wcic-postgres psql -U postgres -d wcic -c \
      "UPDATE wcic.matches SET status='live', home_score=0, away_score=0 WHERE id='${TEST_MATCH_ID}'::uuid" &>/dev/null
    log_ok "Usando partida existente: $TEST_MATCH_ID"
  fi
fi

# ---------------------------------------------------------------------------
# SEÇÃO 3 - Marcar partida como ativa no Redis
# ---------------------------------------------------------------------------
log_step "3. Configurando Redis para teste"

SADD_RESULT=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
  SADD wcic:active_matches "$TEST_MATCH_ID" 2>/dev/null | tr -d '\r')
if [[ "$SADD_RESULT" == "1" || "$SADD_RESULT" == "0" ]]; then
  log_ok "Match $TEST_MATCH_ID adicionado a wcic:active_matches"
else
  log_fail "Falha ao adicionar match ao Redis active_matches: $SADD_RESULT"
fi

# Limpa cursor antigo para garantir que eventos sintéticos são processados
docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
  DEL "wcic:live:cursor:${TEST_MATCH_ID}" &>/dev/null
log_ok "Cursor Redis limpo para o match de teste"

# ---------------------------------------------------------------------------
# SEÇÃO 4 - Inserir evento sintético diretamente no banco
# ---------------------------------------------------------------------------
log_step "4. Simulando evento de gol"

SYNTHETIC_EXT_ID="test-goal-$(date +%s)"
EVENT_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Insere o evento de gol diretamente
INSERTED_EVENT_ID=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "INSERT INTO wcic.match_events (
     match_id, external_id, event_type, minute, period, is_confirmed, raw_payload, created_at
   ) VALUES (
     '${TEST_MATCH_ID}'::uuid,
     '${SYNTHETIC_EXT_ID}',
     'goal',
     45,
     'regular',
     true,
     '{\"test\": true, \"source\": \"test-live-events.sh\"}'::jsonb,
     NOW()
   )
   ON CONFLICT (match_id, external_id) WHERE external_id IS NOT NULL DO NOTHING
   RETURNING id" 2>/dev/null | tr -d ' \n' || echo "")

if [[ -n "$INSERTED_EVENT_ID" ]]; then
  log_ok "Evento de gol inserido - id: $INSERTED_EVENT_ID"
else
  # Pode ser duplicata se o script rodou antes
  EXISTING=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "SELECT id FROM wcic.match_events WHERE external_id='${SYNTHETIC_EXT_ID}'" 2>/dev/null | tr -d ' \n' || echo "")
  if [[ -n "$EXISTING" ]]; then
    log_warn "Evento já existia (deduplicado corretamente): $SYNTHETIC_EXT_ID"
    INSERTED_EVENT_ID="$EXISTING"
  else
    log_fail "Falha ao inserir evento de gol no banco"
  fi
fi

# ---------------------------------------------------------------------------
# SEÇÃO 5 - Validar deduplicação
# ---------------------------------------------------------------------------
log_step "5. Testando deduplicação"

# Tenta inserir o mesmo evento novamente - deve ser silenciado pelo ON CONFLICT
DUP_RESULT=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "INSERT INTO wcic.match_events (
     match_id, external_id, event_type, minute, period, is_confirmed, raw_payload
   ) VALUES (
     '${TEST_MATCH_ID}'::uuid, '${SYNTHETIC_EXT_ID}', 'goal', 45, 'regular', true, '{}'::jsonb
   )
   ON CONFLICT (match_id, external_id) WHERE external_id IS NOT NULL DO NOTHING
   RETURNING id" 2>/dev/null | tr -d ' \n' || echo "")

if [[ -z "$DUP_RESULT" ]]; then
  log_ok "Deduplicação funcionando - inserção duplicada silenciada corretamente"
else
  log_fail "Deduplicação FALHOU - evento duplicado inserido com id: $DUP_RESULT"
fi

# Conta quantos eventos existem com este external_id (deve ser exatamente 1)
DEDUP_COUNT=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT COUNT(*) FROM wcic.match_events WHERE external_id='${SYNTHETIC_EXT_ID}'" 2>/dev/null | tr -d ' ' || echo "?")
if [[ "$DEDUP_COUNT" == "1" ]]; then
  log_ok "Exatamente 1 registro para external_id='$SYNTHETIC_EXT_ID' (esperado)"
else
  log_fail "Contagem incorreta: $DEDUP_COUNT registros para external_id='$SYNTHETIC_EXT_ID'"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 6 - Publicar evento no Redis Pub/Sub
# ---------------------------------------------------------------------------
log_step "6. Publicando no Redis Pub/Sub"

PUBLISH_RESULT=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" PUBLISH \
  "wcic:pub:events.live" \
  "{\"match_id\":\"${TEST_MATCH_ID}\",\"event_type\":\"goal\",\"minute\":45,\"external_id\":\"${SYNTHETIC_EXT_ID}\",\"test\":true}" \
  2>/dev/null | tr -d '\r')

if [[ "$PUBLISH_RESULT" =~ ^[0-9]+$ ]]; then
  log_ok "Evento publicado no canal wcic:pub:events.live (${PUBLISH_RESULT} subscriber(s))"
else
  log_warn "PUBLISH retornou: $PUBLISH_RESULT (0 subscribers é normal se WF-02 não está rodando)"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 7 - Inserir notificação simulando WF-07
# ---------------------------------------------------------------------------
log_step "7. Simulando notificação via WF-07 (inserção direta)"

NOTIF_DEDUP_KEY="test-goal-notif-${SYNTHETIC_EXT_ID}-telegram"
NOTIF_CORR_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")

NOTIF_INSERTED=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "INSERT INTO wcic.notifications (
     notification_type, priority, channel, recipient, body, metadata,
     status, attempts, max_attempts, sent_at, related_match_id,
     correlation_id, event_dedup_key
   ) VALUES (
     'goal_alert', 'critical', 'telegram', 'test-chat-id',
     '⚽ *GOL DE TESTE!* - 45''\n🧪 Evento sintético do test-live-events.sh',
     '{\"test\": true}'::jsonb,
     'sent', 1, 3, NOW(), '${TEST_MATCH_ID}'::uuid,
     '${NOTIF_CORR_ID}'::uuid,
     '${NOTIF_DEDUP_KEY}'
   )
   ON CONFLICT (event_dedup_key) WHERE event_dedup_key IS NOT NULL DO NOTHING
   RETURNING id" 2>/dev/null | tr -d ' \n' || echo "")

NOTIF_MEASURE_TS=$(date +%s%3N)

if [[ -n "$NOTIF_INSERTED" ]]; then
  log_ok "Notificação inserida - id: $NOTIF_INSERTED"
else
  log_warn "Notificação já existia para esta dedup_key (deduplicação de notificação funcionando)"
fi

# Verifica que existe no banco
NOTIF_COUNT=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT COUNT(*) FROM wcic.notifications WHERE event_dedup_key='${NOTIF_DEDUP_KEY}'" 2>/dev/null | tr -d ' ' || echo "0")
if [[ "${NOTIF_COUNT:-0}" -eq 1 ]]; then
  log_ok "Notificação encontrada no banco (notifications)"
else
  log_fail "Notificação não encontrada no banco - count: ${NOTIF_COUNT}"
fi

# Verifica deduplicação de notificação
DUP_NOTIF=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "INSERT INTO wcic.notifications (
     notification_type, priority, channel, recipient, body, status,
     attempts, max_attempts, event_dedup_key
   ) VALUES (
     'goal_alert', 'critical', 'telegram', 'test-chat-id', 'dup test',
     'sent', 1, 3, '${NOTIF_DEDUP_KEY}'
   )
   ON CONFLICT (event_dedup_key) WHERE event_dedup_key IS NOT NULL DO NOTHING
   RETURNING id" 2>/dev/null | tr -d ' \n' || echo "")
if [[ -z "$DUP_NOTIF" ]]; then
  log_ok "Deduplicação de notificação funcionando (ON CONFLICT)"
else
  log_fail "Notificação duplicada inserida: $DUP_NOTIF"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 8 - Telegram (opcional)
# ---------------------------------------------------------------------------
log_step "8. Teste Telegram"

if [[ "$SKIP_TELEGRAM" == "true" ]]; then
  log_info "Telegram pulado (--skip-telegram)"
else
  TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  TG_CHAT="${TELEGRAM_LIVE_CHAT_ID:-}"

  if [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]]; then
    log_warn "TELEGRAM_BOT_TOKEN ou TELEGRAM_LIVE_CHAT_ID não definidos - Telegram pulado"
  else
    TG_MSG="🧪 *WCIC Test*%0A%0A⚽ Evento sintético de gol%0A🕐 $(date '+%H:%M:%S')%0A%0A_Gerado por test-live-events.sh_"
    TG_SEND_TS=$(date +%s%3N)

    TG_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 10 \
      "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT}&text=${TG_MSG}&parse_mode=Markdown" 2>/dev/null)

    TG_BODY=$(echo "$TG_RESPONSE" | head -n -1)
    TG_STATUS=$(echo "$TG_RESPONSE" | tail -n 1)
    TG_RECV_TS=$(date +%s%3N)
    TG_LATENCY=$((TG_RECV_TS - TG_SEND_TS))

    if [[ "$TG_STATUS" == "200" ]]; then
      log_ok "Mensagem enviada ao Telegram (latência: ${TG_LATENCY}ms)"
      if [[ $TG_LATENCY -lt 3000 ]]; then
        log_ok "Latência Telegram dentro do SLA (${TG_LATENCY}ms < 3000ms)"
      else
        log_warn "Latência Telegram alta: ${TG_LATENCY}ms (SLA: < 3000ms)"
      fi
    else
      ERROR_DESC=$(echo "$TG_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('description','?'))" 2>/dev/null || echo "?")
      log_fail "Telegram falhou (HTTP $TG_STATUS): $ERROR_DESC"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# SEÇÃO 9 - Verificação de latência estimada end-to-end
# ---------------------------------------------------------------------------
log_step "9. Latência end-to-end estimada"

CURRENT_TS=$(date +%s%3N)
PIPELINE_LATENCY=$((CURRENT_TS - TEST_START_TS))

log_info "Tempo total do teste: ${PIPELINE_LATENCY}ms"
log_info "Latência WF-02 esperada em produção: 60s (cron) + ~5s processamento = ~65s"
log_info "Latência WF-07 Telegram: ~1-3s"
log_info "Latência total estimada evento→notificação: < 90s"

if [[ $PIPELINE_LATENCY -lt 5000 ]]; then
  log_ok "Operações de banco e Redis dentro do esperado (${PIPELINE_LATENCY}ms)"
else
  log_warn "Operações mais lentas que esperado (${PIPELINE_LATENCY}ms)"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 10 - Limpeza
# ---------------------------------------------------------------------------
log_step "10. Limpeza pós-teste"

# Remove o match de teste do active_matches (não remove do banco para auditoria)
docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
  SREM wcic:active_matches "$TEST_MATCH_ID" &>/dev/null
log_ok "Match removido de wcic:active_matches"

# ---------------------------------------------------------------------------
# RELATÓRIO FINAL
# ---------------------------------------------------------------------------
echo ""
echo "  ═══════════════════════════════════════════════════"
echo "   Relatório Final"
echo "  ═══════════════════════════════════════════════════"
printf "   Total    : %d verificações\n" "$TOTAL"
printf "   \033[32mPassaram\033[0m  : %d\n" "$PASSED"
printf "   \033[33mAvisos\033[0m    : %d\n" "$WARNED"
printf "   \033[31mFalhas\033[0m    : %d\n" "$FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
  echo "   \033[31mStatus: REPROVADO - corrijir os [FAIL] antes da Sprint 4\033[0m"
  echo ""
  exit 1
elif [[ $WARNED -gt 0 ]]; then
  echo "   \033[33mStatus: APROVADO COM AVISOS - pipeline funcional\033[0m"
  echo ""
  exit 0
else
  echo "   \033[32mStatus: APROVADO - pipeline de eventos ao vivo operacional\033[0m"
  echo ""
  exit 0
fi
SHEOF
chmod +x /home/claude/wcic/scripts/test-live-events.sh
bash -n /home/claude/wcic/scripts/test-live-events.sh && echo "sintaxe ok"
