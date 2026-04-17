# Stack CI/CD

Provisionamento do servidor CI/CD em Proxmox via Terraform (`terraform-cicd/`) e configuração via Ansible (`ansible-cicd/`). Stack consolidada em 1 VM por restrição de recursos de laboratório.

---

## Topologia

| Serviço | Host | IP | VMID | vCPU | RAM | Disco |
|---------|------|----|------|------|-----|-------|
| Gitea + Runner + Registry | `cicd-server-01` | `10.10.0.20` | 210 | 2 | 4 GB | 40 GB |

**Serviços (Docker Compose):**
- Gitea 1.21 — porta `:3000` (HTTP) / `:2222` (SSH)
- Docker Registry v2 — porta `:5000`
- Act Runner 0.2.6 — systemd unit

**Memory limits:** Gitea 512 MB · Registry 128 MB · SO + Runner ~1.3 GB restante

---

## Pré-requisitos

```bash
# Variáveis de ambiente Proxmox
source ~/.env.proxmox

# Variáveis NetBox
export TF_VAR_netbox_token="seu-token"
export NETBOX_TOKEN="seu-token"

# Dependências Ansible
ansible-galaxy collection install netbox.netbox community.docker
pip install pynetbox
```

---

## Fluxo de execução

```bash
# 1. Provisionar VM via Terraform
cd terraform-cicd
cp terraform.tfvars.example terraform.tfvars   # preencher credenciais
terraform init
terraform plan -out=tfplan.binary
terraform apply tfplan.binary

# 2. Gerar inventário Ansible
cd ../ansible-cicd
bash inventory/generate_inventory.sh

# 3. Executar todos os playbooks
ansible-playbook -i inventory/hosts.yml site.yml

# 4. Registrar runner (após criar token no Gitea UI em /user/settings/applications)
ansible-playbook -i inventory/hosts.yml site.yml --tags runner \
  -e "gitea_runner_token=SEU_TOKEN"
```

---

## Terraform (`terraform-cicd/`)

| Arquivo | Descrição |
|---------|-----------|
| `main.tf` | Provisiona `cicd-server-01` (VMID 210, 2 vCPU, 4 GB RAM, 40 GB, IP `10.10.0.20`). Mesmo padrão de provider, cloud-init e `lifecycle` do `terraform-proxmox`. Tags: `cicd`, `gitea`, `lab_id`, `environment`. |
| `variables.tf` | 16 variáveis de conexão Proxmox + 9 específicas da stack: `cicd_vmid`, `cicd_ip`, `cicd_cpu_cores`, `cicd_memory_mb`, `cicd_disk_gb`, `gitea_domain`, `gitea_http_port`, `gitea_ssh_port`, `registry_port`. |
| `outputs.tf` | `cicd_ip`, `cicd_hostname`, `cicd_vmid`, `gitea_url`, `registry_url` e `ansible_vars` JSON para consumo pelo inventário. |
| `netbox.tf` | Registra `cicd-server-01` com tags `cicd`/`gitea`/`registry` e 3 serviços: Gitea HTTP (:3000), Gitea SSH (:2222), Registry (:5000). |
| `terraform.tfvars.example` | Referência de todos os parâmetros com instruções de `TF_VAR_*`. |

---

## Ansible (`ansible-cicd/`)

| Playbook | Tag | Descrição |
|----------|-----|-----------|
| `01-prepare-node.yml` | `prepare` | APT, swap off, criação de `/opt/cicd/{gitea-data,registry-data}`, sysctl `vm.max_map_count` e `fs.file-max`. |
| `02-install-docker.yml` | `docker` | Docker Engine via repositório oficial, `docker-compose-plugin`, usuário adicionado ao grupo `docker`. |
| `03-deploy-stack.yml` | `stack` | Renderiza os 3 templates Jinja2, `community.docker.docker_compose_v2`, aguarda Gitea (`:3000`, 30 retries) e Registry (`:5000/v2/`, 15 retries). Handler de recreate acionado por mudança nos templates. |
| `04-configure-runner.yml` | `runner` | Baixa binário `act_runner`, registra via `--no-interactive` com token passado por `-e gitea_runner_token=...`, unidade systemd completa. |
| `05-register-netbox.yml` | `netbox` | Registra `cicd-server-01` no NetBox via `netbox.netbox` collection com tags `cicd`/`gitea`/`registry` e serviços associados. |

### Templates Jinja2 (`templates/`)

| Template | Descrição |
|----------|-----------|
| `docker-compose.yml.j2` | Memory limits: Gitea 512M/256M reserva, Registry 128M/64M. `GITEA__actions__ENABLED=true`. Healthchecks em ambos os serviços. |
| `gitea-app.ini.j2` | SQLite (sem DB externo), Gitea Actions habilitado, `OFFLINE_MODE`, log Warn, sem e-mail, sem Gravatar. |
| `registry-config.yml.j2` | Registry v2 mínimo com delete habilitado e cache in-memory. |

### Configurações globais (`group_vars/all.yml`)

```yaml
gitea_version: "1.21"
act_runner_version: "0.2.6"
registry_version: "2.8"
gitea_http_port: 3000
gitea_ssh_port: 2222
registry_port: 5000
cicd_base_dir: "/opt/cicd"
```

---

## Configurações do repositório

| Arquivo | Descrição |
|---------|-----------|
| `ansible.cfg` | `forks = 5` (VM única), demais configs espelham `ansible-k8s`. |
| `inventory/generate_inventory.sh` | Lê outputs do `terraform-cicd`, gera `hosts.yml` para único host `cicd-server-01`. |
