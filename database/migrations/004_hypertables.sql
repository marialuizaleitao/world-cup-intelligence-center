-- =============================================================================
-- WCIC — World Cup Intelligence Center
-- Migration: 004_hypertables.sql
-- Description: Converte tabelas de alta frequência em hypertables TimescaleDB
--              e configura políticas de retenção e compressão
-- Requires: TimescaleDB extension (migration 001 já instala)
-- Run after: 002_indexes.sql, 003_views.sql
-- =============================================================================

SET search_path TO wcic, public;

-- =============================================================================
-- MATCH EVENTS — Hypertable
-- Volume esperado: ~300 eventos/partida × 104 partidas = ~31.200 eventos totais
-- Particionamento: diário (chunk_time_interval = 1 dia)
-- =============================================================================

SELECT create_hypertable(
    'match_events',
    'created_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- Índice no campo de particionamento + match_id para queries comuns
-- Nota: TimescaleDB não herda índices da tabela base para chunks automaticamente
-- Esse índice é criado em todos os chunks existentes e futuros
CREATE INDEX IF NOT EXISTS idx_match_events_chunk_match
    ON match_events(created_at DESC, match_id);

-- Política de compressão: comprime chunks com mais de 7 dias
-- Reduz armazenamento em 90%+ para dados históricos
SELECT add_compression_policy('match_events', INTERVAL '7 days');

-- Política de retenção: remove dados com mais de 1 ano
-- Copa dura ~6 semanas — manter 1 ano para análises históricas
SELECT add_retention_policy('match_events', INTERVAL '1 year');

-- =============================================================================
-- SENTIMENT SNAPSHOTS — Hypertable
-- Volume esperado: ~288 snapshots/dia (a cada 5 min, 64 entidades) × 45 dias = ~829.440 rows
-- Particionamento: diário
-- =============================================================================

SELECT create_hypertable(
    'sentiment_snapshots',
    'captured_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_sentiment_chunk_entity
    ON sentiment_snapshots(captured_at DESC, entity_type, entity_id);

-- Comprime após 3 dias (dados mudam muito — comprimir logo)
SELECT add_compression_policy('sentiment_snapshots', INTERVAL '3 days');

-- Retém por 6 meses (suficiente para análises pós-Copa)
SELECT add_retention_policy('sentiment_snapshots', INTERVAL '6 months');

-- =============================================================================
-- WORKFLOW LOGS — Hypertable
-- Volume esperado: ~500 execuções/dia × 90 dias = ~45.000 rows
-- Particionamento: semanal (menos granular, menos overhead)
-- =============================================================================

SELECT create_hypertable(
    'workflow_logs',
    'started_at',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_workflow_logs_chunk_name
    ON workflow_logs(started_at DESC, workflow_name, status);

-- Comprime após 14 dias
SELECT add_compression_policy('workflow_logs', INTERVAL '14 days');

-- Retém por 90 dias (suficiente para debugging e auditoria)
SELECT add_retention_policy('workflow_logs', INTERVAL '90 days');

-- =============================================================================
-- CONTINUOUS AGGREGATES — Pré-agrega dados frequentes para queries rápidas
-- TimescaleDB feature: materializa agregações incrementalmente
-- =============================================================================

-- Sentimento agregado por hora por entidade
-- Elimina a necessidade de agrupar milhares de snapshots em tempo real
CREATE MATERIALIZED VIEW sentiment_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', captured_at) AS hour,
    entity_type,
    entity_id,
    source,
    AVG(positive_ratio) AS avg_positive,
    AVG(negative_ratio) AS avg_negative,
    AVG(neutral_ratio) AS avg_neutral,
    SUM(volume) AS total_volume
FROM sentiment_snapshots
GROUP BY time_bucket('1 hour', captured_at), entity_type, entity_id, source
WITH NO DATA;

-- Política de refresh: atualiza a cada 30 minutos, cobre última 1 hora
SELECT add_continuous_aggregate_policy(
    'sentiment_hourly',
    start_offset => INTERVAL '2 hours',
    end_offset => INTERVAL '30 minutes',
    schedule_interval => INTERVAL '30 minutes'
);

COMMENT ON MATERIALIZED VIEW sentiment_hourly
    IS 'Agregação horária de sentimento. TimescaleDB Continuous Aggregate — não fazer refresh manual.';

-- Performance de workflows por hora (Grafana)
CREATE MATERIALIZED VIEW workflow_performance_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', started_at) AS hour,
    workflow_name,
    status,
    COUNT(*) AS executions,
    AVG(duration_ms) AS avg_duration_ms,
    MAX(duration_ms) AS max_duration_ms,
    SUM(items_processed) AS total_items
FROM workflow_logs
GROUP BY time_bucket('1 hour', started_at), workflow_name, status
WITH NO DATA;

SELECT add_continuous_aggregate_policy(
    'workflow_performance_hourly',
    start_offset => INTERVAL '2 hours',
    end_offset => INTERVAL '30 minutes',
    schedule_interval => INTERVAL '30 minutes'
);

-- =============================================================================
-- FIM DA MIGRATION 004
-- Próximo passo: executar 005_seed_reference_data.sql
-- =============================================================================
