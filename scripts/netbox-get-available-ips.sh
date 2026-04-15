#!/usr/bin/env bash
# =============================================================================
# netbox-get-available-ips.sh
# External data source para Terraform: consulta o IPAM do NetBox e retorna
# os próximos IPs disponíveis num prefixo, sem alocá-los (somente leitura).
#
# Entrada (JSON via stdin — campos do Terraform external data source):
#   netbox_url   : URL base da API, ex: http://10.10.0.5:8000
#   netbox_token : API Token do NetBox
#   prefix_cidr  : Prefixo CIDR, ex: 10.10.0.0/24
#   count        : Número de IPs a retornar
#   insecure     : "true" para ignorar verificação TLS
#
# Saída (JSON):
#   {
#     "ips_csv":   "10.10.0.10,10.10.0.11",
#     "ip_0":      "10.10.0.10",
#     "ip_1":      "10.10.0.11",
#     "prefix_id": "42"
#   }
#
# Código de saída:
#   0 = sucesso
#   1 = erro fatal (prefixo não encontrado, IPs insuficientes, auth falhou)
# =============================================================================

set -euo pipefail

# ─── Validação de dependências ────────────────────────────────────────────────
for dep in curl jq; do
  if ! command -v "$dep" &>/dev/null; then
    echo "{\"error\": \"Dependência ausente: $dep\"}" >&2
    exit 1
  fi
done

# ─── Ler entrada JSON do stdin ────────────────────────────────────────────────
INPUT="$(cat)"

netbox_url="$(echo "$INPUT"   | jq -r '.netbox_url')"
netbox_token="$(echo "$INPUT" | jq -r '.netbox_token')"
prefix_cidr="$(echo "$INPUT"  | jq -r '.prefix_cidr')"
count="$(echo "$INPUT"        | jq -r '.count')"
insecure="$(echo "$INPUT"     | jq -r '.insecure')"

# ─── Validação de campos obrigatórios ────────────────────────────────────────
for field_name in netbox_url netbox_token prefix_cidr count; do
  field_value="$(echo "$INPUT" | jq -r ".$field_name")"
  if [[ -z "$field_value" || "$field_value" == "null" ]]; then
    echo "{\"error\": \"Campo obrigatório ausente: $field_name\"}" >&2
    exit 1
  fi
done

# ─── Configurar flags curl ────────────────────────────────────────────────────
CURL_OPTS=(-s -f -H "Authorization: Token ${netbox_token}" -H "Content-Type: application/json")
if [[ "${insecure}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

NETBOX_API="${netbox_url%/}/api"

# ─── Etapa 1: Localizar o ID do prefixo ──────────────────────────────────────
PREFIX_ENCODED="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$prefix_cidr" 2>/dev/null \
  || printf '%s' "$prefix_cidr" | sed 's|/|%2F|g')"

PREFIX_RESPONSE="$(curl "${CURL_OPTS[@]}" \
  "${NETBOX_API}/ipam/prefixes/?prefix=${PREFIX_ENCODED}&limit=1" 2>/dev/null)" || {
  echo "{\"error\": \"Falha ao consultar prefixos no NetBox — verifique URL e token\"}" >&2
  exit 1
}

PREFIX_COUNT="$(echo "$PREFIX_RESPONSE" | jq -r '.count // 0')"
if [[ "$PREFIX_COUNT" -lt 1 ]]; then
  echo "{\"error\": \"Prefixo '${prefix_cidr}' não encontrado no NetBox IPAM\"}" >&2
  exit 1
fi

PREFIX_ID="$(echo "$PREFIX_RESPONSE" | jq -r '.results[0].id')"
if [[ -z "$PREFIX_ID" || "$PREFIX_ID" == "null" ]]; then
  echo "{\"error\": \"Não foi possível extrair o ID do prefixo '${prefix_cidr}'\"}" >&2
  exit 1
fi

# ─── Etapa 2: Consultar IPs disponíveis (somente leitura) ────────────────────
AVAILABLE_RESPONSE="$(curl "${CURL_OPTS[@]}" \
  "${NETBOX_API}/ipam/prefixes/${PREFIX_ID}/available-ips/?limit=${count}" 2>/dev/null)" || {
  echo "{\"error\": \"Falha ao consultar IPs disponíveis para o prefixo ID ${PREFIX_ID}\"}" >&2
  exit 1
}

AVAILABLE_COUNT="$(echo "$AVAILABLE_RESPONSE" | jq 'length')"
if [[ "$AVAILABLE_COUNT" -lt "$count" ]]; then
  echo "{\"error\": \"IPs insuficientes: solicitados ${count}, disponíveis ${AVAILABLE_COUNT} no prefixo ${prefix_cidr}\"}" >&2
  exit 1
fi

# ─── Etapa 3: Extrair apenas o endereço IP (sem prefixo CIDR) ────────────────
# A API retorna "address": "10.10.0.10/24" — extraímos apenas a parte antes de "/"
AVAILABLE_IPS="$(echo "$AVAILABLE_RESPONSE" \
  | jq -r --argjson n "$count" '.[0:$n] | .[].address | split("/")[0]')"

# Converter para array bash
readarray -t IP_ARRAY <<< "$AVAILABLE_IPS"

# ─── Etapa 4: Montar JSON de saída ────────────────────────────────────────────
# O Terraform external data source exige que todos os valores sejam strings
OUTPUT="{}"
OUTPUT="$(echo "$OUTPUT" | jq --arg v "$PREFIX_ID" '. + {"prefix_id": $v}')"

IPS_CSV="$(IFS=','; echo "${IP_ARRAY[*]}")"
OUTPUT="$(echo "$OUTPUT" | jq --arg v "$IPS_CSV" '. + {"ips_csv": $v}')"

for i in "${!IP_ARRAY[@]}"; do
  key="ip_${i}"
  OUTPUT="$(echo "$OUTPUT" | jq --arg k "$key" --arg v "${IP_ARRAY[$i]}" '. + {($k): $v}')"
done

echo "$OUTPUT"
