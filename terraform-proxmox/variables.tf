# ─────────────────────────────────────────────────────────
# Conexão com o Proxmox
# ─────────────────────────────────────────────────────────

variable "proxmox_endpoint" {
  description = "URL completa da API do Proxmox (ex: https://192.168.1.10:8006)"
  type        = string
}

variable "proxmox_token_id" {
  description = "ID do API Token no formato usuario@realm!nome (ex: admin@pve!terraform)"
  type        = string
  sensitive   = true
}

variable "proxmox_token_secret" {
  description = "Secret UUID do API Token gerado no Proxmox"
  type        = string
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Desabilita verificação de certificado TLS (true para cert self-signed do lab)"
  type        = bool
  default     = true
}

variable "proxmox_ssh_private_key" {
  description = "Caminho absoluto para a chave SSH privada de acesso root ao hypervisor"
  type        = string
  default     = "~/.ssh/id_ed25519_proxmox"
}

variable "proxmox_node" {
  description = "Nome do nó Proxmox onde as VMs serão provisionadas"
  type        = string
  default     = "pve-node01"
}

# ─────────────────────────────────────────────────────────
# Identificação do laboratório
# ─────────────────────────────────────────────────────────

variable "lab_id" {
  description = "Identificador único do laboratório para tags e rastreabilidade"
  type        = string
  default     = "lab-k8s-proxmox-01"
}

variable "environment" {
  description = "Ambiente de execução (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment deve ser: dev, staging ou prod."
  }
}

variable "cluster_name" {
  description = "Prefixo usado para nomear as VMs do cluster (ex: k8s → k8s-master-01)"
  type        = string
  default     = "k8s"
}

# ─────────────────────────────────────────────────────────
# Template e Storage
# ─────────────────────────────────────────────────────────

variable "template_vmid" {
  description = "VMID do template cloud-init Ubuntu 22.04 no Proxmox"
  type        = number
  default     = 9000
}

variable "storage_pool" {
  description = "Storage pool do Proxmox para os discos das VMs"
  type        = string
  default     = "local-lvm"
}

variable "cloudinit_storage" {
  description = "Storage onde o drive cloud-init será criado (pode ser o mesmo de storage_pool)"
  type        = string
  default     = "local-lvm"
}

# ─────────────────────────────────────────────────────────
# Rede
# ─────────────────────────────────────────────────────────

variable "network_bridge" {
  description = "Bridge de rede do Proxmox para conectar as VMs (ex: vmbr1)"
  type        = string
  default     = "vmbr1"
}

variable "network_gateway" {
  description = "IP do gateway padrão da rede das VMs"
  type        = string
  default     = "10.10.0.1"
}

variable "network_prefix" {
  description = "Prefixo da máscara CIDR da rede (ex: 24 para /24)"
  type        = string
  default     = "24"
}

variable "dns_servers" {
  description = "Lista de servidores DNS injetados via cloud-init"
  type        = list(string)
  default     = ["8.8.8.8", "1.1.1.1"]
}

variable "dns_domain" {
  description = "Domínio de busca DNS local"
  type        = string
  default     = "lab.local"
}

# ─────────────────────────────────────────────────────────
# Cloud-Init / SSH
# ─────────────────────────────────────────────────────────

variable "ssh_public_key_file" {
  description = "Caminho para o arquivo .pub da chave SSH injetada nas VMs via cloud-init"
  type        = string
  default     = "~/.ssh/id_ed25519_proxmox.pub"
}

variable "vm_user" {
  description = "Nome do usuário criado pelo cloud-init em todas as VMs"
  type        = string
  default     = "ubuntu"
}

# ─────────────────────────────────────────────────────────
# Nó Master
# ─────────────────────────────────────────────────────────

variable "master_vmid" {
  description = "VMID do nó master no Proxmox (deve ser único no cluster)"
  type        = number
  default     = 200
}

variable "master_ip" {
  description = "IP estático do nó master injetado via cloud-init"
  type        = string
  default     = "10.10.0.10"
}

variable "master_cpu_cores" {
  description = "Número de vCPUs alocadas ao nó master"
  type        = number
  default     = 2
}

variable "master_memory_mb" {
  description = "Memória RAM do nó master em MB (mínimo recomendado: 2048)"
  type        = number
  default     = 4096
}

variable "master_disk_gb" {
  description = "Tamanho do disco do nó master em GB"
  type        = number
  default     = 30
}

# ─────────────────────────────────────────────────────────
# Nós Worker
# ─────────────────────────────────────────────────────────

variable "worker_count" {
  description = "Número de nós worker a provisionar"
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 1
    error_message = "worker_count deve ser pelo menos 1."
  }
}

variable "worker_vmid_start" {
  description = "VMID inicial dos workers — incrementado por índice (201, 202, ...)"
  type        = number
  default     = 201
}

variable "worker_ips" {
  description = "Lista de IPs estáticos dos workers — deve ter exatamente worker_count entradas"
  type        = list(string)
  default     = ["10.10.0.11", "10.10.0.12"]
}

variable "worker_cpu_cores" {
  description = "Número de vCPUs alocadas a cada worker"
  type        = number
  default     = 2
}

variable "worker_memory_mb" {
  description = "Memória RAM de cada worker em MB"
  type        = number
  default     = 4096
}

variable "worker_disk_gb" {
  description = "Tamanho do disco de cada worker em GB"
  type        = number
  default     = 50
}
