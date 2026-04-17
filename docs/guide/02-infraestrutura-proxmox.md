# Infraestrutura Proxmox — Referência de Acesso e Operação

> Arquivo de referência para acesso e operação do ambiente Proxmox de laboratório em rede local.
> Mantenha este arquivo atualizado sempre que houver mudanças no ambiente.
> **Nunca armazene senhas ou tokens diretamente neste arquivo.**

---

## Identificação do Laboratório

| Campo | Valor |
|-------|-------|
| **Lab ID** | `lab-proxmox-01` |
| **Responsável** | `jose.mussauer` |
| **Finalidade** | Laboratório de infraestrutura híbrida (IaC, Kubernetes, automação) |
| **Ambiente** | `dev` |
| **Localização** | Rede local — homelab / datacenter interno |

---

## Acesso ao Cluster Proxmox

### Interface Web (UI)

| Campo | Valor |
|-------|-------|
| **URL** | `https://<PROXMOX_IP>:8006` |
| **IP do nó principal** | `<PROXMOX_IP>` — ex: `192.168.1.10` |
| **Porta** | `8006` (HTTPS) |
| **Realm de autenticação** | `pve` (local) ou `<DOMÍNIO>` (AD/LDAP) |
| **Usuário de acesso** | `<USUÁRIO>@pve` — ex: `admin@pve` |
| **Credencial** | Armazenada em `~/.env.proxmox` ou cofre de senhas |

> Para acessar: abra `https://<PROXMOX_IP>:8006` no navegador e aceite o certificado self-signed do lab.

### API REST

| Campo | Valor |
|-------|-------|
| **Endpoint base** | `https://<PROXMOX_IP>:8006/api2/json` |
| **Autenticação** | API Token (preferencial) ou ticket de sessão |
| **Token ID** | `<USUÁRIO>@pve!<TOKEN_NAME>` — ex: `admin@pve!terraform` |
| **Token secret** | Armazenado em variável de ambiente `PROXMOX_API_TOKEN_SECRET` |

**Exemplo de autenticação via API Token:**

```bash
export PROXMOX_URL="https://<PROXMOX_IP>:8006/api2/json"
export PROXMOX_USER="admin@pve"
export PROXMOX_TOKEN_ID="admin@pve!terraform"
export PROXMOX_TOKEN_SECRET="<TOKEN_SECRET>"

curl -sk \
  -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "${PROXMOX_URL}/version" | jq .
```

### SSH (acesso direto ao hypervisor)

| Campo | Valor |
|-------|-------|
| **Host** | `<PROXMOX_IP>` |
| **Porta** | `22` |
| **Usuário** | `root` |
| **Autenticação** | Chave SSH (`~/.ssh/id_ed25519_proxmox`) |

```bash
ssh root@<PROXMOX_IP> -i ~/.ssh/id_ed25519_proxmox
```

---

## Topologia de Rede

### Subnets do laboratório

| Rede | CIDR | Gateway | Função |
|------|------|---------|--------|
| Management | `192.168.1.0/24` | `192.168.1.1` | Acesso à UI e API do Proxmox |
| VMs Lab | `10.10.0.0/24` | `10.10.0.1` | VMs de laboratório geral |
| Kubernetes | `10.20.0.0/24` | `10.20.0.1` | Nós do cluster Kubernetes |
| Storage | `10.30.0.0/24` | — | Tráfego de storage (NFS, Ceph, iSCSI) |

### Bridges Proxmox (interfaces virtuais)

| Bridge | Interface física | VLAN | Finalidade |
|--------|-----------------|------|------------|
| `vmbr0` | `<NIC_FÍSICA>` | — | Rede de management / WAN |
| `vmbr1` | `<NIC_FÍSICA>` | — | Rede interna de VMs |
| `vmbr2` | — | trunk | Rede de storage (se aplicável) |

> Editar conforme configuração real do host Proxmox em: **Datacenter → Node → Network**

---

## Nós do Cluster

| Nome do nó | IP | CPU | RAM | Função |
|------------|-----|-----|-----|--------|
| `pve-node01` | `192.168.1.10` | `<MODELO>` / `<N>` cores | `<N>` GB | Nó primário |
| `pve-node02` | `192.168.1.11` | `<MODELO>` / `<N>` cores | `<N>` GB | Nó secundário |

> Verificar nós ativos: `pvecm status` (via SSH no nó primário)

---

## Storage

| ID | Tipo | Caminho / Endereço | Conteúdo | Tamanho |
|----|------|--------------------|---------|---------|
| `local` | dir | `/var/lib/vz` | ISO, templates, backups | `<N>` GB |
| `local-lvm` | LVM-Thin | `pve/data` | VM disks, CT volumes | `<N>` GB |
| `nfs-lab` | NFS | `<NFS_SERVER>:/mnt/lab` | Backups, ISOs compartilhados | `<N>` GB |
| `ceph-pool` | RBD | — | VM disks (HA) | `<N>` GB |

> Verificar storage disponível: `pvesm status` (via SSH) ou UI em **Datacenter → Storage**

---

## Templates e ISOs disponíveis

### Cloud-Init Templates (para provisionamento automatizado)

| Template ID | Nome | OS | Notas |
|-------------|------|----|-------|
| `9000` | `ubuntu-2204-cloudinit` | Ubuntu 22.04 LTS | Base para VMs Kubernetes |
| `9001` | `debian-12-cloudinit` | Debian 12 | Base para VMs de serviço |
| `9002` | `rocky-9-cloudinit` | Rocky Linux 9 | Base para VMs on-prem RHEL-like |

### ISOs disponíveis (storage `local`)

| Arquivo | OS | Uso |
|---------|----|-----|
| `ubuntu-22.04-live-server.iso` | Ubuntu 22.04 | Instalação manual |
| `debian-12.iso` | Debian 12 | Instalação manual |
| `proxmox-ve_<versão>.iso` | Proxmox VE | Reinstalação do hypervisor |

---

## Credenciais e Secrets

> **Nunca armazene valores reais neste arquivo.**
> Use um dos métodos abaixo para carregar as credenciais antes de executar automações.

### Arquivo de variáveis de ambiente (desenvolvimento local)

Crie o arquivo `~/.env.proxmox` com o seguinte conteúdo e carregue com `source ~/.env.proxmox`:

```bash
# ~/.env.proxmox — NÃO versionar este arquivo (.gitignore)
export PROXMOX_URL="https://<PROXMOX_IP>:8006/api2/json"
export PROXMOX_USER="admin@pve"
export PROXMOX_TOKEN_ID="admin@pve!terraform"
export PROXMOX_TOKEN_SECRET="<TOKEN_SECRET_AQUI>"
export PROXMOX_NODE="pve-node01"
export PROXMOX_SSH_HOST="<PROXMOX_IP>"
export PROXMOX_SSH_USER="root"
export PROXMOX_SSH_KEY="~/.ssh/id_ed25519_proxmox"
```

### Integrações com IaC

**Terraform (`terraform/providers.tf`):**

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.50"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_url
  api_token = "${var.proxmox_token_id}=${var.proxmox_token_secret}"
  insecure  = true   # certificado self-signed no lab
  ssh {
    agent       = true
    username    = "root"
    private_key = file("~/.ssh/id_ed25519_proxmox")
  }
}
```

**Ansible (`ansible/inventory/lab.yml`):**

```yaml
all:
  children:
    proxmox:
      hosts:
        pve-node01:
          ansible_host: "{{ lookup('env', 'PROXMOX_SSH_HOST') }}"
          ansible_user: root
          ansible_ssh_private_key_file: "~/.ssh/id_ed25519_proxmox"
```

---

## Comandos de operação rápida

### Verificação do ambiente

```bash
# Status geral do cluster
ssh root@<PROXMOX_IP> pvecm status

# Listar VMs e containers
ssh root@<PROXMOX_IP> qm list        # VMs (QEMU)
ssh root@<PROXMOX_IP> pct list       # Containers (LXC)

# Status dos storages
ssh root@<PROXMOX_IP> pvesm status

# Status dos serviços Proxmox
ssh root@<PROXMOX_IP> systemctl status pve-cluster pvedaemon pveproxy pvestatd

# Verificar conectividade com a API
curl -sk \
  -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "${PROXMOX_URL}/nodes" | jq '.data[].node'
```

### Criação de VM via CLI (referência rápida)

```bash
# Clonar template cloud-init para nova VM
ssh root@<PROXMOX_IP> \
  qm clone 9000 <VMID> \
    --name <NOME_VM> \
    --full true \
    --storage local-lvm

# Configurar cloud-init
ssh root@<PROXMOX_IP> \
  qm set <VMID> \
    --ipconfig0 ip=<IP>/24,gw=<GATEWAY> \
    --ciuser ubuntu \
    --sshkeys ~/.ssh/authorized_keys \
    --cores 2 --memory 2048

# Iniciar VM
ssh root@<PROXMOX_IP> qm start <VMID>
```

---

## Contexto para automações

| Parâmetro | Valor padrão |
|-----------|-------------|
| Nó padrão para novas VMs | `pve-node01` |
| Storage padrão para discos | `local-lvm` |
| Storage padrão para ISOs | `local` |
| Bridge de rede padrão | `vmbr1` |
| VMID range do lab | `100` – `999` |
| Template base Linux | `9000` (Ubuntu 22.04 cloud-init) |
| Usuário cloud-init padrão | `ubuntu` |
| Chave SSH para VMs | `~/.ssh/id_ed25519_proxmox.pub` |
| Tags obrigatórias nas VMs | `lab_id=lab-proxmox-01`, `lab_owner=jose.mussauer` |

---

## Checklist de pré-requisitos

Antes de executar automações contra este ambiente, verifique:

```
[ ] Variáveis de ambiente carregadas (source ~/.env.proxmox)
[ ] Conectividade com o host Proxmox (ping <PROXMOX_IP>)
[ ] API acessível (curl -sk ${PROXMOX_URL}/version)
[ ] Chave SSH configurada (~/.ssh/id_ed25519_proxmox)
[ ] Provider Terraform inicializado (terraform init)
[ ] Inventário Ansible acessível (ansible -i inventory/ proxmox -m ping)
[ ] Storage com espaço disponível para novas VMs
[ ] VMID desejado disponível (não em uso no cluster)
```
