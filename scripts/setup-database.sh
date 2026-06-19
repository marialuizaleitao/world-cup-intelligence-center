# =============================================================================
# WCIC — scripts/setup-database.sh
#
# Objetivo:
#   1. Carregar as variáveis do arquivo .env
#   2. Validar presença de todas as variáveis obrigatórias
#   3. Gerar docker/postgres/init.generated.sql com as senhas reais
#   4. Executar as migrations e os seeds no PostgreSQL via Docker
#   5. Aplicar grants pós-migration para o metabase_app
#
# Uso:
#   ./scripts/setup-database.sh [--skip-migrations] [--skip-seeds]
#
# Requisitos:
#   - Docker e Docker Compose em execução (postgres healthy)
#   - envsubst instalado (pacote gettext-base no Debian/Ubuntu)
#   - Arquivo .env presente na raiz do projeto
#
# Compatibilidade: Linux, macOS, WSL2
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuração de caminhos (relativos ao diretório do script)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
INIT_TEMPLATE="${PROJECT_ROOT}/docker/postgres/init.sql"
INIT_GENERATED="${PROJECT_ROOT}/docker/postgres/init.generated.sql"
MIGRATIONS_DIR="${PROJECT_ROOT}/database/migrations"
SEEDS_DIR="${PROJECT_ROOT}/database/seeds"
GRANTS_FILE="${PROJECT_ROOT}/scripts/grant-metabase.sql"

# ---------------------------------------------------------------------------
# Flags de controle
# ---------------------------------------------------------------------------
SKIP_MIGRATIONS=false
SKIP_SEEDS=false

for arg in "$@"; do
  case $arg in
    --skip-migrations) SKIP_MIGRATIONS=true ;;
    --skip-seeds)      SKIP_SEEDS=true ;;
    *) echo "[WARN] Argumento desconhecido: $arg" ;;
  esac
done

# ---------------------------------------------------------------------------
# Funções de output
# ---------------------------------------------------------------------------
log_ok()   { echo "[OK]   $*"; }
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_err()  { echo "[ERR]  $*" >&2; }
log_step() { echo ""; echo ">>> $*"; echo ""; }

# ---------------------------------------------------------------------------
# Verificação de dependências
# ---------------------------------------------------------------------------
log_step "Verificando dependências do script"

for cmd in envsubst docker; do
  if ! command -v "$cmd" &>/dev/null; then
    log_err "Comando '$cmd' não encontrado."
    if [[ "$cmd" == "envsubst" ]]; then
      log_err "Instale com: sudo apt-get install -y gettext-base  (Debian/Ubuntu/WSL)"
      log_err "             brew install gettext  (macOS)"
    fi
    exit 1
  fi
  log_ok "$cmd encontrado em $(command -v "$cmd")"
done

# ---------------------------------------------------------------------------
# Carregamento do .env
# ---------------------------------------------------------------------------
log_step "Carregando variáveis de ambiente"

if [[ ! -f "$ENV_FILE" ]]; then
  log_err "Arquivo .env não encontrado em: $ENV_FILE"
  log_err "Copie o arquivo de exemplo: cp .env.example .env"
  exit 1
fi

# Exporta as variáveis do .env (ignora linhas comentadas e vazias)
set -o allexport
# shellcheck disable=SC1090
source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$')
set +o allexport

log_ok ".env carregado de: $ENV_FILE"

# ---------------------------------------------------------------------------
# Validação das variáveis obrigatórias
# ---------------------------------------------------------------------------
log_step "Validando variáveis obrigatórias"

REQUIRED_VARS=(
  "POSTGRES_ROOT_PASSWORD"
  "POSTGRES_N8N_PASSWORD"
  "POSTGRES_WCIC_PASSWORD"
  "POSTGRES_METABASE_PASSWORD"
  "POSTGRES_GRAFANA_PASSWORD"
  "REDIS_PASSWORD"
  "N8N_ENCRYPTION_KEY"
  "N8N_BASIC_AUTH_USER"
  "N8N_BASIC_AUTH_PASSWORD"
  "WEBHOOK_URL"
  "API_JWT_SECRET"
  "API_WEBHOOK_SECRET"
  "GRAFANA_ADMIN_PASSWORD"
)

VALIDATION_FAILED=false

for var in "${REQUIRED_VARS[@]}"; do
  value="${!var:-}"
  if [[ -z "$value" ]]; then
    log_err "Variável obrigatória ausente ou vazia: $var"
    VALIDATION_FAILED=true
  else
    # Exibe os primeiros 4 chars seguidos de *** para não expor o valor
    masked="${value:0:4}***"
    log_ok "$var carregado (${masked})"
  fi
done

if [[ "$VALIDATION_FAILED" == "true" ]]; then
  log_err ""
  log_err "Corrija as variáveis ausentes no arquivo .env e execute novamente."
  exit 1
fi

# ---------------------------------------------------------------------------
# Geração do init.generated.sql via envsubst
# ---------------------------------------------------------------------------
log_step "Gerando docker/postgres/init.generated.sql"

if [[ ! -f "$INIT_TEMPLATE" ]]; then
  log_err "Template não encontrado: $INIT_TEMPLATE"
  exit 1
fi

# envsubst com lista explícita de variáveis evita substituição acidental
# de placeholders SQL que contenham $ (ex: $1 em procedimentos)
VARS_TO_SUBSTITUTE='${POSTGRES_N8N_PASSWORD}${POSTGRES_WCIC_PASSWORD}${POSTGRES_METABASE_PASSWORD}${POSTGRES_GRAFANA_PASSWORD}'

envsubst "$VARS_TO_SUBSTITUTE" < "$INIT_TEMPLATE" > "$INIT_GENERATED"

# Verifica se ainda existem placeholders não substituídos
if grep -q '\${POSTGRES_' "$INIT_GENERATED"; then
  log_err "Placeholders não substituídos encontrados em init.generated.sql"
  log_err "Verifique se todas as variáveis POSTGRES_* estão no .env"
  exit 1
fi

log_ok "Gerado: $INIT_GENERATED"
log_warn "ATENÇÃO: init.generated.sql contém senhas em texto plano."
log_warn "         Adicione ao .gitignore se ainda não estiver."

# Verifica .gitignore
if [[ -f "${PROJECT_ROOT}/.gitignore" ]]; then
  if ! grep -q "init.generated.sql" "${PROJECT_ROOT}/.gitignore"; then
    echo "docker/postgres/init.generated.sql" >> "${PROJECT_ROOT}/.gitignore"
    log_ok "init.generated.sql adicionado ao .gitignore automaticamente"
  fi
fi

# ---------------------------------------------------------------------------
# Verificação de que o container postgres está saudável
# ---------------------------------------------------------------------------
log_step "Verificando saúde do container postgres"

POSTGRES_CONTAINER="wcic-postgres"
MAX_WAIT=60
WAITED=0

until docker exec "$POSTGRES_CONTAINER" pg_isready -U postgres -q 2>/dev/null; do
  if [[ $WAITED -ge $MAX_WAIT ]]; then
    log_err "Container postgres não ficou saudável em ${MAX_WAIT}s."
    log_err "Execute: docker-compose up -d postgres"
    exit 1
  fi
  log_info "Aguardando postgres... (${WAITED}s)"
  sleep 3
  WAITED=$((WAITED + 3))
done

log_ok "Container $POSTGRES_CONTAINER está saudável"

# ---------------------------------------------------------------------------
# Helper: executa SQL no postgres via docker exec
# ---------------------------------------------------------------------------
pg_exec() {
  local db="$1"
  local sql="$2"
  docker exec -i "$POSTGRES_CONTAINER" \
    psql -U postgres -d "$db" -v ON_ERROR_STOP=1 -c "$sql"
}

pg_exec_file() {
  local db="$1"
  local file="$2"
  docker exec -i "$POSTGRES_CONTAINER" \
    psql -U postgres -d "$db" -v ON_ERROR_STOP=1 \
    < "$file"
}

# ---------------------------------------------------------------------------
# Verificação: init.generated.sql já foi aplicado?
# Detecta pela existência do database n8n
# ---------------------------------------------------------------------------
log_step "Verificando estado do banco de dados"

DB_EXISTS=$(docker exec "$POSTGRES_CONTAINER" \
  psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='n8n'" 2>/dev/null || echo "")

if [[ "$DB_EXISTS" == "1" ]]; then
  log_warn "Databases já existem — pulando aplicação do init.generated.sql"
  log_warn "Para recriar do zero: docker-compose down -v && docker-compose up -d postgres"
else
  log_step "Aplicando init.generated.sql (criação de usuários e databases)"
  pg_exec_file "postgres" "$INIT_GENERATED"
  log_ok "init.generated.sql aplicado com sucesso"
fi

# ---------------------------------------------------------------------------
# Migrations
# ---------------------------------------------------------------------------
if [[ "$SKIP_MIGRATIONS" == "false" ]]; then
  log_step "Executando migrations (database: wcic)"

  MIGRATIONS=(
    "001_initial_schema.sql"
    "002_indexes.sql"
    "003_views.sql"
    "004_hypertables.sql"
  )

  for migration in "${MIGRATIONS[@]}"; do
    migration_file="${MIGRATIONS_DIR}/${migration}"
    if [[ ! -f "$migration_file" ]]; then
      log_warn "Migration não encontrada (pulando): $migration_file"
      continue
    fi

    # Verifica se a migration já foi aplicada (tabela de controle simples)
    ALREADY_APPLIED=$(pg_exec "wcic" \
      "SELECT 1 FROM pg_tables WHERE schemaname='public' AND tablename='schema_migrations'" 2>/dev/null \
      | grep -c "1" || echo "0")

    if [[ "$ALREADY_APPLIED" == "0" ]]; then
      # Cria tabela de controle de migrations na primeira execução
      pg_exec "wcic" "
        CREATE TABLE IF NOT EXISTS public.schema_migrations (
          filename VARCHAR(255) PRIMARY KEY,
          applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
      " > /dev/null
    fi

    MIGRATION_DONE=$(pg_exec "wcic" \
      "SELECT 1 FROM public.schema_migrations WHERE filename='${migration}'" 2>/dev/null \
      | grep -c "1" || echo "0")

    if [[ "$MIGRATION_DONE" == "1" ]]; then
      log_info "Já aplicada: $migration"
      continue
    fi

    log_info "Aplicando: $migration"
    pg_exec_file "wcic" "$migration_file"
    pg_exec "wcic" \
      "INSERT INTO public.schema_migrations (filename) VALUES ('${migration}') ON CONFLICT DO NOTHING;" > /dev/null
    log_ok "Aplicada: $migration"
  done
else
  log_warn "Migrations ignoradas (--skip-migrations)"
fi

# ---------------------------------------------------------------------------
# Seeds
# ---------------------------------------------------------------------------
if [[ "$SKIP_SEEDS" == "false" ]]; then
  log_step "Executando seeds (database: wcic)"

  SEEDS=(
    "001_teams.sql"
    "002_venues.sql"
  )

  for seed in "${SEEDS[@]}"; do
    seed_file="${SEEDS_DIR}/${seed}"
    if [[ ! -f "$seed_file" ]]; then
      log_warn "Seed não encontrada (pulando): $seed_file"
      continue
    fi

    SEED_DONE=$(pg_exec "wcic" \
      "SELECT 1 FROM public.schema_migrations WHERE filename='seed_${seed}'" 2>/dev/null \
      | grep -c "1" || echo "0")

    if [[ "$SEED_DONE" == "1" ]]; then
      log_info "Já aplicada: $seed"
      continue
    fi

    log_info "Aplicando seed: $seed"
    pg_exec_file "wcic" "$seed_file"
    pg_exec "wcic" \
      "INSERT INTO public.schema_migrations (filename) VALUES ('seed_${seed}') ON CONFLICT DO NOTHING;" > /dev/null
    log_ok "Aplicada: $seed"
  done
else
  log_warn "Seeds ignoradas (--skip-seeds)"
fi

# ---------------------------------------------------------------------------
# Grants pós-migration para metabase_app no schema wcic
# (só possível após as migrations criarem o schema e as tabelas)
# ---------------------------------------------------------------------------
log_step "Aplicando grants do metabase_app no schema wcic"

GRANT_DONE=$(pg_exec "wcic" \
  "SELECT 1 FROM public.schema_migrations WHERE filename='grant_metabase'" 2>/dev/null \
  | grep -c "1" || echo "0")

if [[ "$GRANT_DONE" == "1" ]]; then
  log_info "Grants do metabase_app já aplicados"
else
  pg_exec "wcic" "
    GRANT USAGE ON SCHEMA wcic TO metabase_app;
    GRANT SELECT ON ALL TABLES IN SCHEMA wcic TO metabase_app;
    ALTER DEFAULT PRIVILEGES IN SCHEMA wcic GRANT SELECT ON TABLES TO metabase_app;
  " > /dev/null
  pg_exec "wcic" \
    "INSERT INTO public.schema_migrations (filename) VALUES ('grant_metabase') ON CONFLICT DO NOTHING;" > /dev/null
  log_ok "Grants do metabase_app aplicados no schema wcic"
fi

# ---------------------------------------------------------------------------
# Resumo final
# ---------------------------------------------------------------------------
log_step "Setup concluído com sucesso"

echo "  Serviço     │ Database  │ Usuário"
echo "  ────────────┼───────────┼─────────────"
echo "  n8n         │ n8n       │ n8n_app"
echo "  api         │ wcic      │ wcic_app"
echo "  metabase    │ metabase  │ metabase_app (+ leitura em wcic)"
echo "  grafana     │ grafana   │ grafana_app"
echo "  exporter    │ wcic      │ postgres (superuser, read-only queries)"
echo ""
echo "  Acesse o n8n em:     ${WEBHOOK_URL}"
echo "  Acesse o Grafana em: http://localhost:3000"
echo "  Acesse o Metabase em: http://localhost:3001"
echo ""
log_ok "Próximo passo: ./scripts/import-workflows.sh"
