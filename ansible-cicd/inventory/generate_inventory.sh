#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# generate_inventory.sh
# Gera o inventário Ansible (hosts.yml) a partir dos outputs
# do Terraform da stack CI/CD. Deve ser executado após
# `terraform apply` em terraform-cicd/.
#
# Uso:
#   cd ansible-cicd
#   bash inventory/generate_inventory.sh
#
# Pré-requisitos:
#   - jq >= 1.6
#   - terraform CLI no PATH
#   - Ter executado `terraform apply` em ../../terraform-cicd
# ─────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/../../terraform-cicd" && pwd)"
OUTPUT_FILE="${SCRIPT_DIR}/hosts.yml"
TEMPLATE_FILE="${SCRIPT_DIR}/hosts.yml.tpl"

# ── Verificações de pré-requisitos ───────────────────────
command -v jq        >/dev/null 2>&1 || { echo "[ERRO] jq nao encontrado. Instale com: apt install jq"; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "[ERRO] terraform nao encontrado no PATH"; exit 1; }

if [[ ! -d "${TERRAFORM_DIR}" ]]; then
  echo "[ERRO] Diretorio terraform-cicd nao encontrado: ${TERRAFORM_DIR}"
  exit 1
fi

if [[ ! -f "${TERRAFORM_DIR}/terraform.tfstate" ]]; then
  echo "[ERRO] terraform.tfstate nao encontrado em ${TERRAFORM_DIR}"
  echo "       Execute 'terraform apply' primeiro."
  exit 1
fi

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
  echo "[ERRO] Template nao encontrado: ${TEMPLATE_FILE}"
  exit 1
fi

echo "[INFO] Lendo outputs do Terraform em: ${TERRAFORM_DIR}"

# ── Extrair o bloco JSON do output ansible_vars ──────────
ANSIBLE_VARS=$(cd "${TERRAFORM_DIR}" && terraform output -raw ansible_vars 2>/dev/null)

if [[ -z "${ANSIBLE_VARS}" ]]; then
  echo "[ERRO] Output 'ansible_vars' vazio. Verifique se o terraform apply foi concluido."
  exit 1
fi

# ── Parsear campos do JSON com jq ─────────────────────────
CICD_HOSTNAME=$(echo "${ANSIBLE_VARS}"   | jq -r '.cicd_hostname')
CICD_IP=$(echo "${ANSIBLE_VARS}"         | jq -r '.cicd_ip')
VM_USER=$(echo "${ANSIBLE_VARS}"         | jq -r '.vm_user')
SSH_PRIVATE_KEY=$(echo "${ANSIBLE_VARS}" | jq -r '.ssh_private_key')
LAB_ID=$(echo "${ANSIBLE_VARS}"          | jq -r '.lab_id')
ENVIRONMENT=$(echo "${ANSIBLE_VARS}"     | jq -r '.environment')
GITEA_DOMAIN=$(echo "${ANSIBLE_VARS}"    | jq -r '.gitea_domain')
GITEA_HTTP_PORT=$(echo "${ANSIBLE_VARS}" | jq -r '.gitea_http_port')
GITEA_SSH_PORT=$(echo "${ANSIBLE_VARS}"  | jq -r '.gitea_ssh_port')
REGISTRY_PORT=$(echo "${ANSIBLE_VARS}"   | jq -r '.registry_port')

# ── Validar campos obrigatorios ───────────────────────────
for field in CICD_HOSTNAME CICD_IP VM_USER SSH_PRIVATE_KEY LAB_ID ENVIRONMENT GITEA_DOMAIN; do
  if [[ -z "${!field}" || "${!field}" == "null" ]]; then
    echo "[ERRO] Campo obrigatorio ausente no output ansible_vars: ${field}"
    exit 1
  fi
done

echo "[INFO] Host CI/CD: ${CICD_HOSTNAME} (${CICD_IP})"
echo "[INFO] Gitea URL: http://${CICD_IP}:${GITEA_HTTP_PORT}"
echo "[INFO] Registry: ${CICD_IP}:${REGISTRY_PORT}"

# ── Substituir placeholders no template ──────────────────
sed \
  -e "s|{{CICD_HOSTNAME}}|${CICD_HOSTNAME}|g" \
  -e "s|{{CICD_IP}}|${CICD_IP}|g" \
  -e "s|{{VM_USER}}|${VM_USER}|g" \
  -e "s|{{SSH_PRIVATE_KEY}}|${SSH_PRIVATE_KEY}|g" \
  -e "s|{{LAB_ID}}|${LAB_ID}|g" \
  -e "s|{{ENVIRONMENT}}|${ENVIRONMENT}|g" \
  -e "s|{{GITEA_DOMAIN}}|${GITEA_DOMAIN}|g" \
  -e "s|{{GITEA_HTTP_PORT}}|${GITEA_HTTP_PORT}|g" \
  -e "s|{{GITEA_SSH_PORT}}|${GITEA_SSH_PORT}|g" \
  -e "s|{{REGISTRY_PORT}}|${REGISTRY_PORT}|g" \
  "${TEMPLATE_FILE}" > "${OUTPUT_FILE}"

# ── Validar YAML gerado ───────────────────────────────────
if python3 -c "import yaml; yaml.safe_load(open('${OUTPUT_FILE}'))" 2>/dev/null; then
  echo "[OK] Inventario gerado com sucesso: ${OUTPUT_FILE}"
else
  echo "[AVISO] hosts.yml foi gerado mas pode conter erros de YAML — verifique manualmente."
fi

echo ""
echo "Para testar a conectividade:"
echo "  cd ansible-cicd && ansible all -i ${OUTPUT_FILE} -m ping"
echo ""
echo "Para executar a stack completa:"
echo "  ansible-playbook -i ${OUTPUT_FILE} site.yml"
