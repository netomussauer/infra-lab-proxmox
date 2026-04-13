#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# generate_inventory.sh
# Gera o inventário Ansible (hosts.yml) a partir dos outputs
# do Terraform. Deve ser executado após `terraform apply`.
#
# Uso:
#   cd ansible-k8s
#   bash inventory/generate_inventory.sh
#
# Pré-requisitos:
#   - jq >= 1.6
#   - terraform CLI no PATH
#   - Ter executado `terraform apply` em ../terraform-proxmox
# ─────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/../../terraform-proxmox" && pwd)"
OUTPUT_FILE="${SCRIPT_DIR}/hosts.yml"
TEMPLATE_FILE="${SCRIPT_DIR}/hosts.yml.tpl"

# ── Verificações de pré-requisitos ───────────────────────
command -v jq    >/dev/null 2>&1 || { echo "[ERRO] jq não encontrado. Instale com: apt install jq"; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "[ERRO] terraform não encontrado no PATH"; exit 1; }

if [[ ! -d "${TERRAFORM_DIR}" ]]; then
  echo "[ERRO] Diretório terraform não encontrado: ${TERRAFORM_DIR}"
  exit 1
fi

if [[ ! -f "${TERRAFORM_DIR}/terraform.tfstate" ]]; then
  echo "[ERRO] terraform.tfstate não encontrado. Execute 'terraform apply' primeiro."
  exit 1
fi

echo "[INFO] Lendo outputs do Terraform em: ${TERRAFORM_DIR}"

# ── Extrair o bloco JSON do output ansible_vars ──────────
ANSIBLE_VARS=$(cd "${TERRAFORM_DIR}" && terraform output -raw ansible_vars 2>/dev/null)

if [[ -z "${ANSIBLE_VARS}" ]]; then
  echo "[ERRO] Output 'ansible_vars' vazio. Verifique se o terraform apply foi concluído."
  exit 1
fi

# ── Parsear campos do JSON ────────────────────────────────
CLUSTER_NAME=$(echo "${ANSIBLE_VARS}"    | jq -r '.cluster_name')
MASTER_IP=$(echo "${ANSIBLE_VARS}"       | jq -r '.master_ip')
MASTER_HOSTNAME=$(echo "${ANSIBLE_VARS}" | jq -r '.master_hostname')
VM_USER=$(echo "${ANSIBLE_VARS}"         | jq -r '.vm_user')
SSH_PRIVATE_KEY=$(echo "${ANSIBLE_VARS}" | jq -r '.ssh_private_key')
LAB_ID=$(echo "${ANSIBLE_VARS}"          | jq -r '.lab_id')
ENVIRONMENT=$(echo "${ANSIBLE_VARS}"     | jq -r '.environment')

# Parsear arrays de workers
mapfile -t WORKER_IPS       < <(echo "${ANSIBLE_VARS}" | jq -r '.worker_ips[]')
mapfile -t WORKER_HOSTNAMES < <(echo "${ANSIBLE_VARS}" | jq -r '.worker_hostnames[]')

# ── Montar bloco de hosts dos workers ────────────────────
WORKER_HOSTS=""
for i in "${!WORKER_HOSTNAMES[@]}"; do
  HOSTNAME="${WORKER_HOSTNAMES[$i]}"
  IP="${WORKER_IPS[$i]}"
  WORKER_HOSTS+="        ${HOSTNAME}:\n"
  WORKER_HOSTS+="          ansible_host: \"${IP}\"\n"
done

# ── Substituir placeholders no template ──────────────────
sed \
  -e "s|{{CLUSTER_NAME}}|${CLUSTER_NAME}|g" \
  -e "s|{{MASTER_IP}}|${MASTER_IP}|g" \
  -e "s|{{MASTER_HOSTNAME}}|${MASTER_HOSTNAME}|g" \
  -e "s|{{VM_USER}}|${VM_USER}|g" \
  -e "s|{{SSH_PRIVATE_KEY}}|${SSH_PRIVATE_KEY}|g" \
  -e "s|{{LAB_ID}}|${LAB_ID}|g" \
  -e "s|{{ENVIRONMENT}}|${ENVIRONMENT}|g" \
  "${TEMPLATE_FILE}" > "${OUTPUT_FILE}.tmp"

# Substituir o placeholder multiline dos workers
python3 - <<EOF
import re, sys

with open("${OUTPUT_FILE}.tmp") as f:
    content = f.read()

worker_block = """${WORKER_HOSTS}"""
# Remove trailing newline do placeholder
content = content.replace("{{WORKER_HOSTS}}\n", worker_block)

with open("${OUTPUT_FILE}", "w") as f:
    f.write(content)
EOF

rm -f "${OUTPUT_FILE}.tmp"

# ── Validar YAML gerado ───────────────────────────────────
if python3 -c "import yaml; yaml.safe_load(open('${OUTPUT_FILE}'))" 2>/dev/null; then
  echo "[OK] Inventário gerado com sucesso: ${OUTPUT_FILE}"
else
  echo "[AVISO] hosts.yml foi gerado mas pode conter erros de YAML — verifique manualmente."
fi

echo ""
echo "Para testar a conectividade:"
echo "  ansible all -i ${OUTPUT_FILE} -m ping"
