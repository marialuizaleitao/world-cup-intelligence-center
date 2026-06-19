-- =============================================================================
-- WCIC — World Cup Intelligence Center
-- Migration: 001_initial_schema.sql
-- Description: Schema completo inicial — tabelas, constraints e comentários
-- Requires: PostgreSQL 15+, TimescaleDB extension
-- Run after: TimescaleDB instalado (imagem timescale/timescaledb:latest-pg15)
-- Run before: 002_indexes.sql, 003_views.sql, 004_hypertables.sql
-- =============================================================================

-- Cria as extensões necessárias
CREATE EXTENSION IF NOT EXISTS "pgcrypto";       -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";        -- busca textual em notícias
CREATE EXTENSION IF NOT EXISTS "timescaledb";    -- hypertables para séries temporais

-- Cria um schema isolado para o projeto
CREATE SCHEMA IF NOT EXISTS wcic;
SET search_path TO wcic, public;

-- =============================================================================
-- ENUM TYPES
-- Definidos como tipos para garantir a integridade sem check constraint verboso
-- =============================================================================

CREATE TYPE match_status AS ENUM (
    'scheduled',
    'live',
    'halftime',
    'finished',
    'postponed',
    'cancelled',
    'suspended'
);

CREATE TYPE match_stage AS ENUM (
    'group_a', 'group_b', 'group_c', 'group_d',
    'group_e', 'group_f', 'group_g', 'group_h',
    'round_of_32', 'round_of_16', 'quarter_final',
    'semi_final', 'third_place', 'final'
);

CREATE TYPE event_type AS ENUM (
    'goal', 'own_goal', 'penalty_scored', 'penalty_missed',
    'yellow_card', 'second_yellow', 'red_card',
    'substitution', 'var_review', 'var_overturned',
    'kick_off', 'half_time', 'full_time',
    'extra_time_start', 'penalty_shootout_start'
);

CREATE TYPE player_position AS ENUM (
    'GK', 'DEF', 'MID', 'FWD'
);

CREATE TYPE confederation AS ENUM (
    'UEFA', 'CONMEBOL', 'CONCACAF', 'CAF', 'AFC', 'OFC'
);

CREATE TYPE sentiment_label AS ENUM (
    'very_positive', 'positive', 'neutral', 'negative', 'very_negative'
);

CREATE TYPE notification_priority AS ENUM (
    'critical', 'high', 'medium', 'low'
);

CREATE TYPE notification_status AS ENUM (
    'pending', 'sent', 'failed', 'retry', 'cancelled'
);

CREATE TYPE notification_channel AS ENUM (
    'telegram', 'slack', 'email', 'webhook', 'push'
);

CREATE TYPE processing_status AS ENUM (
    'pending', 'processing', 'processed', 'failed', 'skipped'
);

CREATE TYPE workflow_status AS ENUM (
    'running', 'success', 'error', 'timeout', 'cancelled'
);

CREATE TYPE impact_type AS ENUM (
    'tactical', 'injury', 'form', 'controversy',
    'lineup', 'suspension', 'weather', 'other'
);

CREATE TYPE prediction_type AS ENUM (
    'pre_match', 'halftime', 'live_update'
);

-- =============================================================================
-- VENUES
-- =============================================================================

CREATE TABLE venues (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(150) NOT NULL,
    city            VARCHAR(100) NOT NULL,
    country         VARCHAR(100) NOT NULL DEFAULT 'United States',
    capacity        INTEGER CHECK (capacity > 0),
    latitude        NUMERIC(9, 6),
    longitude       NUMERIC(9, 6),
    timezone        VARCHAR(50) NOT NULL DEFAULT 'America/New_York',
    surface         VARCHAR(30) DEFAULT 'grass',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE venues IS 'Estádios da Copa do Mundo 2026 (EUA, Canadá, México)';
COMMENT ON COLUMN venues.timezone IS 'Timezone IANA para cálculo correto de horários locais';

-- =============================================================================
-- TEAMS
-- =============================================================================

CREATE TABLE teams (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id     VARCHAR(100) UNIQUE,                           -- ID da API externa
    name            VARCHAR(100) NOT NULL,
    short_name      VARCHAR(20),
    country_code    CHAR(3) NOT NULL,                              -- ISO 3166-1 alpha-3
    confederation   confederation NOT NULL,
    group_name      VARCHAR(5),                                    -- A-H, null após a fase de grupos
    fifa_ranking    SMALLINT CHECK (fifa_ranking > 0),
    coach           VARCHAR(150),
    logo_url        TEXT,
    eliminated      BOOLEAN NOT NULL DEFAULT FALSE,
    eliminated_stage VARCHAR(50),                                  -- Estágio em que o time foi eliminado
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE teams IS '48 seleções classificadas para a Copa do Mundo 2026';
COMMENT ON COLUMN teams.external_id IS 'ID usado pela API principal (Football-Data.org)';
COMMENT ON COLUMN teams.group_name IS 'Grupo na fase de grupos. NULL após eliminatórias.';

-- =============================================================================
-- PLAYERS
-- =============================================================================

CREATE TABLE players (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id     VARCHAR(100) UNIQUE,
    team_id         UUID NOT NULL REFERENCES teams(id) ON DELETE RESTRICT,
    name            VARCHAR(150) NOT NULL,
    short_name      VARCHAR(50),
    position        player_position NOT NULL,
    shirt_number    SMALLINT CHECK (shirt_number BETWEEN 1 AND 99),
    nationality     VARCHAR(100),
    date_of_birth   DATE,
    club_team       VARCHAR(150),
    club_league     VARCHAR(100),
    height_cm       SMALLINT CHECK (height_cm BETWEEN 140 AND 230),
    weight_kg       SMALLINT CHECK (weight_kg BETWEEN 50 AND 150),
    is_captain      BOOLEAN NOT NULL DEFAULT FALSE,
    is_injured      BOOLEAN NOT NULL DEFAULT FALSE,
    is_suspended    BOOLEAN NOT NULL DEFAULT FALSE,
    injury_detail   TEXT,                                          -- Descrição da lesão (se houver)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE players IS 'Elencos das 48 seleções — atualizado conforme as convocações finais';
COMMENT ON COLUMN players.is_injured IS 'Atualizado via WF-01 quando a API reporta lesão';

-- =============================================================================
-- MATCHES
-- =============================================================================

CREATE TABLE matches (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id     VARCHAR(100) NOT NULL UNIQUE,                  -- ID na API externa
    home_team_id    UUID NOT NULL REFERENCES teams(id),
    away_team_id    UUID NOT NULL REFERENCES teams(id),
    venue_id        UUID REFERENCES venues(id),
    stage           match_stage NOT NULL,
    scheduled_at    TIMESTAMPTZ NOT NULL,
    started_at      TIMESTAMPTZ,
    finished_at     TIMESTAMPTZ,
    status          match_status NOT NULL DEFAULT 'scheduled',
    home_score      SMALLINT CHECK (home_score >= 0),
    away_score      SMALLINT CHECK (away_score >= 0),
    home_score_ht   SMALLINT CHECK (home_score_ht >= 0),           -- Placar intervalo
    away_score_ht   SMALLINT CHECK (away_score_ht >= 0),
    home_score_et   SMALLINT,                                      -- Prorrogação
    away_score_et   SMALLINT,
    home_score_pk   SMALLINT,                                      -- Pênaltis
    away_score_pk   SMALLINT,
    winner_team_id  UUID REFERENCES teams(id),
    attendance      INTEGER CHECK (attendance >= 0),
    referee         VARCHAR(150),
    source_api      VARCHAR(50) NOT NULL DEFAULT 'football-data',
    raw_payload     JSONB,                                         -- Payload original para auditoria
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT different_teams CHECK (home_team_id != away_team_id),
    CONSTRAINT valid_winner CHECK (
        winner_team_id IS NULL OR
        winner_team_id = home_team_id OR
        winner_team_id = away_team_id
    )
);

COMMENT ON TABLE matches IS 'Todas as partidas da Copa 2026 — 104 jogos no total';
COMMENT ON COLUMN matches.raw_payload IS 'Payload JSON original da API para auditoria e reprocessamento';
COMMENT ON COLUMN matches.source_api IS 'API que originou o registro — football-data, rapidapi ou manual';

-- =============================================================================
-- MATCH EVENTS (alta frequência — será hypertable)
-- =============================================================================

CREATE TABLE match_events (
    id              UUID NOT NULL DEFAULT gen_random_uuid(),
    match_id        UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    external_id     VARCHAR(100),                                  -- ID do evento na API
    event_type      event_type NOT NULL,
    minute          SMALLINT NOT NULL CHECK (minute >= 0),
    extra_minute    SMALLINT CHECK (extra_minute >= 0),            -- Acréscimos
    period          VARCHAR(20) DEFAULT 'regular',                 -- regular, extra_time, penalties
    team_id         UUID REFERENCES teams(id),
    player_id       UUID REFERENCES players(id),
    assist_player_id UUID REFERENCES players(id),
    player_out_id   UUID REFERENCES players(id),                   -- Para substituições
    detail          TEXT,                                          -- "Header", "Free Kick", etc.
    is_confirmed    BOOLEAN NOT NULL DEFAULT TRUE,                 -- FALSE durante revisão VAR
    raw_payload     JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),            -- Coluna de particionamento

    PRIMARY KEY (id, created_at)                                   -- Necessário para hypertable com partição
);

COMMENT ON TABLE match_events IS 'Eventos granulares de partidas — gols, cartões, substituições. Hypertable.';
COMMENT ON COLUMN match_events.is_confirmed IS 'FALSE quando evento está sob revisão do VAR';
COMMENT ON COLUMN match_events.created_at IS 'Coluna de particionamento do TimescaleDB hypertable';

-- =============================================================================
-- NEWS
-- =============================================================================

CREATE TABLE news (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    url             TEXT NOT NULL UNIQUE,
    url_hash        CHAR(64) NOT NULL UNIQUE,                      -- SHA-256 para lookup O(1)
    source          VARCHAR(100) NOT NULL,                         -- ESPN, UOL, BBC, L'Equipe...
    title           TEXT NOT NULL,
    description     TEXT,
    content         TEXT,
    author          VARCHAR(200),
    language        CHAR(5) NOT NULL DEFAULT 'en',                 -- BCP 47: pt, en, es, fr, de
    published_at    TIMESTAMPTZ,
    related_match_id UUID REFERENCES matches(id),
    related_team_ids UUID[] DEFAULT '{}',                         -- Times mencionados
    processing_status processing_status NOT NULL DEFAULT 'pending',
    processing_error TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE news IS 'Artigos coletados via NewsAPI e RSS feeds — deduplicados por url_hash';
COMMENT ON COLUMN news.url_hash IS 'SHA-256 da URL normalizada para deduplicação rápida sem índice de texto';

-- =============================================================================
-- NEWS ANALYSIS (output dos agentes de IA)
-- =============================================================================

CREATE TABLE news_analysis (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    news_id         UUID NOT NULL UNIQUE REFERENCES news(id) ON DELETE CASCADE,
    summary         TEXT NOT NULL,
    impact_score    NUMERIC(3, 2) NOT NULL CHECK (impact_score BETWEEN 0 AND 1),
    impact_type     impact_type,
    sentiment       sentiment_label NOT NULL,
    key_insight     TEXT,                                          -- Insight mais importante em 1 frase
    tags            TEXT[] DEFAULT '{}',
    affected_team_ids UUID[] DEFAULT '{}',
    affected_player_ids UUID[] DEFAULT '{}',
    -- Metadados de auditoria da IA
    ai_model        VARCHAR(50) NOT NULL DEFAULT 'gpt-4o',
    prompt_version  VARCHAR(20) NOT NULL DEFAULT 'v1.0',
    tokens_used     INTEGER CHECK (tokens_used > 0),
    processing_ms   INTEGER CHECK (processing_ms > 0),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE news_analysis IS 'Output estruturado do agente News Analyst (GPT-4o)';
COMMENT ON COLUMN news_analysis.prompt_version IS 'Versão do prompt usado — permite A/B testing e reprocessamento';

-- =============================================================================
-- SENTIMENT SNAPSHOTS (alta frequência — será hypertable)
-- =============================================================================

CREATE TABLE sentiment_snapshots (
    id              UUID NOT NULL DEFAULT gen_random_uuid(),
    entity_type     VARCHAR(20) NOT NULL CHECK (entity_type IN ('team', 'player', 'match')),
    entity_id       UUID NOT NULL,
    source          VARCHAR(30) NOT NULL CHECK (source IN ('twitter', 'reddit', 'combined')),
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),            -- Coluna de particionamento
    -- Ratios (somam 1.0)
    positive_ratio  NUMERIC(4, 3) CHECK (positive_ratio BETWEEN 0 AND 1),
    negative_ratio  NUMERIC(4, 3) CHECK (negative_ratio BETWEEN 0 AND 1),
    neutral_ratio   NUMERIC(4, 3) CHECK (neutral_ratio BETWEEN 0 AND 1),
    dominant_sentiment sentiment_label,
    intensity       VARCHAR(10) CHECK (intensity IN ('high', 'medium', 'low')),
    volume          INTEGER NOT NULL CHECK (volume >= 0),          -- Número de posts analisados
    trending_topics TEXT[] DEFAULT '{}',
    key_concerns    TEXT[] DEFAULT '{}',
    key_positives   TEXT[] DEFAULT '{}',
    ai_summary      TEXT,
    sample_posts    JSONB,                                         -- Amostra dos posts mais relevantes
    -- Auditoria IA
    ai_model        VARCHAR(50) DEFAULT 'gpt-4o',
    tokens_used     INTEGER,

    PRIMARY KEY (id, captured_at)                                  -- Necessário para hypertable
);

COMMENT ON TABLE sentiment_snapshots IS 'Snapshots de sentimento social capturados a cada 5-30 min. Hypertable.';

-- =============================================================================
-- PREDICTIONS
-- =============================================================================

CREATE TABLE predictions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id        UUID NOT NULL REFERENCES matches(id) ON DELETE RESTRICT,
    prediction_type prediction_type NOT NULL DEFAULT 'pre_match',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Probabilidades (devem somar ~1.000, tolerância de 0.001 por arredondamento)
    home_win_prob   NUMERIC(4, 3) NOT NULL CHECK (home_win_prob BETWEEN 0 AND 1),
    draw_prob       NUMERIC(4, 3) NOT NULL CHECK (draw_prob BETWEEN 0 AND 1),
    away_win_prob   NUMERIC(4, 3) NOT NULL CHECK (away_win_prob BETWEEN 0 AND 1),
    -- Placar previsto
    predicted_home  SMALLINT CHECK (predicted_home >= 0),
    predicted_away  SMALLINT CHECK (predicted_away >= 0),
    -- Análise
    confidence      NUMERIC(3, 2) CHECK (confidence BETWEEN 0 AND 1),
    key_factors     TEXT[] DEFAULT '{}',
    justification   TEXT NOT NULL,
    risk_factors    TEXT[] DEFAULT '{}',
    over_under_2_5  VARCHAR(10) CHECK (over_under_2_5 IN ('over', 'under')),
    both_teams_score BOOLEAN,
    -- Resultado real (preenchido após o jogo pelo WF-11)
    actual_outcome  VARCHAR(10) CHECK (actual_outcome IN ('home', 'draw', 'away')),
    was_correct     BOOLEAN,
    accuracy_score  NUMERIC(3, 2),                                 -- O quão próxima foi a previsão
    -- Auditoria IA
    ai_model        VARCHAR(50) NOT NULL DEFAULT 'gpt-4o',
    prompt_version  VARCHAR(20) NOT NULL DEFAULT 'v1.0',
    tokens_used     INTEGER,
    feature_snapshot JSONB NOT NULL,                               -- Snapshot dos dados usados para reprodutibilidade

    CONSTRAINT probs_sum CHECK (
        ABS((home_win_prob + draw_prob + away_win_prob) - 1.0) < 0.005
    )
);

COMMENT ON TABLE predictions IS 'Previsões geradas pelo agente Match Predictor por partida';
COMMENT ON COLUMN predictions.feature_snapshot IS 'Dados exatos usados na predição — essencial para auditoria e backtesting';
COMMENT ON COLUMN predictions.accuracy_score IS 'Score contínuo de acurácia (0-1), além do binário was_correct';

-- =============================================================================
-- NOTIFICATIONS
-- =============================================================================

CREATE TABLE notifications (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    notification_type VARCHAR(50) NOT NULL,                        -- goal_alert, digest, prediction, etc.
    priority        notification_priority NOT NULL DEFAULT 'medium',
    channel         notification_channel NOT NULL,
    recipient       TEXT NOT NULL,                                 -- Chat ID, email, webhook URL
    subject         TEXT,                                          -- Para email
    body            TEXT NOT NULL,
    metadata        JSONB DEFAULT '{}',                            -- Dados extras específicos do tipo
    status          notification_status NOT NULL DEFAULT 'pending',
    attempts        SMALLINT NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts    SMALLINT NOT NULL DEFAULT 3,
    sent_at         TIMESTAMPTZ,
    next_retry_at   TIMESTAMPTZ,
    error_message   TEXT,
    -- Rastreabilidade
    related_match_id UUID REFERENCES matches(id),
    correlation_id  UUID,                                          -- Liga notificação à cadeia de workflows
    workflow_execution_id VARCHAR(100),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE notifications IS 'Log de todas as notificações enviadas ou tentadas via WF-07';
COMMENT ON COLUMN notifications.correlation_id IS 'Rastreia a cadeia de workflows que originou esta notificação';

-- =============================================================================
-- WORKFLOW LOGS (observabilidade — será hypertable)
-- =============================================================================

CREATE TABLE workflow_logs (
    id              UUID NOT NULL DEFAULT gen_random_uuid(),
    execution_id    VARCHAR(100) NOT NULL,                         -- ID de execução do n8n
    workflow_name   VARCHAR(100) NOT NULL,
    workflow_id     VARCHAR(100),                                  -- ID interno do n8n
    status          workflow_status NOT NULL,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),            -- Coluna de particionamento
    finished_at     TIMESTAMPTZ,
    duration_ms     INTEGER CHECK (duration_ms >= 0),
    -- Contexto da execução
    trigger_type    VARCHAR(30),                                   -- cron, webhook, manual, sub-workflow
    triggered_by    VARCHAR(100),                                  -- Nome do workflow pai, se sub-workflow
    correlation_id  UUID,                                          -- Para rastrear cadeia de workflows
    -- Resultados
    items_processed INTEGER DEFAULT 0 CHECK (items_processed >= 0),
    items_failed    INTEGER DEFAULT 0 CHECK (items_failed >= 0),
    retry_count     SMALLINT DEFAULT 0,
    -- Detalhes
    input_summary   JSONB DEFAULT '{}',                           -- Resumo não-sensível da entrada
    output_summary  JSONB DEFAULT '{}',                           -- Resumo não-sensível da saída
    error_message   TEXT,
    error_node      VARCHAR(100),                                  -- Node onde ocorreu o erro
    error_stack     TEXT,

    PRIMARY KEY (id, started_at)                                   -- Necessário para hypertable
);

COMMENT ON TABLE workflow_logs IS 'Auditoria completa de execuções de workflows — Hypertable com retenção de 90 dias';
COMMENT ON COLUMN workflow_logs.correlation_id IS 'UUID gerado no início da cadeia e propagado por todos os sub-workflows';

-- =============================================================================
-- DATA QUALITY LOGS
-- =============================================================================

CREATE TABLE data_quality_logs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    check_name      VARCHAR(100) NOT NULL,                         -- Ex: "matches_null_scores"
    table_name      VARCHAR(100) NOT NULL,
    metric          VARCHAR(100) NOT NULL,                         -- Ex: "null_count", "duplicate_count"
    value           NUMERIC,                                       -- Valor medido
    threshold       NUMERIC,                                       -- Threshold configurado
    passed          BOOLEAN NOT NULL,
    details         JSONB DEFAULT '{}',
    checked_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- DAILY DIGESTS
-- =============================================================================

CREATE TABLE daily_digests (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    digest_date     DATE NOT NULL UNIQUE,
    content_md      TEXT NOT NULL,
    content_html    TEXT NOT NULL,
    pdf_url         TEXT,
    -- Métricas do digest
    matches_covered INTEGER NOT NULL DEFAULT 0,
    news_analyzed   INTEGER NOT NULL DEFAULT 0,
    predictions_made INTEGER NOT NULL DEFAULT 0,
    -- Auditoria IA
    ai_model        VARCHAR(50) DEFAULT 'gpt-4o',
    prompt_version  VARCHAR(20) DEFAULT 'v1.0',
    tokens_used     INTEGER,
    processing_ms   INTEGER,
    generated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE daily_digests IS 'Relatórios executivos diários gerados pelo agente Daily Reporter';

-- =============================================================================
-- PREDICTION ACCURACY (agregado por período)
-- =============================================================================

CREATE TABLE prediction_accuracy (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    period_type     VARCHAR(20) NOT NULL,                          -- daily, stage, overall
    period_label    VARCHAR(50) NOT NULL,                          -- "2026-06-15", "group_stage"
    prediction_type prediction_type,                               -- NULL = todos os tipos
    -- Métricas
    total_predictions INTEGER NOT NULL DEFAULT 0,
    correct_predictions INTEGER NOT NULL DEFAULT 0,
    accuracy_pct    NUMERIC(5, 2),                                 -- % de acerto
    avg_confidence  NUMERIC(3, 2),                                 -- Confiança média
    calibration_score NUMERIC(4, 3),                              -- Quão bem calibrado está o modelo
    calculated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (period_type, period_label, prediction_type)
);

-- =============================================================================
-- UPDATED_AT TRIGGER (automático para tabelas relevantes)
-- =============================================================================

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_teams_updated_at
    BEFORE UPDATE ON teams
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_players_updated_at
    BEFORE UPDATE ON players
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_matches_updated_at
    BEFORE UPDATE ON matches
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- =============================================================================
-- GRANT PERMISSIONS
-- =============================================================================

-- Usuário da aplicação n8n/API tem acesso ao schema wcic
GRANT USAGE ON SCHEMA wcic TO wcic_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA wcic TO wcic_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA wcic TO wcic_app;

-- =============================================================================
-- FIM DA MIGRATION 001
-- Próximo passo: executar 002_indexes.sql
-- =============================================================================
