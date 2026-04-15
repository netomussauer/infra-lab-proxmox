# infra-lab-proxmox

Laboratório de infraestrutura híbrida: provisionamento de cluster Kubernetes e stack CI/CD em Proxmox usando Terraform e Ansible.

---

## Estrutura do projeto

```
infra-lab-proxmox/
├── .claudecode.md                        ← Instruções globais para o assistente
├── README.md                             ← Este arquivo
├── README.infraestructure.md             ← Referência de acesso ao ambiente Proxmox
│
├── terraform-proxmox/                    ← Stack: Cluster Kubernetes
│   ├── main.tf                           ← Provider bpg/proxmox + recursos de VM
│   ├── variables.tf                      ← Todas as variáveis de entrada
│   ├── outputs.tf                        ← Outputs individuais + ansible_vars JSON
│   └── terraform.tfvars.example
│
├── ansible-k8s/                          ← Stack: Cluster Kubernetes
│   ├── ansible.cfg
│   ├── site.yml
│   ├── group_vars/all.yml                ← K8s 1.29, Calico, CIDRs, sysctl
│   ├── inventory/
│   │   ├── hosts.yml.tpl
│   │   └── generate_inventory.sh
│   └── playbooks/
│       ├── 01-prepare-nodes.yml
│       ├── 02-install-containerd.yml
│       ├── 03-install-kubeadm.yml
│       ├── 04-init-master.yml
│       └── 05-join-workers.yml
│
├── terraform-cicd/                       ← Stack: CI/CD (Gitea + Registry)
│   ├── main.tf                           ← 1 VM consolidada (VMID 210)
│   ├── variables.tf
│   ├── outputs.tf                        ← gitea_url, registry_url, ansible_vars
│   └── terraform.tfvars.example
│
└── ansible-cicd/                         ← Stack: CI/CD (Gitea + Registry)
    ├── ansible.cfg
    ├── site.yml
    ├── group_vars/all.yml                ← versões, portas, diretórios
    ├── inventory/
    │   ├── hosts.yml.tpl
    │   └── generate_inventory.sh
    ├── playbooks/
    │   ├── 01-prepare-node.yml           ← APT, swap off, sysctl, diretórios
    │   ├── 02-install-docker.yml         ← Docker Engine + Compose plugin
    │   ├── 03-deploy-stack.yml           ← docker compose (Gitea + Registry)
    │   └── 04-configure-runner.yml       ← Gitea Act Runner via systemd
    └── templates/
        ├── docker-compose.yml.j2         ← memory limits para 4 GB de RAM
        ├── gitea-app.ini.j2              ← SQLite, Actions habilitado
        └── registry-config.yml.j2
```

---

## Fluxo de execução

### Stack Kubernetes

```bash
source ~/.env.proxmox
cd terraform-proxmox
cp terraform.tfvars.example terraform.tfvars   # preencher credenciais
terraform init && terraform plan -out=tfplan.binary && terraform apply tfplan.binary
cd ../ansible-k8s
bash inventory/generate_inventory.sh
ansible-playbook -i inventory/hosts.yml site.yml
```

### Stack CI/CD

```bash
source ~/.env.proxmox
cd terraform-cicd
cp terraform.tfvars.example terraform.tfvars   # preencher credenciais
terraform init && terraform plan -out=tfplan.binary && terraform apply tfplan.binary
cd ../ansible-cicd
bash inventory/generate_inventory.sh
ansible-playbook -i inventory/hosts.yml site.yml
# Registrar runner (após criar token no Gitea UI em /user/settings/applications)
ansible-playbook -i inventory/hosts.yml site.yml --tags runner \
  -e "gitea_runner_token=SEU_TOKEN"
```

---

## Topologia de VMs

### Cluster Kubernetes

| Nó | Hostname | IP | VMID | vCPU | RAM | Disco |
|----|----------|----|------|------|-----|-------|
| Master | `k8s-master-01` | `10.10.0.10` | 200 | 2 | 4 GB | 30 GB |
| Worker 1 | `k8s-worker-01` | `10.10.0.11` | 201 | 2 | 4 GB | 50 GB |
| Worker 2 | `k8s-worker-02` | `10.10.0.12` | 202 | 2 | 4 GB | 50 GB |

**Stack:** Kubernetes 1.29 · containerd · Calico CNI v3.27 · Ubuntu 22.04

### Servidor CI/CD

| Serviço                   | Host             | IP            | VMID | vCPU | RAM  | Disco |
|---------------------------|------------------|---------------|------|------|------|-------|
| Gitea + Runner + Registry | `cicd-server-01` | `10.10.0.20`  | 210  | 2    | 4 GB | 40 GB |

**Serviços (Docker):** Gitea 1.21 (`:3000`) · Docker Registry v2 (`:5000`) · Act Runner 0.2.6
**Memory limits:** Gitea 512 MB · Registry 128 MB · SO + Runner ~1.3 GB restante

---

## Changelog

### 2026-04-14 — Stack CI/CD

#### Terraform (`terraform-cicd/`)

Stack CI/CD consolidada em 1 VM (recursos escassos de laboratório):

- **`main.tf`** — Provisiona `cicd-server-01` (VMID 210, 2 vCPU, 4 GB RAM, 40 GB, IP 10.10.0.20). Mesmo padrão de provider, cloud-init e `lifecycle` do terraform-proxmox. Tags: `cicd`, `gitea`, `lab_id`, `environment`.
- **`variables.tf`** — Reutiliza as 16 variáveis de conexão Proxmox e adiciona 9 específicas da stack: `cicd_vmid`, `cicd_ip`, `cicd_cpu_cores`, `cicd_memory_mb`, `cicd_disk_gb`, `gitea_domain`, `gitea_http_port`, `gitea_ssh_port`, `registry_port`.
- **`outputs.tf`** — `cicd_ip`, `cicd_hostname`, `cicd_vmid`, `gitea_url`, `registry_url` e `ansible_vars` JSON para consumo pelo inventário.
- **`terraform.tfvars.example`** — Valores de referência com instruções de `TF_VAR_*`.

#### Ansible (`ansible-cicd/`)

- **`ansible.cfg`** — Espelho do ansible-k8s com `forks = 5` (VM única).
- **`group_vars/all.yml`** — Versões Gitea 1.21, Act Runner 0.2.6, Registry 2.8; portas e diretórios `/opt/cicd/*`.
- **`inventory/`** — Mesmo padrão `hosts.yml.tpl` + `generate_inventory.sh` adaptado para único host `cicd-server-01`, lendo de `../../terraform-cicd`.
- **`playbooks/01-prepare-node.yml`** — APT, swap off, criação de `/opt/cicd/{gitea-data,registry-data}`, sysctl `vm.max_map_count` e `fs.file-max`.
- **`playbooks/02-install-docker.yml`** — Docker Engine via repositório oficial, `docker-compose-plugin`, usuário adicionado ao grupo `docker`.
- **`playbooks/03-deploy-stack.yml`** — Renderiza os 3 templates Jinja2, `community.docker.docker_compose_v2`, aguarda Gitea (`:3000`, 30 retries) e Registry (`:5000/v2/`, 15 retries). Handler de recreate acionado por mudança nos templates.
- **`playbooks/04-configure-runner.yml`** — Baixa binário `act_runner`, registra via `--no-interactive` com token passado por `-e gitea_runner_token=...`, unidade systemd completa.
- **`templates/docker-compose.yml.j2`** — Memory limits: Gitea 512M/256M reserva, Registry 128M/64M. `GITEA__actions__ENABLED=true`. Healthchecks em ambos os serviços.
- **`templates/gitea-app.ini.j2`** — SQLite (sem DB externo), Gitea Actions habilitado, `OFFLINE_MODE`, log Warn, sem e-mail, sem Gravatar.
- **`templates/registry-config.yml.j2`** — Registry v2 mínimo com delete habilitado e cache in-memory.

---

### 2026-04-13 — Criação inicial do projeto

#### Terraform (`terraform-proxmox/`)

- **`main.tf`** — Configuração do provider `bpg/proxmox ~> 0.50` com autenticação via API Token e chave SSH. Recursos `proxmox_virtual_environment_vm` para 1 nó master (VMID 200) e 2 workers (VMID 201–202) com clone completo do template cloud-init. IPs estáticos, gateway, DNS e chave SSH injetados via bloco `initialization`. `lifecycle.ignore_changes` em `clone` e `user_account.keys` para evitar recriação em plans subsequentes.

- **`variables.tf`** — Todas as variáveis de entrada com descrições, tipos e defaults. Validações em `environment` (`dev|staging|prod`) e `worker_count` (`>= 1`). Variáveis sensíveis marcadas com `sensitive = true`: `proxmox_token_id`, `proxmox_token_secret`.

- **`outputs.tf`** — Outputs individuais (`master_ip`, `master_hostname`, `master_vmid`, `worker_ips`, `worker_hostnames`, `worker_vmids`, `vm_user`, `ssh_private_key`, `cluster_name`, `kubeconfig_path`) e output composto `ansible_vars` em JSON via `jsonencode()` para consumo direto pelo `generate_inventory.sh`.

- **`terraform.tfvars.example`** — Arquivo de exemplo com todos os parâmetros comentados. Serve como referência para preencher o `.tfvars` real (que não é versionado).

#### Ansible (`ansible-k8s/`)

- **`ansible.cfg`** — Configuração com `pipelining = True`, fact caching em JSON, SSH ControlMaster/ControlPersist, `stdout_callback = yaml`, `callbacks_enabled = profile_tasks, timer`.

- **`group_vars/all.yml`** — Variáveis globais: `kubernetes_version: "1.29"`, `containerd_version: "1.7.*"`, `pod_network_cidr: "192.168.0.0/16"` (Calico), `service_cidr: "10.96.0.0/12"`, `calico_version: "v3.27.0"`, kernel modules e parâmetros sysctl.

- **`inventory/hosts.yml.tpl`** — Template YAML com placeholders `{{...}}` para master e workers. Inclui `ansible_user`, `ansible_ssh_private_key_file`, `cluster_name`, `lab_id`, `environment`.

- **`inventory/generate_inventory.sh`** — Script Bash que lê `terraform output -raw ansible_vars`, parseia com `jq`, substitui placeholders no template via `sed` e `python3` (para o bloco multiline de workers), e valida o YAML gerado.

- **`site.yml`** — Orquestrador com `import_playbook` para cada fase. Tags `prepare`, `containerd`, `kubeadm`, `master`, `workers` permitem execução parcial.

- **`playbooks/01-prepare-nodes.yml`** — Atualização APT, instalação de dependências base, `swapoff -a`, remoção do swap do `/etc/fstab`, serviço systemd para desativar swap no boot, `modprobe overlay br_netfilter`, configuração sysctl via `ansible.posix.sysctl`, sincronização NTP.

- **`playbooks/02-install-containerd.yml`** — Repositório Docker (fonte do `containerd.io`), instalação com versão fixada, geração da config padrão via `containerd config default`, habilitação de `SystemdCgroup = true` e `sandbox_image = "registry.k8s.io/pause:3.9"`, handler de restart.

- **`playbooks/03-install-kubeadm.yml`** — Chave GPG e repositório `pkgs.k8s.io/core:/stable:/v1.29`, instalação de `kubeadm`, `kubelet`, `kubectl`, marcação como `hold` via `dpkg_selections`, habilitação do `kubelet`.

- **`playbooks/04-init-master.yml`** — `kubeadm init` com `--pod-network-cidr` e `--service-cidr`, configuração do kubeconfig para o usuário ansible, `wait_for` na porta 6443, aplicação do manifesto Calico, espera por `node.status.Ready`, geração e salvamento do join command.

- **`playbooks/05-join-workers.yml`** — Leitura do join command do master via `slurp`, execução idempotente do `kubeadm join` (guarded por `stat /etc/kubernetes/kubelet.conf`), espera por `Ready` em cada worker, exibição do status final do cluster.

#### Configuração do repositório

- **`.gitignore`** — Proteção de `terraform.tfvars`, `.terraform/`, `*.tfstate*`, `hosts.yml` (gerado), chaves SSH e arquivos de ambiente.
- **`.claudecode.md`** — Instruções globais para o assistente: estrutura do projeto, fluxo de execução, regras de operação, IPs padrão e pré-requisitos.
- **`README.infraestructure.md`** — Referência completa do ambiente Proxmox: URLs de acesso, topologia de rede, bridges, storage, templates disponíveis, padrão de credenciais e checklist de pré-operação.
