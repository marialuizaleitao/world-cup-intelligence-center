# =============================================================================
# WCIC - scripts/test-sentiment-analysis.sh
# Valida o pipeline completo de Sentiment Analysis (WF-04 + SWF Sentiment Analyst)
# Testa: OpenAI, PostgreSQL (schema + constraints), Redis (cache), n8n
#
# Uso: ./scripts/test-sentiment-analysis.sh [--skip-openai]
# Saída: [OK] [WARN] [FAIL] + relatório final
# Exit: 0 se nenhum FAIL, 1 se qualquer FAIL
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

SKIP_OPENAI=false
for arg in "$@"; do
  case $arg in --skip-openai) SKIP_OPENAI=true ;; esac
done

TOTAL=0; PASSED=0; WARNED=0; FAILED=0

log_ok()   { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1));  printf "  \033[32m[OK  ]\033[0m %s\n" "$*"; }
log_warn() { TOTAL=$((TOTAL+1)); WARNED=$((WARNED+1));  printf "  \033[33m[WARN]\033[0m %s\n" "$*"; }
log_fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1));  printf "  \033[31m[FAIL]\033[0m %s\n" "$*"; }
log_info() { printf "  \033[36m[INFO]\033[0m %s\n" "$*"; }
log_step() { echo ""; printf "  ▶ %s\n" "$*"; echo ""; }

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   WCIC - Sentiment Analysis Pipeline Test       ║"
echo "  ╚══════════════════════════════════════════════════╝"

# ---------------------------------------------------------------------------
# Carregar .env
# ---------------------------------------------------------------------------
[[ ! -f "$ENV_FILE" ]] && { log_fail ".env não encontrado"; exit 1; }
set -o allexport
source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$') 2>/dev/null || true
set +o allexport

REDIS_PASS="${REDIS_PASSWORD:-}"
N8N_URL="${WEBHOOK_URL:-http://localhost:5678}"
N8N_URL="${N8N_URL%/}"
N8N_USER="${N8N_BASIC_AUTH_USER:-admin}"
N8N_PASS="${N8N_BASIC_AUTH_PASSWORD:-}"
OPENAI_KEY="${OPENAI_API_KEY:-}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o}"

# ---------------------------------------------------------------------------
# SEÇÃO 1 - Pré-condições
# ---------------------------------------------------------------------------
log_step "1. Infraestrutura"

docker exec wcic-postgres pg_isready -U postgres -q 2>/dev/null \
  && log_ok "PostgreSQL respondendo" \
  || { log_fail "PostgreSQL indisponível"; exit 1; }

PING=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" ping 2>/dev/null | tr -d '\r')
[[ "$PING" == "PONG" ]] && log_ok "Redis respondendo" || { log_fail "Redis indisponível"; exit 1; }

N8N_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${N8N_URL}/healthz" 2>/dev/null || echo "000")
[[ "$N8N_HTTP" == "200" ]] && log_ok "n8n respondendo" || log_warn "n8n não respondeu (HTTP $N8N_HTTP)"

# ---------------------------------------------------------------------------
# SEÇÃO 2 - Schema do banco para Sentiment Analysis
# ---------------------------------------------------------------------------
log_step "2. Schema - tabela sentiment_snapshots"

# Tabela existe
SS_EXISTS=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM information_schema.tables
   WHERE table_schema='wcic' AND table_name='sentiment_snapshots'" 2>/dev/null || echo "")
[[ "$SS_EXISTS" == "1" ]] \
  && log_ok "Tabela wcic.sentiment_snapshots existe" \
  || { log_fail "Tabela wcic.sentiment_snapshots ausente"; exit 1; }

# Hypertable TimescaleDB
HT=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM timescaledb_information.hypertables
   WHERE hypertable_schema='wcic' AND hypertable_name='sentiment_snapshots'" 2>/dev/null || echo "")
[[ "$HT" == "1" ]] \
  && log_ok "sentiment_snapshots é hypertable TimescaleDB" \
  || log_warn "sentiment_snapshots NÃO é hypertable - migration 004 pode não ter rodado"

# Constraint source aceita 'newsapi' (migration 007)
NEWSAPI_ACCEPTED=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT conname FROM pg_constraint
   WHERE conname='sentiment_snapshots_source_check'
     AND conrelid='wcic.sentiment_snapshots'::regclass" 2>/dev/null | tr -d ' ' || echo "")
if [[ -n "$NEWSAPI_ACCEPTED" ]]; then
  # Verifica que a constraint atual inclui 'newsapi'
  CONSTRAINT_DEF=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "SELECT pg_get_constraintdef(oid) FROM pg_constraint
     WHERE conname='sentiment_snapshots_source_check'" 2>/dev/null || echo "")
  if echo "$CONSTRAINT_DEF" | grep -q "newsapi"; then
    log_ok "Constraint source aceita 'newsapi' (migration 007 aplicada)"
  else
    log_fail "Constraint source NÃO aceita 'newsapi' - execute migration 007"
  fi
else
  log_warn "Constraint source_check não encontrada em sentiment_snapshots"
fi

# Índice de lookup por entity
IDX_ENTITY=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM pg_indexes WHERE schemaname='wcic'
   AND tablename='sentiment_snapshots'
   AND indexname='idx_sentiment_entity_recent'" 2>/dev/null || echo "")
[[ "$IDX_ENTITY" == "1" ]] \
  && log_ok "Índice idx_sentiment_entity_recent existe" \
  || log_warn "Índice idx_sentiment_entity_recent ausente - migration 007 necessária"

# Verifica que teams existem (pré-requisito para WF-04)
TEAM_COUNT=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT COUNT(*) FROM wcic.teams" 2>/dev/null | tr -d ' ' || echo "0")
if [[ "${TEAM_COUNT:-0}" -ge 48 ]]; then
  log_ok "wcic.teams populada ($TEAM_COUNT times)"
else
  log_fail "wcic.teams insuficiente ($TEAM_COUNT times) - WF-04 não encontrará entidades"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 3 - Inserção sintética em sentiment_snapshots
# ---------------------------------------------------------------------------
log_step "3. Teste funcional - inserção de snapshot sintético"

TEAM_UUID=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT id FROM wcic.teams LIMIT 1" 2>/dev/null | tr -d ' \n' || echo "")

if [[ -z "$TEAM_UUID" ]]; then
  log_fail "Nenhum time encontrado - impossível testar INSERT"
else
  log_ok "Time de teste: $TEAM_UUID"

  # INSERT com source='newsapi' - valida migration 007
  SS_INSERTED=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "INSERT INTO wcic.sentiment_snapshots (
       entity_type, entity_id, source, captured_at,
       positive_ratio, negative_ratio, neutral_ratio,
       dominant_sentiment, intensity, volume,
       trending_topics, ai_model, tokens_used
     ) VALUES (
       'team', '${TEAM_UUID}'::uuid, 'newsapi', NOW(),
       0.650, 0.150, 0.200,
       'positive', 'medium', 5,
       ARRAY['Copa 2026','gol','vitória'], 'gpt-4o', 120
     ) RETURNING id" 2>/dev/null | tr -d ' \n' || echo "")

  if [[ -n "$SS_INSERTED" ]]; then
    log_ok "Snapshot sintético inserido (id: $SS_INSERTED)"

    # Valida soma dos ratios
    RATIO_SUM=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
      "SELECT ROUND((positive_ratio + negative_ratio + neutral_ratio)::numeric, 3)
       FROM wcic.sentiment_snapshots WHERE id='${SS_INSERTED}'::uuid" 2>/dev/null | tr -d ' ' || echo "0")
    [[ "$RATIO_SUM" == "1.000" ]] \
      && log_ok "Soma dos ratios = 1.000 (positivo + negativo + neutro)" \
      || log_warn "Soma dos ratios = $RATIO_SUM (esperado: 1.000)"

    # Valida dominant_sentiment ENUM
    DOM_SENT=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
      "SELECT dominant_sentiment FROM wcic.sentiment_snapshots
       WHERE id='${SS_INSERTED}'::uuid" 2>/dev/null | tr -d ' ' || echo "")
    [[ "$DOM_SENT" == "positive" ]] \
      && log_ok "dominant_sentiment gravado corretamente: '$DOM_SENT'" \
      || log_fail "dominant_sentiment incorreto: '$DOM_SENT'"

    # Limpeza
    docker exec wcic-postgres psql -U postgres -d wcic -c \
      "DELETE FROM wcic.sentiment_snapshots WHERE id='${SS_INSERTED}'::uuid" &>/dev/null
    log_ok "Snapshot de teste removido"
  else
    log_fail "Falha ao inserir snapshot sintético - verificar constraint source ou schema"
  fi
fi

# ---------------------------------------------------------------------------
# SEÇÃO 4 - Cache Redis de sentimento
# ---------------------------------------------------------------------------
log_step "4. Redis - cache de sentimento"

if [[ -n "$TEAM_UUID" ]]; then
  CACHE_KEY="wcic:cache:sentiment:team:${TEAM_UUID}"
  CACHE_VALUE='{"positive_ratio":0.65,"negative_ratio":0.15,"neutral_ratio":0.20,"dominant_sentiment":"positive","intensity":"medium","captured_at":"2025-06-01T00:00:00Z"}'

  SET_RESULT=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
    SET "$CACHE_KEY" "$CACHE_VALUE" EX 1800 2>/dev/null | tr -d '\r')
  GET_RESULT=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
    GET "$CACHE_KEY" 2>/dev/null | tr -d '\r')
  TTL_RESULT=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
    TTL "$CACHE_KEY" 2>/dev/null | tr -d '\r')

  if [[ "$SET_RESULT" == "OK" && -n "$GET_RESULT" ]]; then
    log_ok "Cache sentiment SET/GET funcionando"
    [[ "${TTL_RESULT:-0}" -gt 1700 ]] \
      && log_ok "TTL do cache de sentimento: ${TTL_RESULT}s (~30min)" \
      || log_warn "TTL inesperado: ${TTL_RESULT}s"
  else
    log_fail "Cache Redis de sentimento com falha (SET=$SET_RESULT)"
  fi

  # Remove chave de teste
  docker exec wcic-redis redis-cli -a "$REDIS_PASS" DEL "$CACHE_KEY" &>/dev/null
  log_ok "Chave de cache de teste removida"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 5 - OpenAI com prompt do Sentiment Analyst
# ---------------------------------------------------------------------------
log_step "5. OpenAI - Sentiment Analyst"

if [[ "$SKIP_OPENAI" == "true" ]]; then
  log_info "OpenAI pulada (--skip-openai)"
elif [[ -z "$OPENAI_KEY" ]]; then
  log_warn "OPENAI_API_KEY não configurada - OpenAI pulada"
else
  SYSTEM_PROMPT='Você é um especialista em análise de sentimento de futebol. Analise os posts e retorne APENAS JSON puro com: positive_ratio, negative_ratio, neutral_ratio (somam 1.0), dominant_sentiment, intensity, trending_topics, ai_summary, confidence.'
  POSTS='[1] Brazil playing amazingly in World Cup 2026! What a team! (👍450)\n[2] Incredible performance from Vinicius Jr in the last match (👍280)\n[3] Brazil vs Argentina final would be the dream (👍190)'

  OAI_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 20 \
    -H "Authorization: Bearer ${OPENAI_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${OPENAI_MODEL}\",\"messages\":[{\"role\":\"system\",\"content\":\"${SYSTEM_PROMPT}\"},{\"role\":\"user\",\"content\":\"Analise o sentimento dos posts:\\n${POSTS}\"}],\"max_tokens\":300,\"temperature\":0.1,\"response_format\":{\"type\":\"json_object\"}}" \
    "https://api.openai.com/v1/chat/completions" 2>/dev/null)

  OAI_BODY=$(echo "$OAI_RESPONSE" | head -n -1)
  OAI_STATUS=$(echo "$OAI_RESPONSE" | tail -n 1)

  case "$OAI_STATUS" in
    200)
      TOKENS=$(echo "$OAI_BODY" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('total_tokens','?'))" 2>/dev/null || echo "?")
      CONTENT=$(echo "$OAI_BODY" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null || echo "")

      log_ok "OpenAI respondeu ($TOKENS tokens)"

      # Valida JSON e campos
      PARSE_CHECK=$(echo "$CONTENT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    pos = float(d.get('positive_ratio', -1))
    neg = float(d.get('negative_ratio', -1))
    neu = float(d.get('neutral_ratio', -1))
    total = round(pos + neg + neu, 2)
    dom = d.get('dominant_sentiment', '')
    valid_dom = ['very_positive','positive','neutral','negative','very_negative']
    if pos < 0 or neg < 0 or neu < 0:
        print('MISSING_RATIOS')
    elif abs(total - 1.0) > 0.05:
        print(f'SUM_ERROR:{total}')
    elif dom not in valid_dom:
        print(f'INVALID_DOM:{dom}')
    else:
        print(f'OK:dom={dom},sum={total}')
except Exception as e:
    print(f'PARSE_ERROR:{e}')
" 2>/dev/null || echo "PARSE_ERROR")

      if [[ "$PARSE_CHECK" == OK* ]]; then
        log_ok "Resposta GPT válida: $PARSE_CHECK"
      elif [[ "$PARSE_CHECK" == SUM_ERROR* ]]; then
        log_warn "Ratios não somam 1.0: $PARSE_CHECK (SWF renormaliza automaticamente)"
      elif [[ "$PARSE_CHECK" == MISSING_RATIOS ]]; then
        log_fail "Campos de ratio ausentes na resposta GPT"
      else
        log_warn "Resposta GPT: $PARSE_CHECK"
      fi
      ;;
    401) log_fail "OpenAI - API key inválida (HTTP 401)" ;;
    429) log_warn "OpenAI - rate limit (HTTP 429)" ;;
    000) log_fail "OpenAI inacessível" ;;
    *)   log_warn "OpenAI retornou HTTP $OAI_STATUS" ;;
  esac
fi

# ---------------------------------------------------------------------------
# SEÇÃO 6 - n8n: workflows Sprint 4 importados
# ---------------------------------------------------------------------------
log_step "6. n8n - Workflows Sprint 4"

if [[ -z "$N8N_PASS" ]]; then
  log_warn "N8N_BASIC_AUTH_PASSWORD não configurado - verificação pulada"
else
  WF_LIST=$(curl -s --max-time 10 \
    -u "${N8N_USER}:${N8N_PASS}" \
    "${N8N_URL}/api/v1/workflows?limit=100" 2>/dev/null || echo "{}")

  for wf_name in "WF-04 - Sentiment Analyzer" "SWF - OpenAI Sentiment Analyst"; do
    EXISTS=$(echo "$WF_LIST" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); names=[w['name'] for w in d.get('data',[])]; print('yes' if '${wf_name}' in names else 'no')" 2>/dev/null || echo "no")
    [[ "$EXISTS" == "yes" ]] \
      && log_ok "Workflow importado: '$wf_name'" \
      || log_fail "Workflow NÃO encontrado: '$wf_name'"
  done
fi

# ---------------------------------------------------------------------------
# SEÇÃO 7 - Verificar que WF-03 gerou dados para o WF-04 consumir
# ---------------------------------------------------------------------------
log_step "7. Pré-condição WF-04 - dados do WF-03"

NEWS_ANALYSIS_COUNT=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT COUNT(*) FROM wcic.news_analysis na
   WHERE na.affected_team_ids != '{}'
     AND na.created_at > NOW() - INTERVAL '24 hours'" 2>/dev/null | tr -d ' ' || echo "0")

if [[ "${NEWS_ANALYSIS_COUNT:-0}" -gt 0 ]]; then
  log_ok "news_analysis tem $NEWS_ANALYSIS_COUNT registros com teams nas últimas 24h (WF-04 encontrará entidades)"
else
  log_warn "news_analysis sem registros com affected_team_ids nas últimas 24h - WF-04 não encontrará entidades"
  log_info "Execute WF-03 primeiro para popular dados de análise de notícias"
fi

SNAPSHOTS_COUNT=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT COUNT(*) FROM wcic.sentiment_snapshots
   WHERE captured_at > NOW() - INTERVAL '24 hours'" 2>/dev/null | tr -d ' ' || echo "0")
if [[ "${SNAPSHOTS_COUNT:-0}" -gt 0 ]]; then
  log_ok "sentiment_snapshots tem $SNAPSHOTS_COUNT registros nas últimas 24h"
else
  log_info "Nenhum snapshot de sentimento ainda - normal antes da primeira execução do WF-04"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 8 - Continuous Aggregate (TimescaleDB)
# ---------------------------------------------------------------------------
log_step "8. TimescaleDB - continuous aggregate sentiment_hourly"

CA_EXISTS=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM timescaledb_information.continuous_aggregates
   WHERE view_name='sentiment_hourly'" 2>/dev/null || echo "")
if [[ "$CA_EXISTS" == "1" ]]; then
  log_ok "Continuous aggregate 'sentiment_hourly' existe"
else
  log_warn "Continuous aggregate 'sentiment_hourly' não encontrado - migration 004 necessária"
fi

# ---------------------------------------------------------------------------
# RELATÓRIO FINAL
# ---------------------------------------------------------------------------
echo ""
echo "  ══════════════════════════════════════════════════"
echo "   Relatório Final - Sentiment Analysis"
echo "  ══════════════════════════════════════════════════"
printf "   Total    : %d verificações\n" "$TOTAL"
printf "   \033[32mPassaram\033[0m  : %d\n" "$PASSED"
printf "   \033[33mAvisos\033[0m    : %d\n" "$WARNED"
printf "   \033[31mFalhas\033[0m    : %d\n" "$FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
  echo "   \033[31mStatus: REPROVADO - corrija os [FAIL] antes de ativar WF-04\033[0m"
  exit 1
elif [[ $WARNED -gt 0 ]]; then
  echo "   \033[33mStatus: APROVADO COM AVISOS\033[0m"
  exit 0
else
  echo "   \033[32mStatus: APROVADO - pipeline Sentiment Analysis operacional\033[0m"
  exit 0
fi
SHEOF
chmod +x /home/claude/wcic/scripts/test-sentiment-analysis.sh
bash -n /home/claude/wcic/scripts/test-sentiment-analysis.sh && echo "sintaxe ok"
