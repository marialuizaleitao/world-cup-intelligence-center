-- =============================================================================
-- WCIC — World Cup Intelligence Center
-- Migration: 005_fix_sprint2.sql
-- Description: Correções identificadas na revisão de schema da Sprint 2
-- Run after: 004_hypertables.sql
-- Author: Tech Lead review — Sprint 2
--
-- PROBLEMAS IDENTIFICADOS E CORRIGIDOS:
--
-- [P1] match_events: external_id sem UNIQUE constraint
--      Causa: sem unicidade, o mesmo evento da API pode ser inserido múltiplas
--      vezes se o workflow rodar em paralelo ou após retry. A deduplicação Redis
--      é best-effort; o banco precisa ser a última linha de defesa.
--      Impacto: contagem de gols incorreta, eventos duplicados no feed ao vivo.
--
-- [P2] match_events: external_id nullable sem índice parcial
--      Causa: o índice de deduplicação não pode ser UNIQUE se o campo é nullable
--      sem cuidado — NULL != NULL em SQL, então múltiplos NULLs são permitidos.
--      Solução: índice UNIQUE parcial WHERE external_id IS NOT NULL.
--
-- [P3] matches: sem coluna last_sync_at para controle de staleness
--      Causa: sem saber quando foi a última sincronização bem-sucedida com a API,
--      o WF-01 não consegue detectar partidas que pararam de ser atualizadas
--      (API retornou 200 mas sem mudança de dados). Isso é diferente de updated_at,
--      que só muda quando há mudança real nos dados.
--
-- [P4] teams: group_name VARCHAR(5) insuficiente para Copa 2026
--      O formato da Copa 2026 tem grupos A-L (12 grupos). Alguns providers de API
--      retornam "Group A" (7 chars) em vez de apenas "A". O campo atual truncaria
--      silenciosamente. Expandido para VARCHAR(10).
--
-- [P5] match_events: compression settings incompatíveis com segmentby
--      A política de compressão em 004 não define segmentby, o que degrada
--      performance de queries por match_id em chunks comprimidos.
--      Adicionado segmentby correto.
-- =============================================================================

SET search_path TO wcic, public;

-- =============================================================================
-- [P1 + P2] match_events: UNIQUE parcial em external_id
-- Garante que o mesmo evento da API não seja inserido duas vezes.
-- WHERE external_id IS NOT NULL: eventos sem ID externo (gerados internamente)
-- não participam da constraint — múltiplos NULL são válidos.
-- =============================================================================

CREATE UNIQUE INDEX IF NOT EXISTS idx_match_events_external_id_unique
    ON match_events (match_id, external_id)
    WHERE external_id IS NOT NULL;

COMMENT ON INDEX idx_match_events_external_id_unique
    IS 'Garante deduplicação de eventos por (match_id, external_id). '
       'Última linha de defesa além da deduplicação Redis do WF-02.';

-- =============================================================================
-- [P3] matches: coluna last_sync_at
-- Registra o timestamp da última vez que o WF-01 consultou a API para esta
-- partida e recebeu resposta válida (mesmo sem mudança de dados).
-- Diferente de updated_at: updated_at só muda quando dados mudam.
-- Usado pelo WF-01 para detectar partidas "órfãs" (sync parou por algum motivo).
-- =============================================================================

ALTER TABLE matches
    ADD COLUMN IF NOT EXISTS last_sync_at TIMESTAMPTZ;

COMMENT ON COLUMN matches.last_sync_at
    IS 'Timestamp da última sincronização bem-sucedida com a API (WF-01). '
       'NULL = nunca sincronizado. Diferente de updated_at: atualiza mesmo sem mudança de dados.';

-- Índice para o WF-01 detectar rapidamente partidas com sync atrasado
CREATE INDEX IF NOT EXISTS idx_matches_last_sync
    ON matches (last_sync_at NULLS FIRST)
    WHERE status NOT IN ('finished', 'cancelled', 'postponed');

COMMENT ON INDEX idx_matches_last_sync
    IS 'WF-01 usa este índice para encontrar partidas não finalizadas sem sync recente. '
       'NULLS FIRST prioriza partidas nunca sincronizadas.';

-- =============================================================================
-- [P4] teams: expandir group_name para VARCHAR(10)
-- Suporta valores como "Group A" retornados por alguns providers de API,
-- além do formato curto "A" usado nos seeds.
-- ALTER TYPE é seguro — apenas aumenta o limite, não altera dados existentes.
-- =============================================================================

ALTER TABLE teams
    ALTER COLUMN group_name TYPE VARCHAR(10);

COMMENT ON COLUMN teams.group_name
    IS 'Grupo na fase de grupos (A-L para Copa 2026). '
       'Aceita "A" ou "Group A" — normalizado pelo WF-01 para formato curto.';

-- =============================================================================
-- [P5] match_events: reconfigurar compressão com segmentby correto
-- segmentby(match_id) garante que queries por match_id em chunks comprimidos
-- não precisam descomprimir o chunk inteiro — apenas o segment relevante.
-- orderby(created_at DESC) otimiza queries "últimos N eventos de uma partida".
--
-- NOTA: ALTER COMPRESSION SETTINGS requer que não haja política de compressão
-- ativa. Removemos e recriamos com as configurações corretas.
-- =============================================================================

-- Remove política existente (se existir — IF EXISTS evita erro em rerun)
SELECT remove_compression_policy('match_events', if_exists => true);

-- Reconfigura compressão com segmentby correto
ALTER TABLE match_events
    SET (
        timescaledb.compress = true,
        timescaledb.compress_segmentby = 'match_id',
        timescaledb.compress_orderby = 'created_at DESC'
    );

-- Recria política de compressão
SELECT add_compression_policy('match_events', INTERVAL '7 days');

COMMENT ON TABLE match_events
    IS 'Eventos granulares de partidas — gols, cartões, substituições. '
       'Hypertable com compressão segmentada por match_id para queries eficientes.';

-- =============================================================================
-- ÍNDICE ADICIONAL: matches por status + scheduled_at (composto)
-- Identificado como necessário pelo WF-01: busca partidas do dia que
-- ainda não estão finalizadas, ordenadas por horário.
-- O índice parcial em status (migration 002) não cobre a ordenação.
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_matches_active_scheduled
    ON matches (scheduled_at ASC, status)
    WHERE status IN ('scheduled', 'live', 'halftime');

COMMENT ON INDEX idx_matches_active_scheduled
    IS 'WF-01 usa para buscar partidas ativas ordenadas por horário. '
       'Parcial em status ativo reduz o tamanho do índice em ~60%.';

-- =============================================================================
-- VALIDAÇÃO: verifica que as correções foram aplicadas corretamente
-- Executa como parte da migration — falha a migration se algo estiver errado
-- =============================================================================

DO $$
DECLARE
    v_index_exists   BOOLEAN;
    v_column_exists  BOOLEAN;
    v_col_type       TEXT;
BEGIN
    -- Verifica idx_match_events_external_id_unique
    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'wcic'
          AND tablename  = 'match_events'
          AND indexname  = 'idx_match_events_external_id_unique'
    ) INTO v_index_exists;

    IF NOT v_index_exists THEN
        RAISE EXCEPTION 'FALHA: idx_match_events_external_id_unique não foi criado';
    END IF;

    -- Verifica coluna last_sync_at em matches
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'wcic'
          AND table_name   = 'matches'
          AND column_name  = 'last_sync_at'
    ) INTO v_column_exists;

    IF NOT v_column_exists THEN
        RAISE EXCEPTION 'FALHA: coluna last_sync_at não existe em matches';
    END IF;

    -- Verifica tipo de group_name em teams
    SELECT data_type || '(' || character_maximum_length || ')'
    FROM information_schema.columns
    WHERE table_schema = 'wcic'
      AND table_name   = 'teams'
      AND column_name  = 'group_name'
    INTO v_col_type;

    IF v_col_type != 'character varying(10)' THEN
        RAISE EXCEPTION 'FALHA: group_name deveria ser VARCHAR(10), encontrado: %', v_col_type;
    END IF;

    RAISE NOTICE 'Migration 005 validada com sucesso. Todas as correções aplicadas.';
END;
$$;

-- =============================================================================
-- FIM DA MIGRATION 005
-- =============================================================================
