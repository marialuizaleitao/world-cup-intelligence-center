-- =============================================================================
-- WCIC — docker/postgres/init.sql
--
-- Obs: esse arquivo contém placeholders que são substituídos pelo script
-- scripts/setup-database.sh antes de ser usado pelo container.
--
-- NÃO execute este arquivo diretamente no PostgreSQL.
-- Use o arquivo gerado: docker/postgres/init.generated.sql
--
-- Placeholders (substituídos via envsubst):
--   ${POSTGRES_N8N_PASSWORD}
--   ${POSTGRES_WCIC_PASSWORD}
--   ${POSTGRES_METABASE_PASSWORD}
--   ${POSTGRES_GRAFANA_PASSWORD}
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Usuário e database do n8n
-- Usado por: n8n, n8n-worker-1, n8n-worker-2
-- ---------------------------------------------------------------------------
CREATE USER n8n_app WITH PASSWORD '${POSTGRES_N8N_PASSWORD}';
CREATE DATABASE n8n OWNER n8n_app ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8';

GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n_app;

-- ---------------------------------------------------------------------------
-- Usuário e database do WCIC (dados da aplicação)
-- Usado por: api (wcic_app com DML completo)
--            n8n acessa via credencial configurada internamente no n8n
-- ---------------------------------------------------------------------------
CREATE USER wcic_app WITH PASSWORD '${POSTGRES_WCIC_PASSWORD}';
CREATE DATABASE wcic OWNER wcic_app ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8';

GRANT ALL PRIVILEGES ON DATABASE wcic TO wcic_app;

-- ---------------------------------------------------------------------------
-- Usuário e database do Metabase (metadados internos do Metabase)
-- Usado por: serviço metabase para armazenar dashboards e configurações
-- ---------------------------------------------------------------------------
CREATE USER metabase_app WITH PASSWORD '${POSTGRES_METABASE_PASSWORD}';
CREATE DATABASE metabase OWNER metabase_app ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8';

GRANT ALL PRIVILEGES ON DATABASE metabase TO metabase_app;

-- ---------------------------------------------------------------------------
-- Usuário e database do Grafana (metadados internos do Grafana)
-- Usado por: serviço grafana para armazenar dashboards e alertas
-- ---------------------------------------------------------------------------
CREATE USER grafana_app WITH PASSWORD '${POSTGRES_GRAFANA_PASSWORD}';
CREATE DATABASE grafana OWNER grafana_app ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8';

GRANT ALL PRIVILEGES ON DATABASE grafana TO grafana_app;

-- ---------------------------------------------------------------------------
-- Permissão de leitura do metabase_app no banco wcic
--
-- IMPORTANTE: o schema "wcic" e suas tabelas são criados pelas migrations
-- (database/migrations/001_initial_schema.sql) que rodam DEPOIS deste init.
-- Por isso, os GRANTs de SELECT nas tabelas são aplicados pelo script
-- scripts/setup-database.sh via scripts/grant-metabase.sql após as migrations.
--
-- Aqui concedemos apenas o CONNECT e USAGE no schema public como base.
-- ---------------------------------------------------------------------------
GRANT CONNECT ON DATABASE wcic TO metabase_app;

-- ---------------------------------------------------------------------------
-- Extensões necessárias no banco wcic
-- Instaladas aqui pois requerem superuser (postgres)
-- As migrations assumem que estas extensões já existem
-- ---------------------------------------------------------------------------
\connect wcic

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "timescaledb";

-- Retorna ao banco padrão
\connect postgres

-- =============================================================================
-- FIM DO INIT
-- Próximo passo: scripts/setup-database.sh executa as migrations e seeds
-- =============================================================================
