# setup-database.sh - Documentação

**Arquivo:** `scripts/setup-database.sh`  
**Tipo:** Shell script (bash)  
**Compatibilidade:** Linux, macOS, WSL2

---

## Objetivo

Inicializar completamente o banco de dados do WCIC a partir do zero: criar usuários e databases, aplicar todas as migrations em ordem e executar os seeds de dados de referência. Projetado para ser idempotente - pode ser executado múltiplas vezes sem efeitos colaterais.

---

## Pré-requisitos

| Requisito | Verificação |
|---|---|
| Docker em execução | `docker info` |
| Container `wcic-postgres` healthy | `docker ps \| grep wcic-postgres` |
| Arquivo `.env` preenchido | `cat .env \| grep POSTGRES_ROOT_PASSWORD` |
| `envsubst` instalado | `which envsubst` (instalar: `sudo apt-get install -y gettext-base`) |
| Diretório `database/migrations/` com os arquivos SQL | `ls database/migrations/` |
| Diretório `database/seeds/` com os arquivos SQL | `ls database/seeds/` |

---

## Variáveis Utilizadas

| Variável | Obrigatória | Uso |
|---|---|---|
| `POSTGRES_ROOT_PASSWORD` | ✅ | Senha do superuser `postgres` |
| `POSTGRES_N8N_PASSWORD` | ✅ | Senha do usuário `n8n_app` |
| `POSTGRES_WCIC_PASSWORD` | ✅ | Senha do usuário `wcic_app` |
| `POSTGRES_METABASE_PASSWORD` | ✅ | Senha do usuário `metabase_app` |
| `POSTGRES_GRAFANA_PASSWORD` | ✅ | Senha do usuário `grafana_app` |
| `REDIS_PASSWORD` | ✅ | Verificação de saúde do Redis |
| `N8N_BASIC_AUTH_USER` | ✅ | Exibido no resumo final |
| `N8N_BASIC_AUTH_PASSWORD` | ✅ | Validação de completude |
| `N8N_ENCRYPTION_KEY` | ✅ | Validação de completude |
| `WEBHOOK_URL` | ✅ | Exibido no resumo final |
| `API_JWT_SECRET` | ✅ | Validação de completude |
| `API_WEBHOOK_SECRET` | ✅ | Validação de completude |
| `GRAFANA_ADMIN_PASSWORD` | ✅ | Validação de completude |

---

## Fluxo de Execução

```
1. Verifica dependências (envsubst, docker)
2. Carrega .env via source
3. Valida 13 variáveis obrigatórias - falha imediatamente se ausente
4. Substitui placeholders em docker/postgres/init.sql via envsubst
   └─► Gera docker/postgres/init.generated.sql (com senhas reais)
   └─► Adiciona init.generated.sql ao .gitignore se ausente
5. Aguarda container wcic-postgres ficar healthy (até 60s)
6. Verifica se databases já existem (detecta reexecução)
7. Se não existem: aplica init.generated.sql (CREATE USER, CREATE DATABASE)
8. Aplica migrations em ordem (001, 002, 003, 004, 005, 006...)
   └─► Cada migration registrada em public.schema_migrations
   └─► Migration já aplicada → skip (idempotente)
9. Aplica seeds em ordem (001_teams, 002_venues)
   └─► Registrado como seed_{filename} em schema_migrations
10. Aplica GRANT de leitura para metabase_app no schema wcic
11. Exibe tabela de resumo com serviços, databases e usuários
```

---

## Opções de Linha de Comando

| Flag | Comportamento |
|---|---|
| (nenhuma) | Execução completa: init + migrations + seeds |
| `--skip-migrations` | Pula etapa de migrations |
| `--skip-seeds` | Pula etapa de seeds |

---

## Exemplo de Uso

```bash
# Execução completa (primeira vez)
./scripts/setup-database.sh

# Só aplicar novas migrations (sem seeds)
./scripts/setup-database.sh --skip-seeds

# Verificar o que seria feito sem executar
# (não existe --dry-run, mas pode inspecionar init.generated.sql após o script)
```

---

## Saída Esperada

```
[OK]   envsubst encontrado em /usr/bin/envsubst
[OK]   docker encontrado em /usr/bin/docker
[OK]   .env carregado de: /path/to/wcic/.env

>>> Validando variáveis obrigatórias

[OK]   POSTGRES_ROOT_PASSWORD carregado (abcd***)
[OK]   POSTGRES_N8N_PASSWORD carregado (ef01***)
...

>>> Gerando docker/postgres/init.generated.sql

[OK]   Gerado: /path/to/wcic/docker/postgres/init.generated.sql
[WARN] init.generated.sql contém senhas em texto plano.

>>> Verificando saúde do container postgres

[OK]   Container wcic-postgres está saudável

>>> Aplicando migrations (database: wcic)

[INFO] Aplicando: 001_initial_schema.sql
[OK]   Aplicada: 001_initial_schema.sql
[INFO] Aplicando: 002_indexes.sql
[OK]   Aplicada: 002_indexes.sql
...

>>> Setup concluído com sucesso

  Serviço     │ Database  │ Usuário
  ────────────┼───────────┼─────────────
  n8n         │ n8n       │ n8n_app
  ...
```

---

## Possíveis Erros

| Mensagem | Causa | Solução |
|---|---|---|
| `Variável obrigatória ausente: X` | Campo vazio no `.env` | Preencher a variável no `.env` |
| `Container postgres não ficou saudável em 60s` | Container não iniciado | `docker-compose up -d postgres` e aguardar |
| `ON_ERROR_STOP=1` causa saída | Erro de SQL na migration | Verificar o SQL; pode ser migration já parcialmente aplicada |
| `Placeholders não substituídos` | Variável com nome incorreto no `.env` | Verificar nome exato da variável |
| `envsubst não encontrado` | Pacote `gettext-base` não instalado | `sudo apt-get install -y gettext-base` |

---

## Troubleshooting

**Script falha na validação mas variável existe:**
```bash
# Verificar se há espaço ou caractere invisível
cat -A .env | grep POSTGRES_ROOT_PASSWORD
# Variável deve ser: POSTGRES_ROOT_PASSWORD=valor (sem espaços)
```

**Migration falhou no meio:**
```bash
# Verificar qual migration foi aplicada
docker exec wcic-postgres psql -U postgres -d wcic -c \
  "SELECT filename, applied_at FROM public.schema_migrations ORDER BY applied_at;"

# Remover entrada da migration problemática e corrigir o SQL
docker exec wcic-postgres psql -U postgres -d wcic -c \
  "DELETE FROM public.schema_migrations WHERE filename='00X_nome.sql';"
```

**Re-executar do zero (destrutivo):**
```bash
docker-compose down -v       # Remove todos os volumes
docker-compose up -d postgres
./scripts/setup-database.sh
```
EOF
echo "setup-database.md ok"
