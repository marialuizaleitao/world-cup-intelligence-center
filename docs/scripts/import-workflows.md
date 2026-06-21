# import-workflows.sh - Documentação

**Arquivo:** `scripts/import-workflows.sh`  
**Tipo:** Shell script (bash)  
**Compatibilidade:** Linux, macOS, WSL2

---

## Objetivo

Importar todos os arquivos JSON de `n8n/workflows/` para a instância n8n via API REST. Detecta automaticamente se cada workflow já existe (por nome) e executa PUT para atualizar ou POST para criar. Idempotente: pode ser executado múltiplas vezes.

---

## Pré-requisitos

| Requisito | Verificação |
|---|---|
| Container `wcic-n8n-main` em execução | `docker ps \| grep wcic-n8n-main` |
| `curl` instalado | `which curl` |
| `jq` instalado | `which jq` (instalar: `sudo apt-get install -y jq`) |
| `.env` com `N8N_BASIC_AUTH_*` e `WEBHOOK_URL` | `grep N8N_BASIC_AUTH .env` |
| Arquivos JSON em `n8n/workflows/` | `ls n8n/workflows/*.json` |

---

## Variáveis Utilizadas

| Variável | Obrigatória | Uso |
|---|---|---|
| `WEBHOOK_URL` | ✅ | Base URL do n8n (ex: `http://localhost:5678/`) |
| `N8N_BASIC_AUTH_USER` | ✅ | Usuário para autenticação básica |
| `N8N_BASIC_AUTH_PASSWORD` | ✅ | Senha para autenticação básica |

---

## Fluxo de Execução

```
1. Verifica dependências (curl, jq)
2. Carrega .env
3. Constrói N8N_API_URL a partir de WEBHOOK_URL
4. Testa conectividade: GET /api/v1/workflows → espera HTTP 200
5. Busca workflows existentes: GET /api/v1/workflows?limit=100
   └─► Constrói mapa: nome → id
6. Para cada *.json em n8n/workflows/:
   a. Valida JSON (jq empty)
   b. Extrai nome do workflow (.name)
   c. Se já existe (por nome): PUT /api/v1/workflows/{id}
   d. Se não existe: POST /api/v1/workflows
   e. Registra resultado: IMPORTADO | ATUALIZADO | FALHOU
7. Exibe resumo
8. Avisa que workflows ficam INATIVOS após importação
```

---

## Opções de Linha de Comando

| Flag | Comportamento |
|---|---|
| (nenhuma) | Importa todos os arquivos em `n8n/workflows/` |
| `--dry-run` | Valida JSONs sem fazer requisições |
| `--file NOME.json` | Importa apenas o arquivo especificado |

---

## Exemplo de Uso

```bash
# Importar todos os workflows
./scripts/import-workflows.sh

# Testar sem importar
./scripts/import-workflows.sh --dry-run

# Importar apenas WF-01
./scripts/import-workflows.sh --file WF-01-match-collector.json

# Atualizar WF-07 após modificação
./scripts/import-workflows.sh --file WF-07-notification-hub.json
```

---

## Saída Esperada

```
  [OK]   curl disponível
  [OK]   jq disponível
  [OK]   n8n URL: http://localhost:5678
  [OK]   n8n API autenticada (HTTP 200)
  [OK]   2 workflow(s) já existente(s) no n8n

▶ Importando workflows

  [INFO] Processando: WF-01-match-collector.json
  [OK]   IMPORTADO: 'WF-01 - Match Collector' (novo id: abc123)
  [INFO] Processando: WF-02-live-event-monitor.json
  [OK]   ATUALIZADO: 'WF-02 - Live Event Monitor' (id: def456)
  [INFO] Processando: WF-07-notification-hub.json
  [OK]   IMPORTADO: 'WF-07 - Notification Hub' (novo id: ghi789)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Resultado da importação
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Novos importados : 2
  Atualizados      : 1
  Com falha        : 0

  [WARN] workflows importados ficam INATIVOS por padrão.
  [WARN] Ative cada workflow manualmente na UI: http://localhost:5678
```

---

## Possíveis Erros

| Mensagem | Causa | Solução |
|---|---|---|
| `n8n inacessível em http://localhost:5678` | Container não iniciado | `docker-compose up -d n8n` |
| `Credenciais n8n inválidas (HTTP 401)` | Senha incorreta | Verificar `N8N_BASIC_AUTH_PASSWORD` no `.env` |
| `JSON inválido: WF-XX.json` | Arquivo corrompido | Reexportar do n8n ou corrigir manualmente |
| `FALHOU ao importar: HTTP 400` | Schema de node inválido | Verificar versão do n8n vs versão usada para criar o JSON |
| `jq não encontrado` | Pacote não instalado | `sudo apt-get install -y jq` |

---

## Troubleshooting

**Workflow importado mas sem os nodes corretos:**
O JSON pode ter sido gerado para uma versão diferente do n8n. Verificar `typeVersion` dos nodes vs versão instalada: `docker exec wcic-n8n-main n8n --version`.

**Workflow duplicado (dois com o mesmo nome):**
O script detecta por nome. Se houver dois workflows com o mesmo nome no n8n, o comportamento é indefinido. Remover o duplicado via UI antes de importar.

**Após importação, workflow não aparece na UI:**
Fazer refresh da página. O n8n pode ter cacheado a lista anterior.
EOF

cat > /home/claude/wcic/docs/scripts/test-apis.md << 'EOF'
# test-apis.sh - Documentação

**Arquivo:** `scripts/test-apis.sh`  
**Tipo:** Shell script (bash)  
**Compatibilidade:** Linux, macOS, WSL2

---

## Objetivo

Validar conectividade e autenticação de todos os serviços do WCIC antes de iniciar operações. Produz relatório `[OK]` / `[WARN]` / `[FAIL]` por verificação. Exit code 0 se nenhum FAIL, exit code 1 se qualquer FAIL.

---

## Pré-requisitos

| Requisito | Verificação |
|---|---|
| Docker em execução | `docker info` |
| `curl` instalado | `which curl` |
| `python3` instalado | `which python3` |
| `.env` preenchido | variáveis de API não podem ser vazias para os testes externos |

---

## Variáveis Utilizadas

| Variável | Seção | Uso |
|---|---|---|
| `POSTGRES_ROOT_PASSWORD` | postgres | Acesso ao container via psql |
| `REDIS_PASSWORD` | redis | redis-cli ping e operações |
| `WEBHOOK_URL` | n8n | Base URL para health check |
| `N8N_BASIC_AUTH_USER` | n8n | Autenticação na API |
| `N8N_BASIC_AUTH_PASSWORD` | n8n | Autenticação na API |
| `FOOTBALL_DATA_API_KEY` | football | Header X-Auth-Token |
| `RAPIDAPI_KEY` | football | Header X-RapidAPI-Key (fallback) |
| `OPENAI_API_KEY` | openai | Bearer token |
| `OPENAI_MODEL` | openai | Modelo a testar (default: gpt-4o) |

---

## Seções de Verificação

| Seção | Verificações |
|---|---|
| **PostgreSQL** | Container rodando, conexão, 4 databases, schema wcic, 5 tabelas críticas, contagem de seeds, migration 005 |
| **Redis** | Container rodando, PING, uso de memória, leitura/escrita |
| **n8n** | 3 containers, health endpoint, API autenticada, contagem de workflows |
| **Football-Data API** | HTTP 200, nome da competição, rate limit disponível, fallback RapidAPI |
| **OpenAI** | HTTP 200, modelo correto |

---

## Opções de Linha de Comando

| Flag | Comportamento |
|---|---|
| (nenhuma) | Testa todos os serviços |
| `--verbose` | Exibe detalhes adicionais em itens OK |
| `--only postgres` | Testa apenas PostgreSQL |
| `--only redis` | Testa apenas Redis |
| `--only n8n` | Testa apenas n8n |
| `--only football` | Testa apenas Football-Data API |
| `--only openai` | Testa apenas OpenAI |

---

## Exemplo de Uso

```bash
# Teste completo
./scripts/test-apis.sh

# Testar apenas banco antes de aplicar migrations
./scripts/test-apis.sh --only postgres

# Testar APIs externas
./scripts/test-apis.sh --only football --only openai

# Verificar n8n após importar workflows
./scripts/test-apis.sh --only n8n --verbose
```

---

## Saída Esperada

```
  ── PostgreSQL ──────────────────────────────────────
  [OK  ] Container wcic-postgres está rodando
  [OK  ] PostgreSQL aceitando conexões
  [OK  ] Database 'n8n' existe
  [OK  ] Database 'wcic' existe
  [OK  ] Schema 'wcic' existe
  [OK  ] Tabela 'wcic.matches' existe
  [OK  ] Times populados (48 times)
  [WARN] Migration 005 não aplicada - Execute: ./scripts/setup-database.sh

  ── Football-Data API (Provider Primário) ──────────
  [OK  ] Football-Data API respondeu - Competição: FIFA World Cup
  [OK  ] Rate limit disponível: 9 req/min restantes
  [WARN] RAPIDAPI_KEY não definido - Fallback API não testada

═══════════════════════════════════════════════════
  Relatório Final
═══════════════════════════════════════════════════
  Total de verificações : 18
  Passaram [OK]         : 16
  Avisos   [WARN]       : 2
  Falhas   [FAIL]       : 0

  Status: APROVADO COM AVISOS - sistema funcional, mas verifique os [WARN]
```

---

## Possíveis Erros

| Item | Causa Comum | Solução |
|---|---|---|
| `[FAIL] Container wcic-postgres não encontrado` | Stack não iniciada | `docker-compose up -d` |
| `[FAIL] Database 'wcic' não encontrado` | Setup não executado | `./scripts/setup-database.sh` |
| `[FAIL] Football-Data API - token inválido (HTTP 401)` | Key incorreta ou expirada | Verificar em football-data.org |
| `[FAIL] OpenAI API - chave inválida (HTTP 401)` | Key incorreta | Verificar em platform.openai.com |
| `[WARN] Migration 005 não aplicada` | Setup desatualizado | `./scripts/setup-database.sh` |

---

## Troubleshooting

**Script retorna FAIL mas serviço está rodando:**
```bash
# Verificar se o container tem o nome exato esperado
docker ps --format "{{.Names}}"
# O script espera: wcic-postgres, wcic-redis, wcic-n8n-main
```

**OpenAI retorna 429 mesmo com saldo:**
Pode ser rate limit de RPM (requests per minute) atingido. Aguardar 60s e tentar novamente.
EOF
echo "docs de scripts ok"
