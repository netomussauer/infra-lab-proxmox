# Visão Geral do Projeto

Laboratório de infraestrutura híbrida: provisionamento de cluster Kubernetes e stack CI/CD em Proxmox usando Terraform e Ansible.

---

## Estrutura do projeto

```
infra-lab-proxmox/
├── .claudecode.md                        ← Instruções globais para o assistente
├── README.md                             ← Índice de documentação
│
├── docs/                                 ← Documentação do projeto
│   ├── adr/                              ← Decisões de arquitetura (ADR)
│   └── guide/                            ← Procedimentos técnicos
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

| Serviço | Host | IP | VMID | vCPU | RAM | Disco |
|---------|------|----|------|------|-----|-------|
| Gitea + Runner + Registry | `cicd-server-01` | `10.10.0.20` | 210 | 2 | 4 GB | 40 GB |

**Serviços (Docker):** Gitea 1.21 (`:3000`) · Docker Registry v2 (`:5000`) · Act Runner 0.2.6  
**Memory limits:** Gitea 512 MB · Registry 128 MB · SO + Runner ~1.3 GB restante

---

## Changelog

### 2026-04-16 — Integração BookStack (documentação automatizada)

Novo script standalone que varre todo o projeto, categoriza os arquivos como **ADR** ou **Procedimento Técnico** e publica no BookStack pré-existente no laboratório.

#### `scripts/bookstack-sync-docs.sh`

Script Bash invocado manualmente (ou via CI/CD) para sincronizar a documentação do projeto com o BookStack. Funcionalidades principais:

- **Mapeamento estático** de 30 arquivos do projeto para Shelf → Book, separando ADRs de Procedimentos Técnicos
- **Detecção de ADR** por diretório (`adr/`, `decisions/`) ou padrões de conteúdo (`## Decisão`, `# ADR-`, `Status: Accepted`)
- **Detecção de mudanças via SHA-256**: compara o hash atual do arquivo com o hash salvo em `scripts/.bookstack-sync-state.json`; arquivos inalterados recebem `[SKIP]`, alterados `[UPDATE]` e novos `[NEW]`
- **Idempotência de estrutura**: cria Shelf e Books apenas se não existirem, com cache em memória para evitar GETs repetidos
- **Formatação automática de conteúdo**: `.md` publicado como markdown puro; `.tf`, `.yml`, `.sh` embrulhados em blocos de código com syntax highlight correto
- **Flags**: `--dry-run` (simula sem escrever), `--verbose`, `--force` (ignora hash, republica tudo), `--state-file <path>`, `--project-root <path>`

**Pré-requisitos:**

```bash
export BOOKSTACK_URL="http://10.10.0.6:80"
export BOOKSTACK_TOKEN_ID="seu-token-id"
export BOOKSTACK_TOKEN_SECRET="seu-token-secret"

bash scripts/bookstack-sync-docs.sh [--dry-run] [--verbose] [--force]
```

---

### 2026-04-14 — Integração NetBox IPAM + CMDB

Toda VM provisionada agora consulta e registra endereços no NetBox antes de aplicar configurações de rede. Ver [05-netbox-bookstack.md](05-netbox-bookstack.md) para detalhes.

---

### 2026-04-14 — Stack CI/CD

Stack CI/CD consolidada em 1 VM. Ver [04-stack-cicd.md](04-stack-cicd.md) para detalhes.

---

### 2026-04-13 — Criação inicial do projeto

Stack Kubernetes provisionada via Terraform + Ansible. Ver [03-stack-kubernetes.md](03-stack-kubernetes.md) para detalhes.
