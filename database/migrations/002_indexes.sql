-- =============================================================================
-- WCIC — World Cup Intelligence Center
-- Migration: 002_indexes.sql
-- Description: Índices estratégicos para performance
-- Filosofia: índice existe para uma query específica — documentar qual
-- Run after: 001_initial_schema.sql
-- =============================================================================

SET search_path TO wcic, public;

-- =============================================================================
-- MATCHES
-- =============================================================================

-- Query: buscar partidas de hoje / próximos dias (WF-01, dashboards)
CREATE INDEX idx_matches_scheduled_at
    ON matches(scheduled_at DESC);

-- Query: buscar partidas por status (WF-02 precisa saber quais estão ao vivo)
CREATE INDEX idx_matches_status
    ON matches(status)
    WHERE status IN ('scheduled', 'live', 'halftime');

-- Query: histórico head-to-head (WF-05 feature set para previsões)
CREATE INDEX idx_matches_teams_pair
    ON matches(
        LEAST(home_team_id::text, away_team_id::text),
        GREATEST(home_team_id::text, away_team_id::text)
    );

-- Query: partidas por time específico (form recente)
CREATE INDEX idx_matches_home_team ON matches(home_team_id);
CREATE INDEX idx_matches_away_team ON matches(away_team_id);

-- =============================================================================
-- MATCH EVENTS
-- Nota: TimescaleDB cria automaticamente índice no campo de particionamento (created_at)
-- Criar índices adicionais após o hypertable ser criado em 004_hypertables.sql
-- =============================================================================

-- Query: todos os eventos de uma partida (dashboard ao vivo, WF-02)
CREATE INDEX idx_match_events_match_id
    ON match_events(match_id, minute);

-- Query: filtrar por tipo de evento (apenas gols, apenas cartões)
CREATE INDEX idx_match_events_type
    ON match_events(event_type, match_id);

-- Query: eventos de um jogador específico (estatísticas individuais)
CREATE INDEX idx_match_events_player
    ON match_events(player_id)
    WHERE player_id IS NOT NULL;

-- =============================================================================
-- TEAMS
-- =============================================================================

CREATE INDEX idx_teams_country_code ON teams(country_code);
CREATE INDEX idx_teams_group_name ON teams(group_name) WHERE group_name IS NOT NULL;
CREATE INDEX idx_teams_external_id ON teams(external_id) WHERE external_id IS NOT NULL;

-- =============================================================================
-- PLAYERS
-- =============================================================================

CREATE INDEX idx_players_team_id ON players(team_id);
CREATE INDEX idx_players_position ON players(position, team_id);

-- Busca por nome (jornalistas digitam nomes variados)
CREATE INDEX idx_players_name_trgm
    ON players USING gin(name gin_trgm_ops);

-- Query: jogadores disponíveis (não lesionados, não suspensos) — WF-05
CREATE INDEX idx_players_available
    ON players(team_id, position)
    WHERE is_injured = FALSE AND is_suspended = FALSE;

-- =============================================================================
-- NEWS
-- =============================================================================

-- Query: artigos não processados (WF-03 polling para analisar)
CREATE INDEX idx_news_pending
    ON news(created_at)
    WHERE processing_status = 'pending';

-- Query: artigos por fonte e data (deduplicação, monitoramento)
CREATE INDEX idx_news_source_published
    ON news(source, published_at DESC);

-- Query: artigos relacionados a uma partida (WF-06 digest)
CREATE INDEX idx_news_related_match
    ON news(related_match_id)
    WHERE related_match_id IS NOT NULL;

-- Busca full-text em título e descrição (API pública, dashboards)
CREATE INDEX idx_news_fulltext
    ON news USING gin(
        to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, ''))
    );

-- =============================================================================
-- NEWS ANALYSIS
-- =============================================================================

-- Query: notícias de alto impacto recentes (WF-07 decide se notifica)
CREATE INDEX idx_news_analysis_impact_recent
    ON news_analysis(impact_score DESC, created_at DESC)
    WHERE impact_score >= 0.6;

-- Query: análises por tipo de impacto (dashboard editorial)
CREATE INDEX idx_news_analysis_impact_type
    ON news_analysis(impact_type, created_at DESC);

-- Query: artigos que afetam um time específico
CREATE INDEX idx_news_analysis_affected_teams
    ON news_analysis USING gin(affected_team_ids);

-- =============================================================================
-- SENTIMENT SNAPSHOTS
-- Nota: TimescaleDB cria índice em captured_at automaticamente
-- =============================================================================

-- Query: último snapshot de sentimento por entidade (WF-04, dashboards)
CREATE INDEX idx_sentiment_entity
    ON sentiment_snapshots(entity_type, entity_id, captured_at DESC);

-- Query: sentimento por fonte para comparação
CREATE INDEX idx_sentiment_source_time
    ON sentiment_snapshots(source, captured_at DESC);

-- =============================================================================
-- PREDICTIONS
-- =============================================================================

-- Query: previsão mais recente para uma partida (dashboard, API)
CREATE INDEX idx_predictions_match_recent
    ON predictions(match_id, created_at DESC);

-- Query: previsões não avaliadas (WF-11 accuracy tracker)
CREATE INDEX idx_predictions_pending_evaluation
    ON predictions(match_id)
    WHERE was_correct IS NULL AND prediction_type = 'pre_match';

-- Query: performance do modelo ao longo do tempo (Grafana)
CREATE INDEX idx_predictions_accuracy_time
    ON predictions(created_at DESC)
    WHERE was_correct IS NOT NULL;

-- =============================================================================
-- NOTIFICATIONS
-- =============================================================================

-- Query: notificações pendentes para retry (WF-10)
CREATE INDEX idx_notifications_pending_retry
    ON notifications(next_retry_at)
    WHERE status IN ('pending', 'retry');

-- Query: histórico de notificações por partida (auditoria)
CREATE INDEX idx_notifications_match
    ON notifications(related_match_id, created_at DESC)
    WHERE related_match_id IS NOT NULL;

-- Query: métricas de entrega por canal (Prometheus, Grafana)
CREATE INDEX idx_notifications_channel_status
    ON notifications(channel, status, created_at DESC);

-- =============================================================================
-- WORKFLOW LOGS
-- Nota: TimescaleDB cria índice em started_at automaticamente
-- =============================================================================

-- Query: execuções com erro recentes (Grafana alertas, debugging)
CREATE INDEX idx_workflow_logs_errors
    ON workflow_logs(workflow_name, started_at DESC)
    WHERE status = 'error';

-- Query: rastrear cadeia de workflows por correlation_id
CREATE INDEX idx_workflow_logs_correlation
    ON workflow_logs(correlation_id)
    WHERE correlation_id IS NOT NULL;

-- Query: performance de workflow específico (duração média — Grafana)
CREATE INDEX idx_workflow_logs_performance
    ON workflow_logs(workflow_name, duration_ms)
    WHERE status = 'success';

-- =============================================================================
-- FIM DA MIGRATION 002
-- Próximo passo: executar 003_views.sql
-- =============================================================================
