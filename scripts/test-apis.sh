# =============================================================================
# WCIC - scripts/test-apis.sh
#
# Valida a conectividade e as credenciais de todos os serviços externos e internos.
# Produz relatório com [OK] / [WARN] / [FAIL] para cada verificação.
#
# Uso:
#   ./scripts/test-apis.sh [--verbose] [--only postgres|redis|n8n|football|openai]
#
# Saída:
#   Exit 0 - todos os testes passaram ou apenas WARNs
#   Exit 1 - pelo menos um FAIL
#
# Compatibilidade: Linux, macOS, WSL2
# =============================================================================

set -uo pipefail
# Nota: sem -e pra que falhas individuais não parem o script

# ---------------------------------------------------------------------------
# Paths e configuração
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

VERBOSE=false
ONLY_SERVICE=""

for arg in "$@"; do
  case $arg in
    --verbose)    VERBOSE=true ;;
    --only=*)     ONLY_SERVICE="${arg#--only=}" ;;
    --only)       shift; ONLY_SERVICE="${1:-}" ;;
    -h|--help)
      echo "Uso: $0 [--verbose] [--only postgres|redis|n8n|football|openai]"
      exit 0
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Contadores globais
# ---------------------------------------------------------------------------
TOTAL=0
PASSED=0
WARNED=0
FAILED=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
_result() {
  local status="$1"
  local label="$2"
  local detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  case "$status" in
    OK)
      PASSED=$((PASSED + 1))
      printf "  \033[32m[OK  ]\033[0m %s" "$label"
      [[ -n "$detail" && "$VERBOSE" == "true" ]] && printf " - %s" "$detail"
      echo
      ;;
    WARN)
      WARNED=$((WARNED + 1))
      printf "  \033[33m[WARN]\033[0m %s" "$label"
      [[ -n "$detail" ]] && printf " - %s" "$detail"
      echo
      ;;
    FAIL)
      FAILED=$((FAILED + 1))
      printf "  \033[31m[FAIL]\033[0m %s" "$label"
      [[ -n "$detail" ]] && printf " - %s" "$detail"
      echo
      ;;
  esac
}

log_section() {
  echo ""
  echo "  ── $* ──────────────────────────────────────"
}

# ---------------------------------------------------------------------------
# Carregar .env
# ---------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════"
echo "  WCIC - API & Services Connectivity Test"
echo "═══════════════════════════════════════════════════"
echo ""

if [[ ! -f "$ENV_FILE" ]]; then
  echo "  \033[31m[FAIL]\033[0m .env não encontrado em $ENV_FILE"
  echo "  Execute: cp .env.example .env e preencha as variáveis"
  exit 1
fi

set -o allexport
# shellcheck disable=SC1090
source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$') 2>/dev/null || true
set +o allexport

_result OK ".env carregado" "$ENV_FILE"

# ---------------------------------------------------------------------------
# SEÇÃO 1 - PostgreSQL
# ---------------------------------------------------------------------------
should_run() { [[ -z "$ONLY_SERVICE" || "$ONLY_SERVICE" == "$1" ]]; }

if should_run "postgres"; then
  log_section "PostgreSQL"

  PG_HOST="${POSTGRES_HOST:-localhost}"
  PG_PORT="${POSTGRES_PORT:-5432}"
  PG_ROOT_PASS="${POSTGRES_ROOT_PASSWORD:-}"

  # Verificar se o container está rodando
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "wcic-postgres"; then
    _result OK "Container wcic-postgres está rodando"
  else
    _result FAIL "Container wcic-postgres não encontrado" "Execute: docker-compose up -d postgres"
  fi

  # Testar conexão como superuser
  if [[ -z "$PG_ROOT_PASS" ]]; then
    _result WARN "POSTGRES_ROOT_PASSWORD não definido" "Pulando testes de conexão"
  else
    # Ping básico
    if docker exec wcic-postgres pg_isready -U postgres -q 2>/dev/null; then
      _result OK "PostgreSQL aceitando conexões"
    else
      _result FAIL "PostgreSQL não está respondendo" "Verifique: docker logs wcic-postgres"
    fi

    # Verificar databases
    for db in n8n wcic metabase grafana; do
      EXISTS=$(docker exec wcic-postgres psql -U postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${db}'" 2>/dev/null || echo "")
      if [[ "$EXISTS" == "1" ]]; then
        _result OK "Database '$db' existe"
      else
        _result FAIL "Database '$db' não encontrado" "Execute: ./scripts/setup-database.sh"
      fi
    done

    # Verificar schema wcic
    SCHEMA_EXISTS=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
      "SELECT 1 FROM information_schema.schemata WHERE schema_name='wcic'" 2>/dev/null || echo "")
    if [[ "$SCHEMA_EXISTS" == "1" ]]; then
      _result OK "Schema 'wcic' existe"
    else
      _result FAIL "Schema 'wcic' não encontrado" "Execute as migrations"
    fi

    # Verificar tabelas críticas
    for table in teams venues matches match_events workflow_logs; do
      TABLE_EXISTS=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
        "SELECT 1 FROM information_schema.tables WHERE table_schema='wcic' AND table_name='${table}'" 2>/dev/null || echo "")
      if [[ "$TABLE_EXISTS" == "1" ]]; then
        _result OK "Tabela 'wcic.${table}' existe"
      else
        _result FAIL "Tabela 'wcic.${table}' não encontrada" "Execute: ./scripts/setup-database.sh"
      fi
    done

    # Verificar seeds
    TEAM_COUNT=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
      "SELECT COUNT(*) FROM wcic.teams" 2>/dev/null | tr -d ' ' || echo "0")
    if [[ "${TEAM_COUNT:-0}" -ge 48 ]]; then
      _result OK "Times populados ($TEAM_COUNT times)"
    elif [[ "${TEAM_COUNT:-0}" -gt 0 ]]; then
      _result WARN "Apenas $TEAM_COUNT times - esperado 48" "Execute: ./scripts/setup-database.sh"
    else
      _result FAIL "Tabela teams vazia" "Execute seeds: ./scripts/setup-database.sh"
    fi

    VENUE_COUNT=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
      "SELECT COUNT(*) FROM wcic.venues" 2>/dev/null | tr -d ' ' || echo "0")
    if [[ "${VENUE_COUNT:-0}" -ge 16 ]]; then
      _result OK "Venues populados ($VENUE_COUNT estádios)"
    else
      _result FAIL "Tabela venues vazia ou incompleta ($VENUE_COUNT)" "Execute seeds"
    fi

    # Verificar migration 005
    M005=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
      "SELECT 1 FROM public.schema_migrations WHERE filename='005_fix_sprint2.sql'" 2>/dev/null || echo "")
    if [[ "$M005" == "1" ]]; then
      _result OK "Migration 005 (fix_sprint2) aplicada"
    else
      _result WARN "Migration 005 não aplicada" "Execute: ./scripts/setup-database.sh"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# SEÇÃO 2 - Redis
# ---------------------------------------------------------------------------
if should_run "redis"; then
  log_section "Redis"

  REDIS_PASS="${REDIS_PASSWORD:-}"

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "wcic-redis"; then
    _result OK "Container wcic-redis está rodando"
  else
    _result FAIL "Container wcic-redis não encontrado" "Execute: docker-compose up -d redis"
  fi

  if [[ -z "$REDIS_PASS" ]]; then
    _result WARN "REDIS_PASSWORD não definido" "Pulando testes de conexão"
  else
    PING=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" ping 2>/dev/null | tr -d '\r')
    if [[ "$PING" == "PONG" ]]; then
      _result OK "Redis respondeu ao PING"
    else
      _result FAIL "Redis não respondeu" "Resposta: ${PING:-nenhuma}"
    fi

    # Verificar memória
    MEM_USED=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" info memory 2>/dev/null \
      | grep "used_memory_human" | cut -d: -f2 | tr -d '\r ' || echo "?")
    _result OK "Redis memória em uso: $MEM_USED"

    # Teste de escrita e leitura
    TEST_KEY="wcic:test:connectivity:$(date +%s)"
    SET_RESULT=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
      SET "$TEST_KEY" "ok" EX 10 2>/dev/null | tr -d '\r')
    GET_RESULT=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
      GET "$TEST_KEY" 2>/dev/null | tr -d '\r')

    if [[ "$SET_RESULT" == "OK" && "$GET_RESULT" == "ok" ]]; then
      _result OK "Redis leitura/escrita funcionando"
      # Limpa chave de teste
      docker exec wcic-redis redis-cli -a "$REDIS_PASS" DEL "$TEST_KEY" &>/dev/null
    else
      _result FAIL "Redis leitura/escrita falhou" "SET=$SET_RESULT GET=$GET_RESULT"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# SEÇÃO 3 - n8n
# ---------------------------------------------------------------------------
if should_run "n8n"; then
  log_section "n8n"

  N8N_URL="${WEBHOOK_URL:-http://localhost:5678}"
  N8N_URL="${N8N_URL%/}"
  N8N_USER="${N8N_BASIC_AUTH_USER:-admin}"
  N8N_PASS="${N8N_BASIC_AUTH_PASSWORD:-}"

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "wcic-n8n-main"; then
    _result OK "Container wcic-n8n-main está rodando"
  else
    _result FAIL "Container wcic-n8n-main não encontrado" "Execute: docker-compose up -d n8n"
  fi

  # Workers
  for worker in wcic-n8n-worker-1 wcic-n8n-worker-2; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$worker"; then
      _result OK "Container $worker está rodando"
    else
      _result WARN "Container $worker não encontrado" "Execute: docker-compose up -d $worker"
    fi
  done

  if [[ -z "$N8N_PASS" ]]; then
    _result WARN "N8N_BASIC_AUTH_PASSWORD não definido" "Pulando testes de API"
  else
    # Testar health endpoint
    HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 10 "${N8N_URL}/healthz" 2>/dev/null || echo "000")
    if [[ "$HEALTH_STATUS" == "200" ]]; then
      _result OK "n8n health endpoint respondeu (HTTP 200)"
    else
      _result FAIL "n8n health endpoint falhou (HTTP $HEALTH_STATUS)" "$N8N_URL/healthz"
    fi

    # Testar API com autenticação
    API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 10 \
      -u "${N8N_USER}:${N8N_PASS}" \
      "${N8N_URL}/api/v1/workflows" 2>/dev/null || echo "000")

    case "$API_STATUS" in
      200) _result OK "n8n API autenticada (HTTP 200)" ;;
      401) _result FAIL "Credenciais n8n inválidas (HTTP 401)" "Verifique N8N_BASIC_AUTH_*" ;;
      000) _result FAIL "n8n API inacessível" "$N8N_URL/api/v1/workflows" ;;
      *)   _result WARN "n8n API retornou HTTP $API_STATUS" ;;
    esac

    # Contar workflows importados
    if [[ "$API_STATUS" == "200" ]]; then
      WF_COUNT=$(curl -s \
        --max-time 10 \
        -u "${N8N_USER}:${N8N_PASS}" \
        "${N8N_URL}/api/v1/workflows?limit=100" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null || echo "?")
      _result OK "Workflows no n8n: $WF_COUNT"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# SEÇÃO 4 - Football-Data API
# ---------------------------------------------------------------------------
if should_run "football"; then
  log_section "Football-Data API (Provider Primário)"

  FD_KEY="${FOOTBALL_DATA_API_KEY:-}"

  if [[ -z "$FD_KEY" ]]; then
    _result WARN "FOOTBALL_DATA_API_KEY não definido" "Teste pulado"
  else
    # Testar endpoint de competições (lightweight - não consome rate limit significativo)
    FD_RESPONSE=$(curl -s -w "\n%{http_code}" \
      --max-time 15 \
      -H "X-Auth-Token: ${FD_KEY}" \
      "https://api.football-data.org/v4/competitions/WC" 2>/dev/null)

    FD_BODY=$(echo "$FD_RESPONSE" | head -n -1)
    FD_STATUS=$(echo "$FD_RESPONSE" | tail -n 1)

    case "$FD_STATUS" in
      200)
        COMP_NAME=$(echo "$FD_BODY" | python3 -c \
          "import sys,json; d=json.load(sys.stdin); print(d.get('name','?'))" 2>/dev/null || echo "?")
        _result OK "Football-Data API respondeu - Competição: $COMP_NAME"

        # Verifica rate limit headers
        CALLS_AVAILABLE=$(curl -s -I \
          --max-time 10 \
          -H "X-Auth-Token: ${FD_KEY}" \
          "https://api.football-data.org/v4/competitions" 2>/dev/null \
          | grep -i "x-requests-available-minute" | awk '{print $2}' | tr -d '\r' || echo "?")
        if [[ -n "$CALLS_AVAILABLE" && "$CALLS_AVAILABLE" != "?" ]]; then
          _result OK "Rate limit disponível: $CALLS_AVAILABLE req/min restantes"
        fi
        ;;
      401)
        _result FAIL "Football-Data API - token inválido (HTTP 401)" \
          "Verifique FOOTBALL_DATA_API_KEY no .env"
        ;;
      403)
        _result WARN "Football-Data API - token sem acesso à Copa do Mundo (HTTP 403)" \
          "Verifique plano da conta em football-data.org"
        ;;
      429)
        _result WARN "Football-Data API - rate limit atingido (HTTP 429)" \
          "Aguarde 1 minuto e teste novamente"
        ;;
      000)
        _result FAIL "Football-Data API inacessível" "Verifique conectividade de rede"
        ;;
      *)
        _result WARN "Football-Data API retornou HTTP $FD_STATUS" "$FD_BODY"
        ;;
    esac

    # Fallback - RapidAPI
    RA_KEY="${RAPIDAPI_KEY:-}"
    if [[ -z "$RA_KEY" ]]; then
      _result WARN "RAPIDAPI_KEY não definido" "Fallback API não testada"
    else
      RA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 15 \
        -H "X-RapidAPI-Key: ${RA_KEY}" \
        -H "X-RapidAPI-Host: api-football-v1.p.rapidapi.com" \
        "https://api-football-v1.p.rapidapi.com/v3/status" 2>/dev/null || echo "000")
      case "$RA_STATUS" in
        200) _result OK "RapidAPI Football (fallback) acessível" ;;
        401|403) _result WARN "RapidAPI Football - credencial inválida (HTTP $RA_STATUS)" ;;
        *) _result WARN "RapidAPI Football retornou HTTP $RA_STATUS" ;;
      esac
    fi
  fi
fi

# ---------------------------------------------------------------------------
# SEÇÃO 5 - OpenAI
# ---------------------------------------------------------------------------
if should_run "openai"; then
  log_section "OpenAI API"

  OAI_KEY="${OPENAI_API_KEY:-}"
  OAI_MODEL="${OPENAI_MODEL:-gpt-4o}"

  if [[ -z "$OAI_KEY" ]]; then
    _result WARN "OPENAI_API_KEY não definido" "Teste pulado"
  else
    # Testar com requisição mínima (1 token de input, 1 de output)
    OAI_RESPONSE=$(curl -s -w "\n%{http_code}" \
      --max-time 20 \
      -H "Authorization: Bearer ${OAI_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"${OAI_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
      "https://api.openai.com/v1/chat/completions" 2>/dev/null)

    OAI_BODY=$(echo "$OAI_RESPONSE" | head -n -1)
    OAI_STATUS=$(echo "$OAI_RESPONSE" | tail -n 1)

    case "$OAI_STATUS" in
      200)
        USED_MODEL=$(echo "$OAI_BODY" | python3 -c \
          "import sys,json; d=json.load(sys.stdin); print(d.get('model','?'))" 2>/dev/null || echo "?")
        _result OK "OpenAI API respondeu - modelo: $USED_MODEL"

        # Verifica se é o modelo correto
        if [[ "$USED_MODEL" != "$OAI_MODEL"* ]]; then
          _result WARN "Modelo retornado ($USED_MODEL) diferente do configurado ($OAI_MODEL)"
        fi
        ;;
      401)
        _result FAIL "OpenAI API - chave inválida (HTTP 401)" "Verifique OPENAI_API_KEY"
        ;;
      429)
        _result WARN "OpenAI API - rate limit ou saldo insuficiente (HTTP 429)" \
          "Verifique billing em platform.openai.com"
        ;;
      000)
        _result FAIL "OpenAI API inacessível" "Verifique conectividade de rede"
        ;;
      *)
        ERROR_MSG=$(echo "$OAI_BODY" | python3 -c \
          "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('message','?'))" 2>/dev/null || echo "?")
        _result WARN "OpenAI API retornou HTTP $OAI_STATUS" "$ERROR_MSG"
        ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# RELATÓRIO FINAL
# ---------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════"
echo "  Relatório Final"
echo "═══════════════════════════════════════════════════"
printf "  Total de verificações : %d\n" "$TOTAL"
printf "  \033[32mPassaram [OK]  \033[0m        : %d\n" "$PASSED"
printf "  \033[33mAvisos   [WARN]\033[0m        : %d\n" "$WARNED"
printf "  \033[31mFalhas   [FAIL]\033[0m        : %d\n" "$FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
  echo "  \033[31mStatus: REPROVADO - $FAILED verificação(ões) falharam\033[0m"
  echo "  Revise os itens [FAIL] acima antes de continuar."
  echo ""
  exit 1
elif [[ $WARNED -gt 0 ]]; then
  echo "  \033[33mStatus: APROVADO COM AVISOS - sistema funcional, mas verifique os [WARN]\033[0m"
  echo ""
  exit 0
else
  echo "  \033[32mStatus: APROVADO - todos os serviços operacionais\033[0m"
  echo ""
  exit 0
fi
SHEOF
chmod +x /home/claude/wcic/scripts/test-apis.sh
bash -n /home/claude/wcic/scripts/test-apis.sh && echo "sintaxe ok"
