#!/usr/bin/env bash
# =============================================================================
# bookstack-sync-docs.sh
# Varre o projeto infra-lab-proxmox, classifica arquivos como ADR ou
# Procedimento Técnico, publica no BookStack pré-existente no laboratório
# e detecta atualizações em re-runs via state file com SHA256.
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
# FILE MAP — array associativo (chave: caminho relativo; valor: BOOK|CHAPTER|PAGE)
# =============================================================================

declare -A FILE_MAP

FILE_MAP["README.md"]="Procedimentos Técnicos|Visão Geral|Visão Geral do Projeto"
FILE_MAP[".claudecode.md"]="Procedimentos Técnicos|Visão Geral|Instruções Globais do Projeto"
FILE_MAP["README.infraestructure.md"]="Procedimentos Técnicos|Rede e IPAM|Referência de Infraestrutura Proxmox"
FILE_MAP["terraform-proxmox/main.tf"]="Procedimentos Técnicos|Terraform - Kubernetes|Provisionamento de VMs Kubernetes"
FILE_MAP["terraform-proxmox/variables.tf"]="Procedimentos Técnicos|Terraform - Kubernetes|Variáveis Terraform - Kubernetes"
FILE_MAP["terraform-proxmox/outputs.tf"]="Procedimentos Técnicos|Terraform - Kubernetes|Outputs Terraform - Kubernetes"
FILE_MAP["terraform-proxmox/netbox.tf"]="Procedimentos Técnicos|Terraform - Kubernetes|Integração NetBox - Kubernetes"
FILE_MAP["terraform-cicd/main.tf"]="Procedimentos Técnicos|Terraform - CI/CD|Provisionamento VM CI/CD"
FILE_MAP["terraform-cicd/variables.tf"]="Procedimentos Técnicos|Terraform - CI/CD|Variáveis Terraform - CI/CD"
FILE_MAP["terraform-cicd/outputs.tf"]="Procedimentos Técnicos|Terraform - CI/CD|Outputs Terraform - CI/CD"
FILE_MAP["terraform-cicd/netbox.tf"]="Procedimentos Técnicos|Terraform - CI/CD|Integração NetBox - CI/CD"
FILE_MAP["ansible-k8s/site.yml"]="Procedimentos Técnicos|Ansible - Kubernetes|Orquestração do Cluster Kubernetes"
FILE_MAP["ansible-k8s/group_vars/all.yml"]="Procedimentos Técnicos|Ansible - Kubernetes|Variáveis Globais - Kubernetes"
FILE_MAP["ansible-k8s/playbooks/01-prepare-nodes.yml"]="Procedimentos Técnicos|Ansible - Kubernetes|Preparação dos Nós"
FILE_MAP["ansible-k8s/playbooks/02-install-containerd.yml"]="Procedimentos Técnicos|Ansible - Kubernetes|Instalação do containerd"
FILE_MAP["ansible-k8s/playbooks/03-install-kubeadm.yml"]="Procedimentos Técnicos|Ansible - Kubernetes|Instalação do kubeadm"
FILE_MAP["ansible-k8s/playbooks/04-init-master.yml"]="Procedimentos Técnicos|Ansible - Kubernetes|Inicialização do Master"
FILE_MAP["ansible-k8s/playbooks/05-join-workers.yml"]="Procedimentos Técnicos|Ansible - Kubernetes|Ingresso dos Workers"
FILE_MAP["ansible-k8s/playbooks/06-register-netbox.yml"]="Procedimentos Técnicos|Rede e IPAM|Registro K8s no NetBox"
FILE_MAP["ansible-k8s/inventory/generate_inventory.sh"]="Procedimentos Técnicos|Ansible - Kubernetes|Geração do Inventário Dinâmico"
FILE_MAP["ansible-cicd/site.yml"]="Procedimentos Técnicos|Ansible - CI/CD|Orquestração da Stack CI/CD"
FILE_MAP["ansible-cicd/group_vars/all.yml"]="Procedimentos Técnicos|Ansible - CI/CD|Variáveis Globais - CI/CD"
FILE_MAP["ansible-cicd/playbooks/01-prepare-node.yml"]="Procedimentos Técnicos|Ansible - CI/CD|Preparação do Servidor CI/CD"
FILE_MAP["ansible-cicd/playbooks/02-install-docker.yml"]="Procedimentos Técnicos|Ansible - CI/CD|Instalação do Docker"
FILE_MAP["ansible-cicd/playbooks/03-deploy-stack.yml"]="Procedimentos Técnicos|Ansible - CI/CD|Deploy da Stack CI/CD"
FILE_MAP["ansible-cicd/playbooks/04-configure-runner.yml"]="Procedimentos Técnicos|Ansible - CI/CD|Configuração do Act Runner"
FILE_MAP["ansible-cicd/playbooks/05-register-netbox.yml"]="Procedimentos Técnicos|Rede e IPAM|Registro CI/CD no NetBox"
FILE_MAP["ansible-cicd/inventory/generate_inventory.sh"]="Procedimentos Técnicos|Ansible - CI/CD|Geração do Inventário CI/CD"
FILE_MAP["scripts/netbox-sync-lab-ips.sh"]="Procedimentos Técnicos|Scripts|Sincronização IPAM NetBox"
FILE_MAP["scripts/netbox-get-available-ips.sh"]="Procedimentos Técnicos|Scripts|Consulta de IPs Disponíveis"
FILE_MAP["scripts/bookstack-sync-docs.sh"]="Procedimentos Técnicos|Scripts|Sincronização de Documentação"

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
      --cleanup-duplicates   Remove pages duplicadas chamadas "Procedimento Técnico"
                             (mantém apenas a mais recente por updated_at). Requer
                             --url e credenciais configuradas. Combine com -n para
                             dry-run (apenas listar, sem deletar).
  -h, --help                 Exibir este help

Estrutura BookStack criada:
  Shelf: infra-lab-proxmox
    ├── Book: ADRs
    │   └── Chapter: Infraestrutura Geral  (placeholder — ADRs futuros)
    └── Book: Procedimentos Técnicos
        ├── Chapter: Visão Geral
        ├── Chapter: Terraform - Kubernetes
        ├── Chapter: Terraform - CI/CD
        ├── Chapter: Ansible - Kubernetes
        ├── Chapter: Ansible - CI/CD
        ├── Chapter: Scripts
        └── Chapter: Rede e IPAM

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

  # Remover páginas duplicadas "Procedimento Técnico"
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
  echo "╔══════════════════════════════════════════════════════╗"
  printf  "║      BookStack Sync — Resumo da sincronização        ║\n"
  echo "╠══════════════════════════════════════════════════════╣"
  printf  "║  Modo                  :  %-27s║\n" "$mode_label"
  printf  "║  Arquivos processados  :  %-27s║\n" "$COUNT_FILES"
  printf  "║  Pages novas (NEW)     :  %-27s║\n" "$COUNT_NEW"
  printf  "║  Pages atualizadas     :  %-27s║\n" "$COUNT_UPDATE"
  printf  "║  Pages sem alteração   :  %-27s║\n" "$COUNT_SKIP"
  printf  "║  Erros                 :  %-27s║\n" "$COUNT_ERRORS"
  echo "╚══════════════════════════════════════════════════════╝"
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
  }

  log_verbose "HTTP ${BS_LAST_HTTP_CODE} <- DELETE ${url}"
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
# Executa GET. Retorna body em stdout; HTTP code em BS_LAST_HTTP_CODE.
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
  }

  log_verbose "HTTP ${BS_LAST_HTTP_CODE} <- GET ${url}"
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

  local name_encoded
  name_encoded=$(printf '%s' "$name" | sed 's/ /%20/g; s/|/%7C/g')

  local response
  response=$(bs_get "${api_base}/shelves?filter[name]=${name_encoded}&count=1")

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

  # Verificar conflito — tratar como skip
  if [[ "$BS_LAST_HTTP_CODE" == "409" ]] || \
     grep -qi "already exists\|unique\|duplicate" "${BS_RESPONSE_TMP}" 2>/dev/null; then
    log_skip "Shelf '${name}' já existe (conflict) — buscando novamente"
    existing_id=$(bs_find_shelf "$name")
    SHELF_IDS["$name"]="${existing_id:-0}"
    echo "${existing_id:-0}"
    return 0
  fi

  log_error "Falha ao criar shelf '${name}' — HTTP ${BS_LAST_HTTP_CODE}"
  echo ""
  return 1
}

# bs_find_book NAME
# Retorna o ID do book ou "" se não encontrar.
bs_find_book() {
  local name="$1"
  local api_base="${BOOKSTACK_URL%/}/api"

  local name_encoded
  name_encoded=$(printf '%s' "$name" | sed 's/ /%20/g; s/|/%7C/g')

  local response
  response=$(bs_get "${api_base}/books?filter[name]=${name_encoded}&count=1")

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
    if [[ "$DRY_RUN" == "false" ]] && [[ "$shelf_id" != "0" ]]; then
      local shelf_body
      shelf_body=$(jq -n --arg bid "$existing_id" '{ books: [($bid | tonumber)] }')
      bs_put "${api_base}/shelves/${shelf_id}" "$shelf_body" > /dev/null || true
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

    # Associar ao shelf
    if [[ "$shelf_id" != "0" ]]; then
      local shelf_body
      shelf_body=$(jq -n --arg bid "$new_id" '{ books: [($bid | tonumber)] }')
      bs_put "${api_base}/shelves/${shelf_id}" "$shelf_body" > /dev/null || true
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

  local name_encoded
  name_encoded=$(printf '%s' "$name" | sed 's/ /%20/g; s/|/%7C/g; s/-/%2D/g')

  local response
  response=$(bs_get "${api_base}/chapters?filter[name]=${name_encoded}&filter[book_id]=${book_id}&count=10")

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

  local name_encoded
  name_encoded=$(printf '%s' "$name" | sed 's/ /%20/g; s/|/%7C/g')

  local response
  response=$(bs_get "${api_base}/pages?filter[name]=${name_encoded}&filter[chapter_id]=${chapter_id}&count=10")

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

# bs_create_page BOOK_ID CHAPTER_ID NAME MARKDOWN_CONTENT
# Cria nova page. Retorna o ID em stdout.
bs_create_page() {
  local book_id="$1"
  local chapter_id="$2"
  local name="$3"
  local markdown_content="$4"
  local api_base="${BOOKSTACK_URL%/}/api"

  local body
  body=$(jq -n \
    --arg bid "$book_id" \
    --arg cid "$chapter_id" \
    --arg name "$name" \
    --arg md "$markdown_content" \
    '{ book_id: ($bid | tonumber), chapter_id: ($cid | tonumber), name: $name, markdown: $md }')

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
    # Buscar ID existente
    local existing_id
    existing_id=$(bs_find_page "$name" "$chapter_id")
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
    '{ name: $name, markdown: $md }')

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
# Cria toda a hierarquia Shelf→Books→Chapters necessária para o projeto.
# Popula os arrays globais SHELF_IDS, BOOK_IDS, CHAPTER_IDS.
bs_ensure_structure() {
  log_info "Verificando/criando estrutura BookStack..."
  echo ""

  local shelf_name="infra-lab-proxmox"
  local shelf_id

  # ── Shelf principal
  shelf_id=$(bs_ensure_shelf "$shelf_name" \
    "Documentação do laboratório de infraestrutura híbrida Proxmox")

  if [[ -z "$shelf_id" ]]; then
    log_error "Não foi possível garantir shelf '${shelf_name}' — abortando"
    exit 1
  fi

  # ── Book: ADRs
  local book_adrs_id
  book_adrs_id=$(bs_ensure_book "ADRs" "$shelf_id" \
    "Architecture Decision Records do projeto infra-lab-proxmox")

  if [[ -n "$book_adrs_id" ]] && [[ "$book_adrs_id" != "0" ]]; then
    # Chapter placeholder para ADRs
    local ch_infra_id
    ch_infra_id=$(bs_ensure_chapter "Infraestrutura Geral" "$book_adrs_id" \
      "ADRs relacionados à infraestrutura geral do laboratório")

    # Criar page placeholder se o chapter foi criado agora
    if [[ "$DRY_RUN" == "false" ]] && [[ -n "$ch_infra_id" ]] && [[ "$ch_infra_id" != "0" ]]; then
      local existing_placeholder
      existing_placeholder=$(bs_find_page "ADRs — Infraestrutura Geral" "$ch_infra_id")
      if [[ -z "$existing_placeholder" ]]; then
        local placeholder_md
        placeholder_md='# ADRs — Infraestrutura Geral

> Esta página é um placeholder gerado automaticamente por `bookstack-sync-docs.sh`.

Nenhum ADR foi documentado ainda para o projeto **infra-lab-proxmox**.

Quando ADRs forem criados (arquivos em diretórios `adr/` ou `decisions/`, ou
arquivos com padrões como `## Decisão`, `## Contexto`, `## Consequências`,
`# ADR-`, `Status: Accepted`), eles serão publicados automaticamente neste livro.

---

## Formato esperado de ADR

```markdown
# ADR-001 — Título da Decisão

**Status:** Accepted
**Data:** YYYY-MM-DD
**Autor:** nome.sobrenome

## Contexto

Descreva o contexto e o problema que motivou a decisão.

## Decisão

Descreva a decisão tomada.

## Consequências

Descreva os impactos positivos e negativos da decisão.
```'
        bs_create_page "$book_adrs_id" "$ch_infra_id" \
          "ADRs — Infraestrutura Geral" "$placeholder_md" > /dev/null || true
        log_new "Page placeholder criada em ADRs > Infraestrutura Geral"
      fi
    elif [[ "$DRY_RUN" == "true" ]]; then
      log_dryrun "Criaria page placeholder em ADRs > Infraestrutura Geral"
    fi
  fi

  # ── Book: Procedimentos Técnicos
  local book_pt_id
  book_pt_id=$(bs_ensure_book "Procedimentos Técnicos" "$shelf_id" \
    "Procedimentos técnicos, configurações e referências do projeto infra-lab-proxmox")

  if [[ -z "$book_pt_id" ]]; then
    log_error "Não foi possível garantir book 'Procedimentos Técnicos' — abortando"
    exit 1
  fi

  # ── Chapters do book Procedimentos Técnicos
  local -a pt_chapters=(
    "Visão Geral|Visão geral e documentação raiz do projeto"
    "Terraform - Kubernetes|Código Terraform para provisionamento do cluster Kubernetes"
    "Terraform - CI/CD|Código Terraform para provisionamento da stack CI/CD"
    "Ansible - Kubernetes|Playbooks Ansible para configuração do cluster Kubernetes"
    "Ansible - CI/CD|Playbooks Ansible para configuração da stack CI/CD"
    "Scripts|Scripts de automação e utilitários do laboratório"
    "Rede e IPAM|Configuração de rede, IPAM NetBox e referências de infraestrutura"
  )

  local ch_entry ch_name ch_desc ch_id
  for ch_entry in "${pt_chapters[@]}"; do
    IFS='|' read -r ch_name ch_desc <<< "$ch_entry"
    ch_id=$(bs_ensure_chapter "$ch_name" "$book_pt_id" "$ch_desc")
    log_verbose "Chapter '${ch_name}' resolvido: id=${ch_id}"
  done

  echo ""
  log_info "Estrutura BookStack verificada/criada com sucesso"
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

# state_update RELATIVE_PATH HASH PAGE_ID BOOK_ID CHAPTER_ID PAGE_NAME
# Atualiza a entrada de um arquivo no STATE_JSON (em memória).
state_update() {
  local rel_path="$1"
  local hash="$2"
  local page_id="$3"
  local book_id="$4"
  local chapter_id="$5"
  local page_name="$6"

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
      chapter_id: ($cid | tonumber),
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
      printf '# %s\n\n' "$title"
      printf '> Arquivo: `%s`  \n' "$rel_path"
      printf '> Última atualização: %s  \n' "$now"
      printf '> Gerenciado por: bookstack-sync-docs.sh\n\n'
      printf '---\n\n'
      printf '```hcl\n'
      printf '%s\n' "$file_content"
      printf '```\n'
      ;;
    yml|yaml|YAML|YML)
      # YAML: envolve em bloco de código
      printf '# %s\n\n' "$title"
      printf '> Arquivo: `%s`  \n' "$rel_path"
      printf '> Última atualização: %s  \n' "$now"
      printf '> Gerenciado por: bookstack-sync-docs.sh\n\n'
      printf '---\n\n'
      printf '```yaml\n'
      printf '%s\n' "$file_content"
      printf '```\n'
      ;;
    sh|bash)
      # Shell script: envolve em bloco de código
      printf '# %s\n\n' "$title"
      printf '> Arquivo: `%s`  \n' "$rel_path"
      printf '> Última atualização: %s  \n' "$now"
      printf '> Gerenciado por: bookstack-sync-docs.sh\n\n'
      printf '---\n\n'
      printf '```bash\n'
      printf '%s\n' "$file_content"
      printf '```\n'
      ;;
    *)
      # Extensão desconhecida: envolve em bloco de código genérico
      printf '# %s\n\n' "$title"
      printf '> Arquivo: `%s`  \n' "$rel_path"
      printf '> Última atualização: %s  \n' "$now"
      printf '> Gerenciado por: bookstack-sync-docs.sh\n\n'
      printf '---\n\n'
      printf '```\n'
      printf '%s\n' "$file_content"
      printf '```\n'
      ;;
  esac
}

# =============================================================================
# PROCESSAMENTO DE UM ARQUIVO
# =============================================================================

# process_file REL_PATH BOOK_NAME CHAPTER_NAME PAGE_NAME
# Orquestra: hash → state lookup → skip / create / update.
process_file() {
  local rel_path="$1"
  local book_name="$2"
  local chapter_name="$3"
  local page_name="$4"

  local abs_path="${PROJECT_ROOT}/${rel_path}"

  COUNT_FILES=$((COUNT_FILES + 1))

  # Verificar se o arquivo existe
  if [[ ! -f "$abs_path" ]]; then
    log_warn "Arquivo não encontrado: ${rel_path} — pulando"
    return 0
  fi

  # Calcular hash atual
  local current_hash
  current_hash=$(get_file_hash "$abs_path")

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

  # Resolver IDs de book e chapter
  local book_id="${BOOK_IDS[$book_name]:-}"
  local chapter_id="${CHAPTER_IDS["${book_id}::${chapter_name}"]:-}"

  # Se não estiver em cache, buscar ou criar
  if [[ -z "$book_id" ]]; then
    local shelf_id="${SHELF_IDS[infra-lab-proxmox]:-0}"
    book_id=$(bs_ensure_book "$book_name" "$shelf_id" "")
    if [[ -z "$book_id" ]]; then
      log_error "Não foi possível resolver book '${book_name}' para ${rel_path}"
      COUNT_ERRORS=$((COUNT_ERRORS + 1))
      return 0
    fi
  fi

  if [[ -z "$chapter_id" ]]; then
    chapter_id=$(bs_ensure_chapter "$chapter_name" "$book_id" "")
    if [[ -z "$chapter_id" ]]; then
      log_error "Não foi possível resolver chapter '${chapter_name}' para ${rel_path}"
      COUNT_ERRORS=$((COUNT_ERRORS + 1))
      return 0
    fi
  fi

  # Gerar conteúdo da page
  local page_content
  page_content=$(file_to_page_content "$abs_path" "$page_name" "$rel_path")

  # ── Decidir ação: UPDATE ou NEW ──────────────────────────────────────────

  # Caso 1: page_id existe no state → UPDATE
  if [[ -n "$stored_page_id" ]] && [[ "$stored_page_id" != "null" ]] && \
     [[ "$stored_page_id" != "0" ]]; then

    if [[ "$DRY_RUN" == "true" ]]; then
      log_dryrun "Atualizaria page id=${stored_page_id} '${page_name}' (${rel_path})"
      COUNT_UPDATE=$((COUNT_UPDATE + 1))
      return 0
    fi

    if bs_update_page "$stored_page_id" "$page_name" "$page_content"; then
      log_update "Page id=${stored_page_id} '${page_name}' atualizada (${rel_path})"
      COUNT_UPDATE=$((COUNT_UPDATE + 1))
      state_update "$rel_path" "$current_hash" "$stored_page_id" \
        "$book_id" "$chapter_id" "$page_name"
    else
      log_warn "Falha ao atualizar page id=${stored_page_id} — tentando criar nova"
      # Fallthrough para criação
      stored_page_id=""
    fi
  fi

  # Caso 2: sem page_id no state → verificar BookStack e criar se necessário
  if [[ -z "$stored_page_id" ]] || [[ "$stored_page_id" == "0" ]] || \
     [[ "$stored_page_id" == "null" ]]; then

    # Verificar se já existe no BookStack pelo nome
    local existing_id=""
    if [[ "$chapter_id" != "0" ]]; then
      existing_id=$(bs_find_page "$page_name" "$chapter_id")
    fi

    if [[ -n "$existing_id" ]]; then
      # Existe no BookStack mas não no state → associar e atualizar
      log_info "Page '${page_name}' encontrada no BookStack (id=${existing_id}) — atualizando"

      if [[ "$DRY_RUN" == "true" ]]; then
        log_dryrun "Atualizaria page id=${existing_id} '${page_name}' (${rel_path})"
        COUNT_UPDATE=$((COUNT_UPDATE + 1))
        return 0
      fi

      if bs_update_page "$existing_id" "$page_name" "$page_content"; then
        log_update "Page id=${existing_id} '${page_name}' atualizada (${rel_path})"
        COUNT_UPDATE=$((COUNT_UPDATE + 1))
        state_update "$rel_path" "$current_hash" "$existing_id" \
          "$book_id" "$chapter_id" "$page_name"
      else
        log_error "Falha ao atualizar page id=${existing_id} '${page_name}'"
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
      fi

    else
      # Não existe em nenhum lugar → criar
      if [[ "$DRY_RUN" == "true" ]]; then
        log_dryrun "Criaria page '${page_name}' em '${book_name} > ${chapter_name}' (${rel_path})"
        COUNT_NEW=$((COUNT_NEW + 1))
        return 0
      fi

      local new_page_id
      new_page_id=$(bs_create_page "$book_id" "$chapter_id" "$page_name" "$page_content")

      if [[ -n "$new_page_id" ]] && [[ "$new_page_id" != "0" ]]; then
        log_new "Page id=${new_page_id} '${page_name}' criada em '${book_name} > ${chapter_name}'"
        COUNT_NEW=$((COUNT_NEW + 1))
        state_update "$rel_path" "$current_hash" "$new_page_id" \
          "$book_id" "$chapter_id" "$page_name"
      else
        log_error "Falha ao criar page '${page_name}' para ${rel_path}"
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
      fi
    fi
  fi
}

# =============================================================================
# VARREDURA E SINCRONIZAÇÃO
# =============================================================================

# scan_and_sync
# Itera sobre FILE_MAP e chama process_file para cada entrada.
scan_and_sync() {
  log_info "Iniciando varredura e sincronização de arquivos..."
  echo ""

  local rel_path book_name chapter_name page_name map_value

  # Iterar sobre o FILE_MAP em ordem determinística
  local -a sorted_keys=()
  while IFS= read -r rel_path; do
    sorted_keys+=("$rel_path")
  done < <(printf '%s\n' "${!FILE_MAP[@]}" | sort)

  for rel_path in "${sorted_keys[@]}"; do
    map_value="${FILE_MAP[$rel_path]}"
    IFS='|' read -r book_name chapter_name page_name <<< "$map_value"

    log_verbose "Processando: ${rel_path} → ${book_name} > ${chapter_name} > ${page_name}"

    process_file "$rel_path" "$book_name" "$chapter_name" "$page_name" || {
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

  # Mascarar secret nos logs (primeiros 4 chars + ...)
  local secret_masked
  if [[ "${#BOOKSTACK_TOKEN_SECRET}" -gt 4 ]]; then
    secret_masked="${BOOKSTACK_TOKEN_SECRET:0:4}..."
  else
    secret_masked="***"
  fi

  # Montar array global BS_BASE_ARGS
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
  local api_base="${BOOKSTACK_URL%/}/api"

  BS_LAST_HTTP_CODE=""
  bs_get "${api_base}/books" > /dev/null || true

  if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
    log_error "API do BookStack não acessível em ${api_base}/books — HTTP ${BS_LAST_HTTP_CODE:-000}"
    log_error "Verifique a URL, o token e a conectividade de rede antes de continuar"
    exit 1
  fi

  log_info "API do BookStack acessível (HTTP 200)"

  # Garantir estrutura completa
  bs_ensure_structure
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
# Consulta todas as pages com o nome "Procedimento Técnico" (ou qualquer
# nome passado via $1), mantém apenas a mais recente por updated_at e
# deleta as demais. Respeita --dry-run.
#
# Uso interno: chamado por main() quando CLEANUP_DUPLICATES=true.
bs_cleanup_duplicates() {
  local page_name="${1:-Procedimento Técnico}"
  local api_base="${BOOKSTACK_URL%/}/api"

  log_info "=== Limpeza de páginas duplicadas ==="
  log_info "Buscando páginas com nome: '${page_name}'"

  # URL-encode o nome da página para o filtro (espaços → %20, ç → %C3%A7, etc.)
  local name_encoded
  name_encoded=$(printf '%s' "$page_name" | \
    python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" \
    2>/dev/null \
    || printf '%s' "$page_name" | sed 's/ /%20/g; s/ç/%C3%A7/g; s/é/%C3%A9/g; s/ê/%C3%AA/g; s/ã/%C3%A3/g; s/â/%C3%A2/g; s/ó/%C3%B3/g; s/í/%C3%AD/g; s/á/%C3%A1/g; s/ú/%C3%BA/g')

  # Buscar todas as páginas com esse nome (até 500 resultados)
  local response
  response=$(bs_get "${api_base}/pages?filter[name]=${name_encoded}&count=500")

  if [[ "$BS_LAST_HTTP_CODE" != "200" ]]; then
    log_error "Falha ao listar páginas — HTTP ${BS_LAST_HTTP_CODE}"
    return 1
  fi

  # Extrair total de resultados encontrados
  local total
  total=$(echo "$response" | jq '.data | length' 2>/dev/null || echo "0")

  if [[ "$total" -eq 0 ]]; then
    log_info "Nenhuma página encontrada com o nome '${page_name}' — nada a fazer"
    return 0
  fi

  log_info "Encontradas ${total} página(s) com esse nome"

  # Agrupar por chapter_id: para cada grupo, manter a mais recente (maior updated_at)
  # e coletar as demais como candidatas à remoção.
  # Produz JSON: array de objetos { id, name, chapter_id, updated_at, book_id }
  local candidates
  candidates=$(echo "$response" | jq -r '
    [.data[] | {
      id: .id,
      name: .name,
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
    | [.id, .name, (.chapter_id | tostring), (.book_id | tostring), .updated_at]
    | @tsv
  ' 2>/dev/null || true)

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
      bs_delete "${api_base}/pages/${dup_id}"

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
  echo "╔══════════════════════════════════════════════════════╗"
  printf  "║      Limpeza de Duplicatas — Resumo                  ║\n"
  echo "╠══════════════════════════════════════════════════════╣"
  printf  "║  Modo                  :  %-27s║\n" "$( [[ "$DRY_RUN" == "true" ]] && echo "DRY-RUN" || echo "EXECUTADO" )"
  printf  "║  Total encontradas     :  %-27s║\n" "$total"
  printf  "║  Duplicatas detectadas :  %-27s║\n" "$count_found"
  if [[ "$DRY_RUN" == "false" ]]; then
    printf  "║  Removidas             :  %-27s║\n" "$count_deleted"
    printf  "║  Erros na remoção      :  %-27s║\n" "$count_errors"
  fi
  echo "╚══════════════════════════════════════════════════════╝"

  if [[ "$count_errors" -gt 0 ]]; then
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
    validate_config
    bs_cleanup_duplicates "Procedimento Técnico"
    exit $?
  fi

  detect_project_root
  validate_config
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
