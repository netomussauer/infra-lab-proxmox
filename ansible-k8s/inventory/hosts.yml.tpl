---
# ─────────────────────────────────────────────────────────
# hosts.yml.tpl — Template do inventário Ansible
# Este arquivo é usado pelo generate_inventory.sh para gerar
# o inventário real (hosts.yml) a partir dos outputs do Terraform.
# NÃO edite hosts.yml diretamente — sempre regenere via script.
# ─────────────────────────────────────────────────────────

all:
  vars:
    ansible_user: "{{VM_USER}}"
    ansible_ssh_private_key_file: "{{SSH_PRIVATE_KEY}}"
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
    cluster_name: "{{CLUSTER_NAME}}"
    lab_id: "{{LAB_ID}}"
    environment: "{{ENVIRONMENT}}"

  children:
    masters:
      hosts:
        {{MASTER_HOSTNAME}}:
          ansible_host: "{{MASTER_IP}}"

    workers:
      hosts:
{{WORKER_HOSTS}}
