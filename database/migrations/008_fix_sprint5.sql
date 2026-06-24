-- =============================================================================
-- WCIC - World Cup Intelligence Center
-- Migration: 008_fix_sprint5.sql
-- Description: Adições necessárias para Sprint 5 - AI Prediction Engine
-- Run after: 007_fix_sprint4.sql
--
-- PROBLEMAS IDENTIFICADOS NA AUDITORIA:
--
-- [P1] predictions: sem coluna raw_gpt_response
--      O SWF Match Predictor retorna a resposta JSON completa do GPT.
--      Armazenar apenas os campos mapeados perde a resposta original para
--      debugging, reprocessamento e comparação entre prompt_versions.
--      Padrão estabelecido na Sprint 4 (news_analysis.raw_gpt_response).
--
-- [P2] predictions: sem coluna brier_score
--      O Brier Score é a métrica padrão de calibração probabilística para
--      modelos preditivos. É calculado pelo WF-11 após o jogo:
--      BS = (p_home - I_home)² + (p_draw - I_draw)² + (p_away - I_away)²
--      Onde I é 1 se o outcome ocorreu, 0 caso contrário.
--      Essencial para o dashboard de accuracy da Sprint 5.
--
-- [P3] predictions: sem coluna actual_home_score / actual_away_score
--      O WF-11 precisa registrar o placar real para calcular a proximidade
--      do placar previsto vs real, além do outcome binário (home/draw/away).
--      Permite métricas como "erro médio de gols".
--
-- [P4] prediction_accuracy: sem coluna brier_score_avg
--      A tabela de agregação não tem o campo para o Brier Score médio por
--      período - necessário para o dashboard de calibração do modelo.
--
-- [P5] prediction_accuracy: sem colunas home_team_id / away_team_id para
--      análise de accuracy por seleção específica.
--      O WF-11 precisa saber qual time foi previsto corretamente vs errado.
--
-- [P6] predictions: índice para WF-05 buscar partidas sem previsão
--      O WF-05 precisa identificar partidas nas próximas 2h sem previsão
--      pre_match. O índice existente (idx_predictions_pending_evaluation)
--      é para WF-11, não para WF-05.
--
-- [P7] matches: sem coluna referee_country para feature do predictor
--      A origem do árbitro é um feature leve mas relevante para modelos
--      de previsão em copas (viés geográfico em algumas decisões).
-- =============================================================================

SET search_path TO wcic, public;

-- =============================================================================
-- [P1] predictions: coluna raw_gpt_response
-- =============================================================================

ALTER TABLE predictions
    ADD COLUMN IF NOT EXISTS raw_gpt_response JSONB;

COMMENT ON COLUMN predictions.raw_gpt_response
    IS 'Resposta JSON completa do SWF Match Predictor antes do parse. '
       'Preserva para debugging, reprocessamento e backtesting quando prompt muda.';

-- =============================================================================
-- [P2] predictions: coluna brier_score
-- Calculado pelo WF-11 após resultado confirmado.
-- Fórmula: (p_home - I_home)² + (p_draw - I_draw)² + (p_away - I_away)²
-- Range: [0, 2] - menor é melhor. 0 = previsão perfeita.
-- =============================================================================

ALTER TABLE predictions
    ADD COLUMN IF NOT EXISTS brier_score NUMERIC(5, 4)
    CHECK (brier_score BETWEEN 0 AND 2);

COMMENT ON COLUMN predictions.brier_score
    IS 'Brier Score calculado pelo WF-11 após o resultado. '
       'Fórmula: Σ(p_i - I_i)² para i ∈ {home,draw,away}. '
       'Range: [0.0, 2.0] - menor é melhor. NULL até o jogo terminar.';

-- =============================================================================
-- [P3] predictions: placar real para comparação pós-jogo
-- =============================================================================

ALTER TABLE predictions
    ADD COLUMN IF NOT EXISTS actual_home_score SMALLINT
    CHECK (actual_home_score >= 0);

ALTER TABLE predictions
    ADD COLUMN IF NOT EXISTS actual_away_score SMALLINT
    CHECK (actual_away_score >= 0);

COMMENT ON COLUMN predictions.actual_home_score
    IS 'Placar real do time da casa - preenchido pelo WF-11 após o jogo.';
COMMENT ON COLUMN predictions.actual_away_score
    IS 'Placar real do time visitante - preenchido pelo WF-11 após o jogo.';

-- =============================================================================
-- [P4] prediction_accuracy: brier_score_avg
-- =============================================================================

ALTER TABLE prediction_accuracy
    ADD COLUMN IF NOT EXISTS brier_score_avg NUMERIC(5, 4)
    CHECK (brier_score_avg BETWEEN 0 AND 2);

COMMENT ON COLUMN prediction_accuracy.brier_score_avg
    IS 'Brier Score médio do período - métrica de calibração probabilística. '
       'Um modelo bem calibrado com BS < 0.5 é considerado bom para futebol.';

-- =============================================================================
-- [P5] prediction_accuracy: team_id para análise por seleção
-- =============================================================================

ALTER TABLE prediction_accuracy
    ADD COLUMN IF NOT EXISTS team_id UUID
    REFERENCES teams(id) ON DELETE SET NULL;

COMMENT ON COLUMN prediction_accuracy.team_id
    IS 'Filtra accuracy para uma seleção específica. '
       'NULL = accuracy geral (todos os jogos do período).';

-- Atualiza UNIQUE constraint para incluir team_id
ALTER TABLE prediction_accuracy
    DROP CONSTRAINT IF EXISTS prediction_accuracy_period_type_period_label_prediction_type_key;

ALTER TABLE prediction_accuracy
    ADD CONSTRAINT prediction_accuracy_unique
    UNIQUE (period_type, period_label, prediction_type, team_id);

-- =============================================================================
-- [P6] Índice para WF-05: partidas próximas sem previsão pre_match
-- WF-05 roda a cada 30min e busca: matches nas próximas 2h sem prediction
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_predictions_match_type
    ON predictions (match_id, prediction_type);

COMMENT ON INDEX idx_predictions_match_type
    IS 'WF-05: verifica se já existe previsão pre_match para uma partida. '
       'Evita gerar previsões duplicadas para o mesmo jogo.';

-- Índice para WF-05 identificar partidas elegíveis (status=scheduled, próximas 2h)
CREATE INDEX IF NOT EXISTS idx_matches_upcoming_predictions
    ON matches (scheduled_at ASC, status)
    WHERE status = 'scheduled'
      AND scheduled_at > NOW();

COMMENT ON INDEX idx_matches_upcoming_predictions
    IS 'WF-05: busca partidas scheduled nas próximas horas para geração de previsão. '
       'Partial index em status=scheduled reduz tamanho - partidas passadas excluídas automaticamente.';

-- =============================================================================
-- [P7] matches: referee_country (feature leve para predictor)
-- =============================================================================

ALTER TABLE matches
    ADD COLUMN IF NOT EXISTS referee_country VARCHAR(100);

COMMENT ON COLUMN matches.referee_country
    IS 'País de origem do árbitro - feature contextual para o SWF Match Predictor. '
       'Populado pelo WF-01 quando disponível na API.';

-- =============================================================================
-- ADIÇÃO: tabela match_stats para estatísticas agregadas por partida
-- WF-05 precisa de features quantitativas (forma recente, gols, etc.)
-- que não estão disponíveis diretamente nas tabelas existentes.
-- Esta tabela é populada pelo WF-05 antes de chamar o predictor.
-- =============================================================================

CREATE TABLE IF NOT EXISTS match_stats (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id        UUID NOT NULL UNIQUE REFERENCES matches(id) ON DELETE CASCADE,
    -- Forma recente (últimos 5 jogos de cada time)
    home_form       CHAR(1)[] DEFAULT '{}',   -- ['W','W','D','L','W']
    away_form       CHAR(1)[] DEFAULT '{}',
    home_form_pts   SMALLINT DEFAULT 0,        -- Pontos nos últimos 5 jogos (max 15)
    away_form_pts   SMALLINT DEFAULT 0,
    -- Médias de gols (últimos 5 jogos)
    home_goals_scored_avg   NUMERIC(4,2),
    home_goals_conceded_avg NUMERIC(4,2),
    away_goals_scored_avg   NUMERIC(4,2),
    away_goals_conceded_avg NUMERIC(4,2),
    -- Head-to-head (últimos 10 encontros entre os dois times)
    h2h_home_wins   SMALLINT DEFAULT 0,
    h2h_draws       SMALLINT DEFAULT 0,
    h2h_away_wins   SMALLINT DEFAULT 0,
    h2h_home_goals_avg NUMERIC(4,2),
    h2h_away_goals_avg NUMERIC(4,2),
    -- Contexto do torneio
    home_goals_in_tournament   SMALLINT DEFAULT 0,
    away_goals_in_tournament   SMALLINT DEFAULT 0,
    home_matches_in_tournament SMALLINT DEFAULT 0,
    away_matches_in_tournament SMALLINT DEFAULT 0,
    -- Notícias e sentimento (snapshot no momento da previsão)
    home_news_impact_avg  NUMERIC(3,2),  -- avg impact_score das últimas 24h
    away_news_impact_avg  NUMERIC(3,2),
    home_sentiment_score  NUMERIC(4,3),  -- positive_ratio do último snapshot
    away_sentiment_score  NUMERIC(4,3),
    -- Alertas de contexto
    home_has_injury_news  BOOLEAN DEFAULT FALSE,
    away_has_injury_news  BOOLEAN DEFAULT FALSE,
    home_suspended_count  SMALLINT DEFAULT 0,
    away_suspended_count  SMALLINT DEFAULT 0,
    -- Metadados
    computed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE match_stats
    IS 'Feature set computado pelo WF-05 para cada partida antes da previsão GPT. '
       'Snapshot dos dados quantitativos no momento da geração da previsão. '
       'UNIQUE em match_id - um conjunto de stats por partida.';

-- Índice para WF-05 verificar se stats já foram computadas
CREATE INDEX IF NOT EXISTS idx_match_stats_match
    ON match_stats (match_id, computed_at DESC);

-- =============================================================================
-- VALIDAÇÃO
-- =============================================================================

DO $$
DECLARE
    v_col BOOLEAN;
    v_tbl BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'wcic' AND table_name = 'predictions'
          AND column_name = 'brier_score'
    ) INTO v_col;
    IF NOT v_col THEN
        RAISE EXCEPTION 'FALHA: brier_score ausente em predictions';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'wcic' AND table_name = 'match_stats'
    ) INTO v_tbl;
    IF NOT v_tbl THEN
        RAISE EXCEPTION 'FALHA: tabela match_stats não criada';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'wcic' AND table_name = 'prediction_accuracy'
          AND column_name = 'brier_score_avg'
    ) INTO v_col;
    IF NOT v_col THEN
        RAISE EXCEPTION 'FALHA: brier_score_avg ausente em prediction_accuracy';
    END IF;

    RAISE NOTICE 'Migration 008 validada com sucesso.';
END;
$$;

-- =============================================================================
-- FIM DA MIGRATION 008
-- =============================================================================
