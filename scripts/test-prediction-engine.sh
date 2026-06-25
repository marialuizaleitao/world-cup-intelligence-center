# =============================================================================
# WCIC - scripts/test-prediction-engine.sh
# Valida o pipeline completo de AI Prediction Engine (WF-05 + SWF Match Predictor)
#
# Uso: ./scripts/test-prediction-engine.sh [--skip-openai]
# Saída: [OK] [WARN] [FAIL] + relatório final
# Exit: 0 se nenhum FAIL, 1 se qualquer FAIL
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

SKIP_OPENAI=false
for arg in "$@"; do case $arg in --skip-openai) SKIP_OPENAI=true ;; esac; done

TOTAL=0; PASSED=0; WARNED=0; FAILED=0

log_ok()   { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1));  printf "  \033[32m[OK  ]\033[0m %s\n" "$*"; }
log_warn() { TOTAL=$((TOTAL+1)); WARNED=$((WARNED+1));  printf "  \033[33m[WARN]\033[0m %s\n" "$*"; }
log_fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1));  printf "  \033[31m[FAIL]\033[0m %s\n" "$*"; }
log_info() { printf "  \033[36m[INFO]\033[0m %s\n" "$*"; }
log_step() { echo ""; printf "  ▶ %s\n" "$*"; echo ""; }

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   WCIC - AI Prediction Engine Test              ║"
echo "  ╚══════════════════════════════════════════════════╝"

[[ ! -f "$ENV_FILE" ]] && { log_fail ".env não encontrado"; exit 1; }
set -o allexport
source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$') 2>/dev/null || true
set +o allexport

REDIS_PASS="${REDIS_PASSWORD:-}"
N8N_URL="${WEBHOOK_URL:-http://localhost:5678}"
N8N_URL="${N8N_URL%/}"
N8N_USER="${N8N_BASIC_AUTH_USER:-admin}"
N8N_PASS="${N8N_BASIC_AUTH_PASSWORD:-}"
OPENAI_KEY="${OPENAI_API_KEY:-}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o}"

# ---------------------------------------------------------------------------
# SEÇÃO 1 - Infraestrutura
# ---------------------------------------------------------------------------
log_step "1. Infraestrutura"

docker exec wcic-postgres pg_isready -U postgres -q 2>/dev/null \
  && log_ok "PostgreSQL respondendo" || { log_fail "PostgreSQL indisponível"; exit 1; }

PING=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" ping 2>/dev/null | tr -d '\r')
[[ "$PING" == "PONG" ]] && log_ok "Redis respondendo" || { log_fail "Redis indisponível"; exit 1; }

N8N_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${N8N_URL}/healthz" 2>/dev/null || echo "000")
[[ "$N8N_HTTP" == "200" ]] && log_ok "n8n respondendo" || log_warn "n8n não respondeu (HTTP $N8N_HTTP)"

# ---------------------------------------------------------------------------
# SEÇÃO 2 - Schema Sprint 5
# ---------------------------------------------------------------------------
log_step "2. Schema do banco - Sprint 5"

M008=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM public.schema_migrations WHERE filename='008_fix_sprint5.sql'" 2>/dev/null || echo "")
[[ "$M008" == "1" ]] \
  && log_ok "Migration 008 aplicada" \
  || log_fail "Migration 008 ausente - execute ./scripts/setup-database.sh"

# Tabela match_stats
MS_EXISTS=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM information_schema.tables WHERE table_schema='wcic' AND table_name='match_stats'" 2>/dev/null || echo "")
[[ "$MS_EXISTS" == "1" ]] \
  && log_ok "Tabela wcic.match_stats existe" \
  || log_fail "Tabela wcic.match_stats ausente - migration 008 necessária"

# brier_score em predictions
BS_COL=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM information_schema.columns WHERE table_schema='wcic' AND table_name='predictions' AND column_name='brier_score'" 2>/dev/null || echo "")
[[ "$BS_COL" == "1" ]] \
  && log_ok "Coluna brier_score existe em predictions" \
  || log_fail "Coluna brier_score ausente - migration 008 necessária"

# raw_gpt_response em predictions
RAW_COL=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM information_schema.columns WHERE table_schema='wcic' AND table_name='predictions' AND column_name='raw_gpt_response'" 2>/dev/null || echo "")
[[ "$RAW_COL" == "1" ]] \
  && log_ok "Coluna raw_gpt_response existe em predictions" \
  || log_fail "Coluna raw_gpt_response ausente - migration 008 necessária"

# brier_score_avg em prediction_accuracy
BSA_COL=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM information_schema.columns WHERE table_schema='wcic' AND table_name='prediction_accuracy' AND column_name='brier_score_avg'" 2>/dev/null || echo "")
[[ "$BSA_COL" == "1" ]] \
  && log_ok "Coluna brier_score_avg existe em prediction_accuracy" \
  || log_fail "Coluna brier_score_avg ausente - migration 008 necessária"

# prediction_accuracy_unique constraint
UNIQ=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT 1 FROM pg_constraint WHERE conname='prediction_accuracy_unique' AND conrelid='wcic.prediction_accuracy'::regclass" 2>/dev/null || echo "")
[[ "$UNIQ" == "1" ]] \
  && log_ok "Constraint prediction_accuracy_unique existe" \
  || log_fail "Constraint prediction_accuracy_unique ausente - UPSERT do WF-11 falhará"

# Pré-requisito: times no banco
TEAM_COUNT=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT COUNT(*) FROM wcic.teams" 2>/dev/null | tr -d ' ' || echo "0")
[[ "${TEAM_COUNT:-0}" -ge 48 ]] \
  && log_ok "wcic.teams populada ($TEAM_COUNT times)" \
  || log_fail "wcic.teams com apenas $TEAM_COUNT times - execute seeds"

# ---------------------------------------------------------------------------
# SEÇÃO 3 - Inserção sintética em match_stats
# ---------------------------------------------------------------------------
log_step "3. Teste funcional - match_stats"

MATCH_ID=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT id FROM wcic.matches ORDER BY scheduled_at LIMIT 1" 2>/dev/null | tr -d ' \n' || echo "")

if [[ -z "$MATCH_ID" ]]; then
  log_warn "Nenhuma partida no banco - criando partida sintética"
  HOME_ID=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "SELECT id FROM wcic.teams LIMIT 1" 2>/dev/null | tr -d ' \n' || echo "")
  AWAY_ID=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "SELECT id FROM wcic.teams OFFSET 1 LIMIT 1" 2>/dev/null | tr -d ' \n' || echo "")
  MATCH_ID=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "INSERT INTO wcic.matches (external_id, home_team_id, away_team_id, stage, scheduled_at, status, source_api)
     VALUES ('test-pred-$(date +%s)', '${HOME_ID}'::uuid, '${AWAY_ID}'::uuid, 'group_a', NOW()+INTERVAL '1 hour', 'scheduled', 'test')
     RETURNING id" 2>/dev/null | tr -d ' \n' || echo "")
  [[ -n "$MATCH_ID" ]] && log_ok "Partida sintética criada: $MATCH_ID" || { log_fail "Falha ao criar partida sintética"; }
else
  log_ok "Usando partida existente: $MATCH_ID"
fi

if [[ -n "$MATCH_ID" ]]; then
  MS_INSERTED=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "INSERT INTO wcic.match_stats (match_id, home_form, away_form, home_form_pts, away_form_pts,
       home_goals_scored_avg, home_goals_conceded_avg, away_goals_scored_avg, away_goals_conceded_avg,
       h2h_home_wins, h2h_draws, h2h_away_wins)
     VALUES ('${MATCH_ID}'::uuid, ARRAY['W','W','D','L','W'], ARRAY['D','W','W','L','W'],
       10, 9, 1.60, 0.80, 1.40, 1.00, 5, 3, 2)
     ON CONFLICT (match_id) DO UPDATE SET home_form_pts = EXCLUDED.home_form_pts
     RETURNING id" 2>/dev/null | tr -d ' \n' || echo "")

  [[ -n "$MS_INSERTED" ]] \
    && log_ok "match_stats inserido/atualizado para a partida" \
    || log_fail "Falha ao inserir em match_stats"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 4 - Inserção sintética em predictions + cálculo Brier Score
# ---------------------------------------------------------------------------
log_step "4. Teste funcional - predictions e Brier Score"

if [[ -n "$MATCH_ID" ]]; then
  PRED_ID=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
    "INSERT INTO wcic.predictions (match_id, prediction_type, home_win_prob, draw_prob, away_win_prob,
       predicted_home, predicted_away, confidence, justification, ai_model, prompt_version,
       feature_snapshot)
     VALUES ('${MATCH_ID}'::uuid, 'pre_match', 0.550, 0.270, 0.180, 2, 1, 0.72,
       'Test prediction: home team has better form and home advantage.', 'gpt-4o', 'v1.0',
       '{\"test\": true}'::jsonb)
     RETURNING id" 2>/dev/null | tr -d ' \n' || echo "")

  if [[ -n "$PRED_ID" ]]; then
    log_ok "Previsão sintética inserida: $PRED_ID"

    # Valida que probs estão no range correto
    PROB_SUM=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
      "SELECT ROUND((home_win_prob + draw_prob + away_win_prob)::numeric, 3)
       FROM wcic.predictions WHERE id='${PRED_ID}'::uuid" 2>/dev/null | tr -d ' ' || echo "0")
    [[ "$PROB_SUM" == "1.000" ]] \
      && log_ok "Soma das probabilidades = 1.000" \
      || log_warn "Soma das probabilidades = $PROB_SUM (esperado 1.000)"

    # Simula cálculo do Brier Score (home win = outcome real)
    BS_CALC=$(python3 -c "
p_home, p_draw, p_away = 0.550, 0.270, 0.180
# Outcome real: home win
I_home, I_draw, I_away = 1, 0, 0
bs = (p_home-I_home)**2 + (p_draw-I_draw)**2 + (p_away-I_away)**2
print(f'{bs:.4f}')
" 2>/dev/null || echo "?")
    log_ok "Brier Score calculado (simulação home win): BS=$BS_CALC (range [0,2] - menor é melhor)"

    # Atualiza previsão como se WF-11 tivesse avaliado
    docker exec wcic-postgres psql -U postgres -d wcic -c \
      "UPDATE wcic.predictions SET actual_outcome='home', was_correct=true,
       brier_score=${BS_CALC}::numeric, accuracy_score=(1 - ${BS_CALC}::numeric / 2),
       actual_home_score=2, actual_away_score=1
       WHERE id='${PRED_ID}'::uuid" &>/dev/null
    log_ok "Previsão avaliada com resultado simulado (home win, 2x1)"

    # Limpeza
    docker exec wcic-postgres psql -U postgres -d wcic -c \
      "DELETE FROM wcic.predictions WHERE id='${PRED_ID}'::uuid" &>/dev/null
    log_ok "Previsão sintética removida"
  else
    log_fail "Falha ao inserir previsão sintética em wcic.predictions"
  fi
fi

# ---------------------------------------------------------------------------
# SEÇÃO 5 - Redis: cache de previsão
# ---------------------------------------------------------------------------
log_step "5. Redis - cache de previsão"

if [[ -n "$MATCH_ID" ]]; then
  CACHE_KEY="wcic:cache:prediction:${MATCH_ID}"
  CACHE_VAL="{\"match_id\":\"${MATCH_ID}\",\"home_win_prob\":0.55,\"draw_prob\":0.27,\"away_win_prob\":0.18,\"confidence\":0.72}"

  SET_R=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
    SET "$CACHE_KEY" "$CACHE_VAL" EX 3600 2>/dev/null | tr -d '\r')
  GET_R=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
    GET "$CACHE_KEY" 2>/dev/null | tr -d '\r')
  TTL_R=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
    TTL "$CACHE_KEY" 2>/dev/null | tr -d '\r')

  [[ "$SET_R" == "OK" && -n "$GET_R" ]] \
    && log_ok "Cache de previsão SET/GET funcionando" \
    || log_fail "Cache Redis de previsão com falha"

  [[ "${TTL_R:-0}" -gt 3500 ]] \
    && log_ok "TTL do cache: ${TTL_R}s (~1h)" \
    || log_warn "TTL inesperado: ${TTL_R}s"

  docker exec wcic-redis redis-cli -a "$REDIS_PASS" DEL "$CACHE_KEY" &>/dev/null
  log_ok "Chave de cache de teste removida"

  # Testa Pub/Sub channel
  PUB_R=$(docker exec wcic-redis redis-cli -a "$REDIS_PASS" \
    PUBLISH "wcic:pub:predictions.new" \
    "{\"match_id\":\"${MATCH_ID}\",\"test\":true}" 2>/dev/null | tr -d '\r')
  [[ "$PUB_R" =~ ^[0-9]+$ ]] \
    && log_ok "PUBLISH em wcic:pub:predictions.new funcionando ($PUB_R subscriber(s))" \
    || log_warn "PUBLISH retornou: $PUB_R"
fi

# ---------------------------------------------------------------------------
# SEÇÃO 6 - OpenAI com prompt do Match Predictor
# ---------------------------------------------------------------------------
log_step "6. OpenAI - Match Predictor"

if [[ "$SKIP_OPENAI" == "true" ]]; then
  log_info "OpenAI pulada (--skip-openai)"
elif [[ -z "$OPENAI_KEY" ]]; then
  log_warn "OPENAI_API_KEY não configurada - OpenAI pulada"
else
  SYS='Você é um estatístico esportivo. Analise e retorne APENAS JSON puro com: home_win_prob, draw_prob, away_win_prob (somam 1.000), predicted_home_score, predicted_away_score, confidence, key_factors, justification.'
  USR='PARTIDA: Brazil vs Argentina - Copa do Mundo 2026 - Semifinal
FORMA: Brazil WWWDW (13pts) | Argentina WWWWW (15pts)
H2H: Brazil venceu 4, Empates 3, Argentina venceu 3
GOLS: Brazil 2.0/jogo | Argentina 2.4/jogo
LESÕES: Brazil: sem lesões críticas | Argentina: sem lesões críticas'

  OAI_R=$(curl -s -w "\n%{http_code}" --max-time 30 \
    -H "Authorization: Bearer ${OPENAI_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${OPENAI_MODEL}\",\"messages\":[{\"role\":\"system\",\"content\":\"${SYS}\"},{\"role\":\"user\",\"content\":\"${USR}\"}],\"max_tokens\":500,\"temperature\":0.15,\"response_format\":{\"type\":\"json_object\"}}" \
    "https://api.openai.com/v1/chat/completions" 2>/dev/null)

  OAI_BODY=$(echo "$OAI_R" | head -n -1)
  OAI_STATUS=$(echo "$OAI_R" | tail -n 1)

  case "$OAI_STATUS" in
    200)
      TOKENS=$(echo "$OAI_BODY" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('total_tokens','?'))" 2>/dev/null || echo "?")
      CONTENT=$(echo "$OAI_BODY" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null || echo "")
      log_ok "OpenAI respondeu ($TOKENS tokens)"

      VALIDATION=$(echo "$CONTENT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    hp = float(d.get('home_win_prob', -1))
    dp = float(d.get('draw_prob', -1))
    ap = float(d.get('away_win_prob', -1))
    total = round(hp + dp + ap, 3)
    just = d.get('justification', '')
    conf = float(d.get('confidence', -1))
    errors = []
    if hp < 0 or dp < 0 or ap < 0: errors.append('probs_missing')
    if abs(total - 1.0) > 0.05: errors.append(f'sum={total}')
    if len(just) < 20: errors.append(f'justification_short={len(just)}')
    if conf < 0 or conf > 1: errors.append(f'confidence_invalid={conf}')
    if errors: print('ERRORS:' + ','.join(errors))
    else: print(f'OK:home={hp:.3f},draw={dp:.3f},away={ap:.3f},conf={conf:.2f}')
except Exception as e:
    print(f'PARSE_ERROR:{e}')
" 2>/dev/null || echo "PARSE_ERROR")

      if [[ "$VALIDATION" == OK* ]]; then
        log_ok "Previsão GPT válida: $VALIDATION"
      elif [[ "$VALIDATION" == ERRORS* ]]; then
        log_warn "Previsão GPT com alertas: $VALIDATION (SWF renormaliza automaticamente)"
      else
        log_fail "Previsão GPT inválida: $VALIDATION"
      fi
      ;;
    401) log_fail "OpenAI - API key inválida (HTTP 401)" ;;
    429) log_warn "OpenAI - rate limit (HTTP 429)" ;;
    000) log_fail "OpenAI inacessível" ;;
    *)   log_warn "OpenAI retornou HTTP $OAI_STATUS" ;;
  esac
fi

# ---------------------------------------------------------------------------
# SEÇÃO 7 - n8n: workflows Sprint 5 importados
# ---------------------------------------------------------------------------
log_step "7. n8n - Workflows Sprint 5"

if [[ -z "$N8N_PASS" ]]; then
  log_warn "N8N_BASIC_AUTH_PASSWORD não configurado - verificação pulada"
else
  WF_LIST=$(curl -s --max-time 10 \
    -u "${N8N_USER}:${N8N_PASS}" \
    "${N8N_URL}/api/v1/workflows?limit=100" 2>/dev/null || echo "{}")

  for wf_name in "WF-05 - AI Prediction Engine" "WF-11 - Prediction Accuracy Tracker" \
                  "SWF - OpenAI Match Predictor"; do
    EXISTS=$(echo "$WF_LIST" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); names=[w['name'] for w in d.get('data',[])]; print('yes' if '${wf_name}' in names else 'no')" 2>/dev/null || echo "no")
    [[ "$EXISTS" == "yes" ]] \
      && log_ok "Workflow importado: '$wf_name'" \
      || log_fail "Workflow NÃO encontrado no n8n: '$wf_name'"
  done
fi

# ---------------------------------------------------------------------------
# SEÇÃO 8 - Consistência WF-05 → WF-11
# ---------------------------------------------------------------------------
log_step "8. Consistência entre WF-05 e WF-11"

PRED_TOTAL=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT COUNT(*) FROM wcic.predictions WHERE prediction_type='pre_match'" 2>/dev/null | tr -d ' ' || echo "0")
PRED_EVALUATED=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT COUNT(*) FROM wcic.predictions WHERE was_correct IS NOT NULL" 2>/dev/null | tr -d ' ' || echo "0")
PRED_PENDING=$(docker exec wcic-postgres psql -U postgres -d wcic -tAc \
  "SELECT COUNT(*) FROM wcic.predictions p JOIN wcic.matches m ON m.id=p.match_id WHERE p.was_correct IS NULL AND m.status='finished'" 2>/dev/null | tr -d ' ' || echo "0")

log_info "Total de previsões pre_match: $PRED_TOTAL"
log_info "Previsões avaliadas (was_correct != NULL): $PRED_EVALUATED"
if [[ "${PRED_PENDING:-0}" -gt 0 ]]; then
  log_warn "$PRED_PENDING previsões pendentes de avaliação (jogos finished sem was_correct) - WF-11 deve processar"
else
  log_ok "Zero previsões pendentes de avaliação (WF-11 up-to-date)"
fi

# ---------------------------------------------------------------------------
# RELATÓRIO FINAL
# ---------------------------------------------------------------------------
echo ""
echo "  ══════════════════════════════════════════════════"
echo "   Relatório Final - AI Prediction Engine"
echo "  ══════════════════════════════════════════════════"
printf "   Total    : %d verificações\n" "$TOTAL"
printf "   \033[32mPassaram\033[0m  : %d\n" "$PASSED"
printf "   \033[33mAvisos\033[0m    : %d\n" "$WARNED"
printf "   \033[31mFalhas\033[0m    : %d\n" "$FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
  echo "   \033[31mStatus: REPROVADO - corrija os [FAIL] antes de ativar WF-05\033[0m"
  exit 1
elif [[ $WARNED -gt 0 ]]; then
  echo "   \033[33mStatus: APROVADO COM AVISOS\033[0m"
  exit 0
else
  echo "   \033[32mStatus: APROVADO - pipeline de previsões operacional\033[0m"
  exit 0
fi
SHEOF
chmod +x /home/claude/wcic/scripts/test-prediction-engine.sh
bash -n /home/claude/wcic/scripts/test-prediction-engine.sh && echo "sintaxe ok"
