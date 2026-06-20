# =============================================================================
# WCIC - scripts/import-workflows.sh
#
# Importa todos os workflows da pasta n8n/workflows/ para a instância n8n
# via API REST do n8n.
#
# Uso:
#   ./scripts/import-workflows.sh [--dry-run] [--file WF-01-match-collector.json]
#
# Pré-requisitos:
#   - n8n em execução e acessível (WEBHOOK_URL ou N8N_URL no .env)
#   - N8N_BASIC_AUTH_USER e N8N_BASIC_AUTH_PASSWORD no .env
#   - curl instalado
#   - jq instalado (sudo apt-get install -y jq)
#
# Compatibilidade: Linux, macOS, WSL2
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
WORKFLOWS_DIR="${PROJECT_ROOT}/n8n/workflows"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
DRY_RUN=false
SINGLE_FILE=""

for arg in "$@"; do
  case $arg in
    --dry-run)       DRY_RUN=true ;;
    --file=*)        SINGLE_FILE="${arg#--file=}" ;;
    --file)          shift; SINGLE_FILE="${1:-}" ;;
    -h|--help)
      echo "Uso: $0 [--dry-run] [--file FILENAME.json]"
      echo "  --dry-run   Valida workflows sem importar"
      echo "  --file      Importa apenas um arquivo específico"
      exit 0
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
log_ok()   { echo "  [OK]   $*"; }
log_info() { echo "  [INFO] $*"; }
log_warn() { echo "  [WARN] $*"; }
log_err()  { echo "  [ERR]  $*" >&2; }
log_step() { echo ""; echo "? $*"; }

# ---------------------------------------------------------------------------
# Dependências
# ---------------------------------------------------------------------------
log_step "Verificando dependências"

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    log_err "$cmd não encontrado."
    [[ "$cmd" == "jq" ]] && log_err "Instale: sudo apt-get install -y jq  |  brew install jq"
    exit 1
  fi
  log_ok "$cmd disponível"
done

# ---------------------------------------------------------------------------
# Carregar .env
# ---------------------------------------------------------------------------
log_step "Carregando configuração"

if [[ ! -f "$ENV_FILE" ]]; then
  log_err ".env não encontrado em $ENV_FILE"
  exit 1
fi

set -o allexport
# shellcheck disable=SC1090
source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$')
set +o allexport

# ---------------------------------------------------------------------------
# Configuração da URL do n8n
# ---------------------------------------------------------------------------
# Suporta tanto WEBHOOK_URL quanto N8N_URL
N8N_BASE_URL="${WEBHOOK_URL:-http://localhost:5678}"
# Remove trailing slash
N8N_BASE_URL="${N8N_BASE_URL%/}"
N8N_API_URL="${N8N_BASE_URL}/api/v1"

AUTH_USER="${N8N_BASIC_AUTH_USER:-admin}"
AUTH_PASS="${N8N_BASIC_AUTH_PASSWORD:-}"

if [[ -z "$AUTH_PASS" ]]; then
  log_err "N8N_BASIC_AUTH_PASSWORD não definido no .env"
  exit 1
fi

log_ok "n8n URL: $N8N_BASE_URL"
log_ok "Usuário: $AUTH_USER"

# ---------------------------------------------------------------------------
# Testar conectividade com o n8n
# ---------------------------------------------------------------------------
log_step "Testando conectividade com o n8n"

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  -u "${AUTH_USER}:${AUTH_PASS}" \
  "${N8N_API_URL}/workflows" 2>/dev/null || echo "000")

if [[ "$HTTP_STATUS" == "200" ]]; then
  log_ok "n8n API acessível (HTTP $HTTP_STATUS)"
elif [[ "$HTTP_STATUS" == "401" ]]; then
  log_err "Credenciais inválidas (HTTP 401)"
  log_err "Verifique N8N_BASIC_AUTH_USER e N8N_BASIC_AUTH_PASSWORD no .env"
  exit 1
elif [[ "$HTTP_STATUS" == "000" ]]; then
  log_err "n8n inacessível em $N8N_BASE_URL"
  log_err "Execute: docker-compose up -d n8n"
  exit 1
else
  log_err "Resposta inesperada do n8n: HTTP $HTTP_STATUS"
  exit 1
fi

# ---------------------------------------------------------------------------
# Determinar arquivos a importar
# ---------------------------------------------------------------------------
log_step "Descobrindo workflows"

if [[ ! -d "$WORKFLOWS_DIR" ]]; then
  log_err "Diretório não encontrado: $WORKFLOWS_DIR"
  exit 1
fi

if [[ -n "$SINGLE_FILE" ]]; then
  # Modo arquivo único
  if [[ -f "${WORKFLOWS_DIR}/${SINGLE_FILE}" ]]; then
    WORKFLOW_FILES=("${WORKFLOWS_DIR}/${SINGLE_FILE}")
  elif [[ -f "$SINGLE_FILE" ]]; then
    WORKFLOW_FILES=("$SINGLE_FILE")
  else
    log_err "Arquivo não encontrado: $SINGLE_FILE"
    exit 1
  fi
else
  # Todos os workflows na pasta
  mapfile -t WORKFLOW_FILES < <(find "$WORKFLOWS_DIR" -name "*.json" | sort)
fi

if [[ ${#WORKFLOW_FILES[@]} -eq 0 ]]; then
  log_warn "Nenhum arquivo .json encontrado em $WORKFLOWS_DIR"
  exit 0
fi

log_ok "${#WORKFLOW_FILES[@]} arquivo(s) encontrado(s)"
for f in "${WORKFLOW_FILES[@]}"; do
  log_info "  ? $(basename "$f")"
done

# ---------------------------------------------------------------------------
# Buscar workflows existentes no n8n para detectar updates vs creates
# ---------------------------------------------------------------------------
log_step "Buscando workflows existentes no n8n"

EXISTING_WORKFLOWS_JSON=$(curl -s \
  --max-time 15 \
  -u "${AUTH_USER}:${AUTH_PASS}" \
  "${N8N_API_URL}/workflows?limit=100" 2>/dev/null)

# Mapa: nome ? id dos workflows existentes
declare -A EXISTING_MAP
if echo "$EXISTING_WORKFLOWS_JSON" | jq -e '.data' &>/dev/null; then
  while IFS=$'\t' read -r wf_name wf_id; do
    EXISTING_MAP["$wf_name"]="$wf_id"
  done < <(echo "$EXISTING_WORKFLOWS_JSON" | jq -r '.data[] | [.name, .id] | @tsv')
  log_ok "${#EXISTING_MAP[@]} workflow(s) já existente(s) no n8n"
else
  log_warn "Não foi possível buscar workflows existentes — todos serão criados como novos"
fi

# ---------------------------------------------------------------------------
# Importar workflows
# ---------------------------------------------------------------------------
log_step "Importando workflows${DRY_RUN:+ (DRY RUN — sem alterações reais)}"

IMPORTED=0
UPDATED=0
FAILED=0
SKIPPED=0

for wf_file in "${WORKFLOW_FILES[@]}"; do
  filename=$(basename "$wf_file")
  log_info "Processando: $filename"

  # Valida JSON antes de tentar importar
  if ! jq empty "$wf_file" 2>/dev/null; then
    log_err "JSON inválido: $filename — pulando"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Extrai nome do workflow do JSON
  WF_NAME=$(jq -r '.name // "unnamed"' "$wf_file")

  if [[ "$DRY_RUN" == "true" ]]; then
    log_ok "[DRY RUN] $filename — JSON válido, nome: '$WF_NAME'"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Verifica se já existe pelo nome
  EXISTING_ID="${EXISTING_MAP[$WF_NAME]:-}"

  if [[ -n "$EXISTING_ID" ]]; then
    # UPDATE — workflow já existe
    HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
      --max-time 30 \
      -X PUT \
      -u "${AUTH_USER}:${AUTH_PASS}" \
      -H "Content-Type: application/json" \
      -d "@${wf_file}" \
      "${N8N_API_URL}/workflows/${EXISTING_ID}" 2>/dev/null)

    HTTP_BODY=$(echo "$HTTP_RESPONSE" | head -n -1)
    HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n 1)

    if [[ "$HTTP_CODE" == "200" ]]; then
      log_ok "ATUALIZADO: '$WF_NAME' (id: $EXISTING_ID)"
      UPDATED=$((UPDATED + 1))
    else
      ERROR_MSG=$(echo "$HTTP_BODY" | jq -r '.message // "erro desconhecido"' 2>/dev/null || echo "parse error")
      log_err "FALHOU ao atualizar '$WF_NAME': HTTP $HTTP_CODE — $ERROR_MSG"
      FAILED=$((FAILED + 1))
    fi
  else
    # CREATE — novo workflow
    HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
      --max-time 30 \
      -X POST \
      -u "${AUTH_USER}:${AUTH_PASS}" \
      -H "Content-Type: application/json" \
      -d "@${wf_file}" \
      "${N8N_API_URL}/workflows" 2>/dev/null)

    HTTP_BODY=$(echo "$HTTP_RESPONSE" | head -n -1)
    HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n 1)

    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
      NEW_ID=$(echo "$HTTP_BODY" | jq -r '.id // "unknown"' 2>/dev/null || echo "unknown")
      log_ok "IMPORTADO: '$WF_NAME' (novo id: $NEW_ID)"
      IMPORTED=$((IMPORTED + 1))
    else
      ERROR_MSG=$(echo "$HTTP_BODY" | jq -r '.message // "erro desconhecido"' 2>/dev/null || echo "parse error")
      log_err "FALHOU ao importar '$WF_NAME': HTTP $HTTP_CODE — $ERROR_MSG"
      FAILED=$((FAILED + 1))
    fi
  fi
done

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------
echo ""
echo "????????????????????????????????????????"
echo " Resultado da importação"
echo "????????????????????????????????????????"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  Modo DRY RUN — nenhuma alteração foi feita"
  echo "  Workflows válidos: $SKIPPED"
else
  echo "  Novos importados : $IMPORTED"
  echo "  Atualizados      : $UPDATED"
  echo "  Com falha        : $FAILED"
fi

echo ""

if [[ $FAILED -gt 0 ]]; then
  log_err "$FAILED workflow(s) falharam. Revise os erros acima."
  exit 1
fi

if [[ "$DRY_RUN" == "false" && $((IMPORTED + UPDATED)) -gt 0 ]]; then
  echo ""
  log_warn "ATENÇÃO: workflows importados ficam INATIVOS por padrão."
  log_warn "Ative cada workflow manualmente na UI: $N8N_BASE_URL"
  log_warn "Ou use a API:"
  log_warn "  curl -X PATCH -u admin:PASS ${N8N_API_URL}/workflows/{id}/activate"
fi
SHEOF
chmod +x /home/claude/wcic/scripts/import-workflows.sh
bash -n /home/claude/wcic/scripts/import-workflows.sh && echo "sintaxe ok"
