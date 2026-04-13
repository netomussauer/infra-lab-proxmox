# infra-lab-proxmox

Laboratório de infraestrutura híbrida: provisionamento de cluster Kubernetes em Proxmox usando Terraform e Ansible.

---

## Estrutura do projeto

```
infra-lab-proxmox/
├── .claudecode.md                        ← Instruções globais para o assistente
├── README.md                             ← Este arquivo
├── README.infraestructure.md             ← Referência de acesso ao ambiente Proxmox
├── terraform-proxmox/
│   ├── main.tf                           ← Provider bpg/proxmox + recursos de VM
│   ├── variables.tf                      ← Todas as variáveis de entrada
│   ├── outputs.tf                        ← Outputs individuais + ansible_vars JSON
│   └── terraform.tfvars.example          ← Valores de exemplo (não versionar .tfvars real)
└── ansible-k8s/
    ├── ansible.cfg                       ← Configuração do Ansible
    ├── site.yml                          ← Playbook principal (orquestra todos os demais)
    ├── group_vars/
    │   └── all.yml                       ← Variáveis globais (versões, CIDRs, sysctl)
    ├── inventory/
    │   ├── hosts.yml.tpl                 ← Template do inventário
    │   └── generate_inventory.sh         ← Gera hosts.yml a partir do terraform output
    └── playbooks/
        ├── 01-prepare-nodes.yml          ← Swap off, kernel modules, sysctl
        ├── 02-install-containerd.yml     ← Runtime de containers
        ├── 03-install-kubeadm.yml        ← kubeadm, kubelet, kubectl v1.29
        ├── 04-init-master.yml            ← kubeadm init + Calico CNI
        └── 05-join-workers.yml           ← kubeadm join nos workers
```

---

## Fluxo de execução

```bash
# 1. Preencher variáveis reais
cp terraform-proxmox/terraform.tfvars.example terraform-proxmox/terraform.tfvars
# editar terraform.tfvars com IPs, token e credenciais reais

# 2. Carregar credenciais Proxmox
source ~/.env.proxmox

# 3. Provisionar VMs com Terraform
cd terraform-proxmox
terraform init
terraform plan
terraform apply

# 4. Gerar inventário Ansible dinamicamente
cd ../ansible-k8s
bash inventory/generate_inventory.sh

# 5. Instalar e configurar o cluster Kubernetes
ansible-playbook -i inventory/hosts.yml site.yml
```

---

## Topologia do cluster

| Nó | Hostname | IP | VMID | vCPU | RAM | Disco |
|----|----------|----|------|------|-----|-------|
| Master | `k8s-master-01` | `10.10.0.10` | 200 | 2 | 4 GB | 30 GB |
| Worker 1 | `k8s-worker-01` | `10.10.0.11` | 201 | 2 | 4 GB | 50 GB |
| Worker 2 | `k8s-worker-02` | `10.10.0.12` | 202 | 2 | 4 GB | 50 GB |

**Stack:** Kubernetes 1.29 · containerd · Calico CNI v3.27 · Ubuntu 22.04 cloud-init

---

## Changelog

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
