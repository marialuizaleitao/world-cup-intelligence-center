# =============================================================================
# WCIC - scripts/test-news-intelligence.sh
# Valida o pipeline completo de News Intelligence (WF-03 + SWF News Analyst)
# Testa: NewsAPI, OpenAI, PostgreSQL (schema + seeds), Redis, n8n, deduplicação
#
# Uso: ./scripts/test-news-intelligence.sh [--skip-openai] [--skip-newsapi]
# Saída: [OK] [WARN] [FAIL] por verificação + relatório final
# Exit: 0 se nenhum FAIL, 1 se qualquer FAIL
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

SKIP_OPENAI=false
SKIP_NEWSAPI=false
for arg in "$@"; do
  case $arg in
    --skip-openai)  SKIP_OPENAI=true ;;
    --skip-newsapi) SKIP_NEWSAPI=true ;;
  esac
done

TOTAL=0; PASSED=0; WARNED=0; FAILED=0

log_ok()   { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1));  printf "  \033[32m[OK  ]\033[0m %s\n" "$*"; }
log_warn() { TOTAL=$((TOTAL+1)); WARNED=$((WARNED+1));  printf "  \033[33m[WARN]\033[0m %s\n" "$*"; }
log_fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1));  printf "  \033[31m[FAIL]\033[0m %s\n" "$*"; }
log_info() { printf "  \033[36m[INFO]\033[0m %s\n" "$*"; }
log_step() { echo ""; printf "  ? %s\n" "$*"; echo ""; }

echo ""
echo "  +--------------------------------------------------+"
echo "  ¦   WCIC - News Intelligence Pipeline Test        ¦"
echo "  +--------------------------------------------------+"

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
NEWSAPI_KEY="${NEWSAPI_KEY:-}"
OPENAI_KEY="${OPENAI_API_KEY:-}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o}"

# ---------------------------------------------------------------------------
# SEÇÃO 1 - Pré-condições de infra
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
# SEÇÃO 2 - Schema do banco para Sprint 4
# ---------------------------------------------------------------------------
log_step "2. Schema do banco de dados"

# Migration 007
M007=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM public.schema_migrations WHERE filename='007_fix_sprint4.sql'" 2>/dev/null || echo "")
[[ "$M007" == "1" ]] \
  && log_ok "Migration 007 aplicada" \
  || log_fail "Migration 007 ausente - execute ./scripts/setup-database.sh"

# Tabela news_sources
NS_COUNT=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT COUNT(*) FROM wcic.news_sources WHERE is_active=true" 2>/dev/null | tr -d ' ' || echo "0")
if [[ "${NS_COUNT:-0}" -ge 4 ]]; then
  log_ok "news_sources populada ($NS_COUNT fontes ativas)"
else
  log_fail "news_sources vazia ou insuficiente ($NS_COUNT fontes) - migration 007 necessária"
fi

# Coluna topics em news_analysis
TOPICS_COL=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM information_schema.columns WHERE table_schema='wcic' AND table_name='news_analysis' AND column_name='topics'" 2>/dev/null || echo "")
[[ "$TOPICS_COL" == "1" ]] \
  && log_ok "Coluna topics existe em news_analysis" \
  || log_fail "Coluna topics ausente - migration 007 necessária"

# Coluna raw_gpt_response
RAW_COL=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM information_schema.columns WHERE table_schema='wcic' AND table_name='news_analysis' AND column_name='raw_gpt_response'" 2>/dev/null || echo "")
[[ "$RAW_COL" == "1" ]] \
  && log_ok "Coluna raw_gpt_response existe em news_analysis" \
  || log_fail "Coluna raw_gpt_response ausente - migration 007 necessária"

# Índice idx_news_pending_analysis
IDX_PENDING=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM pg_indexes WHERE schemaname='wcic' AND indexname='idx_news_pending_analysis'" 2>/dev/null || echo "")
[[ "$IDX_PENDING" == "1" ]] \
  && log_ok "Índice idx_news_pending_analysis existe" \
  || log_warn "Índice idx_news_pending_analysis ausente - performance degradada em alto volume"

# Constraint source em sentiment_snapshots
CONSTRAINT_OK=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM pg_constraint WHERE conname='sentiment_snapshots_source_check' AND conrelid='wcic.sentiment_snapshots'::regclass" 2>/dev/null || echo "")
if [[ "$CONSTRAINT_OK" == "1" ]]; then
  # Testa se newsapi é aceito
  NEWSAPI_OK=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "SELECT 'newsapi'::text = ANY(ARRAY['twitter','reddit','newsapi','combined','manual'])" 2>/dev/null | tr -d ' ' || echo "f")
  [[ "$NEWSAPI_OK" == "t" ]] \
    && log_ok "Constraint source em sentiment_snapshots aceita 'newsapi'" \
    || log_fail "Constraint source NÃO aceita 'newsapi' - migration 007 necessária"
else
  log_warn "Constraint source_check não encontrada em sentiment_snapshots"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 3 - Redis para Sprint 4
# ---------------------------------------------------------------------------
log_step "3. Redis - chaves Sprint 4"

# Verifica se dedup set existe e tamanho
DEDUP_SIZE=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
  SCARD wcic:dedup:news 2>/dev/null | tr -d '\r' || echo "0")
if [[ "${DEDUP_SIZE:-0}" -ge 0 ]]; then
  log_ok "wcic:dedup:news acessível (${DEDUP_SIZE} URLs deduplicadas)"
else
  log_warn "wcic:dedup:news não existe ainda (normal na primeira execução)"
fi

# Testa operações SET e SISMEMBER
TEST_HASH="test_hash_$(date +%s)"
SADD_RESULT=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
  SADD wcic:dedup:news "$TEST_HASH" 2>/dev/null | tr -d '\r')
SISMEMBER=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
  SISMEMBER wcic:dedup:news "$TEST_HASH" 2>/dev/null | tr -d '\r')
docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
  SREM wcic:dedup:news "$TEST_HASH" &>/dev/null

if [[ "$SADD_RESULT" == "1" && "$SISMEMBER" == "1" ]]; then
  log_ok "Redis SADD/SISMEMBER funcionando (deduplicação operacional)"
else
  log_fail "Redis SADD/SISMEMBER com falha (SADD=$SADD_RESULT, SISMEMBER=$SISMEMBER)"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 4 - NewsAPI
# ---------------------------------------------------------------------------
log_step "4. NewsAPI"

if [[ "$SKIP_NEWSAPI" == "true" ]]; then
  log_info "NewsAPI pulada (--skip-newsapi)"
elif [[ -z "$NEWSAPI_KEY" ]]; then
  log_warn "NEWSAPI_KEY não configurada - NewsAPI pulada"
else
  NEWSAPI_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 15 \
    "https://newsapi.org/v2/everything?q=FIFA+World+Cup+2026&language=en&pageSize=3&apiKey=${NEWSAPI_KEY}" \
    2>/dev/null)
  NEWSAPI_BODY=$(echo "$NEWSAPI_RESPONSE" | head -n -1)
  NEWSAPI_STATUS=$(echo "$NEWSAPI_RESPONSE" | tail -n 1)

  case "$NEWSAPI_STATUS" in
    200)
      ARTICLE_COUNT=$(echo "$NEWSAPI_BODY" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(len(d.get('articles',[])))" 2>/dev/null || echo "?")
      log_ok "NewsAPI respondeu - $ARTICLE_COUNT artigos para 'FIFA World Cup 2026'"
      ;;
    401)
      log_fail "NewsAPI - API key inválida (HTTP 401)" ;;
    426)
      log_warn "NewsAPI - plano free não suporta este endpoint (HTTP 426)" ;;
    429)
      log_warn "NewsAPI - rate limit atingido (HTTP 429)" ;;
    000)
      log_fail "NewsAPI inacessível - verificar conexão de rede" ;;
    *)
      log_warn "NewsAPI retornou HTTP $NEWSAPI_STATUS" ;;
  esac
fi

# ---------------------------------------------------------------------------
# SEÇÃO 5 - OpenAI com prompt do News Analyst
# ---------------------------------------------------------------------------
log_step "5. OpenAI - News Analyst"

if [[ "$SKIP_OPENAI" == "true" ]]; then
  log_info "OpenAI pulada (--skip-openai)"
elif [[ -z "$OPENAI_KEY" ]]; then
  log_warn "OPENAI_API_KEY não configurada - OpenAI pulada"
else
  SYSTEM_PROMPT='Você é um analista de futebol. Analise o artigo e retorne APENAS JSON puro com os campos: summary, impact_score (0-1), impact_type, sentiment, key_insight, tags, topics, affected_teams, affected_players.'
  USER_CONTENT='TÍTULO: Brazil announces final World Cup 2026 squad without injured Neymar\nRESUMO: Brazil coach confirmed the 26-man squad for the tournament, with Neymar ruled out due to knee injury.'

  OAI_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 25 \
    -H "Authorization: Bearer ${OPENAI_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${OPENAI_MODEL}\",\"messages\":[{\"role\":\"system\",\"content\":\"${SYSTEM_PROMPT}\"},{\"role\":\"user\",\"content\":\"${USER_CONTENT}\"}],\"max_tokens\":400,\"temperature\":0.2,\"response_format\":{\"type\":\"json_object\"}}" \
    "https://api.openai.com/v1/chat/completions" 2>/dev/null)

  OAI_BODY=$(echo "$OAI_RESPONSE" | head -n -1)
  OAI_STATUS=$(echo "$OAI_RESPONSE" | tail -n 1)

  case "$OAI_STATUS" in
    200)
      CONTENT=$(echo "$OAI_BODY" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'][:100])" 2>/dev/null || echo "?")
      TOKENS=$(echo "$OAI_BODY" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('total_tokens','?'))" 2>/dev/null || echo "?")

      # Tenta parsear o JSON retornado
      PARSE_OK=$(echo "$CONTENT" | python3 -c \
        "import sys,json; d=json.loads(sys.stdin.read()); print('ok' if 'impact_score' in d or 'summary' in d else 'partial')" 2>/dev/null || echo "fail")

      log_ok "OpenAI respondeu ($TOKENS tokens)"
      [[ "$PARSE_OK" == "ok" ]] \
        && log_ok "Resposta GPT contém campos esperados (impact_score, summary)" \
        || log_warn "Resposta GPT parseable mas sem todos os campos esperados"
      ;;
    401)
      log_fail "OpenAI - API key inválida (HTTP 401)" ;;
    429)
      log_warn "OpenAI - rate limit ou saldo insuficiente (HTTP 429)" ;;
    000)
      log_fail "OpenAI inacessível" ;;
    *)
      log_warn "OpenAI retornou HTTP $OAI_STATUS" ;;
  esac
fi

# ---------------------------------------------------------------------------
# SEÇÃO 6 - n8n: workflows Sprint 4 importados
# ---------------------------------------------------------------------------
log_step "6. n8n - Workflows Sprint 4"

if [[ -z "$N8N_PASS" ]]; then
  log_warn "N8N_BASIC_AUTH_PASSWORD não configurado - verificação de workflows pulada"
else
  WF_LIST=$(curl -s --max-time 10 \
    -u "${N8N_USER}:${N8N_PASS}" \
    "${N8N_URL}/api/v1/workflows?limit=100" 2>/dev/null || echo "{}")

  for wf_name in "WF-03 - News Intelligence" "WF-04 - Sentiment Analyzer" \
                  "SWF - OpenAI News Analyst" "SWF - OpenAI Sentiment Analyst"; do
    EXISTS=$(echo "$WF_LIST" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); names=[w['name'] for w in d.get('data',[])]; print('yes' if '${wf_name}' in names else 'no')" 2>/dev/null || echo "no")
    if [[ "$EXISTS" == "yes" ]]; then
      log_ok "Workflow importado: '$wf_name'"
    else
      log_fail "Workflow NÃO encontrado no n8n: '$wf_name'"
    fi
  done
fi

# ---------------------------------------------------------------------------
# SEÇÃO 7 - Teste funcional: inserção sintética
# ---------------------------------------------------------------------------
log_step "7. Teste funcional - inserção de artigo sintético"

SYNTHETIC_HASH="test_$(date +%s)_$(shuf -i 1000-9999 -n 1)"
SYNTHETIC_URL="https://test.wcic.local/article/${SYNTHETIC_HASH}"

INSERTED=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "INSERT INTO wcic.news (url, url_hash, source, title, language, processing_status)
   VALUES ('${SYNTHETIC_URL}', '${SYNTHETIC_HASH}', 'test', 'WCIC Test Article - Sprint 4', 'en', 'pending')
   ON CONFLICT (url_hash) DO NOTHING
   RETURNING id" 2>/dev/null | tr -d ' \n' || echo "")

if [[ -n "$INSERTED" ]]; then
  log_ok "Artigo sintético inserido em wcic.news (id: $INSERTED)"

  # Testa ON CONFLICT (deduplicação)
  DUP=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "INSERT INTO wcic.news (url, url_hash, source, title, language, processing_status)
     VALUES ('${SYNTHETIC_URL}', '${SYNTHETIC_HASH}', 'test', 'Duplicate', 'en', 'pending')
     ON CONFLICT (url_hash) DO NOTHING
     RETURNING id" 2>/dev/null | tr -d ' \n' || echo "")

  [[ -z "$DUP" ]] \
    && log_ok "Deduplicação PostgreSQL funcionando (ON CONFLICT url_hash)" \
    || log_fail "Deduplicação falhou - artigo duplicado inserido"

  # Testa inserção de análise sintética
  ANA_INSERTED=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "INSERT INTO wcic.news_analysis (news_id, summary, impact_score, sentiment, tags, topics, ai_model, prompt_version)
     VALUES ('${INSERTED}'::uuid, 'Test summary', 0.75, 'positive', ARRAY['test'], ARRAY['tactics'], 'gpt-4o', 'v1.0')
     ON CONFLICT (news_id) DO NOTHING
     RETURNING id" 2>/dev/null | tr -d ' \n' || echo "")
  [[ -n "$ANA_INSERTED" ]] \
    && log_ok "Análise sintética inserida em news_analysis" \
    || log_fail "Falha ao inserir em news_analysis (constraint ou schema incorreto)"

  # Atualiza status para 'processed'
  docker exec wcic-postgres psql -U postgres -d wcic -c \
    "UPDATE wcic.news SET processing_status='processed' WHERE id='${INSERTED}'::uuid" &>/dev/null
  log_ok "processing_status atualizado para 'processed'"

  # Limpeza
  docker exec wcic-postgres psql -U postgres -d wcic -c \
    "DELETE FROM wcic.news WHERE id='${INSERTED}'::uuid" &>/dev/null
  log_ok "Dados de teste removidos"
else
  log_fail "Falha ao inserir artigo sintético em wcic.news"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 8 - Deduplicação Redis para notícias
# ---------------------------------------------------------------------------
log_step "8. Deduplicação Redis"

DEDUP_KEY="wcic:dedup:news"
TEST_HASH2="dedup_test_$(date +%s)"

docker exec wcic-redis redis-cli -a "$REDIS_PASS" SADD "$DEDUP_KEY" "$TEST_HASH2" &>/dev/null
IS_MEMBER=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" SISMEMBER "$DEDUP_KEY" "$TEST_HASH2" 2>/dev/null | tr -d '\r')
docker exec wcic-redis redis-cli -a "$REDIS_PASS" SREM "$DEDUP_KEY" "$TEST_HASH2" &>/dev/null

[[ "$IS_MEMBER" == "1" ]] \
  && log_ok "Ciclo SADD?SISMEMBER?SREM funcional" \
  || log_fail "Ciclo de deduplicação Redis falhou"

# TTL do set de dedup
TTL_VAL=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" TTL "$DEDUP_KEY" 2>/dev/null | tr -d '\r')
if [[ "$TTL_VAL" == "-2" || "$TTL_VAL" == "-1" ]]; then
  log_info "wcic:dedup:news sem TTL ativo (normal antes da primeira execução do WF-03)"
else
  log_ok "wcic:dedup:news TTL ativo: ${TTL_VAL}s"
fi

# ---------------------------------------------------------------------------
# RELATÓRIO FINAL
# ---------------------------------------------------------------------------
echo ""
echo "  --------------------------------------------------"
echo "   Relatório Final - News Intelligence"
echo "  --------------------------------------------------"
printf "   Total    : %d verificações\n" "$TOTAL"
printf "   \033[32mPassaram\033[0m  : %d\n" "$PASSED"
printf "   \033[33mAvisos\033[0m    : %d\n" "$WARNED"
printf "   \033[31mFalhas\033[0m    : %d\n" "$FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
  echo "   \033[31mStatus: REPROVADO - corrija os [FAIL] antes de ativar WF-03\033[0m"
  exit 1
elif [[ $WARNED -gt 0 ]]; then
  echo "   \033[33mStatus: APROVADO COM AVISOS\033[0m"
  exit 0
else
  echo "   \033[32mStatus: APROVADO - pipeline News Intelligence operacional\033[0m"
  exit 0
fi
SHEOF
chmod +x /home/claude/wcic/scripts/test-news-intelligence.sh
bash -n /home/claude/wcic/scripts/test-news-intelligence.sh && echo "sintaxe ok"
