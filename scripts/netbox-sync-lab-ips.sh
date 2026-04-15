#!/usr/bin/env bash
# =============================================================================
# netbox-sync-lab-ips.sh
# Escaneia as redes do laboratório Proxmox, descobre IPs em uso e sincroniza
# com o NetBox IPAM de forma idempotente.
#
# Executar ANTES de qualquer provisionamento Terraform do lab para garantir
# que o IPAM esteja sincronizado com a realidade do ambiente.
#
# Uso: netbox-sync-lab-ips.sh [OPÇÕES] [REDE1 REDE2 ...]
#
# Opções:
#   -u, --netbox-url URL      URL base do NetBox (padrão: $NETBOX_URL)
#   -t, --token TOKEN         API Token (padrão: $NETBOX_TOKEN)
#   -k, --insecure            Ignorar verificação TLS (padrão: false)
#   -n, --dry-run             Não fazer alterações no NetBox
#   -v, --verbose             Saída detalhada das chamadas API
#   -s, --skip-networks LIST  Redes a ignorar, separadas por vírgula
#       --timeout SECS        Timeout de ping/nmap por host (padrão: 2)
#   -h, --help                Exibir este help
#
# Variáveis de ambiente:
#   NETBOX_URL    URL base do NetBox
#   NETBOX_TOKEN  API Token (preferível a passar via --token)
#
# Exemplos:
#   export NETBOX_TOKEN="token123"
#   ./netbox-sync-lab-ips.sh --netbox-url http://10.10.0.5:8000
#
#   ./netbox-sync-lab-ips.sh -n -u http://10.10.0.5:8000 10.10.0.0/24
#
#   ./netbox-sync-lab-ips.sh -v --skip-networks 192.168.1.0/24
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
readonly NB_RESPONSE_TMP="/tmp/nb_response_$$.json"

# Redes padrão do laboratório: "CIDR|DESCRIÇÃO|ESCANEAR_ATIVAMENTE"
readonly -a DEFAULT_NETWORKS=(
  "10.10.0.0/24|VMs Lab|yes"
  "192.168.1.0/24|Management|yes"
  "10.20.0.0/24|Kubernetes|yes"
  "10.30.0.0/24|Storage|no"
)

# Tags padrão para todos os recursos criados
readonly NB_TAGS='["lab-k8s-proxmox-01", "dev", "auto-discovered"]'

# =============================================================================
# ESTADO GLOBAL (contadores — somente leitura após main)
# =============================================================================

COUNT_NETWORKS=0
COUNT_HOSTS=0
COUNT_NEW=0
COUNT_UPDATE=0
COUNT_SKIP=0
COUNT_ERRORS=0

# =============================================================================
# CONFIGURAÇÃO (preenchida por parse_args)
# =============================================================================

NETBOX_URL="${NETBOX_URL:-}"
NETBOX_TOKEN="${NETBOX_TOKEN:-}"
INSECURE=false
DRY_RUN=false
VERBOSE=false
PING_TIMEOUT=2
SKIP_NETWORKS=""

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
else
  COLOR_RESET=""
  COLOR_CYAN=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_GRAY=""
  COLOR_RED=""
  COLOR_MAGENTA=""
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
Uso: ${SCRIPT_NAME} [OPÇÕES] [REDE1 REDE2 ...]

Escaneia as redes do laboratório Proxmox e sincroniza os IPs descobertos
com o NetBox IPAM de forma idempotente.

Opções:
  -u, --netbox-url URL      URL base do NetBox (padrão: \$NETBOX_URL)
  -t, --token TOKEN         API Token (padrão: \$NETBOX_TOKEN)
  -k, --insecure            Ignorar verificação TLS (padrão: false)
  -n, --dry-run             Não fazer alterações no NetBox
  -v, --verbose             Saída detalhada das chamadas API
  -s, --skip-networks LIST  Redes a ignorar, separadas por vírgula
      --timeout SECS        Timeout de ping/nmap por host (padrão: 2)
  -h, --help                Exibir este help

Redes padrão (se não especificadas):
  10.10.0.0/24   VMs Lab          (escaneada ativamente)
  192.168.1.0/24 Management       (escaneada ativamente)
  10.20.0.0/24   Kubernetes       (escaneada ativamente)
  10.30.0.0/24   Storage          (apenas prefixo registrado — sem scan)

Variáveis de ambiente:
  NETBOX_URL    URL base do NetBox
  NETBOX_TOKEN  API Token (preferível a passar via --token)

Exemplos:
  # Sincronizar todas as redes padrão
  export NETBOX_TOKEN="token123"
  ./${SCRIPT_NAME} --netbox-url http://10.10.0.5:8000

  # Modo dry-run na rede de VMs apenas
  ./${SCRIPT_NAME} -n -u http://10.10.0.5:8000 10.10.0.0/24

  # Verbose + ignorar rede de management
  ./${SCRIPT_NAME} -v --skip-networks 192.168.1.0/24
EOF
}

# =============================================================================
# RELATÓRIO FINAL
# =============================================================================

print_summary() {
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  printf  "║         NetBox Sync — Resumo do laboratório          ║\n"
  echo "╠══════════════════════════════════════════════════════╣"
  printf  "║  Redes escaneadas   :  %-29s║\n" "$COUNT_NETWORKS"
  printf  "║  Hosts descobertos  :  %-29s║\n" "$COUNT_HOSTS"
  printf  "║  IPs novos (NEW)    :  %-29s║\n" "$COUNT_NEW"
  printf  "║  IPs atualizados    :  %-29s║\n" "$COUNT_UPDATE"
  printf  "║  IPs já registrados :  %-29s║\n" "$COUNT_SKIP"
  printf  "║  Erros              :  %-29s║\n" "$COUNT_ERRORS"
  echo "╚══════════════════════════════════════════════════════╝"
}

# =============================================================================
# PARSE DE ARGUMENTOS
# =============================================================================

parse_args() {
  local -a custom_networks=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--netbox-url)
        NETBOX_URL="${2:?'--netbox-url requer um valor'}"
        shift 2
        ;;
      -t|--token)
        NETBOX_TOKEN="${2:?'--token requer um valor'}"
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
      -s|--skip-networks)
        SKIP_NETWORKS="${2:?'--skip-networks requer um valor'}"
        shift 2
        ;;
      --timeout)
        PING_TIMEOUT="${2:?'--timeout requer um valor'}"
        shift 2
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
        # Argumento posicional: trata como rede CIDR customizada
        custom_networks+=("$1")
        shift
        ;;
    esac
  done

  # Exportar redes customizadas para uso em main
  CUSTOM_NETWORKS=("${custom_networks[@]+"${custom_networks[@]}"}")
}

# =============================================================================
# VERIFICAÇÃO DE DEPENDÊNCIAS
# =============================================================================

FALLBACK_PING=false

check_deps() {
  local missing=()

  for dep in curl jq; do
    if ! command -v "$dep" &>/dev/null; then
      missing+=("$dep")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Dependências obrigatórias ausentes: ${missing[*]}"
    log_error "Instale com: apt-get install ${missing[*]}  (ou equivalente do seu sistema)"
    exit 1
  fi

  if command -v nmap &>/dev/null; then
    log_info "nmap encontrado — usando scan ativo com nmap"
    FALLBACK_PING=false
  else
    log_warn "nmap não encontrado — usando fallback com ping sweep paralelo"
    log_warn "Para resultados mais precisos, instale: apt-get install nmap"
    FALLBACK_PING=true
  fi

  # Verificar host/dig para resolução de nome (opcional)
  if ! command -v host &>/dev/null && ! command -v dig &>/dev/null; then
    log_warn "Nem 'host' nem 'dig' encontrados — hostnames serão registrados como 'unknown'"
  fi
}

# =============================================================================
# WRAPPERS DA API NETBOX
# =============================================================================

# Monta as opções base do curl
_curl_opts() {
  local -a opts=(-s -H "Authorization: Token ${NETBOX_TOKEN}" -H "Content-Type: application/json")
  if [[ "$INSECURE" == "true" ]]; then
    opts+=(-k)
  fi
  printf '%s\n' "${opts[@]}"
}

# nb_get URL
# Executa GET. Retorna body em stdout; HTTP code em NB_LAST_HTTP_CODE.
nb_get() {
  local url="$1"
  local -a curl_opts
  mapfile -t curl_opts < <(_curl_opts)

  log_verbose "GET ${url}"

  NB_LAST_HTTP_CODE=$(curl "${curl_opts[@]}" \
    -o "${NB_RESPONSE_TMP}" \
    -w "%{http_code}" \
    "${url}" 2>/dev/null) || {
    log_error "curl falhou ao executar GET ${url}"
    NB_LAST_HTTP_CODE="000"
    echo "{}" > "${NB_RESPONSE_TMP}"
  }

  log_verbose "HTTP ${NB_LAST_HTTP_CODE} <- GET ${url}"
  if [[ "$VERBOSE" == "true" ]]; then
    local preview
    preview=$(jq -c '.' "${NB_RESPONSE_TMP}" 2>/dev/null | head -c 200 || true)
    log_verbose "Body (200 chars): ${preview}"
  fi

  cat "${NB_RESPONSE_TMP}"
}

# nb_post URL BODY_JSON
# Executa POST. Retorna body em stdout; HTTP code em NB_LAST_HTTP_CODE.
nb_post() {
  local url="$1"
  local body="$2"
  local -a curl_opts
  mapfile -t curl_opts < <(_curl_opts)

  log_verbose "POST ${url}"

  NB_LAST_HTTP_CODE=$(curl "${curl_opts[@]}" \
    -o "${NB_RESPONSE_TMP}" \
    -w "%{http_code}" \
    -X POST \
    -d "${body}" \
    "${url}" 2>/dev/null) || {
    log_error "curl falhou ao executar POST ${url}"
    NB_LAST_HTTP_CODE="000"
    echo "{}" > "${NB_RESPONSE_TMP}"
  }

  log_verbose "HTTP ${NB_LAST_HTTP_CODE} <- POST ${url}"
  if [[ "$VERBOSE" == "true" ]]; then
    local preview
    preview=$(jq -c '.' "${NB_RESPONSE_TMP}" 2>/dev/null | head -c 200 || true)
    log_verbose "Body (200 chars): ${preview}"
  fi

  cat "${NB_RESPONSE_TMP}"
}

# nb_patch URL BODY_JSON
# Executa PATCH. Retorna body em stdout; HTTP code em NB_LAST_HTTP_CODE.
nb_patch() {
  local url="$1"
  local body="$2"
  local -a curl_opts
  mapfile -t curl_opts < <(_curl_opts)

  log_verbose "PATCH ${url}"

  NB_LAST_HTTP_CODE=$(curl "${curl_opts[@]}" \
    -o "${NB_RESPONSE_TMP}" \
    -w "%{http_code}" \
    -X PATCH \
    -d "${body}" \
    "${url}" 2>/dev/null) || {
    log_error "curl falhou ao executar PATCH ${url}"
    NB_LAST_HTTP_CODE="000"
    echo "{}" > "${NB_RESPONSE_TMP}"
  }

  log_verbose "HTTP ${NB_LAST_HTTP_CODE} <- PATCH ${url}"
  if [[ "$VERBOSE" == "true" ]]; then
    local preview
    preview=$(jq -c '.' "${NB_RESPONSE_TMP}" 2>/dev/null | head -c 200 || true)
    log_verbose "Body (200 chars): ${preview}"
  fi

  cat "${NB_RESPONSE_TMP}"
}

# =============================================================================
# OPERAÇÕES NETBOX — PREFIXOS
# =============================================================================

# nb_ensure_prefix CIDR DESCRIPTION
# Garante que o prefixo CIDR existe no NetBox. Cria se não existir.
nb_ensure_prefix() {
  local cidr="$1"
  local description="$2"

  local api_base="${NETBOX_URL%/}/api"
  local cidr_encoded
  cidr_encoded=$(printf '%s' "$cidr" | sed 's|/|%2F|g')

  log_info "Verificando prefixo ${cidr} no NetBox..."

  local response
  response=$(nb_get "${api_base}/ipam/prefixes/?prefix=${cidr_encoded}&limit=1")

  if [[ "$NB_LAST_HTTP_CODE" != "200" ]]; then
    log_error "Falha ao consultar prefixo ${cidr} — HTTP ${NB_LAST_HTTP_CODE}"
    log_error "Body: $(cat "${NB_RESPONSE_TMP}" 2>/dev/null || true)"
    COUNT_ERRORS=$((COUNT_ERRORS + 1))
    return 1
  fi

  local count
  count=$(echo "$response" | jq -r '.count // 0')

  if [[ "$count" -ge 1 ]]; then
    log_skip "Prefixo ${cidr} já existe no NetBox"
    return 0
  fi

  # Prefixo não existe — criar
  local body
  body=$(jq -n \
    --arg prefix "$cidr" \
    --arg desc "$description" \
    --argjson tags "$NB_TAGS" \
    '{
      prefix: $prefix,
      status: "active",
      description: $desc,
      tags: $tags
    }')

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dryrun "Criaria prefixo ${cidr} — \"${description}\""
    return 0
  fi

  local create_response
  create_response=$(nb_post "${api_base}/ipam/prefixes/" "$body")

  if [[ "$NB_LAST_HTTP_CODE" == "201" ]]; then
    log_new "Prefixo ${cidr} criado no NetBox (\"${description}\")"
  else
    log_error "Falha ao criar prefixo ${cidr} — HTTP ${NB_LAST_HTTP_CODE}"
    log_error "Body: $(cat "${NB_RESPONSE_TMP}" 2>/dev/null || true)"
    COUNT_ERRORS=$((COUNT_ERRORS + 1))
    return 1
  fi
}

# =============================================================================
# OPERAÇÕES NETBOX — ENDEREÇOS IP
# =============================================================================

# nb_get_ip IP_WITH_MASK
# Consulta /api/ipam/ip-addresses/?address=. Popula NB_IP_ID e NB_IP_STATUS.
nb_get_ip() {
  local address="$1"   # ex: "10.10.0.10/32"

  local api_base="${NETBOX_URL%/}/api"
  local addr_encoded
  addr_encoded=$(printf '%s' "$address" | sed 's|/|%2F|g')

  local response
  response=$(nb_get "${api_base}/ipam/ip-addresses/?address=${addr_encoded}&limit=1")

  if [[ "$NB_LAST_HTTP_CODE" != "200" ]]; then
    log_error "Falha ao consultar IP ${address} — HTTP ${NB_LAST_HTTP_CODE}"
    NB_IP_ID=""
    NB_IP_STATUS=""
    return 1
  fi

  local count
  count=$(echo "$response" | jq -r '.count // 0')

  if [[ "$count" -lt 1 ]]; then
    NB_IP_ID=""
    NB_IP_STATUS=""
    return 0
  fi

  NB_IP_ID=$(echo "$response" | jq -r '.results[0].id // ""')
  NB_IP_STATUS=$(echo "$response" | jq -r '.results[0].status.value // ""')
}

# nb_create_ip IP HOSTNAME
# Cria um novo IP no NetBox.
nb_create_ip() {
  local ip="$1"
  local hostname="$2"

  local api_base="${NETBOX_URL%/}/api"

  local body
  body=$(jq -n \
    --arg address "${ip}/32" \
    --arg dns_name "$hostname" \
    --argjson tags "$NB_TAGS" \
    '{
      address: $address,
      status: "active",
      dns_name: $dns_name,
      description: "Auto-discovered by netbox-sync-lab-ips.sh",
      tags: $tags
    }')

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dryrun "Criaria IP ${ip}/32 (dns_name=${hostname})"
    COUNT_NEW=$((COUNT_NEW + 1))
    return 0
  fi

  local response
  response=$(nb_post "${api_base}/ipam/ip-addresses/" "$body")

  if [[ "$NB_LAST_HTTP_CODE" == "201" ]]; then
    log_new "IP ${ip}/32 criado (dns_name=${hostname})"
    COUNT_NEW=$((COUNT_NEW + 1))
  else
    log_error "Falha ao criar IP ${ip}/32 — HTTP ${NB_LAST_HTTP_CODE}"
    log_error "Body: $(cat "${NB_RESPONSE_TMP}" 2>/dev/null || true)"
    COUNT_ERRORS=$((COUNT_ERRORS + 1))
    return 1
  fi
}

# nb_update_ip ID IP HOSTNAME
# Atualiza o status de um IP existente para "active".
nb_update_ip() {
  local id="$1"
  local ip="$2"
  local hostname="$3"

  local api_base="${NETBOX_URL%/}/api"

  local body
  body=$(jq -n \
    --arg dns_name "$hostname" \
    '{
      status: "active",
      dns_name: $dns_name,
      description: "Auto-discovered by netbox-sync-lab-ips.sh"
    }')

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dryrun "Atualizaria IP ${ip}/32 (id=${id}) -> status=active"
    COUNT_UPDATE=$((COUNT_UPDATE + 1))
    return 0
  fi

  local response
  response=$(nb_patch "${api_base}/ipam/ip-addresses/${id}/" "$body")

  if [[ "$NB_LAST_HTTP_CODE" == "200" ]]; then
    log_update "IP ${ip}/32 atualizado para status=active (id=${id})"
    COUNT_UPDATE=$((COUNT_UPDATE + 1))
  else
    log_error "Falha ao atualizar IP ${ip}/32 (id=${id}) — HTTP ${NB_LAST_HTTP_CODE}"
    log_error "Body: $(cat "${NB_RESPONSE_TMP}" 2>/dev/null || true)"
    COUNT_ERRORS=$((COUNT_ERRORS + 1))
    return 1
  fi
}

# =============================================================================
# DESCOBERTA DE HOSTS
# =============================================================================

# scan_network_nmap CIDR
# Retorna IPs descobertos, um por linha, em stdout.
scan_network_nmap() {
  local cidr="$1"

  log_info "Escaneando ${cidr} com nmap..."

  local raw_output
  if ! raw_output=$(nmap -sn -T4 --min-parallelism 20 "$cidr" 2>/dev/null); then
    log_warn "nmap falhou para ${cidr}"
    return 1
  fi

  # Extrair IPs da saída do nmap (linha "Nmap scan report for X.X.X.X" ou "for hostname (X.X.X.X)")
  echo "$raw_output" \
    | grep -oP '(?<=Nmap scan report for )(\d{1,3}\.){3}\d{1,3}|(?<=\()(\d{1,3}\.){3}\d{1,3}(?=\))' \
    | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n \
    | uniq
}

# scan_network_ping CIDR
# Fallback: ping sweep paralelo. Retorna IPs descobertos, um por linha, em stdout.
scan_network_ping() {
  local cidr="$1"

  # Extrair os 3 primeiros octetos da rede (funciona para /24)
  local base_ip
  base_ip=$(echo "$cidr" | grep -oP '^\d{1,3}\.\d{1,3}\.\d{1,3}')

  if [[ -z "$base_ip" ]]; then
    log_warn "Não foi possível extrair base IP de ${cidr} para ping sweep"
    return 1
  fi

  log_info "Escaneando ${cidr} com ping sweep paralelo (fallback)..."

  local tmp_results="/tmp/nb_ping_results_$$.txt"
  : > "$tmp_results"

  local pids=()
  local i
  for i in $(seq 1 254); do
    local ip="${base_ip}.${i}"
    (
      if ping -c 1 -W "$PING_TIMEOUT" "$ip" &>/dev/null 2>&1; then
        echo "$ip" >> "$tmp_results"
      fi
    ) &
    pids+=($!)

    # Limitar concorrência a 50 processos simultâneos
    if [[ ${#pids[@]} -ge 50 ]]; then
      wait "${pids[@]}" 2>/dev/null || true
      pids=()
    fi
  done

  # Aguardar todos os processos restantes
  if [[ ${#pids[@]} -gt 0 ]]; then
    wait "${pids[@]}" 2>/dev/null || true
  fi

  if [[ -f "$tmp_results" ]]; then
    sort -t. -k1,1n -k2,2n -k3,3n -k4,4n "$tmp_results" | uniq
    rm -f "$tmp_results"
  fi
}

# =============================================================================
# RESOLUÇÃO DE HOSTNAME
# =============================================================================

# resolve_hostname IP
# Tenta resolver o hostname reverso do IP. Retorna o nome ou "unknown".
resolve_hostname() {
  local ip="$1"
  local hostname=""

  if command -v host &>/dev/null; then
    hostname=$(host "$ip" 2>/dev/null \
      | grep -oP '(?<=pointer )\S+' \
      | sed 's/\.$//' \
      | head -1 || true)
  fi

  if [[ -z "$hostname" ]] && command -v dig &>/dev/null; then
    hostname=$(dig -x "$ip" +short 2>/dev/null \
      | sed 's/\.$//' \
      | head -1 || true)
  fi

  if [[ -z "$hostname" ]]; then
    hostname="unknown"
  fi

  echo "$hostname"
}

# =============================================================================
# ORQUESTRAÇÃO POR REDE
# =============================================================================

# _is_network_skipped CIDR
# Retorna 0 se a rede deve ser ignorada, 1 caso contrário.
_is_network_skipped() {
  local cidr="$1"
  if [[ -z "$SKIP_NETWORKS" ]]; then
    return 1
  fi

  local skip
  # Substituir vírgulas por newlines e verificar
  while IFS= read -r skip; do
    skip="${skip// /}"  # remover espaços
    if [[ "$skip" == "$cidr" ]]; then
      return 0
    fi
  done < <(echo "$SKIP_NETWORKS" | tr ',' '\n')

  return 1
}

# process_network CIDR DESCRIPTION SCAN_ACTIVE
# Garante o prefixo e, se SCAN_ACTIVE=yes, descobre e sincroniza IPs.
process_network() {
  local cidr="$1"
  local description="$2"
  local scan_active="$3"

  if _is_network_skipped "$cidr"; then
    log_skip "Rede ${cidr} ignorada conforme --skip-networks"
    return 0
  fi

  echo ""
  log_info "━━━ Processando rede: ${cidr} (${description}) ━━━"

  # Garantir prefixo no NetBox
  nb_ensure_prefix "$cidr" "$description" || true

  if [[ "$scan_active" != "yes" ]]; then
    log_info "Rede ${cidr} marcada como somente-prefixo — scan ativo ignorado"
    COUNT_NETWORKS=$((COUNT_NETWORKS + 1))
    return 0
  fi

  # Descoberta de hosts
  local discovered_ips=""

  if [[ "$FALLBACK_PING" == "false" ]]; then
    discovered_ips=$(scan_network_nmap "$cidr") || {
      log_warn "Scan nmap falhou para ${cidr} — tentando fallback ping"
      discovered_ips=$(scan_network_ping "$cidr") || {
        log_warn "Fallback ping também falhou para ${cidr} — pulando rede"
        COUNT_NETWORKS=$((COUNT_NETWORKS + 1))
        return 0
      }
    }
  else
    discovered_ips=$(scan_network_ping "$cidr") || {
      log_warn "Ping sweep falhou para ${cidr} — pulando rede"
      COUNT_NETWORKS=$((COUNT_NETWORKS + 1))
      return 0
    }
  fi

  if [[ -z "$discovered_ips" ]]; then
    log_warn "Nenhum host descoberto em ${cidr}"
    COUNT_NETWORKS=$((COUNT_NETWORKS + 1))
    return 0
  fi

  # Processar cada IP descoberto
  local ip
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue

    COUNT_HOSTS=$((COUNT_HOSTS + 1))
    log_info "Processando IP: ${ip}"

    # Resolver hostname
    local hostname
    hostname=$(resolve_hostname "$ip")
    log_verbose "Hostname resolvido para ${ip}: ${hostname}"

    # Verificar no NetBox
    NB_IP_ID=""
    NB_IP_STATUS=""
    nb_get_ip "${ip}/32" || {
      log_error "Falha ao consultar IP ${ip} no NetBox — pulando"
      COUNT_ERRORS=$((COUNT_ERRORS + 1))
      continue
    }

    if [[ -z "$NB_IP_ID" ]]; then
      # IP não existe — criar
      nb_create_ip "$ip" "$hostname" || true

    elif [[ "$NB_IP_STATUS" == "active" ]]; then
      # IP existe e já está ativo — pular
      log_skip "IP ${ip}/32 já registrado no NetBox com status=active"
      COUNT_SKIP=$((COUNT_SKIP + 1))

    else
      # IP existe com outro status — atualizar
      log_info "IP ${ip}/32 existe no NetBox com status=${NB_IP_STATUS} — atualizando"
      nb_update_ip "$NB_IP_ID" "$ip" "$hostname" || true
    fi

  done <<< "$discovered_ips"

  COUNT_NETWORKS=$((COUNT_NETWORKS + 1))
}

# =============================================================================
# VALIDAÇÕES PRÉ-EXECUÇÃO
# =============================================================================

validate_config() {
  local token_masked

  if [[ -z "$NETBOX_URL" ]]; then
    log_error "NETBOX_URL não definida. Use --netbox-url ou export NETBOX_URL=..."
    exit 1
  fi

  if [[ -z "$NETBOX_TOKEN" ]]; then
    log_error "NETBOX_TOKEN não definido. Use --token ou export NETBOX_TOKEN=..."
    exit 1
  fi

  # Mascarar token nos logs (primeiros 8 chars + ...)
  if [[ "${#NETBOX_TOKEN}" -gt 8 ]]; then
    token_masked="${NETBOX_TOKEN:0:8}..."
  else
    token_masked="${NETBOX_TOKEN}..."
  fi

  log_info "NetBox URL  : ${NETBOX_URL}"
  log_info "Token       : ${token_masked}"
  log_info "Insecure TLS: ${INSECURE}"
  log_info "Dry-run     : ${DRY_RUN}"
  log_info "Verbose     : ${VERBOSE}"
  log_info "Timeout ping: ${PING_TIMEOUT}s"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dryrun "Modo dry-run ativo — nenhuma alteração será feita no NetBox"
  fi

  # Teste de conectividade com a API
  log_info "Testando conectividade com a API do NetBox..."
  local api_base="${NETBOX_URL%/}/api"

  NB_LAST_HTTP_CODE=""
  nb_get "${api_base}/status/" > /dev/null || true

  if [[ "$NB_LAST_HTTP_CODE" != "200" ]]; then
    log_error "API do NetBox não acessível em ${api_base}/status/ — HTTP ${NB_LAST_HTTP_CODE:-000}"
    log_error "Verifique a URL e a conectividade de rede antes de continuar"
    exit 1
  fi

  log_info "API do NetBox acessível (HTTP 200)"
}

# =============================================================================
# CLEANUP
# =============================================================================

cleanup() {
  rm -f "${NB_RESPONSE_TMP}" 2>/dev/null || true
}

trap cleanup EXIT

# =============================================================================
# MAIN
# =============================================================================

main() {
  # Declarar array de redes customizadas (escopo global necessário para parse_args)
  declare -a CUSTOM_NETWORKS=()

  echo ""
  log_info "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} ==="
  log_info "Sincronizador de IPs do laboratório Proxmox → NetBox IPAM"
  echo ""

  parse_args "$@"
  check_deps
  validate_config

  # Determinar quais redes processar
  local -a networks_to_process=()

  if [[ ${#CUSTOM_NETWORKS[@]} -gt 0 ]]; then
    # Redes passadas como argumento CLI — sem descrição conhecida, usar "Custom Network"
    log_info "Usando redes customizadas passadas via argumento"
    local custom_cidr
    for custom_cidr in "${CUSTOM_NETWORKS[@]}"; do
      networks_to_process+=("${custom_cidr}|Custom Network|yes")
    done
  else
    # Usar redes padrão do laboratório
    log_info "Usando redes padrão do laboratório"
    networks_to_process=("${DEFAULT_NETWORKS[@]}")
  fi

  log_info "Total de redes a processar: ${#networks_to_process[@]}"

  # Processar cada rede
  local entry cidr description scan_active
  for entry in "${networks_to_process[@]}"; do
    IFS='|' read -r cidr description scan_active <<< "$entry"
    process_network "$cidr" "$description" "$scan_active" || {
      log_warn "Falha ao processar rede ${cidr} — continuando"
      COUNT_ERRORS=$((COUNT_ERRORS + 1))
    }
  done

  # Relatório final
  print_summary

  # Código de saída baseado em erros
  if [[ "$COUNT_ERRORS" -gt 0 ]]; then
    log_error "Sincronização concluída com ${COUNT_ERRORS} erro(s)"
    exit 1
  else
    log_info "Sincronização concluída com sucesso"
    exit 0
  fi
}

main "$@"
