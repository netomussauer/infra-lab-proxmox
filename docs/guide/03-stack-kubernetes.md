# Stack Kubernetes

Provisionamento do cluster Kubernetes em Proxmox via Terraform (`terraform-proxmox/`) e configuração via Ansible (`ansible-k8s/`).

---

## Topologia

| Nó | Hostname | IP | VMID | vCPU | RAM | Disco |
|----|----------|----|------|------|-----|-------|
| Master | `k8s-master-01` | `10.10.0.10` | 200 | 2 | 4 GB | 30 GB |
| Worker 1 | `k8s-worker-01` | `10.10.0.11` | 201 | 2 | 4 GB | 50 GB |
| Worker 2 | `k8s-worker-02` | `10.10.0.12` | 202 | 2 | 4 GB | 50 GB |

**Stack:** Kubernetes 1.29 · containerd 1.7 · Calico CNI v3.27 · Ubuntu 22.04

---

## Pré-requisitos

```bash
# Variáveis de ambiente Proxmox
source ~/.env.proxmox

# Variáveis NetBox (para registro IPAM)
export TF_VAR_netbox_token="seu-token"
export NETBOX_TOKEN="seu-token"

# Dependências Ansible
ansible-galaxy collection install netbox.netbox
pip install pynetbox

# NetBox deve ter o prefixo 10.10.0.0/24 criado no IPAM
# Token NetBox com permissões: ipam.prefix (read), ipam.ipaddress (write), virtualization.* (write)
```

---

## Fluxo de execução

```bash
# 1. Provisionar VMs via Terraform
cd terraform-proxmox
cp terraform.tfvars.example terraform.tfvars   # preencher credenciais
terraform init
terraform plan -out=tfplan.binary
terraform apply tfplan.binary

# 2. Gerar inventário Ansible a partir dos outputs do Terraform
cd ../ansible-k8s
bash inventory/generate_inventory.sh

# 3. Executar todos os playbooks
ansible-playbook -i inventory/hosts.yml site.yml

# Execução parcial por tag
ansible-playbook -i inventory/hosts.yml site.yml --tags prepare
ansible-playbook -i inventory/hosts.yml site.yml --tags containerd
ansible-playbook -i inventory/hosts.yml site.yml --tags kubeadm
ansible-playbook -i inventory/hosts.yml site.yml --tags master
ansible-playbook -i inventory/hosts.yml site.yml --tags workers
ansible-playbook -i inventory/hosts.yml site.yml --tags netbox
```

---

## Terraform (`terraform-proxmox/`)

| Arquivo | Descrição |
|---------|-----------|
| `main.tf` | Provider `bpg/proxmox ~> 0.50`, recursos `proxmox_virtual_environment_vm` para master (VMID 200) e workers (VMID 201–202). Clone completo do template cloud-init com IPs estáticos via bloco `initialization`. `lifecycle.ignore_changes` em `clone` e `user_account.keys`. |
| `variables.tf` | Variáveis com descrições, tipos e defaults. Validações em `environment` (`dev\|staging\|prod`) e `worker_count` (`>= 1`). Variáveis sensíveis: `proxmox_token_id`, `proxmox_token_secret`. |
| `outputs.tf` | Outputs individuais (`master_ip`, `master_hostname`, `master_vmid`, `worker_ips`, `worker_hostnames`, `worker_vmids`, `vm_user`, `ssh_private_key`, `cluster_name`, `kubeconfig_path`) e `ansible_vars` JSON via `jsonencode()`. |
| `netbox.tf` | Provider `netbox-community/netbox ~> 3.5`, `data "external" "available_ips"` (chama script de consulta), recursos `netbox_ip_address`, `netbox_cluster_type`, `netbox_cluster`, `netbox_virtual_machine`, `netbox_interface`, `netbox_primary_ip`. |
| `terraform.tfvars.example` | Referência de todos os parâmetros. O `.tfvars` real não é versionado. |

---

## Ansible (`ansible-k8s/`)

| Playbook | Tag | Descrição |
|----------|-----|-----------|
| `01-prepare-nodes.yml` | `prepare` | Atualização APT, dependências base, `swapoff -a`, remoção do swap do `/etc/fstab`, serviço systemd para desativar swap no boot, `modprobe overlay br_netfilter`, sysctl via `ansible.posix.sysctl`, NTP. |
| `02-install-containerd.yml` | `containerd` | Repositório Docker, instalação com versão fixada, config padrão via `containerd config default`, `SystemdCgroup = true`, `sandbox_image = "registry.k8s.io/pause:3.9"`, handler de restart. |
| `03-install-kubeadm.yml` | `kubeadm` | Chave GPG e repositório `pkgs.k8s.io/core:/stable:/v1.29`, instalação de `kubeadm`, `kubelet`, `kubectl`, marcação como `hold`, habilitação do `kubelet`. |
| `04-init-master.yml` | `master` | `kubeadm init` com `--pod-network-cidr` e `--service-cidr`, kubeconfig para o usuário ansible, `wait_for` na porta 6443, manifesto Calico, espera por `node.status.Ready`, geração e salvamento do join command. |
| `05-join-workers.yml` | `workers` | Leitura do join command via `slurp`, `kubeadm join` idempotente (guarded por `stat /etc/kubernetes/kubelet.conf`), espera por `Ready` em cada worker, status final do cluster. |
| `06-register-netbox.yml` | `netbox` | Atualiza cada nó no NetBox via `netbox.netbox` collection com `k8s_role: control-plane\|worker`, associa IP à interface, debug final com link de verificação. |

### Configurações globais (`group_vars/all.yml`)

```yaml
kubernetes_version: "1.29"
containerd_version: "1.7.*"
pod_network_cidr: "192.168.0.0/16"   # Calico
service_cidr: "10.96.0.0/12"
calico_version: "v3.27.0"
```

### Geração de inventário

`inventory/generate_inventory.sh` lê `terraform output -raw ansible_vars`, parseia com `jq`, substitui placeholders no `hosts.yml.tpl` via `sed` e `python3`, e valida o YAML gerado.

---

## Configurações do repositório

| Arquivo | Descrição |
|---------|-----------|
| `.gitignore` | Protege `terraform.tfvars`, `.terraform/`, `*.tfstate*`, `hosts.yml` (gerado), chaves SSH e arquivos de ambiente. |
| `ansible.cfg` | `pipelining = True`, fact caching em JSON, SSH ControlMaster/ControlPersist, `stdout_callback = yaml`, `callbacks_enabled = profile_tasks, timer`. |
