---
# ─────────────────────────────────────────────────────────
# hosts.yml.tpl — Template do inventário Ansible (CI/CD)
# Este arquivo é usado pelo generate_inventory.sh para gerar
# o inventário real (hosts.yml) a partir dos outputs do Terraform.
# NÃO edite hosts.yml diretamente — sempre regenere via script.
# ─────────────────────────────────────────────────────────

all:
  vars:
    ansible_user: "{{VM_USER}}"
    ansible_ssh_private_key_file: "{{SSH_PRIVATE_KEY}}"
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
    lab_id: "{{LAB_ID}}"
    environment: "{{ENVIRONMENT}}"

  children:
    cicd_servers:
      hosts:
        {{CICD_HOSTNAME}}:
          ansible_host: "{{CICD_IP}}"
          gitea_domain: "{{GITEA_DOMAIN}}"
          gitea_http_port: {{GITEA_HTTP_PORT}}
          gitea_ssh_port: {{GITEA_SSH_PORT}}
          registry_port: {{REGISTRY_PORT}}
