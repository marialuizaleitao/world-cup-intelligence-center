-- =============================================================================
-- WCIC — World Cup Intelligence Center
-- Migration: 006_fix_sprint3.sql
-- Description: Correções identificadas na auditoria da Sprint 3
-- Run after: 005_fix_sprint2.sql
--
-- PROBLEMAS IDENTIFICADOS:
--
-- [P1] match_stage ENUM incompleto para Copa 2026
--      A Copa 2026 tem 12 grupos (A-L, não A-H). O ENUM match_stage definido
--      na migration 001 contém apenas group_a..group_h. Os grupos I, J, K, L
--      estão ausentes. O WF-02 vai tentar inserir eventos de partidas nos
--      grupos I-L e falhar na FK para matches, ou o WF-01 vai falhar ao
--      tentar inserir matches com stage='group_i'.
--
-- [P2] notifications: ausência de índice em correlation_id
--      O WF-07 vai buscar notificações por correlation_id para detectar
--      duplicatas (rate limiting de notificações idênticas). Sem índice,
--      isso será full scan na tabela a cada evento ao vivo.
--      Volume estimado Sprint 3: 500+ notificações/dia.
--
-- [P3] match_events: coluna match_minute_key ausente
--      O WF-02 usa cursor baseado em 'minute' para detectar eventos novos.
--      Porém, dois eventos podem ocorrer no mesmo minuto (ex: dois gols em
--      sequência no minuto 45). O cursor só por minute perde o segundo evento.
--      Solução: campo compound_key (external_id quando disponível, senão
--      match_id::minute::event_type::sequence) para cursor mais preciso.
--      Na prática: o cursor passa a ser o external_id máximo, não o minute.
--      A migration adiciona índice composto para suportar essa query.
--
-- [P4] notifications: coluna event_dedup_key ausente
--      Para evitar enviar duas notificações para o mesmo evento (ex: WF-02
--      rodando em dois workers ao mesmo tempo), precisamos de uma chave de
--      deduplicação única por evento+canal. Sem ela, o Redis rate limiter
--      é a única proteção, mas tem TTL de 60s - insuficiente se um worker
--      reprocessa um evento antigo.
-- =============================================================================

SET search_path TO wcic, public;

-- =============================================================================
-- [P1] Adicionar grupos I, J, K, L ao ENUM match_stage
-- ALTER TYPE ... ADD VALUE é não-transacional no PostgreSQL - não pode estar
-- dentro de um bloco de transação. Executa como statement independente.
-- IF NOT EXISTS evita erro em rerun da migration.
-- =============================================================================

ALTER TYPE match_stage ADD VALUE IF NOT EXISTS 'group_i' AFTER 'group_h';
ALTER TYPE match_stage ADD VALUE IF NOT EXISTS 'group_j' AFTER 'group_i';
ALTER TYPE match_stage ADD VALUE IF NOT EXISTS 'group_k' AFTER 'group_j';
ALTER TYPE match_stage ADD VALUE IF NOT EXISTS 'group_l' AFTER 'group_k';

COMMENT ON TYPE match_stage IS
    'Estágios da Copa do Mundo 2026. Grupos A-L (12 grupos, 48 times). '
    'Atualizado na migration 006 para incluir grupos I-L ausentes na 001.';

-- =============================================================================
-- [P2] Índice em notifications.correlation_id
-- WF-07 usa para detectar notificações duplicadas por cadeia de eventos.
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_notifications_correlation_id
    ON notifications (correlation_id)
    WHERE correlation_id IS NOT NULL;

COMMENT ON INDEX idx_notifications_correlation_id
    IS 'WF-07 busca notificações anteriores por correlation_id para deduplicação. '
       'Partial index (IS NOT NULL) exclui notificações sem rastreabilidade.';

-- Índice adicional: notificações recentes por tipo+canal (rate limiting no WF-07)
CREATE INDEX IF NOT EXISTS idx_notifications_type_channel_recent
    ON notifications (notification_type, channel, created_at DESC)
    WHERE status IN ('sent', 'pending');

COMMENT ON INDEX idx_notifications_type_channel_recent
    IS 'WF-07 verifica se notificação similar foi enviada recentemente. '
       'Partial index em status ativo reduz tamanho do índice.';

-- =============================================================================
-- [P3] Índice composto para cursor do WF-02 por (match_id, external_id)
-- Suporta a query: SELECT MAX(external_id::bigint) FROM match_events
--                  WHERE match_id = $1 AND external_id IS NOT NULL
-- O índice da migration 005 (idx_match_events_external_id_unique) já cobre
-- (match_id, external_id) mas é UNIQUE parcial - adequado para dedup.
-- Adicionamos índice de covering para a query de cursor (sem UNIQUE).
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_match_events_cursor_lookup
    ON match_events (match_id, created_at DESC)
    INCLUDE (external_id, event_type, minute);

COMMENT ON INDEX idx_match_events_cursor_lookup
    IS 'WF-02 usa para buscar último evento processado por partida (cursor). '
       'INCLUDE elimina heap fetch para os campos mais acessados.';

-- =============================================================================
-- [P4] notifications: coluna event_dedup_key
-- Chave de deduplicação composta: hash(match_id + event_type + minute + channel)
-- Permite UNIQUE constraint que previne inserção dupla mesmo sem Redis.
-- NULL permitido para notificações não relacionadas a eventos ao vivo.
-- =============================================================================

ALTER TABLE notifications
    ADD COLUMN IF NOT EXISTS event_dedup_key VARCHAR(128);

COMMENT ON COLUMN notifications.event_dedup_key
    IS 'Hash de deduplicação: sha256(match_id||event_type||minute||channel). '
       'NULL para notificações não relacionadas a eventos ao vivo (digests, alertas). '
       'Índice UNIQUE parcial previne duplicata mesmo com retry de worker.';

-- Índice UNIQUE parcial - apenas para notificações de eventos ao vivo
CREATE UNIQUE INDEX IF NOT EXISTS idx_notifications_event_dedup
    ON notifications (event_dedup_key)
    WHERE event_dedup_key IS NOT NULL;

COMMENT ON INDEX idx_notifications_event_dedup
    IS 'Garante que o mesmo evento ao vivo não gera duas notificações no mesmo canal. '
       'Última linha de defesa além do rate limiter Redis do WF-07.';

-- =============================================================================
-- VALIDAÇÃO DA MIGRATION
-- =============================================================================

DO $$
DECLARE
    v_groups_count   INTEGER;
    v_index_exists   BOOLEAN;
    v_col_exists     BOOLEAN;
BEGIN
    -- Verifica que grupos I-L foram adicionados ao ENUM
    SELECT COUNT(*) INTO v_groups_count
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'match_stage'
      AND e.enumlabel IN ('group_i', 'group_j', 'group_k', 'group_l');

    IF v_groups_count < 4 THEN
        RAISE EXCEPTION 'FALHA: grupos I-L não adicionados ao ENUM match_stage (encontrados: %)', v_groups_count;
    END IF;

    -- Verifica índice de correlation_id
    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'wcic'
          AND tablename = 'notifications'
          AND indexname = 'idx_notifications_correlation_id'
    ) INTO v_index_exists;

    IF NOT v_index_exists THEN
        RAISE EXCEPTION 'FALHA: idx_notifications_correlation_id não criado';
    END IF;

    -- Verifica coluna event_dedup_key
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'wcic'
          AND table_name = 'notifications'
          AND column_name = 'event_dedup_key'
    ) INTO v_col_exists;

    IF NOT v_col_exists THEN
        RAISE EXCEPTION 'FALHA: coluna event_dedup_key não existe em notifications';
    END IF;

    RAISE NOTICE 'Migration 006 validada com sucesso.';
END;
$$;

-- =============================================================================
-- FIM DA MIGRATION 006
-- =============================================================================
