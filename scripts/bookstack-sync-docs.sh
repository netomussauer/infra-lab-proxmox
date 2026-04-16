#!/usr/bin/env bash
# =============================================================================
# bookstack-sync-docs.sh
# Varre o projeto infra-lab-proxmox e publica cada arquivo como um Book
# dentro da Shelf correta (ADRs ou Procedimentos Técnicos) no BookStack.
# Cada Book contém exatamente uma Page com o conteúdo do arquivo.
# Detecta atualizações em re-runs via state file com SHA256.
#
# Uso: bookstack-sync-docs.sh [OPÇÕES]
#
# Opções:
#   -u, --url URL              URL base do BookStack (padrão: $BOOKSTACK_URL)
#       --token-id ID          Token ID da API (padrão: $BOOKSTACK_TOKEN_ID)
#       --token-secret SECRET  Token Secret da API (padrão: $BOOKSTACK_TOKEN_SECRET)
#   -k, --insecure             Ignorar TLS (padrão: true — lab usa cert self-signed)
#   -n, --dry-run              Não publicar — apenas mostrar o que seria feito
#   -v, --verbose              Detalhar chamadas HTTP
#   -f, --force                Forçar re-publicação mesmo sem alterações (ignora state)
#       --state-file PATH      Caminho do state file (padrão: scripts/.bookstack-sync-state.json)
#       --project-root PATH    Raiz do projeto (padrão: detectada automaticamente)
#   -h, --help                 Exibir este help
#
# Variáveis de ambiente:
#   BOOKSTACK_URL           URL base do BookStack
#   BOOKSTACK_TOKEN_ID      ID do token API
#   BOOKSTACK_TOKEN_SECRET  Secret do token API
#
# Exemplos:
#   export BOOKSTACK_TOKEN_ID="abc123"
#   export BOOKSTACK_TOKEN_SECRET="xyz789"
#   ./bookstack-sync-docs.sh --url https://10.10.0.6:8080
#
#   # Dry-run para ver o que seria publicado
#   ./bookstack-sync-docs.sh -n --url https://10.10.0.6:8080
#
#   # Forçar re-publicação de tudo
#   ./bookstack-sync-docs.sh --force --url https://10.10.0.6:8080
#
# Código de saída:
#   0 = sucesso (zero erros)
#   1 = um ou mais erros durante a sincronização
# =============================================================================
# chmod +x este arquivo antes de executar

set -euo pipefail

# =============================================================================
# CONSTANTES E DEFAULTS
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly BS_RESPONSE_TMP="/tmp/bs_response_$$.json"

# =============================================================================
# ESTADO GLOBAL (contadores)
# =============================================================================

COUNT_FILES=0
COUNT_NEW=0
COUNT_UPDATE=0
COUNT_SKIP=0
COUNT_ERRORS=0

# IDs resolvidos de estrutura BookStack (preenchidos por bs_ensure_structure)
declare -A SHELF_IDS=()
declare -A BOOK_IDS=()
declare -A CHAPTER_IDS=()

# State carregado em memória (JSON string)
STATE_JSON="{}"

# =============================================================================
# CONFIGURAÇÃO (preenchida por parse_args)
# =============================================================================

BOOKSTACK_URL="${BOOKSTACK_URL:-}"
BOOKSTACK_TOKEN_ID="${BOOKSTACK_TOKEN_ID:-}"
BOOKSTACK_TOKEN_SECRET="${BOOKSTACK_TOKEN_SECRET:-}"
INSECURE=true   # lab usa certificado SSL self-signed não válido
DRY_RUN=false
VERBOSE=false
FORCE=false
STATE_FILE=""
PROJECT_ROOT=""
CLEANUP_DUPLICATES=false

# Array global de argumentos curl — populado por _build_bs_base_args
declare -a BS_BASE_ARGS=()

# Variável global para último HTTP code retornado pelas funções bs_*
BS_LAST_HTTP_CODE=""

# =============================================================================
# FILE MAP — array associativo (chave: caminho relativo; valor: SHELF|BOOK_TITLE)
# Cada arquivo vira um Book dentro da Shelf indicada.
# Dentro do Book há exatamente uma Page com o mesmo título do Book.
# =============================================================================

declare -A FILE_MAP

FILE_MAP["README.md"]="Procedimentos Técnicos|Visão Geral do Projeto"
FILE_MAP[".claudecode.md"]="Procedimentos Técnicos|Instruções Globais do Projeto"
FILE_MAP["README.infraestructure.md"]="Procedimentos Técnicos|Referência de Infraestrutura Proxmox"
FILE_MAP["terraform-proxmox/main.tf"]="Procedimentos Técnicos|Provisionamento de VMs Kubernetes"
FILE_MAP["terraform-proxmox/variables.tf"]="Procedimentos Técnicos|Variáveis Terraform - Kubernetes"
FILE_MAP["terraform-proxmox/outputs.tf"]="Procedimentos Técnicos|Outputs Terraform - Kubernetes"
FILE_MAP["terraform-proxmox/netbox.tf"]="Procedimentos Técnicos|Integração NetBox - Kubernetes"
FILE_MAP["terraform-cicd/main.tf"]="Procedimentos Técnicos|Provisionamento VM CI/CD"
FILE_MAP["terraform-cicd/variables.tf"]="Procedimentos Técnicos|Variáveis Terraform - CI/CD"
FILE_MAP["terraform-cicd/outputs.tf"]="Procedimentos Técnicos|Outputs Terraform - CI/CD"
FILE_MAP["terraform-cicd/netbox.tf"]="Procedimentos Técnicos|Integração NetBox - CI/CD"
FILE_MAP["ansible-k8s/site.yml"]="Procedimentos Técnicos|Orquestração do Cluster Kubernetes"
FILE_MAP["ansible-k8s/group_vars/all.yml"]="Procedimentos Técnicos|Variáveis Globais - Kubernetes"
FILE_MAP["ansible-k8s/playbooks/01-prepare-nodes.yml"]="Procedimentos Técnicos|Preparação dos Nós"
FILE_MAP["ansible-k8s/playbooks/02-install-containerd.yml"]="Procedimentos Técnicos|Instalação do containerd"
FILE_MAP["ansible-k8s/playbooks/03-install-kubeadm.yml"]="Procedimentos Técnicos|Instalação do kubeadm"
FILE_MAP["ansible-k8s/playbooks/04-init-master.yml"]="Procedimentos Técnicos|Inicialização do Master"
FILE_MAP["ansible-k8s/playbooks/05-join-workers.yml"]="Procedimentos Técnicos|Ingresso dos Workers"
FILE_MAP["ansible-k8s/playbooks/06-register-netbox.yml"]="Procedimentos Técnicos|Registro K8s no NetBox"
FILE_MAP["ansible-k8s/inventory/generate_inventory.sh"]="Procedimentos Técnicos|Geração do Inventário Dinâmico"
FILE_MAP["ansible-cicd/site.yml"]="Procedimentos Técnicos|Orquestração da Stack CI/CD"
FILE_MAP["ansible-cicd/group_vars/all.yml"]="Procedimentos Técnicos|Variáveis Globais - CI/CD"
FILE_MAP["ansible-cicd/playbooks/01-prepare-node.yml"]="Procedimentos Técnicos|Preparação do Servidor CI/CD"
FILE_MAP["ansible-cicd/playbooks/02-install-docker.yml"]="Procedimentos Técnicos|Instalação do Docker"
FILE_MAP["ansible-cicd/playbooks/03-deploy-stack.yml"]="Procedimentos Técnicos|Deploy da Stack CI/CD"
FILE_MAP["ansible-cicd/playbooks/04-configure-runner.yml"]="Procedimentos Técnicos|Configuração do Act Runner"
FILE_MAP["ansible-cicd/playbooks/05-register-netbox.yml"]="Procedimentos Técnicos|Registro CI/CD no NetBox"
FILE_MAP["ansible-cicd/inventory/generate_inventory.sh"]="Procedimentos Técnicos|Geração do Inventário CI/CD"
FILE_MAP["scripts/netbox-sync-lab-ips.sh"]="Procedimentos Técnicos|Sincronização IPAM NetBox"
FILE_MAP["scripts/netbox-get-available-ips.sh"]="Procedimentos Técnicos|Consulta de IPs Disponíveis"
FILE_MAP["scripts/bookstack-sync-docs.sh"]="Procedimentos Técnicos|Sincronização de Documentação"

# =============================================================================
# UTILITÁRIOS DE LOG
# =============================================================================

# Detectar suporte a cores uma única vez
if [ -t 1 ]; then
  COLOR_RESET="\033[0m"
  COLOR_CYAN="\033[0;36m"
  COLOR_GREEN="\033[0;32m"
  COLOR_YELLOW="\033[0;33m"
  COLOR_GRAY="\033[0;90m"
  COLOR_RED="\033[0;31m"
  COLOR_MAGENTA="\033[0;35m"
  COLOR_BLUE="\033[0;34m"
else
  COLOR_RESET=""
  COLOR_CYAN=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_GRAY=""
  COLOR_RED=""
  COLOR_MAGENTA=""
  COLOR_BLUE=""
fi

log_info() {
  echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $*"
}

log_new() {
  echo -e "${COLOR_GREEN}[NEW]${COLOR_RESET}   $*"
}

log_update() {
  echo -e "${COLOR_YELLOW}[UPDATE]${COLOR_RESET} $*"
}

log_skip() {
  echo -e "${COLOR_GRAY}[SKIP]${COLOR_RESET}  $*"
}

log_warn() {
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*" >&2
}

log_error() {
  echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_dryrun() {
  echo -e "${COLOR_MAGENTA}[DRY-RUN]${COLOR_RESET} $*"
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${COLOR_GRAY}[VERBOSE]${COLOR_RESET} $*" >&2
  fi
}

# =============================================================================
# HELP
# =============================================================================

print_help() {
  cat <<EOF
Uso: ${SCRIPT_NAME} [OPÇÕES]

Varre o projeto infra-lab-proxmox, classifica arquivos como ADR ou
Procedimento Técnico e publica/atualiza pages no BookStack do laboratório.

Opções:
  -u, --url URL              URL base do BookStack (padrão: \$BOOKSTACK_URL)
      --token-id ID          Token ID da API (padrão: \$BOOKSTACK_TOKEN_ID)
      --token-secret SECRET  Token Secret da API (padrão: \$BOOKSTACK_TOKEN_SECRET)
  -k, --insecure             Ignorar TLS (padrão: true — lab usa cert self-signed)
  -n, --dry-run              Não publicar — apenas mostrar o que seria feito
  -v, --verbose              Detalhar chamadas HTTP
  -f, --force                Forçar re-publicação mesmo sem alterações (ignora state)
      --state-file PATH      Caminho do state file (padrão: scripts/.bookstack-sync-state.json)
      --project-root PATH    Raiz do projeto (padrão: detectada automaticamente)
      --cleanup-duplicates   Remove shelves duplicados ("ADRs", "Procedimentos Técnicos",
                             "infra-lab-proxmox") e books duplicados (títulos do FILE_MAP).
                             Mantém o objeto com id menor (o mais antigo). Requer
                             --url e credenciais configuradas. Combine com -n para
                             dry-run (apenas listar, sem deletar).
  -h, --help                 Exibir este help

Estrutura BookStack criada:
  Shelf: "ADRs"
    └── Book: "<título do ADR>"
          └── Page: "<título do ADR>"

  Shelf: "Procedimentos Técnicos"
    └── Book: "Visão Geral do Projeto"
          └── Page: "Visão Geral do Projeto"
    └── Book: "Provisionamento de VMs Kubernetes"
          └── Page: "Provisionamento de VMs Kubernetes"
    └── Book: "..." (um book por arquivo do FILE_MAP)
          └── Page: "..." (mesmo nome do book, conteúdo do arquivo)

Variáveis de ambiente:
  BOOKSTACK_URL           URL base do BookStack
  BOOKSTACK_TOKEN_ID      ID do token API
  BOOKSTACK_TOKEN_SECRET  Secret do token API

Exemplos:
  export BOOKSTACK_TOKEN_ID="abc123"
  export BOOKSTACK_TOKEN_SECRET="xyz789"
  ./${SCRIPT_NAME} --url https://10.10.0.6:8080

  # Dry-run para ver o que seria publicado
  ./${SCRIPT_NAME} -n --url https://10.10.0.6:8080

  # Forçar re-publicação de tudo
  ./${SCRIPT_NAME} --force --url https://10.10.0.6:8080

  # Listar duplicatas sem remover (dry-run)
  ./${SCRIPT_NAME} --cleanup-duplicates -n --url https://10.10.0.6:8080

  # Remover pages duplicadas e books duplicados
  ./${SCRIPT_NAME} --cleanup-duplicates --url https://10.10.0.6:8080
EOF
}

# =============================================================================
# RELATÓRIO FINAL
# =============================================================================

print_summary() {
  local mode_label="PUBLICADO"
  [[ "$DRY_RUN" == "true" ]] && mode_label="DRY-RUN"

  echo ""
  echo "+------------------------------------------------------+"
  echo "|      BookStack Sync -- Resumo da sincronizacao       |"
  echo "+------------------------------------------------------+"
  echo "|  Modo                  :  ${mode_label}"
  echo "|  Arquivos processados  :  ${COUNT_FILES}"
  echo "|  Pages novas (NEW)     :  ${COUNT_NEW}"
  echo "|  Pages atualizadas     :  ${COUNT_UPDATE}"
  echo "|  Pages sem alteracao   :  ${COUNT_SKIP}"
  echo "|  Erros                 :  ${COUNT_ERRORS}"
  echo "+------------------------------------------------------+"
}

# =============================================================================
# PARSE DE ARGUMENTOS
# =============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--url)
        BOOKSTACK_URL="${2:?'--url requer um valor'}"
        shift 2
        ;;
      --token-id)
        BOOKSTACK_TOKEN_ID="${2:?'--token-id requer um valor'}"
        shift 2
        ;;
      --token-secret)
        BOOKSTACK_TOKEN_SECRET="${2:?'--token-secret requer um valor'}"
        shift 2
        ;;
      -k|--insecure)
        INSECURE=true
        shift
        ;;
      -n|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -f|--force)
        FORCE=true
        shift
        ;;
      --state-file)
        STATE_FILE="${2:?'--state-file requer um valor'}"
        shift 2
        ;;
      --project-root)
        PROJECT_ROOT="${2:?'--project-root requer um valor'}"
        shift 2
        ;;
      --cleanup-duplicates)
        CLEANUP_DUPLICATES=true
        shift
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      -*)
        log_error "Opção desconhecida: $1"
        print_help
        exit 1
        ;;
      *)
        log_error "Argumento posicional inesperado: $1"
        print_help
        exit 1
        ;;
    esac
  done
}

# =============================================================================
# VERIFICAÇÃO DE DEPENDÊNCIAS
# =============================================================================

check_deps() {
  local missing=()

  for dep in curl jq sha256sum; do
    if ! command -v "$dep" &>/dev/null; then
      missing+=("$dep")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Dependências obrigatórias ausentes: ${missing[*]}"
    log_error "Instale com: apt-get install ${missing[*]}  (ou equivalente do seu sistema)"
    exit 1
  fi

  if command -v pandoc &>/dev/null; then
    log_verbose "pandoc encontrado (opcional) — disponível para conversões futuras"
  else
    log_verbose "pandoc não encontrado (opcional) — não é necessário para esta versão"
  fi
}

# =============================================================================
# WRAPPERS DA API BOOKSTACK — DELETE
# =============================================================================

# bs_delete URL
# Executa DELETE. Retorna HTTP code em BS_LAST_HTTP_CODE.
# Retorna 1 se curl falhar ou se o HTTP code não for 2xx/204.
bs_delete() {
  local url="$1"

  log_verbose "DELETE ${url}"

  BS_LAST_HTTP_CODE=$(curl "${BS_BASE_ARGS[@]}" \
    -o "${BS_RESPONSE_TMP}" \
    -w "%{http_code}" \
    -X DELETE \
    "${url}" 2>/dev/null) || {
    log_error "curl falhou ao executar DELETE ${url}"
    BS_LAST_HTTP_CODE="000"
    echo "{}" > "${BS_RESPONSE_TMP}"
    return 1
  }

  log_verbose "HTTP ${BS_LAST_HTTP_CODE} <- DELETE ${url}"

  # Validar código HTTP
  if [[ "${BS_LAST_HTTP_CODE}" != 2* ]]; then
    log_error "DELETE ${url} retornou HTTP ${BS_LAST_HTTP_CODE} (esperado 2xx/204)"
    log_error "Body bruto: $(head -c 500 "${BS_RESPONSE_TMP}" 2>/dev/null || true)"
    return 1
  fi

  return 0
}

# =============================================================================
# WRAPPERS DA API BOOKSTACK

# Popula o array global BS_BASE_ARGS com as opções comuns a todas as chamadas.
# Usar array global evita o padrão printf+mapfile que fragmenta headers no Bash.
_build_bs_base_args() {
  BS_BASE_ARGS=(
    -s
    -H "Authorization: Token ${BOOKSTACK_TOKEN_ID}:${BOOKSTACK_TOKEN_SECRET}"
    -H "Content-Type: application/json"
    -H "Accept: application/json"
  )
  [[ "$INSECURE" == "true" ]] && BS_BASE_ARGS+=(-k)
}

# bs_get URL
# Executa GET. Retorna body em stdout se HTTP 2xx; HTTP code em BS_LAST_HTTP_CODE.
# Se o HTTP code não for 2xx, imprime o body bruto como erro e retorna 1 sem
# emitir o body para stdout, evitando que jq receba HTML ou mensagens de erro.
bs_get() {
  local url="$1"

  log_verbose "GET ${url}"

  BS_LAST_HTTP_CODE=$(curl "${BS_BASE_ARGS[@]}" \
    -o "${BS_RESPONSE_TMP}" \
    -w "%{http_code}" \
    "${url}" 2>/dev/null) || {
    log_error "curl falhou ao executar GET ${url}"
    BS_LAST_HTTP_CODE="000"
    echo "{}" > "${BS_RESPONSE_TMP}"
    return 1
  }

  log_verbose "HTTP ${BS_LAST_HTTP_CODE} <- GET ${url}"

  # Validar código HTTP antes de retornar o body
  if [[ "${BS_LAST_HTTP_CODE}" != 2* ]]; then
    log_error "GET ${url} retornou HTTP ${BS_LAST_HTTP_CODE} (esperado 2xx)"
    log_error "Body bruto: $(head -c 500 "${BS_RESPONSE_TMP}" 2>/dev/null || true)"
    echo "{}" > "${BS_RESPONSE_TMP}"
    return 1
  fi

  if [[ "$VERBOSE" == "true" ]]; then
    local preview
    preview=$(jq -c '.' "${BS_RESPONSE_TMP}" 2>/dev/null | head -c 300 || true)
    log_verbose "Body (300 chars): ${preview}"
  fi

  cat "${BS_RESPONSE_TMP}"
}

# bs_post URL BODY_JSON
# Executa POST. Retorna body em stdout; HTTP code em BS_LAST_HTTP_CODE.
bs_post() {
  local url="$1"
  local body="$2"

  log_verbose "POST ${url}"

  BS_LAST_HTTP_CODE=$(curl "${BS_BASE_ARGS[@]}" \
    -o "${BS_RESPONSE_TMP}" \
    -w "%{http_code}" \
    -X POST \
    -d "${body}" \
    "${url}" 2>/dev/null) || {
    log_error "curl falhou ao executar POST ${url}"
    BS_LAST_HTTP_CODE="000"
    echo "{}" > "${BS_RESPONSE_TMP}"
  }

  log_verbose "HTTP ${BS_LAST_HTTP_CODE} <- POST ${url}"
  if [[ "$VERBOSE" == "true" ]]; then
    local preview
    preview=$(jq -c '.' "${BS_RESPONSE_TMP}" 2>/dev/null | head -c 300 || true)
    log_verbose "Body (300 chars): ${preview}"
  fi

  cat "${BS_RESPONSE_TMP}"
}

# bs_put URL BODY_JSON
# Executa PUT. Retorna body em stdout; HTTP code em BS_LAST_HTTP_CODE.
bs_put() {
  local url="$1"
  local body="$2"

  log_verbose "PUT ${url}"

  BS_LAST_HTTP_CODE=$(curl "${BS_BASE_ARGS[@]}" \
    -o "${BS_RESPONSE_TMP}" \
    -w "%{http_code}" \
    -X PUT \
    -d "${body}" \
    "${url}" 2>/dev/null) || {
    log_error "curl falhou ao executar PUT ${url}"
    BS_LAST_HTTP_CODE="000"
    echo "{}" > "${BS_RESPONSE_TMP}"
  }

  log_verbose "HTTP ${BS_LAST_HTTP_CODE} <- PUT ${url}"
  if [[ "$VERBOSE" == "true" ]]; then
    local preview
    preview=$(jq -c '.' "${BS_RESPONSE_TMP}" 2>/dev/null | head -c 300 || true)
    log_verbose "Body (300 chars): ${preview}"
  fi

  cat "${BS_RESPONSE_TMP}"
}

# =============================================================================
# OPERAÇÕES BOOKSTACK — ESTRUTURA (Shelf / Book / Chapter)
# =============================================================================

# bs_find_shelf NAME
# Retorna o ID do shelf ou "" se não encontrar.
bs_find_shelf() {
  local name="$1"
  local api_base="${BOOKSTACK_URL%/}/api"

  local http_code_tmp
  http_code_tmp="/tmp/bs_http_code_$$.tmp"

  curl "${BS_BASE_ARGS[@]}" \
    --get \
    --data-urlencode "filter[name]=${name}" \
    --data-urlencode "count=1" \
    -w "%{http_code}" \
    -o "${BS_RESPONSE_TMP}" \
    "${api_base}/shelves" \
    > "${http_code_tmp}" 2>/dev/null || true
  BS_LAST_HTTP_CODE=$(cat "${http_code_tmp}" 2>/dev/null || echo "000")
  rm -f "${http_code_tmp}"

  log_verbose "GET ${api_base}/shelves?filter[name]=${name}&count=1 → HTTP ${BS_LAST_HTTP_CODE}"

  local response
  response=$(cat "${BS_RESPONSE_TMP}" 2>/dev/null || echo "{}")

  if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
    log_warn "Falha ao buscar shelf '${name}' — HTTP ${BS_LAST_HTTP_CODE}"
    echo ""
    return 0
  fi

  local found_id
  found_id=$(echo "$response" | jq -r \
    --arg n "$name" '.data[] | select(.name == $n) | .id' 2>/dev/null | head -1 || true)

  echo "${found_id:-}"
}

# bs_ensure_shelf NAME DESCRIPTION
# Garante que o shelf existe. Retorna o ID em stdout.
bs_ensure_shelf() {
  local name="$1"
  local description="${2:-}"
  local api_base="${BOOKSTACK_URL%/}/api"

  # Verificar cache
  if [[ -n "${SHELF_IDS[$name]+_}" ]] && [[ -n "${SHELF_IDS[$name]}" ]]; then
    echo "${SHELF_IDS[$name]}"
    return 0
  fi

  local existing_id
  existing_id=$(bs_find_shelf "$name")

  if [[ -n "$existing_id" ]]; then
    log_skip "Shelf '${name}' já existe (id=${existing_id})"
    SHELF_IDS["$name"]="$existing_id"
    echo "$existing_id"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dryrun "Criaria shelf '${name}'"
    SHELF_IDS["$name"]="0"
    echo "0"
    return 0
  fi

  local body
  body=$(jq -n --arg name "$name" --arg desc "$description" \
    '{ name: $name, description: $desc }')

  local response
  response=$(bs_post "${api_base}/shelves" "$body")

  if [[ "$BS_LAST_HTTP_CODE" == "200" ]] || [[ "$BS_LAST_HTTP_CODE" == "201" ]]; then
    local new_id
    new_id=$(echo "$response" | jq -r '.id // ""')
    log_new "Shelf '${name}' criada (id=${new_id})"
    SHELF_IDS["$name"]="$new_id"
    echo "$new_id"
    return 0
  fi

  # Qualquer código diferente de 200/201 (409, 422, 500, ...): tentar encontrar
  # novamente antes de declarar erro — cobre falsos negativos do bs_find_shelf
  # e respostas de conflito com corpo não padronizado (422 em vez de 409).
  log_warn "POST shelf '${name}' retornou HTTP ${BS_LAST_HTTP_CODE} — verificando se já existe"
  existing_id=$(bs_find_shelf "$name")
  if [[ -n "$existing_id" ]]; then
    log_skip "Shelf '${name}' já existe (id=${existing_id}) — usando existente"
    SHELF_IDS["$name"]="$existing_id"
    echo "$existing_id"
    return 0
  fi

  log_error "Falha ao criar/encontrar shelf '${name}' — HTTP ${BS_LAST_HTTP_CODE}"
  echo ""
  return 1
}

# bs_find_book NAME
# Retorna o ID do book ou "" se não encontrar.
bs_find_book() {
  local name="$1"
  local api_base="${BOOKSTACK_URL%/}/api"

  local http_code_tmp
  http_code_tmp="/tmp/bs_http_code_$$.tmp"

  curl "${BS_BASE_ARGS[@]}" \
    --get \
    --data-urlencode "filter[name]=${name}" \
    --data-urlencode "count=1" \
    -w "%{http_code}" \
    -o "${BS_RESPONSE_TMP}" \
    "${api_base}/books" \
    > "${http_code_tmp}" 2>/dev/null || true
  BS_LAST_HTTP_CODE=$(cat "${http_code_tmp}" 2>/dev/null || echo "000")
  rm -f "${http_code_tmp}"

  log_verbose "GET ${api_base}/books?filter[name]=${name}&count=1 → HTTP ${BS_LAST_HTTP_CODE}"

  local response
  response=$(cat "${BS_RESPONSE_TMP}" 2>/dev/null || echo "{}")

  if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
    log_warn "Falha ao buscar book '${name}' — HTTP ${BS_LAST_HTTP_CODE}"
    echo ""
    return 0
  fi

  local found_id
  found_id=$(echo "$response" | jq -r \
    --arg n "$name" '.data[] | select(.name == $n) | .id' 2>/dev/null | head -1 || true)

  echo "${found_id:-}"
}

# bs_ensure_book NAME SHELF_ID DESCRIPTION
# Garante que o book existe e está associado ao shelf. Retorna o ID em stdout.
bs_ensure_book() {
  local name="$1"
  local shelf_id="$2"
  local description="${3:-}"
  local api_base="${BOOKSTACK_URL%/}/api"

  # Verificar cache
  if [[ -n "${BOOK_IDS[$name]+_}" ]] && [[ -n "${BOOK_IDS[$name]}" ]]; then
    echo "${BOOK_IDS[$name]}"
    return 0
  fi

  local existing_id
  existing_id=$(bs_find_book "$name")

  if [[ -n "$existing_id" ]]; then
    log_skip "Book '${name}' já existe (id=${existing_id})"
    BOOK_IDS["$name"]="$existing_id"
    # Associar ao shelf mesmo que o book já exista (idempotente)
    # Faz GET do shelf antes de PUT para preservar os books já associados.
    # Se o GET falhar, pula a associação — evita substituir books por array vazio.
    if [[ "$DRY_RUN" == "false" ]] && [[ "$shelf_id" != "0" ]]; then
      local book_id_to_add="$existing_id"
      local shelf_response
      shelf_response=$(bs_get "${api_base}/shelves/${shelf_id}" || true)
      if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
        log_warn "Não foi possível verificar books do shelf id=${shelf_id} (HTTP ${BS_LAST_HTTP_CODE}) — pulando associação"
      else
        local current_books_ids
        current_books_ids=$(echo "$shelf_response" | jq -r '[(.books // [])[] | .id]' 2>/dev/null || echo "[]")
        local already_linked
        already_linked=$(echo "$current_books_ids" | jq --arg bid "$book_id_to_add" 'map(tostring) | index($bid)' 2>/dev/null)
        if [[ "$already_linked" == "null" ]]; then
          local merged_books
          merged_books=$(echo "$current_books_ids" | jq --arg bid "$book_id_to_add" '. + [($bid | tonumber)]')
          local shelf_name_val
          shelf_name_val=$(echo "$shelf_response" | jq -r '.name // ""')
          local shelf_body
          shelf_body=$(jq -n \
            --arg name "$shelf_name_val" \
            --argjson books "$merged_books" \
            '{ name: $name, books: $books }')
          bs_put "${api_base}/shelves/${shelf_id}" "$shelf_body" > /dev/null || true
          log_info "Book '${name}' vinculado ao shelf '${shelf_name_val}' (id=${shelf_id})"
        else
          log_skip "Book '${name}' já está vinculado ao shelf id=${shelf_id} — nenhuma ação"
        fi
      fi
    fi
    echo "$existing_id"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dryrun "Criaria book '${name}' no shelf id=${shelf_id}"
    BOOK_IDS["$name"]="0"
    echo "0"
    return 0
  fi

  local body
  body=$(jq -n --arg name "$name" --arg desc "$description" \
    '{ name: $name, description: $desc }')

  local response
  response=$(bs_post "${api_base}/books" "$body")

  if [[ "$BS_LAST_HTTP_CODE" == "200" ]] || [[ "$BS_LAST_HTTP_CODE" == "201" ]]; then
    local new_id
    new_id=$(echo "$response" | jq -r '.id // ""')
    log_new "Book '${name}' criado (id=${new_id})"
    BOOK_IDS["$name"]="$new_id"

    # Associar ao shelf preservando os books já associados.
    # Se o GET falhar, pula a associação — evita substituir books por array vazio.
    if [[ "$shelf_id" != "0" ]]; then
      local book_id_to_add="$new_id"
      local shelf_response
      shelf_response=$(bs_get "${api_base}/shelves/${shelf_id}" || true)
      if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
        log_warn "Não foi possível verificar books do shelf id=${shelf_id} (HTTP ${BS_LAST_HTTP_CODE}) — pulando associação"
      else
        local current_books_ids
        current_books_ids=$(echo "$shelf_response" | jq -r '[(.books // [])[] | .id]' 2>/dev/null || echo "[]")
        local already_linked
        already_linked=$(echo "$current_books_ids" | jq --arg bid "$book_id_to_add" 'map(tostring) | index($bid)' 2>/dev/null)
        if [[ "$already_linked" == "null" ]]; then
          local merged_books
          merged_books=$(echo "$current_books_ids" | jq --arg bid "$book_id_to_add" '. + [($bid | tonumber)]')
          local shelf_name_val
          shelf_name_val=$(echo "$shelf_response" | jq -r '.name // ""')
          local shelf_body
          shelf_body=$(jq -n \
            --arg name "$shelf_name_val" \
            --argjson books "$merged_books" \
            '{ name: $name, books: $books }')
          bs_put "${api_base}/shelves/${shelf_id}" "$shelf_body" > /dev/null || true
          log_info "Book '${name}' vinculado ao shelf '${shelf_name_val}' (id=${shelf_id})"
        else
          log_skip "Book '${name}' já está vinculado ao shelf id=${shelf_id} — nenhuma ação"
        fi
      fi
    fi

    echo "$new_id"
    return 0
  fi

  if [[ "$BS_LAST_HTTP_CODE" == "409" ]] || \
     grep -qi "already exists\|unique\|duplicate" "${BS_RESPONSE_TMP}" 2>/dev/null; then
    log_skip "Book '${name}' já existe (conflict) — buscando novamente"
    existing_id=$(bs_find_book "$name")
    BOOK_IDS["$name"]="${existing_id:-0}"
    echo "${existing_id:-0}"
    return 0
  fi

  log_error "Falha ao criar book '${name}' — HTTP ${BS_LAST_HTTP_CODE}"
  echo ""
  return 1
}

# bs_find_chapter NAME BOOK_ID
# Retorna o ID do chapter ou "" se não encontrar.
bs_find_chapter() {
  local name="$1"
  local book_id="$2"
  local api_base="${BOOKSTACK_URL%/}/api"

  local http_code_tmp
  http_code_tmp="/tmp/bs_http_code_$$.tmp"

  curl "${BS_BASE_ARGS[@]}" \
    --get \
    --data-urlencode "filter[name]=${name}" \
    --data-urlencode "filter[book_id]=${book_id}" \
    --data-urlencode "count=10" \
    -w "%{http_code}" \
    -o "${BS_RESPONSE_TMP}" \
    "${api_base}/chapters" \
    > "${http_code_tmp}" 2>/dev/null || true
  BS_LAST_HTTP_CODE=$(cat "${http_code_tmp}" 2>/dev/null || echo "000")
  rm -f "${http_code_tmp}"

  log_verbose "GET ${api_base}/chapters?filter[name]=${name}&filter[book_id]=${book_id}&count=10 → HTTP ${BS_LAST_HTTP_CODE}"

  local response
  response=$(cat "${BS_RESPONSE_TMP}" 2>/dev/null || echo "{}")

  if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
    log_warn "Falha ao buscar chapter '${name}' (book_id=${book_id}) — HTTP ${BS_LAST_HTTP_CODE}"
    echo ""
    return 0
  fi

  local found_id
  found_id=$(echo "$response" | jq -r \
    --arg n "$name" --arg bid "$book_id" \
    '.data[] | select(.name == $n and (.book_id | tostring) == $bid) | .id' 2>/dev/null | head -1 || true)

  echo "${found_id:-}"
}

# bs_ensure_chapter NAME BOOK_ID DESCRIPTION
# Garante que o chapter existe no book. Retorna o ID em stdout.
bs_ensure_chapter() {
  local name="$1"
  local book_id="$2"
  local description="${3:-}"
  local api_base="${BOOKSTACK_URL%/}/api"

  local cache_key="${book_id}::${name}"

  # Verificar cache
  if [[ -n "${CHAPTER_IDS[$cache_key]+_}" ]] && [[ -n "${CHAPTER_IDS[$cache_key]}" ]]; then
    echo "${CHAPTER_IDS[$cache_key]}"
    return 0
  fi

  local existing_id
  existing_id=$(bs_find_chapter "$name" "$book_id")

  if [[ -n "$existing_id" ]]; then
    log_skip "Chapter '${name}' já existe no book id=${book_id} (id=${existing_id})"
    CHAPTER_IDS["$cache_key"]="$existing_id"
    echo "$existing_id"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dryrun "Criaria chapter '${name}' no book id=${book_id}"
    CHAPTER_IDS["$cache_key"]="0"
    echo "0"
    return 0
  fi

  local body
  body=$(jq -n --arg name "$name" --arg desc "$description" --arg bid "$book_id" \
    '{ book_id: ($bid | tonumber), name: $name, description: $desc }')

  local response
  response=$(bs_post "${api_base}/chapters" "$body")

  if [[ "$BS_LAST_HTTP_CODE" == "200" ]] || [[ "$BS_LAST_HTTP_CODE" == "201" ]]; then
    local new_id
    new_id=$(echo "$response" | jq -r '.id // ""')
    log_new "Chapter '${name}' criado no book id=${book_id} (id=${new_id})"
    CHAPTER_IDS["$cache_key"]="$new_id"
    echo "$new_id"
    return 0
  fi

  if [[ "$BS_LAST_HTTP_CODE" == "409" ]] || \
     grep -qi "already exists\|unique\|duplicate" "${BS_RESPONSE_TMP}" 2>/dev/null; then
    log_skip "Chapter '${name}' já existe (conflict) — buscando novamente"
    existing_id=$(bs_find_chapter "$name" "$book_id")
    CHAPTER_IDS["$cache_key"]="${existing_id:-0}"
    echo "${existing_id:-0}"
    return 0
  fi

  log_error "Falha ao criar chapter '${name}' — HTTP ${BS_LAST_HTTP_CODE}"
  echo ""
  return 1
}

# bs_find_page NAME CHAPTER_ID
# Retorna o ID da page ou "" se não encontrar.
bs_find_page() {
  local name="$1"
  local chapter_id="$2"
  local api_base="${BOOKSTACK_URL%/}/api"

  local http_code_tmp
  http_code_tmp="/tmp/bs_http_code_$$.tmp"

  curl "${BS_BASE_ARGS[@]}" \
    --get \
    --data-urlencode "filter[name]=${name}" \
    --data-urlencode "filter[chapter_id]=${chapter_id}" \
    --data-urlencode "count=10" \
    -w "%{http_code}" \
    -o "${BS_RESPONSE_TMP}" \
    "${api_base}/pages" \
    > "${http_code_tmp}" 2>/dev/null || true
  BS_LAST_HTTP_CODE=$(cat "${http_code_tmp}" 2>/dev/null || echo "000")
  rm -f "${http_code_tmp}"

  log_verbose "GET ${api_base}/pages?filter[name]=${name}&filter[chapter_id]=${chapter_id}&count=10 → HTTP ${BS_LAST_HTTP_CODE}"

  local response
  response=$(cat "${BS_RESPONSE_TMP}" 2>/dev/null || echo "{}")

  if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
    log_warn "Falha ao buscar page '${name}' (chapter_id=${chapter_id}) — HTTP ${BS_LAST_HTTP_CODE}"
    echo ""
    return 0
  fi

  local found_id
  found_id=$(echo "$response" | jq -r \
    --arg n "$name" --arg cid "$chapter_id" \
    '.data[] | select(.name == $n and (.chapter_id | tostring) == $cid) | .id' 2>/dev/null | head -1 || true)

  echo "${found_id:-}"
}

# bs_find_page_in_book NAME BOOK_ID
# Retorna o ID da page dentro do book (sem chapter) ou "" se não encontrar.
bs_find_page_in_book() {
  local name="$1"
  local book_id="$2"
  local api_base="${BOOKSTACK_URL%/}/api"

  local http_code_tmp
  http_code_tmp="/tmp/bs_http_code_$$.tmp"

  curl "${BS_BASE_ARGS[@]}" \
    --get \
    --data-urlencode "filter[name]=${name}" \
    --data-urlencode "filter[book_id]=${book_id}" \
    --data-urlencode "count=10" \
    -w "%{http_code}" \
    -o "${BS_RESPONSE_TMP}" \
    "${api_base}/pages" \
    > "${http_code_tmp}" 2>/dev/null || true
  BS_LAST_HTTP_CODE=$(cat "${http_code_tmp}" 2>/dev/null || echo "000")
  rm -f "${http_code_tmp}"

  log_verbose "GET ${api_base}/pages?filter[name]=${name}&filter[book_id]=${book_id}&count=10 → HTTP ${BS_LAST_HTTP_CODE}"

  local response
  response=$(cat "${BS_RESPONSE_TMP}" 2>/dev/null || echo "{}")

  if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
    log_warn "Falha ao buscar page '${name}' (book_id=${book_id}) — HTTP ${BS_LAST_HTTP_CODE}"
    echo ""
    return 0
  fi

  local found_id
  found_id=$(echo "$response" | jq -r \
    --arg n "$name" --arg bid "$book_id" \
    '.data[] | select(.name == $n and (.book_id | tostring) == $bid) | .id' 2>/dev/null | head -1 || true)

  echo "${found_id:-}"
}

# bs_create_page BOOK_ID CHAPTER_ID NAME MARKDOWN_CONTENT
# Cria nova page. Se CHAPTER_ID for "" ou "0", cria a page diretamente no book
# (sem chapter). Retorna o ID em stdout.
bs_create_page() {
  local book_id="$1"
  local chapter_id="$2"
  local name="$3"
  local markdown_content="$4"
  local api_base="${BOOKSTACK_URL%/}/api"

  local body
  if [[ -n "$chapter_id" ]] && [[ "$chapter_id" != "0" ]]; then
    body=$(jq -n \
      --arg bid "$book_id" \
      --arg cid "$chapter_id" \
      --arg name "$name" \
      --arg md "$markdown_content" \
      '{ book_id: ($bid | tonumber), chapter_id: ($cid | tonumber), name: $name, markdown: $md, html: ("<pre>" + $md + "</pre>") }')
  else
    body=$(jq -n \
      --arg bid "$book_id" \
      --arg name "$name" \
      --arg md "$markdown_content" \
      '{ book_id: ($bid | tonumber), name: $name, markdown: $md, html: ("<pre>" + $md + "</pre>") }')
  fi

  local response
  response=$(bs_post "${api_base}/pages" "$body")

  if [[ "$BS_LAST_HTTP_CODE" == "200" ]] || [[ "$BS_LAST_HTTP_CODE" == "201" ]]; then
    local new_id
    new_id=$(echo "$response" | jq -r '.id // ""')
    echo "$new_id"
    return 0
  fi

  if [[ "$BS_LAST_HTTP_CODE" == "409" ]] || \
     grep -qi "already exists\|unique\|duplicate" "${BS_RESPONSE_TMP}" 2>/dev/null; then
    log_skip "Page '${name}' já existe (conflict 409) — tratando como skip"
    # Buscar ID existente: sem chapter, buscar por book_id
    local existing_id
    if [[ -n "$chapter_id" ]] && [[ "$chapter_id" != "0" ]]; then
      existing_id=$(bs_find_page "$name" "$chapter_id")
    else
      existing_id=$(bs_find_page_in_book "$name" "$book_id")
    fi
    echo "${existing_id:-0}"
    return 0
  fi

  log_error "Falha ao criar page '${name}' — HTTP ${BS_LAST_HTTP_CODE}"
  log_verbose "Body: $(cat "${BS_RESPONSE_TMP}" 2>/dev/null || true)"
  echo ""
  return 1
}

# bs_update_page PAGE_ID NAME MARKDOWN_CONTENT
# Atualiza page existente via PUT. Retorna 0 em sucesso.
bs_update_page() {
  local page_id="$1"
  local name="$2"
  local markdown_content="$3"
  local api_base="${BOOKSTACK_URL%/}/api"

  local body
  body=$(jq -n \
    --arg name "$name" \
    --arg md "$markdown_content" \
    '{ name: $name, markdown: $md, html: ("<pre>" + $md + "</pre>") }')

  bs_put "${api_base}/pages/${page_id}" "$body" > /dev/null

  if [[ "$BS_LAST_HTTP_CODE" == "200" ]]; then
    return 0
  fi

  log_error "Falha ao atualizar page id=${page_id} '${name}' — HTTP ${BS_LAST_HTTP_CODE}"
  log_verbose "Body: $(cat "${BS_RESPONSE_TMP}" 2>/dev/null || true)"
  return 1
}

# =============================================================================
# CRIAÇÃO DA ESTRUTURA COMPLETA
# =============================================================================

# bs_ensure_structure
# Garante que as duas shelves principais existam.
# Books individuais são criados dinamicamente em sync_file().
bs_ensure_structure() {
  log_info "Verificando/criando shelves principais..."
  echo ""

  local shelf_id

  shelf_id=$(bs_ensure_shelf "Procedimentos Técnicos" \
    "Procedimentos técnicos do laboratório infra-lab-proxmox")
  if [[ -z "$shelf_id" ]]; then
    log_error "Não foi possível garantir shelf 'Procedimentos Técnicos' — abortando"
    exit 1
  fi

  shelf_id=$(bs_ensure_shelf "ADRs" \
    "Architecture Decision Records do laboratório infra-lab-proxmox")
  if [[ -z "$shelf_id" ]]; then
    log_error "Não foi possível garantir shelf 'ADRs' — abortando"
    exit 1
  fi

  echo ""
  log_info "Shelves verificadas/criadas com sucesso"
}

# =============================================================================
# STATE FILE
# =============================================================================

# load_state
# Lê o state file para STATE_JSON. Cria vazio se não existir.
load_state() {
  local state_file="$STATE_FILE"

  if [[ ! -f "$state_file" ]]; then
    log_info "State file não encontrado — iniciando sincronização completa"
    STATE_JSON='{"version":"1.0","last_sync":"","files":{}}'
    return 0
  fi

  if ! STATE_JSON=$(jq '.' "$state_file" 2>/dev/null); then
    log_warn "State file corrompido — reiniciando state"
    STATE_JSON='{"version":"1.0","last_sync":"","files":{}}'
    return 0
  fi

  local last_sync
  last_sync=$(echo "$STATE_JSON" | jq -r '.last_sync // ""')
  log_info "State carregado — última sincronização: ${last_sync:-'nunca'}"
}

# save_state
# Sobrescreve o state file com STATE_JSON atual.
save_state() {
  local state_file="$STATE_FILE"
  local state_dir
  state_dir=$(dirname "$state_file")

  if [[ ! -d "$state_dir" ]]; then
    mkdir -p "$state_dir"
  fi

  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')

  STATE_JSON=$(echo "$STATE_JSON" | jq --arg ts "$now" '.last_sync = $ts')

  if [[ "$DRY_RUN" == "false" ]]; then
    echo "$STATE_JSON" > "$state_file"
    chmod 600 "$state_file"
    log_verbose "State file salvo: ${state_file}"
  else
    log_dryrun "Não salvaria state file (dry-run ativo)"
  fi
}

# get_file_hash FILE_PATH
# Retorna o SHA256 hex do arquivo (apenas o hash, sem nome de arquivo).
get_file_hash() {
  local file_path="$1"
  sha256sum "$file_path" 2>/dev/null | awk '{print $1}' || echo ""
}

# state_get_page_id RELATIVE_PATH
# Extrai .files[path].page_id do STATE_JSON. Retorna "" se não existir.
state_get_page_id() {
  local rel_path="$1"
  echo "$STATE_JSON" | jq -r --arg p "$rel_path" '.files[$p].page_id // ""'
}

# state_get_hash RELATIVE_PATH
# Extrai .files[path].hash do STATE_JSON. Retorna "" se não existir.
state_get_hash() {
  local rel_path="$1"
  echo "$STATE_JSON" | jq -r --arg p "$rel_path" '.files[$p].hash // ""'
}

# state_update RELATIVE_PATH HASH PAGE_ID BOOK_ID PAGE_NAME [CHAPTER_ID]
# Atualiza a entrada de um arquivo no STATE_JSON (em memória).
# CHAPTER_ID é opcional; quando omitido ou vazio, grava "" para compatibilidade
# com entradas legadas.
state_update() {
  local rel_path="$1"
  local hash="$2"
  local page_id="$3"
  local book_id="$4"
  local page_name="$5"
  local chapter_id="${6:-}"

  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')

  STATE_JSON=$(echo "$STATE_JSON" | jq \
    --arg p "$rel_path" \
    --arg h "$hash" \
    --arg pid "$page_id" \
    --arg bid "$book_id" \
    --arg cid "$chapter_id" \
    --arg pname "$page_name" \
    --arg ts "$now" \
    '.files[$p] = {
      hash: $h,
      page_id: ($pid | tonumber),
      book_id: ($bid | tonumber),
      chapter_id: $cid,
      page_name: $pname,
      last_updated: $ts
    }')
}

# =============================================================================
# DETECÇÃO DE ADR
# =============================================================================

# detect_adr FILE_PATH
# Retorna 0 se o arquivo deve ser tratado como ADR, 1 caso contrário.
detect_adr() {
  local file_path="$1"
  local rel_path="$2"

  # Verificar diretório
  if echo "$rel_path" | grep -qE '(^|/)adr/|(^|/)decisions/'; then
    return 0
  fi

  # Verificar conteúdo (apenas para arquivos Markdown)
  local ext="${file_path##*.}"
  if [[ "$ext" == "md" ]] || [[ "$ext" == "MD" ]]; then
    if grep -qE '## Decisão|## Contexto|## Consequências|^# ADR-|^Status: Accepted' \
        "$file_path" 2>/dev/null; then
      return 0
    fi
  fi

  return 1
}

# =============================================================================
# CONVERSÃO DE ARQUIVO PARA CONTEÚDO DE PAGE
# =============================================================================

# file_to_page_content FILE_PATH TITLE REL_PATH
# Converte o arquivo para conteúdo Markdown adequado ao BookStack.
# Imprime o conteúdo em stdout.
file_to_page_content() {
  local file_path="$1"
  local title="$2"
  local rel_path="$3"

  local ext="${file_path##*.}"
  # Tratar arquivos sem extensão ou com nome iniciado em ponto
  local basename_file
  basename_file=$(basename "$file_path")
  if [[ "$basename_file" == .* ]] && [[ "$ext" == "$basename_file" ]]; then
    # Ex: .claudecode.md — ext será claudecode.md; extrair real ext
    ext="${basename_file##*.}"
  fi

  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')

  local file_content
  file_content=$(cat "$file_path" 2>/dev/null || echo "")

  case "$ext" in
    md|MD)
      # Markdown: conteúdo direto
      printf '%s' "$file_content"
      ;;
    tf|hcl)
      # Terraform/HCL: envolve em bloco de código
      echo "# ${title}"
      echo ""
      echo "> Arquivo: \`${rel_path}\`  "
      echo "> Última atualização: ${now}  "
      echo "> Gerenciado por: bookstack-sync-docs.sh"
      echo ""
      echo "---"
      echo ""
      echo '```hcl'
      printf '%s\n' "$file_content"
      echo '```'
      ;;
    yml|yaml|YAML|YML)
      # YAML: envolve em bloco de código
      echo "# ${title}"
      echo ""
      echo "> Arquivo: \`${rel_path}\`  "
      echo "> Última atualização: ${now}  "
      echo "> Gerenciado por: bookstack-sync-docs.sh"
      echo ""
      echo "---"
      echo ""
      echo '```yaml'
      printf '%s\n' "$file_content"
      echo '```'
      ;;
    sh|bash)
      # Shell script: envolve em bloco de código
      echo "# ${title}"
      echo ""
      echo "> Arquivo: \`${rel_path}\`  "
      echo "> Última atualização: ${now}  "
      echo "> Gerenciado por: bookstack-sync-docs.sh"
      echo ""
      echo "---"
      echo ""
      echo '```bash'
      printf '%s\n' "$file_content"
      echo '```'
      ;;
    *)
      # Extensão desconhecida: envolve em bloco de código genérico
      echo "# ${title}"
      echo ""
      echo "> Arquivo: \`${rel_path}\`  "
      echo "> Última atualização: ${now}  "
      echo "> Gerenciado por: bookstack-sync-docs.sh"
      echo ""
      echo "---"
      echo ""
      echo '```'
      printf '%s\n' "$file_content"
      echo '```'
      ;;
  esac
}

# =============================================================================
# PROCESSAMENTO DE UM ARQUIVO
# =============================================================================

# sync_file REL_PATH
# Lê FILE_MAP[REL_PATH] no formato "SHELF|BOOK_TITLE", garante a hierarquia
# Shelf→Book, busca/cria a Page única dentro do Book e controla hash/state.
sync_file() {
  local rel_path="$1"
  local mapping="${FILE_MAP[$rel_path]}"

  local shelf_name book_title
  IFS='|' read -r shelf_name book_title <<< "$mapping"

  local full_path
  full_path="${PROJECT_ROOT%/}/${rel_path}"

  COUNT_FILES=$((COUNT_FILES + 1))

  # Verificar se o arquivo existe
  if [[ ! -f "$full_path" ]]; then
    log_warn "Arquivo não encontrado: ${rel_path} — pulando"
    return 0
  fi

  # Calcular hash atual
  local current_hash
  current_hash=$(get_file_hash "$full_path")

  if [[ -z "$current_hash" ]]; then
    log_warn "Não foi possível calcular hash de ${rel_path} — pulando"
    COUNT_ERRORS=$((COUNT_ERRORS + 1))
    return 0
  fi

  # Consultar state
  local stored_hash
  stored_hash=$(state_get_hash "$rel_path")

  local stored_page_id
  stored_page_id=$(state_get_page_id "$rel_path")

  # Verificar se hash bate e force está desligado
  if [[ -n "$stored_hash" ]] && [[ "$stored_hash" == "$current_hash" ]] && [[ "$FORCE" == "false" ]]; then
    log_skip "${rel_path} → sem alterações (hash idêntico)"
    COUNT_SKIP=$((COUNT_SKIP + 1))
    return 0
  fi

  # 1. Garantir shelf
  local shelf_id
  shelf_id=$(bs_ensure_shelf "$shelf_name" "")
  if [[ -z "$shelf_id" ]]; then
    log_error "Não foi possível resolver shelf '${shelf_name}' para ${rel_path}"
    COUNT_ERRORS=$((COUNT_ERRORS + 1))
    return 0
  fi

  # 2. Garantir book dentro da shelf
  local book_id
  book_id=$(bs_ensure_book "$book_title" "$shelf_id" "")
  if [[ -z "$book_id" ]]; then
    log_error "Não foi possível resolver book '${book_title}' para ${rel_path}"
    COUNT_ERRORS=$((COUNT_ERRORS + 1))
    return 0
  fi

  # 3. Gerar conteúdo da page
  local content
  content=$(file_to_page_content "$full_path" "$book_title" "$rel_path")

  if [[ -z "$content" ]]; then
    log_warn "${rel_path}: conteúdo gerado está vazio — arquivo pode não ter sido encontrado ou estar vazio"
    # Não abortar — deixar criar página vazia com fallback
  fi
  log_verbose "${rel_path}: content size = ${#content} bytes"

  # Base URL da API — usada nas chamadas bs_get/bs_update_page dentro de sync_file
  local api_base="${BOOKSTACK_URL%/}/api"

  # ── Decidir ação: UPDATE ou NEW ──────────────────────────────────────────
  # Fluxo de decisão:
  #   Caso 1 (page_id no state, hash mudou ou force):
  #     → GET /pages/{id}: 404/000 → limpar id, cair no Caso 2
  #     → GET 200, página vazia → forçar UPDATE
  #     → GET 200, conteúdo presente → UPDATE normal
  #   Caso 2 (sem page_id no state):
  #     → bs_find_page_in_book: não encontrou → NEW (bs_create_page)
  #     → encontrou:
  #         GET /pages/{id}: página vazia → UPDATE
  #         hash idêntico e não force → SKIP (atualiza só state)
  #         hash diferente ou force → UPDATE

  # Caso 1: page_id existe no state → verificar se ainda existe no BookStack e UPDATE
  # Se a página sumiu (404/000), limpa stored_page_id e cai no Caso 2 (recriação).
  if [[ -n "$stored_page_id" ]] && [[ "$stored_page_id" != "null" ]] && \
     [[ "$stored_page_id" != "0" ]]; then

    # Verificar se a página ainda existe no BookStack antes de tentar atualizar
    local check_response
    check_response=$(bs_get "${api_base}/pages/${stored_page_id}" || true)
    if [[ "$BS_LAST_HTTP_CODE" == "404" ]] || [[ "$BS_LAST_HTTP_CODE" == "000" ]]; then
      log_warn "Page id=${stored_page_id} não encontrada no BookStack (HTTP ${BS_LAST_HTTP_CODE}) — será recriada"
      stored_page_id=""
      # cai para o Caso 2 abaixo
    elif [[ "$BS_LAST_HTTP_CODE" == "200" ]]; then
      # Página existe — verificar se está vazia (pode forçar atualização mesmo com hash igual)
      local bs_md bs_html
      bs_md=$(echo "$check_response" | jq -r '.markdown // ""' 2>/dev/null || echo "")
      bs_html=$(echo "$check_response" | jq -r '.raw_html // .html // ""' 2>/dev/null || echo "")
      if [[ -z "$bs_md" ]] && [[ -z "$bs_html" ]]; then
        log_info "Page id=${stored_page_id} '${book_title}' existe mas está vazia — forçando atualização"
      fi
      # prossegue com bs_update_page normalmente

      if [[ "$DRY_RUN" == "true" ]]; then
        log_dryrun "Atualizaria page id=${stored_page_id} '${book_title}' (${rel_path})"
        COUNT_UPDATE=$((COUNT_UPDATE + 1))
        return 0
      fi

      if bs_update_page "$stored_page_id" "$book_title" "$content"; then
        log_update "Page id=${stored_page_id} '${book_title}' atualizada (${rel_path})"
        COUNT_UPDATE=$((COUNT_UPDATE + 1))
        state_update "$rel_path" "$current_hash" "$stored_page_id" \
          "$book_id" "$book_title"
      else
        log_warn "Falha ao atualizar page id=${stored_page_id} — tentando criar nova"
        stored_page_id=""
      fi
    else
      # GET retornou outro código (ex: 500) — não atualizar; cai no Caso 2
      log_warn "GET page id=${stored_page_id} retornou HTTP ${BS_LAST_HTTP_CODE} — será recriada"
      stored_page_id=""
    fi
  fi

  # Caso 2: sem page_id no state → verificar BookStack e criar se necessário
  if [[ -z "$stored_page_id" ]] || [[ "$stored_page_id" == "0" ]] || \
     [[ "$stored_page_id" == "null" ]]; then

    # Verificar se já existe no BookStack pelo nome dentro do book
    local existing_id=""
    if [[ "$book_id" != "0" ]]; then
      existing_id=$(bs_find_page_in_book "$book_title" "$book_id")
    fi

    if [[ -n "$existing_id" ]]; then
      # Existe no BookStack mas não no state — verificar conteúdo atual antes de atualizar.
      # Fluxo: SKIP se conteúdo presente e hash idêntico; UPDATE se vazio, hash diferente ou force.
      local page_response
      page_response=$(bs_get "${api_base}/pages/${existing_id}" || true)

      local current_bs_markdown current_bs_html
      current_bs_markdown=$(echo "$page_response" | jq -r '.markdown // ""' 2>/dev/null || echo "")
      current_bs_html=$(echo "$page_response" | jq -r '.raw_html // .html // ""' 2>/dev/null || echo "")

      local page_is_empty=false
      if [[ -z "$current_bs_markdown" ]] && [[ -z "$current_bs_html" ]]; then
        page_is_empty=true
      fi

      # Determinar se atualização é necessária
      local needs_update=false
      if [[ "$page_is_empty" == "true" ]]; then
        log_info "Page '${book_title}' existe mas está vazia — atualizando (${rel_path})"
        needs_update=true
      elif [[ "$FORCE" == "true" ]] || [[ "$stored_hash" != "$current_hash" ]]; then
        log_info "Page '${book_title}' existe — conteúdo desatualizado, atualizando (${rel_path})"
        needs_update=true
      else
        log_skip "${rel_path} → página já existe com conteúdo e hash idêntico"
        COUNT_SKIP=$((COUNT_SKIP + 1))
        state_update "$rel_path" "$current_hash" "$existing_id" "$book_id" "$book_title"
        return 0
      fi

      if [[ "$needs_update" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
          log_dryrun "Atualizaria page id=${existing_id} '${book_title}' (${rel_path})"
          COUNT_UPDATE=$((COUNT_UPDATE + 1))
          return 0
        fi

        if bs_update_page "$existing_id" "$book_title" "$content"; then
          log_update "Page id=${existing_id} '${book_title}' atualizada (${rel_path})"
          COUNT_UPDATE=$((COUNT_UPDATE + 1))
          state_update "$rel_path" "$current_hash" "$existing_id" \
            "$book_id" "$book_title"
        else
          log_error "Falha ao atualizar page id=${existing_id} '${book_title}'"
          COUNT_ERRORS=$((COUNT_ERRORS + 1))
        fi
      fi

    else
      # Não existe em nenhum lugar → criar (page direto no book, sem chapter)
      if [[ "$DRY_RUN" == "true" ]]; then
        log_dryrun "Criaria page '${book_title}' em shelf '${shelf_name}' > book '${book_title}' (${rel_path})"
        COUNT_NEW=$((COUNT_NEW + 1))
        return 0
      fi

      local new_page_id
      new_page_id=$(bs_create_page "$book_id" "" "$book_title" "$content")

      if [[ -n "$new_page_id" ]] && [[ "$new_page_id" != "0" ]]; then
        log_new "Page id=${new_page_id} '${book_title}' criada em '${shelf_name} > ${book_title}'"
        COUNT_NEW=$((COUNT_NEW + 1))
        state_update "$rel_path" "$current_hash" "$new_page_id" \
          "$book_id" "$book_title"
      else
        log_error "Falha ao criar page '${book_title}' para ${rel_path}"
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
      fi
    fi
  fi
}

# =============================================================================
# VARREDURA E SINCRONIZAÇÃO
# =============================================================================

# scan_and_sync
# Itera sobre FILE_MAP e chama sync_file para cada entrada.
scan_and_sync() {
  log_info "Iniciando varredura e sincronização de arquivos..."
  echo ""

  local rel_path map_value

  # Iterar sobre o FILE_MAP em ordem determinística
  local -a sorted_keys=()
  while IFS= read -r rel_path; do
    sorted_keys+=("$rel_path")
  done < <(printf '%s\n' "${!FILE_MAP[@]}" | sort)

  for rel_path in "${sorted_keys[@]}"; do
    map_value="${FILE_MAP[$rel_path]}"
    local shelf_name book_title
    IFS='|' read -r shelf_name book_title <<< "$map_value"

    log_verbose "Processando: ${rel_path} → shelf '${shelf_name}' > book '${book_title}'"

    sync_file "$rel_path" || {
      log_warn "Falha ao processar ${rel_path} — continuando"
      COUNT_ERRORS=$((COUNT_ERRORS + 1))
    }
  done

  echo ""
  log_info "Varredura concluída"
}

# =============================================================================
# VALIDAÇÕES PRÉ-EXECUÇÃO
# =============================================================================

validate_config() {
  local build_structure="${1:-true}"

  if [[ -z "$BOOKSTACK_URL" ]]; then
    log_error "BOOKSTACK_URL não definida. Use --url ou export BOOKSTACK_URL=..."
    exit 1
  fi

  if [[ -z "$BOOKSTACK_TOKEN_ID" ]]; then
    log_error "BOOKSTACK_TOKEN_ID não definido. Use --token-id ou export BOOKSTACK_TOKEN_ID=..."
    exit 1
  fi

  if [[ -z "$BOOKSTACK_TOKEN_SECRET" ]]; then
    log_error "BOOKSTACK_TOKEN_SECRET não definido. Use --token-secret ou export BOOKSTACK_TOKEN_SECRET=..."
    exit 1
  fi

  # Normalizar BOOKSTACK_URL: remover trailing slash
  BOOKSTACK_URL="${BOOKSTACK_URL%/}"

  # Mascarar secret nos logs (primeiros 4 chars + ...)
  local secret_masked
  if [[ "${#BOOKSTACK_TOKEN_SECRET}" -gt 4 ]]; then
    secret_masked="${BOOKSTACK_TOKEN_SECRET:0:4}..."
  else
    secret_masked="***"
  fi

  # Montar array global BS_BASE_ARGS — deve ocorrer antes de qualquer chamada bs_*
  _build_bs_base_args

  log_info "BookStack URL  : ${BOOKSTACK_URL}"
  log_info "Token ID       : ${BOOKSTACK_TOKEN_ID}"
  log_info "Token Secret   : ${secret_masked}"
  log_info "Insecure TLS   : ${INSECURE}"
  log_info "Dry-run        : ${DRY_RUN}"
  log_info "Force          : ${FORCE}"
  log_info "Verbose        : ${VERBOSE}"
  log_info "State file     : ${STATE_FILE}"
  log_info "Project root   : ${PROJECT_ROOT}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dryrun "Modo dry-run ativo — nenhuma alteração será feita no BookStack"
  fi

  if [[ "$FORCE" == "true" ]]; then
    log_warn "Modo force ativo — todos os arquivos serão re-publicados independente do state"
  fi

  # Testar conectividade com a API do BookStack
  log_info "Testando conectividade com a API do BookStack..."
  local api_base="${BOOKSTACK_URL}/api"

  BS_LAST_HTTP_CODE=""
  bs_get "${api_base}/books" > /dev/null || true

  if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
    log_error "API do BookStack não acessível em ${api_base}/books — HTTP ${BS_LAST_HTTP_CODE:-000}"
    log_error "Verifique a URL, o token e a conectividade de rede antes de continuar"
    exit 1
  fi

  log_info "API do BookStack acessível (HTTP 200)"

  # Garantir estrutura completa (apenas no fluxo de sincronização, não no cleanup)
  if [[ "$build_structure" == "true" ]]; then
    bs_ensure_structure
  fi
}

# =============================================================================
# DETECÇÃO AUTOMÁTICA DA RAIZ DO PROJETO
# =============================================================================

# detect_project_root
# Sobe na árvore de diretórios até encontrar .claudecode.md ou README.md + scripts/.
# Popula PROJECT_ROOT e STATE_FILE se não definidos.
detect_project_root() {
  if [[ -n "$PROJECT_ROOT" ]]; then
    # Normalizar: remover trailing slash
    PROJECT_ROOT="${PROJECT_ROOT%/}"
    if [[ ! -d "$PROJECT_ROOT" ]]; then
      log_error "project-root especificado não existe: ${PROJECT_ROOT}"
      exit 1
    fi
  else
    # Detectar automaticamente: o script está em scripts/ dentro da raiz
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Tentar subir um nível (scripts/ → raiz)
    local candidate
    candidate="$(dirname "$script_dir")"

    if [[ -f "${candidate}/.claudecode.md" ]] || \
       [[ -f "${candidate}/README.md" ]]; then
      PROJECT_ROOT="$candidate"
    else
      # Fallback: usar diretório corrente
      PROJECT_ROOT="$(pwd)"
      log_warn "Não foi possível detectar raiz do projeto automaticamente — usando: ${PROJECT_ROOT}"
    fi
  fi

  if [[ -z "$STATE_FILE" ]]; then
    STATE_FILE="${PROJECT_ROOT}/scripts/.bookstack-sync-state.json"
  fi

  log_info "Raiz do projeto : ${PROJECT_ROOT}"
}

# =============================================================================
# LIMPEZA DE PÁGINAS DUPLICADAS
# =============================================================================

# bs_cleanup_duplicates
# Busca TODAS as páginas com paginação (offset incremental), filtra localmente
# pelo nome exato passado via $1, mantém apenas a mais recente por updated_at
# dentro de cada chapter_id e deleta as demais. Respeita --dry-run.
#
# A busca por offset evita o problema de filter[name] com caracteres acentuados
# e de colchetes não codificados que fazem a API retornar 0 resultados.
#
# Uso interno: chamado por main() quando CLEANUP_DUPLICATES=true.
bs_cleanup_duplicates() {
  local page_name="${1:-Procedimentos Técnicos}"
  local api_base="${BOOKSTACK_URL%/}/api"

  log_info "=== Limpeza de páginas duplicadas ==="
  log_info "Buscando páginas com nome: '${page_name}'"

  # ── Acumulação de todas as páginas via paginação por offset ────────────────
  # BS_RESPONSE_TMP é sobrescrito a cada bs_get; usamos um arquivo separado
  # para acumular o array JSON crescente entre as iterações.
  local all_pages_tmp
  all_pages_tmp=$(mktemp /tmp/bs_all_pages_$$.XXXXXX.json)
  # Inicializa com array vazio
  echo '[]' > "$all_pages_tmp"

  local page_size=500
  local offset=0
  local batch_count=0
  local http_errors=0

  log_info "Coletando todas as páginas com paginação (page_size=${page_size})..."

  while true; do
    local batch
    batch=$(bs_get "${api_base}/pages?count=${page_size}&offset=${offset}" || true)

    if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
      log_error "Falha ao listar páginas (offset=${offset}) — HTTP ${BS_LAST_HTTP_CODE}"
      http_errors=$((http_errors + 1))
      break
    fi

    batch_count=$(echo "$batch" | jq '(.data // []) | length' 2>/dev/null || echo "0")
    batch_count="${batch_count:-0}"

    log_verbose "Batch offset=${offset}: ${batch_count} página(s) recebidas"

    [[ "$batch_count" -eq 0 ]] && break

    # Concatenar .data do batch ao array acumulado usando arquivo temporário.
    # jq lê o array atual do arquivo e o batch da variável; produz novo array.
    local merged
    merged=$(jq -s '.[0] + (.[1].data // [])' \
      "$all_pages_tmp" \
      <(echo "$batch") 2>/dev/null || true)

    if [[ -z "$merged" ]]; then
      log_error "Falha ao mesclar batch (offset=${offset}) — abortando paginação"
      http_errors=$((http_errors + 1))
      break
    fi

    printf '%s' "$merged" > "$all_pages_tmp"

    offset=$((offset + page_size))

    # Se o batch veio com menos itens que page_size, é a última página
    [[ "$batch_count" -lt "$page_size" ]] && break
  done

  if [[ "$http_errors" -gt 0 ]]; then
    log_error "Erros durante a coleta de páginas — abortando limpeza"
    rm -f "$all_pages_tmp"
    return 1
  fi

  local total_collected
  total_collected=$(jq 'length' "$all_pages_tmp" 2>/dev/null || echo "0")
  log_info "Total de páginas coletadas: ${total_collected}"

  # ── Filtro local por nome exato ────────────────────────────────────────────
  local matched_tmp
  matched_tmp=$(mktemp /tmp/bs_matched_$$.XXXXXX.json)

  jq --arg name "$page_name" '[.[] | select(.name == $name)]' \
    "$all_pages_tmp" > "$matched_tmp" 2>/dev/null || echo '[]' > "$matched_tmp"

  rm -f "$all_pages_tmp"

  local total
  total=$(jq 'length' "$matched_tmp" 2>/dev/null || echo "0")
  total="${total:-0}"

  if [[ "$total" -eq 0 ]]; then
    log_info "Nenhuma página encontrada com o nome '${page_name}' — nada a fazer"
    rm -f "$matched_tmp"
    return 0
  fi

  log_info "Encontradas ${total} página(s) com esse nome"

  # ── Agrupar por chapter_id, manter mais recente, coletar duplicatas ────────
  # Protege campos numéricos com // 0 e strings com // "" para evitar
  # "Invalid numeric literal" caso o servidor retorne null nesses campos.
  local candidates
  candidates=$(jq -r '
    [.[] | select(.id != null) | {
      id: (.id // 0),
      name: (.name // ""),
      chapter_id: (.chapter_id // 0),
      book_id: (.book_id // 0),
      updated_at: (.updated_at // "1970-01-01T00:00:00.000000Z")
    }]
    | group_by(.chapter_id)
    | map(
        sort_by(.updated_at) | reverse |
        if length > 1 then .[1:]   # remove o mais recente (índice 0), retorna os demais
        else empty
        end
      )
    | flatten
    | .[]
    | [(.id | tostring), .name, (.chapter_id | tostring), (.book_id | tostring), .updated_at]
    | @tsv
  ' "$matched_tmp" 2>/dev/null || true)

  rm -f "$matched_tmp"

  if [[ -z "$candidates" ]]; then
    log_info "Nenhuma duplicata encontrada — todas as ${total} página(s) são únicas por chapter"
    return 0
  fi

  local count_found=0
  local count_deleted=0
  local count_errors=0

  # Contar candidatos antes de iterar (para o resumo)
  count_found=$(echo "$candidates" | wc -l | tr -d ' ')

  log_info "Duplicatas encontradas: ${count_found} página(s) serão removidas"
  echo ""

  # Iterar sobre cada candidato
  while IFS=$'\t' read -r dup_id dup_name dup_chapter_id dup_book_id dup_updated_at; do
    [[ -z "$dup_id" ]] && continue

    if [[ "$DRY_RUN" == "true" ]]; then
      log_dryrun "Removeria page id=${dup_id} '${dup_name}' (chapter_id=${dup_chapter_id}, updated_at=${dup_updated_at})"
    else
      log_info "Removendo page id=${dup_id} '${dup_name}' (chapter_id=${dup_chapter_id}, updated_at=${dup_updated_at})"
      bs_delete "${api_base}/pages/${dup_id}" || true

      if [[ "$BS_LAST_HTTP_CODE" == "204" ]] || [[ "$BS_LAST_HTTP_CODE" == "200" ]]; then
        log_update "Page id=${dup_id} removida com sucesso"
        count_deleted=$((count_deleted + 1))
      else
        log_error "Falha ao remover page id=${dup_id} — HTTP ${BS_LAST_HTTP_CODE}"
        count_errors=$((count_errors + 1))
      fi
    fi
  done <<< "$candidates"

  echo ""
  echo "+------------------------------------------------------+"
  echo "|      Limpeza de Duplicatas -- Resumo                 |"
  echo "+------------------------------------------------------+"
  echo "|  Modo                  :  $( [[ "$DRY_RUN" == "true" ]] && echo "DRY-RUN" || echo "EXECUTADO" )"
  echo "|  Total coletadas       :  ${total_collected}"
  echo "|  Com nome correspondente: ${total}"
  echo "|  Duplicatas detectadas :  ${count_found}"
  if [[ "$DRY_RUN" == "false" ]]; then
    echo "|  Removidas             :  ${count_deleted}"
    echo "|  Erros na remocao      :  ${count_errors}"
  fi
  echo "+------------------------------------------------------+"

  if [[ "$count_errors" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# bs_cleanup_duplicate_shelves
# Busca TODOS os shelves com paginação (sem filter[name] — para contornar o problema
# de colchetes na query string em proxies nginx). Filtra localmente pelos nomes
# "ADRs", "Procedimentos Técnicos" e "infra-lab-proxmox". Para cada nome, mantém
# o shelf com id menor (o mais antigo — provavelmente o legítimo) e deleta os
# demais. Respeita --dry-run.
#
# Uso interno: chamado por main() quando CLEANUP_DUPLICATES=true.
bs_cleanup_duplicate_shelves() {
  local api_base="${BOOKSTACK_URL%/}/api"

  log_info "=== Limpeza de shelves duplicados ==="
  log_info "Nomes monitorados: 'ADRs', 'Procedimentos Técnicos', 'infra-lab-proxmox'"

  # ── Coletar todos os shelves via paginação por offset ───────────────────────
  local all_shelves_tmp
  all_shelves_tmp=$(mktemp /tmp/bs_all_shelves_$$.XXXXXX.json)
  echo '[]' > "$all_shelves_tmp"

  local page_size=500
  local offset=0
  local batch_count=0
  local http_errors=0

  log_info "Coletando todos os shelves com paginação (page_size=${page_size})..."

  while true; do
    local batch
    batch=$(bs_get "${api_base}/shelves?count=${page_size}&offset=${offset}" || true)

    if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
      log_error "Falha ao listar shelves (offset=${offset}) — HTTP ${BS_LAST_HTTP_CODE}"
      http_errors=$((http_errors + 1))
      break
    fi

    batch_count=$(echo "$batch" | jq '(.data // []) | length' 2>/dev/null || echo "0")
    batch_count="${batch_count:-0}"

    log_verbose "Batch offset=${offset}: ${batch_count} shelf(ves) recebido(s)"

    [[ "$batch_count" -eq 0 ]] && break

    local merged
    merged=$(jq -s '.[0] + (.[1].data // [])' \
      "$all_shelves_tmp" \
      <(echo "$batch") 2>/dev/null || true)

    if [[ -z "$merged" ]]; then
      log_error "Falha ao mesclar batch de shelves (offset=${offset}) — abortando paginação"
      http_errors=$((http_errors + 1))
      break
    fi

    printf '%s' "$merged" > "$all_shelves_tmp"
    offset=$((offset + page_size))
    [[ "$batch_count" -lt "$page_size" ]] && break
  done

  if [[ "$http_errors" -gt 0 ]]; then
    log_error "Erros durante a coleta de shelves — abortando limpeza de shelves"
    rm -f "$all_shelves_tmp"
    return 1
  fi

  local total_collected
  total_collected=$(jq 'length' "$all_shelves_tmp" 2>/dev/null || echo "0")
  log_info "Total de shelves coletados: ${total_collected}"

  # ── Processar cada nome monitorado ──────────────────────────────────────────
  local -a monitored_shelf_names=("ADRs" "Procedimentos Técnicos" "infra-lab-proxmox")
  local grand_found=0
  local grand_deleted=0
  local grand_errors=0

  local sname
  for sname in "${monitored_shelf_names[@]}"; do

    local matched_tmp
    matched_tmp=$(mktemp /tmp/bs_matched_shelves_$$.XXXXXX.json)

    jq --arg name "$sname" '[.[] | select(.name == $name)]' \
      "$all_shelves_tmp" > "$matched_tmp" 2>/dev/null || echo '[]' > "$matched_tmp"

    local total_name
    total_name=$(jq 'length' "$matched_tmp" 2>/dev/null || echo "0")
    total_name="${total_name:-0}"

    log_info "Shelves com nome '${sname}': ${total_name} encontrado(s)"

    if [[ "$total_name" -le 1 ]]; then
      log_info "  -> Sem duplicatas para '${sname}'"
      rm -f "$matched_tmp"
      continue
    fi

    # Ordenar por id crescente; manter o de menor id (índice 0), deletar os demais
    local candidates_shelves
    candidates_shelves=$(jq -r '
      sort_by(.id)
      | .[1:]
      | .[]
      | [(.id | tostring), .name, (.slug // "")]
      | @tsv
    ' "$matched_tmp" 2>/dev/null || true)

    rm -f "$matched_tmp"

    if [[ -z "$candidates_shelves" ]]; then
      log_info "  -> Nenhuma duplicata detectada para '${sname}'"
      continue
    fi

    local count_name
    count_name=$(echo "$candidates_shelves" | wc -l | tr -d ' ')
    grand_found=$((grand_found + count_name))
    log_info "  -> ${count_name} duplicata(s) a remover para '${sname}'"

    while IFS=$'\t' read -r dup_id dup_name dup_slug; do
      [[ -z "$dup_id" ]] && continue

      if [[ "$DRY_RUN" == "true" ]]; then
        log_dryrun "Removeria shelf id=${dup_id} '${dup_name}' (slug=${dup_slug})"
      else
        log_info "Removendo shelf id=${dup_id} '${dup_name}' (slug=${dup_slug})"
        bs_delete "${api_base}/shelves/${dup_id}" || true

        if [[ "$BS_LAST_HTTP_CODE" == "204" ]] || [[ "$BS_LAST_HTTP_CODE" == "200" ]]; then
          log_update "Shelf id=${dup_id} removido com sucesso"
          grand_deleted=$((grand_deleted + 1))
        else
          log_error "Falha ao remover shelf id=${dup_id} — HTTP ${BS_LAST_HTTP_CODE}"
          grand_errors=$((grand_errors + 1))
        fi
      fi
    done <<< "$candidates_shelves"
  done

  rm -f "$all_shelves_tmp"

  # ── Resumo ──────────────────────────────────────────────────────────────────
  echo ""
  echo "+------------------------------------------------------+"
  echo "|      Limpeza de Shelves Duplicados -- Resumo         |"
  echo "+------------------------------------------------------+"
  echo "|  Modo                  :  $( [[ "$DRY_RUN" == "true" ]] && echo "DRY-RUN" || echo "EXECUTADO" )"
  echo "|  Shelves totais colet. :  ${total_collected}"
  echo "|  Duplicatas detectadas :  ${grand_found}"
  if [[ "$DRY_RUN" == "false" ]]; then
    echo "|  Removidos             :  ${grand_deleted}"
    echo "|  Erros na remocao      :  ${grand_errors}"
  fi
  echo "+------------------------------------------------------+"

  if [[ "$grand_errors" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# bs_cleanup_duplicate_books
# Busca TODOS os books com paginação (sem filter[name] — para contornar o problema
# de colchetes na query string em proxies nginx). Filtra localmente pelos títulos
# de books definidos no FILE_MAP (terceiro campo). Para cada nome, mantém o book
# com id menor (o mais antigo — provavelmente o legítimo) e deleta os demais.
# Respeita --dry-run.
# Nota: "ADRs" e "Procedimentos Técnicos" passaram a ser shelves — não são
# monitorados aqui.
#
# Uso interno: chamado por main() quando CLEANUP_DUPLICATES=true.
bs_cleanup_duplicate_books() {
  local api_base="${BOOKSTACK_URL%/}/api"

  log_info "=== Limpeza de books duplicados ==="

  # Coletar títulos únicos de books a partir do FILE_MAP
  local -a monitored_names=()
  local _rel _map _sn _bt
  for _rel in "${!FILE_MAP[@]}"; do
    _map="${FILE_MAP[$_rel]}"
    IFS='|' read -r _sn _bt <<< "$_map"
    monitored_names+=("$_bt")
  done
  # Deduplicate
  local -a unique_names=()
  while IFS= read -r _bt; do
    unique_names+=("$_bt")
  done < <(printf '%s\n' "${monitored_names[@]}" | sort -u)

  log_info "Monitorando ${#unique_names[@]} título(s) de book definidos no FILE_MAP"

  # ── Coletar todos os books via paginação por offset ─────────────────────────
  local all_books_tmp
  all_books_tmp=$(mktemp /tmp/bs_all_books_$$.XXXXXX.json)
  echo '[]' > "$all_books_tmp"

  local page_size=500
  local offset=0
  local batch_count=0
  local http_errors=0

  log_info "Coletando todos os books com paginação (page_size=${page_size})..."

  while true; do
    local batch
    batch=$(bs_get "${api_base}/books?count=${page_size}&offset=${offset}" || true)

    if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
      log_error "Falha ao listar books (offset=${offset}) — HTTP ${BS_LAST_HTTP_CODE}"
      http_errors=$((http_errors + 1))
      break
    fi

    batch_count=$(echo "$batch" | jq '(.data // []) | length' 2>/dev/null || echo "0")
    batch_count="${batch_count:-0}"

    log_verbose "Batch offset=${offset}: ${batch_count} book(s) recebidos"

    [[ "$batch_count" -eq 0 ]] && break

    local merged
    merged=$(jq -s '.[0] + (.[1].data // [])' \
      "$all_books_tmp" \
      <(echo "$batch") 2>/dev/null || true)

    if [[ -z "$merged" ]]; then
      log_error "Falha ao mesclar batch de books (offset=${offset}) — abortando paginação"
      http_errors=$((http_errors + 1))
      break
    fi

    printf '%s' "$merged" > "$all_books_tmp"
    offset=$((offset + page_size))
    [[ "$batch_count" -lt "$page_size" ]] && break
  done

  if [[ "$http_errors" -gt 0 ]]; then
    log_error "Erros durante a coleta de books — abortando limpeza de books"
    rm -f "$all_books_tmp"
    return 1
  fi

  local total_collected
  total_collected=$(jq 'length' "$all_books_tmp" 2>/dev/null || echo "0")
  log_info "Total de books coletados: ${total_collected}"

  # ── Processar cada nome monitorado ──────────────────────────────────────────
  local grand_found=0
  local grand_deleted=0
  local grand_errors=0

  local book_name
  for book_name in "${unique_names[@]}"; do

    # Filtrar localmente por nome exato
    local matched_tmp
    matched_tmp=$(mktemp /tmp/bs_matched_books_$$.XXXXXX.json)

    jq --arg name "$book_name" '[.[] | select(.name == $name)]' \
      "$all_books_tmp" > "$matched_tmp" 2>/dev/null || echo '[]' > "$matched_tmp"

    local total_name
    total_name=$(jq 'length' "$matched_tmp" 2>/dev/null || echo "0")
    total_name="${total_name:-0}"

    log_info "Books com nome '${book_name}': ${total_name} encontrado(s)"

    if [[ "$total_name" -le 1 ]]; then
      log_info "  → Sem duplicatas para '${book_name}'"
      rm -f "$matched_tmp"
      continue
    fi

    # Ordenar por id crescente; manter o de menor id (índice 0), deletar os demais
    local candidates_books
    candidates_books=$(jq -r '
      sort_by(.id)
      | .[1:]
      | .[]
      | [(.id | tostring), .name, (.slug // "")]
      | @tsv
    ' "$matched_tmp" 2>/dev/null || true)

    rm -f "$matched_tmp"

    if [[ -z "$candidates_books" ]]; then
      log_info "  → Nenhuma duplicata detectada para '${book_name}'"
      continue
    fi

    local count_name
    count_name=$(echo "$candidates_books" | wc -l | tr -d ' ')
    grand_found=$((grand_found + count_name))

    log_info "  → ${count_name} duplicata(s) a remover para '${book_name}'"

    while IFS=$'\t' read -r dup_id dup_name dup_slug; do
      [[ -z "$dup_id" ]] && continue

      if [[ "$DRY_RUN" == "true" ]]; then
        log_dryrun "Removeria book id=${dup_id} '${dup_name}' (slug=${dup_slug})"
      else
        log_info "Removendo book id=${dup_id} '${dup_name}' (slug=${dup_slug})"
        bs_delete "${api_base}/books/${dup_id}" || true

        if [[ "$BS_LAST_HTTP_CODE" == "204" ]] || [[ "$BS_LAST_HTTP_CODE" == "200" ]]; then
          log_update "Book id=${dup_id} removido com sucesso"
          grand_deleted=$((grand_deleted + 1))
        else
          log_error "Falha ao remover book id=${dup_id} — HTTP ${BS_LAST_HTTP_CODE}"
          grand_errors=$((grand_errors + 1))
        fi
      fi
    done <<< "$candidates_books"
  done

  rm -f "$all_books_tmp"

  # ── Resumo ──────────────────────────────────────────────────────────────────
  echo ""
  echo "+------------------------------------------------------+"
  echo "|      Limpeza de Books Duplicados -- Resumo           |"
  echo "+------------------------------------------------------+"
  echo "|  Modo                  :  $( [[ "$DRY_RUN" == "true" ]] && echo "DRY-RUN" || echo "EXECUTADO" )"
  echo "|  Books totais coletados:  ${total_collected}"
  echo "|  Duplicatas detectadas :  ${grand_found}"
  if [[ "$DRY_RUN" == "false" ]]; then
    echo "|  Removidos             :  ${grand_deleted}"
    echo "|  Erros na remocao      :  ${grand_errors}"
  fi
  echo "+------------------------------------------------------+"

  if [[ "$grand_errors" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# =============================================================================
# CLEANUP
# =============================================================================

cleanup() {
  rm -f "${BS_RESPONSE_TMP}" 2>/dev/null || true
}

trap cleanup EXIT

# =============================================================================
# MAIN
# =============================================================================

main() {
  echo ""
  log_info "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} ==="
  log_info "Sincronizador de documentação infra-lab-proxmox → BookStack"
  echo ""

  parse_args "$@"
  check_deps

  # Modo de limpeza de duplicatas — executa e sai sem sincronizar
  if [[ "$CLEANUP_DUPLICATES" == "true" ]]; then
    detect_project_root
    # Passa "false" para não criar estrutura BookStack durante o cleanup
    validate_config "false"
    bs_cleanup_duplicate_shelves
    bs_cleanup_duplicate_books
    bs_cleanup_duplicates "Procedimentos Técnicos"
    exit $?
  fi

  detect_project_root
  # Passa "true" (padrão) para garantir estrutura BookStack antes de sincronizar
  validate_config "true"
  load_state

  echo ""
  scan_and_sync
  save_state
  print_summary

  if [[ "$COUNT_ERRORS" -gt 0 ]]; then
    log_error "Sincronização concluída com ${COUNT_ERRORS} erro(s)"
    exit 1
  else
    log_info "Sincronização concluída com sucesso"
    exit 0
  fi
}

main "$@"
