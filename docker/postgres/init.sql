-- =============================================================================
-- WCIC — docker/postgres/init.sql
-- Executado automaticamente pelo container na primeira inicialização
-- Cria os databases e usuários necessários para cada serviço
-- =============================================================================

-- Usuário para o n8n
CREATE USER n8n_app WITH PASSWORD 'PLACEHOLDER_REPLACED_BY_ENV';
CREATE DATABASE n8n OWNER n8n_app;

-- Usuário para a aplicação WCIC (workflows + API)
CREATE USER wcic_app WITH PASSWORD 'PLACEHOLDER_REPLACED_BY_ENV';
CREATE DATABASE wcic OWNER wcic_app;

-- Usuário para o Metabase (somente leitura)
CREATE USER metabase_app WITH PASSWORD 'PLACEHOLDER_REPLACED_BY_ENV';
CREATE DATABASE metabase OWNER metabase_app;

-- Usuário para o Grafana
CREATE USER grafana_app WITH PASSWORD 'PLACEHOLDER_REPLACED_BY_ENV';
CREATE DATABASE grafana OWNER grafana_app;

-- Metabase lê do banco WCIC (somente leitura)
\c wcic
GRANT CONNECT ON DATABASE wcic TO metabase_app;
GRANT USAGE ON SCHEMA wcic TO metabase_app;
GRANT SELECT ON ALL TABLES IN SCHEMA wcic TO metabase_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA wcic GRANT SELECT ON TABLES TO metabase_app;

-- =============================================================================
-- Obs: as senhas acima são substituídas pelo script setup-database.sh
-- que lê os valores corretos do arquivo .env antes de executar esse SQL.
-- =============================================================================
