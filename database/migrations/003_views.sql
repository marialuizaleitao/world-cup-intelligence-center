-- =============================================================================
-- WCIC — World Cup Intelligence Center
-- Migration: 003_views.sql
-- Description: Materialized views para performance de dashboards
-- Estratégia: views são refreshed pelo WF-08 a cada 5 minutos
--             CONCURRENTLY evita bloqueio de leituras durante refresh
-- Run after: 002_indexes.sql
-- =============================================================================

SET search_path TO wcic, public;

-- =============================================================================
-- mv_group_standings — Classificação por grupo
-- Refreshed por: WF-08 a cada 5 min durante partidas, 30 min no restante
-- Usado por: dashboard principal, API /standings
-- =============================================================================

CREATE MATERIALIZED VIEW mv_group_standings AS
WITH team_results AS (
    SELECT
        t.id AS team_id,
        t.name AS team_name,
        t.short_name,
        t.country_code,
        t.group_name,
        t.logo_url,
        -- Uma linha por partida finalizada
        m.id AS match_id,
        CASE
            WHEN m.home_team_id = t.id THEN 'home'
            ELSE 'away'
        END AS side,
        CASE
            WHEN m.home_team_id = t.id THEN m.home_score
            ELSE m.away_score
        END AS goals_for,
        CASE
            WHEN m.home_team_id = t.id THEN m.away_score
            ELSE m.home_score
        END AS goals_against,
        CASE
            WHEN m.winner_team_id = t.id THEN 'W'
            WHEN m.status = 'finished' AND m.winner_team_id IS NULL THEN 'D'
            WHEN m.status = 'finished' AND m.winner_team_id != t.id THEN 'L'
            ELSE NULL
        END AS result
    FROM teams t
    LEFT JOIN matches m ON (m.home_team_id = t.id OR m.away_team_id = t.id)
        AND m.status = 'finished'
        AND m.stage::text LIKE 'group_%'
    WHERE t.group_name IS NOT NULL
)
SELECT
    team_id,
    team_name,
    short_name,
    country_code,
    group_name,
    logo_url,
    COUNT(match_id) AS played,
    COUNT(CASE WHEN result = 'W' THEN 1 END) AS won,
    COUNT(CASE WHEN result = 'D' THEN 1 END) AS drawn,
    COUNT(CASE WHEN result = 'L' THEN 1 END) AS lost,
    COALESCE(SUM(goals_for), 0) AS goals_for,
    COALESCE(SUM(goals_against), 0) AS goals_against,
    COALESCE(SUM(goals_for), 0) - COALESCE(SUM(goals_against), 0) AS goal_difference,
    (COUNT(CASE WHEN result = 'W' THEN 1 END) * 3) +
    COUNT(CASE WHEN result = 'D' THEN 1 END) AS points,
    NOW() AS last_refreshed_at
FROM team_results
GROUP BY team_id, team_name, short_name, country_code, group_name, logo_url
ORDER BY group_name, points DESC, goal_difference DESC, goals_for DESC;

CREATE UNIQUE INDEX ON mv_group_standings(team_id);
CREATE INDEX ON mv_group_standings(group_name, points DESC);

COMMENT ON MATERIALIZED VIEW mv_group_standings
    IS 'Tabela de classificação por grupo. Refresh via WF-08.';

-- =============================================================================
-- mv_match_summary — Resumo de partidas com times e placar
-- Usado por: API /matches, dashboard de resultados
-- =============================================================================

CREATE MATERIALIZED VIEW mv_match_summary AS
SELECT
    m.id AS match_id,
    m.external_id,
    m.stage,
    m.status,
    m.scheduled_at,
    m.started_at,
    m.finished_at,
    -- Time da casa
    ht.id AS home_team_id,
    ht.name AS home_team_name,
    ht.short_name AS home_team_short,
    ht.country_code AS home_country_code,
    ht.logo_url AS home_logo_url,
    -- Time visitante
    at.id AS away_team_id,
    at.name AS away_team_name,
    at.short_name AS away_team_short,
    at.country_code AS away_country_code,
    at.logo_url AS away_logo_url,
    -- Placar
    m.home_score,
    m.away_score,
    m.home_score_ht,
    m.away_score_ht,
    -- Venue
    v.name AS venue_name,
    v.city AS venue_city,
    v.timezone AS venue_timezone,
    -- Previsão mais recente (pré-jogo)
    p.home_win_prob,
    p.draw_prob,
    p.away_win_prob,
    p.confidence AS prediction_confidence,
    -- Sentimento mais recente (combinado)
    s.positive_ratio AS sentiment_positive,
    s.negative_ratio AS sentiment_negative,
    s.dominant_sentiment,
    NOW() AS last_refreshed_at
FROM matches m
JOIN teams ht ON ht.id = m.home_team_id
JOIN teams at ON at.id = m.away_team_id
LEFT JOIN venues v ON v.id = m.venue_id
LEFT JOIN LATERAL (
    SELECT home_win_prob, draw_prob, away_win_prob, confidence
    FROM predictions
    WHERE match_id = m.id AND prediction_type = 'pre_match'
    ORDER BY created_at DESC
    LIMIT 1
) p ON TRUE
LEFT JOIN LATERAL (
    SELECT positive_ratio, negative_ratio, dominant_sentiment
    FROM sentiment_snapshots
    WHERE entity_type = 'match' AND entity_id = m.id AND source = 'combined'
    ORDER BY captured_at DESC
    LIMIT 1
) s ON TRUE;

CREATE UNIQUE INDEX ON mv_match_summary(match_id);
CREATE INDEX ON mv_match_summary(scheduled_at DESC);
CREATE INDEX ON mv_match_summary(status);

COMMENT ON MATERIALIZED VIEW mv_match_summary
    IS 'Visão denormalizada de partidas com times, placar, previsão e sentimento. Refresh via WF-08.';

-- =============================================================================
-- mv_top_scorers — Artilharia da Copa
-- Usado por: dashboard de estatísticas
-- =============================================================================

CREATE MATERIALIZED VIEW mv_top_scorers AS
SELECT
    p.id AS player_id,
    p.name AS player_name,
    p.shirt_number,
    p.position,
    t.name AS team_name,
    t.country_code,
    COUNT(me.id) AS goals,
    COUNT(CASE WHEN me.event_type = 'penalty_scored' THEN 1 END) AS penalty_goals,
    COUNT(CASE WHEN me.event_type = 'goal' AND me.assist_player_id IS NOT NULL THEN 1 END) AS non_penalty_goals,
    -- Assistências (esse player aparece como assist_player_id)
    (SELECT COUNT(*)
     FROM match_events
     WHERE assist_player_id = p.id
       AND event_type IN ('goal', 'penalty_scored')) AS assists
FROM players p
JOIN teams t ON t.id = p.team_id
LEFT JOIN match_events me ON me.player_id = p.id
    AND me.event_type IN ('goal', 'penalty_scored', 'own_goal')
    AND me.event_type != 'own_goal'  -- Gols contra não contam para o jogador
GROUP BY p.id, p.name, p.shirt_number, p.position, t.name, t.country_code
HAVING COUNT(me.id) > 0
ORDER BY goals DESC, assists DESC;

CREATE UNIQUE INDEX ON mv_top_scorers(player_id);

COMMENT ON MATERIALIZED VIEW mv_top_scorers
    IS 'Artilharia da Copa — atualizada após cada gol via WF-08.';

-- =============================================================================
-- mv_prediction_performance — Performance do modelo preditivo
-- Usado por: dashboard de IA, Grafana
-- =============================================================================

CREATE MATERIALIZED VIEW mv_prediction_performance AS
SELECT
    DATE_TRUNC('day', created_at) AS prediction_date,
    prediction_type,
    COUNT(*) AS total,
    COUNT(CASE WHEN was_correct = TRUE THEN 1 END) AS correct,
    COUNT(CASE WHEN was_correct = FALSE THEN 1 END) AS incorrect,
    COUNT(CASE WHEN was_correct IS NULL THEN 1 END) AS pending,
    ROUND(
        100.0 * COUNT(CASE WHEN was_correct = TRUE THEN 1 END) /
        NULLIF(COUNT(CASE WHEN was_correct IS NOT NULL THEN 1 END), 0),
        1
    ) AS accuracy_pct,
    AVG(confidence) AS avg_confidence,
    NOW() AS last_refreshed_at
FROM predictions
GROUP BY DATE_TRUNC('day', created_at), prediction_type
ORDER BY prediction_date DESC, prediction_type;

CREATE UNIQUE INDEX ON mv_prediction_performance(prediction_date, prediction_type);

-- =============================================================================
-- mv_news_impact_feed — Feed de notícias de alto impacto
-- Usado por: dashboard editorial, API /news/impact
-- =============================================================================

CREATE MATERIALIZED VIEW mv_news_impact_feed AS
SELECT
    n.id AS news_id,
    n.title,
    n.source,
    n.published_at,
    n.language,
    n.url,
    na.summary,
    na.impact_score,
    na.impact_type,
    na.sentiment,
    na.key_insight,
    na.tags,
    -- Times afetados
    ARRAY(
        SELECT t.name
        FROM teams t
        WHERE t.id = ANY(na.affected_team_ids)
    ) AS affected_team_names,
    NOW() AS last_refreshed_at
FROM news n
JOIN news_analysis na ON na.news_id = n.id
WHERE na.impact_score >= 0.5
ORDER BY na.impact_score DESC, n.published_at DESC;

CREATE UNIQUE INDEX ON mv_news_impact_feed(news_id);
CREATE INDEX ON mv_news_impact_feed(impact_score DESC, published_at DESC);

-- =============================================================================
-- Procedure de refresh — chamada pelo WF-08
-- Atualiza todas as views em sequência segura (CONCURRENTLY não bloqueia leituras)
-- =============================================================================

CREATE OR REPLACE PROCEDURE refresh_all_views()
LANGUAGE plpgsql AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY wcic.mv_group_standings;
    REFRESH MATERIALIZED VIEW CONCURRENTLY wcic.mv_match_summary;
    REFRESH MATERIALIZED VIEW CONCURRENTLY wcic.mv_top_scorers;
    REFRESH MATERIALIZED VIEW CONCURRENTLY wcic.mv_prediction_performance;
    REFRESH MATERIALIZED VIEW CONCURRENTLY wcic.mv_news_impact_feed;
END;
$$;

COMMENT ON PROCEDURE refresh_all_views
    IS 'Chamada pelo WF-08 (Dashboard Sync). CONCURRENTLY garante zero downtime durante refresh.';

-- =============================================================================
-- FIM DA MIGRATION 003
-- Próximo passo: executar 004_hypertables.sql
-- =============================================================================
