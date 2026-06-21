-- =============================================================================
-- WCIC - World Cup Intelligence Center
-- Migration: 007_fix_sprint4.sql
-- Description: Correções e adições necessárias para a Sprint 4
--              (News Intelligence + Sentiment Analysis)
-- Run after: 006_fix_sprint3.sql
--
-- PROBLEMAS IDENTIFICADOS:
--
-- [P1] news: campo url_hash é CHAR(64) mas SHA-256 em hex é exatamente 64 chars.
--      O WF-03 calculará o hash via crypto.createHash('sha256') no n8n, que
--      retorna string hex lowercase. Correto. Porém a tabela não tem índice
--      GIN em tags para busca por tag, necessário para dashboard editorial.
--
-- [P2] news_analysis: campo 'raw_response' ausente.
--      O agente GPT retorna um JSON completo. Armazenar apenas os campos
--      mapeados perde a resposta original para debugging e reprocessamento.
--      Necessário para auditoria quando prompt_version muda.
--
-- [P3] sentiment_snapshots: source CHECK constraint muito restritivo.
--      Aceita apenas 'twitter', 'reddit', 'combined'. WF-04 usará também
--      'newsapi' (sentimento derivado de notícias) e 'manual' (testes).
--      Expandir para VARCHAR sem CHECK ou com CHECK mais amplo.
--
-- [P4] news: ausência de índice de busca em 'source' para dedup por fonte.
--      WF-03 precisa verificar artigos já processados por fonte nas últimas
--      24h para rate limiting inteligente por provider.
--
-- [P5] news_analysis: ausência de coluna 'topics' para categorização temática.
--      O News Analyst GPT classifica artigos em tópicos (lesão, tática,
--      escalação, controvérsia). Necessário para filtros de dashboard.
-- =============================================================================

SET search_path TO wcic, public;

-- =============================================================================
-- [P1] Índice GIN em news_analysis.tags para busca por tag
-- WF-03 dashboard: "mostrar artigos com tag 'lesão'"
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_news_analysis_tags
    ON news_analysis USING gin(tags);

COMMENT ON INDEX idx_news_analysis_tags
    IS 'WF-03/dashboard: busca artigos por tag. GIN suporta operador @> (contains).';

-- Índice composto para query "notícias pendentes de análise IA por ordem de criação"
-- WF-03 usa para buscar o próximo batch de artigos para processar
CREATE INDEX IF NOT EXISTS idx_news_pending_analysis
    ON news (created_at ASC)
    WHERE processing_status = 'pending';

COMMENT ON INDEX idx_news_pending_analysis
    IS 'WF-03: busca artigos pendentes de análise em ordem FIFO. '
       'Partial index em pending reduz tamanho drasticamente.';

-- =============================================================================
-- [P2] news_analysis: coluna raw_gpt_response para auditoria
-- =============================================================================

ALTER TABLE news_analysis
    ADD COLUMN IF NOT EXISTS raw_gpt_response JSONB;

COMMENT ON COLUMN news_analysis.raw_gpt_response
    IS 'Resposta JSON completa do GPT-4o antes do parse. '
       'Preserva para debugging, reprocessamento e comparação entre prompt_versions. '
       'NULL para registros migrados de versões anteriores.';

-- =============================================================================
-- [P3] sentiment_snapshots: expandir source para aceitar mais origens
-- ALTER TYPE não se aplica aqui pois source é CHECK constraint, não ENUM.
-- Removemos o CHECK antigo e criamos um mais abrangente.
-- =============================================================================

ALTER TABLE sentiment_snapshots
    DROP CONSTRAINT IF EXISTS sentiment_snapshots_source_check;

ALTER TABLE sentiment_snapshots
    ADD CONSTRAINT sentiment_snapshots_source_check
    CHECK (source IN ('twitter', 'reddit', 'newsapi', 'combined', 'manual'));

COMMENT ON COLUMN sentiment_snapshots.source
    IS 'Origem dos dados de sentimento. '
       'twitter/reddit: redes sociais. newsapi: derivado de notícias. '
       'combined: agregado de múltiplas fontes. manual: testes.';

-- =============================================================================
-- [P4] news: índice em (source, processing_status, created_at)
-- WF-03 rate limiting inteligente: "quantos artigos desta fonte nas últimas Xh?"
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_news_source_status_time
    ON news (source, processing_status, created_at DESC);

COMMENT ON INDEX idx_news_source_status_time
    IS 'WF-03: rate limiting por fonte. '
       'Query: COUNT(*) WHERE source=$1 AND created_at > NOW()-INTERVAL ''1 hour''.';

-- =============================================================================
-- [P5] news_analysis: coluna topics para categorização temática
-- Separado de 'tags' (palavras-chave) - topics são categorias estruturadas
-- definidas pelo prompt do GPT (injury, tactics, lineup, controversy, etc.)
-- =============================================================================

ALTER TABLE news_analysis
    ADD COLUMN IF NOT EXISTS topics TEXT[] DEFAULT '{}';

COMMENT ON COLUMN news_analysis.topics
    IS 'Categorias temáticas estruturadas classificadas pelo GPT News Analyst. '
       'Valores: injury, suspension, lineup, tactics, controversy, transfer, '
       'performance, weather, venue, historical. Diferente de tags (palavras livres).';

-- Índice GIN para filtro por tópico
CREATE INDEX IF NOT EXISTS idx_news_analysis_topics
    ON news_analysis USING gin(topics);

COMMENT ON INDEX idx_news_analysis_topics
    IS 'Dashboard editorial: filtrar notícias por categoria temática.';

-- =============================================================================
-- ADIÇÃO: tabela news_sources para configuração de feeds RSS e APIs
-- Necessária para WF-03 carregar fontes dinamicamente (sem hardcode no workflow)
-- =============================================================================

CREATE TABLE IF NOT EXISTS news_sources (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(100) NOT NULL UNIQUE,
    source_type     VARCHAR(20) NOT NULL CHECK (source_type IN ('newsapi', 'rss', 'manual')),
    url             TEXT NOT NULL,
    language        CHAR(5) NOT NULL DEFAULT 'en',
    country         CHAR(2),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    priority        SMALLINT NOT NULL DEFAULT 5 CHECK (priority BETWEEN 1 AND 10),
    -- Rate limiting por fonte
    requests_per_hour SMALLINT DEFAULT 10,
    last_fetched_at TIMESTAMPTZ,
    -- Configuração de query (para NewsAPI)
    query_template  TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE news_sources
    IS 'Configuração dinâmica de fontes de notícias para WF-03. '
       'Permite adicionar/remover fontes sem alterar o workflow.';

-- Seed inicial com fontes configuradas
INSERT INTO news_sources (name, source_type, url, language, country, priority, query_template) VALUES
    ('NewsAPI-EN',    'newsapi', 'https://newsapi.org/v2/everything', 'en', 'us', 10,
     'FIFA World Cup 2026 soccer football'),
    ('NewsAPI-PT',    'newsapi', 'https://newsapi.org/v2/everything', 'pt', 'br', 9,
     'Copa do Mundo 2026 futebol'),
    ('ESPN RSS',      'rss',     'https://www.espn.com/espn/rss/soccer/news', 'en', 'us', 8,
     NULL),
    ('BBC Sport RSS', 'rss',     'http://feeds.bbci.co.uk/sport/football/rss.xml', 'en', 'gb', 7,
     NULL),
    ('UOL Esporte',   'rss',     'https://esporte.uol.com.br/futebol/rss.xml', 'pt', 'br', 7,
     NULL),
    ('L Equipe RSS',  'rss',     'https://www.lequipe.fr/rss/actu_rss_Football.xml', 'fr', 'fr', 6,
     NULL)
ON CONFLICT (name) DO NOTHING;

COMMENT ON TABLE news_sources IS
    'Fontes de notícias ativas para WF-03. '
    'Seed inicial com 6 fontes multilíngues.';

-- =============================================================================
-- ADIÇÃO: índice para sentiment_snapshots por entity_id isolado
-- WF-04 busca todos os snapshots de uma entidade específica para calcular trend
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_sentiment_entity_recent
    ON sentiment_snapshots (entity_id, captured_at DESC)
    WHERE entity_type IN ('team', 'player');

COMMENT ON INDEX idx_sentiment_entity_recent
    IS 'WF-04: busca snapshots recentes de uma equipe/jogador para cálculo de tendência. '
       'Partial index em team/player (exclui match) pois trend é calculado por entidade persistente.';

-- =============================================================================
-- VALIDAÇÃO
-- =============================================================================

DO $$
DECLARE
    v_col_exists  BOOLEAN;
    v_tbl_exists  BOOLEAN;
    v_idx_exists  BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'wcic' AND table_name = 'news_analysis'
          AND column_name = 'raw_gpt_response'
    ) INTO v_col_exists;
    IF NOT v_col_exists THEN
        RAISE EXCEPTION 'FALHA: raw_gpt_response ausente em news_analysis';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'wcic' AND table_name = 'news_analysis'
          AND column_name = 'topics'
    ) INTO v_col_exists;
    IF NOT v_col_exists THEN
        RAISE EXCEPTION 'FALHA: topics ausente em news_analysis';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'wcic' AND table_name = 'news_sources'
    ) INTO v_tbl_exists;
    IF NOT v_tbl_exists THEN
        RAISE EXCEPTION 'FALHA: tabela news_sources não criada';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'wcic' AND tablename = 'news'
          AND indexname = 'idx_news_pending_analysis'
    ) INTO v_idx_exists;
    IF NOT v_idx_exists THEN
        RAISE EXCEPTION 'FALHA: idx_news_pending_analysis não criado';
    END IF;

    RAISE NOTICE 'Migration 007 validada com sucesso.';
END;
$$;

-- =============================================================================
-- FIM DA MIGRATION 007
-- =============================================================================
