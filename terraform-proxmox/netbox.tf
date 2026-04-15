# =============================================================================
# netbox.tf — Integração IPAM + CMDB com o NetBox
#
# Fluxo:
#   1. data "external" consulta IPs disponíveis no NetBox (somente leitura)
#   2. netbox_ip_address reserva os IPs alocando-os no IPAM
#   3. proxmox_virtual_environment_vm usa os IPs reservados (em main.tf)
#   4. netbox_virtual_machine registra cada VM no CMDB do NetBox
#   5. netbox_interface + netbox_primary_ip associam IPs às interfaces das VMs
# =============================================================================

# ─────────────────────────────────────────────────────────
# Configuração do provider NetBox
# ─────────────────────────────────────────────────────────
provider "netbox" {
  server_url           = var.netbox_url
  api_token            = var.netbox_token
  allow_insecure_https = var.netbox_insecure
}

# ─────────────────────────────────────────────────────────
# Consulta de IPs disponíveis via script externo (somente leitura)
# Solicita: 1 master + worker_count workers = worker_count+1 no total
# ─────────────────────────────────────────────────────────
data "external" "available_ips" {
  program = ["bash", "${path.module}/../scripts/netbox-get-available-ips.sh"]

  query = {
    netbox_url   = var.netbox_url
    netbox_token = var.netbox_token
    prefix_cidr  = var.network_cidr
    count        = tostring(var.worker_count + 1)
    insecure     = tostring(var.netbox_insecure)
  }
}

# ─────────────────────────────────────────────────────────
# Locals: extrai IPs e ID do prefixo do resultado do script
# ─────────────────────────────────────────────────────────
locals {
  netbox_master_ip  = data.external.available_ips.result["ip_0"]
  netbox_worker_ips = [for i in range(var.worker_count) : data.external.available_ips.result["ip_${i + 1}"]]
  netbox_prefix_id  = tonumber(data.external.available_ips.result["prefix_id"])
}

# ─────────────────────────────────────────────────────────
# Cluster Type: "Kubernetes" no NetBox
# ─────────────────────────────────────────────────────────
resource "netbox_cluster_type" "kubernetes" {
  name = "Kubernetes"
}

# ─────────────────────────────────────────────────────────
# Cluster Kubernetes — representa o cluster inteiro no NetBox
# ─────────────────────────────────────────────────────────
resource "netbox_cluster" "k8s" {
  name            = var.cluster_name
  cluster_type_id = netbox_cluster_type.kubernetes.id
  tags            = [var.lab_id, var.environment]
}

# ─────────────────────────────────────────────────────────
# IPAM — Reserva o IP do nó master
# lifecycle.ignore_changes evita recriação se o IP já foi alocado
# ─────────────────────────────────────────────────────────
resource "netbox_ip_address" "master" {
  ip_address  = "${local.netbox_master_ip}/${var.network_prefix}"
  status      = "active"
  description = "${var.cluster_name}-master-01"
  tags        = [var.lab_id, var.environment]

  lifecycle {
    ignore_changes = [ip_address]
  }
}

# ─────────────────────────────────────────────────────────
# IPAM — Reserva os IPs dos nós worker
# ─────────────────────────────────────────────────────────
resource "netbox_ip_address" "workers" {
  count       = var.worker_count
  ip_address  = "${local.netbox_worker_ips[count.index]}/${var.network_prefix}"
  status      = "active"
  description = "${var.cluster_name}-worker-0${count.index + 1}"
  tags        = [var.lab_id, var.environment]

  lifecycle {
    ignore_changes = [ip_address]
  }
}

# ─────────────────────────────────────────────────────────
# CMDB — VM do nó master
# depends_on garante que a VM existe no Proxmox antes do registro
# ─────────────────────────────────────────────────────────
resource "netbox_virtual_machine" "k8s_master" {
  name       = proxmox_virtual_environment_vm.k8s_master.name
  cluster_id = netbox_cluster.k8s.id
  status     = "active"
  vcpus      = var.master_cpu_cores
  memory_mb  = var.master_memory_mb
  disk_gb    = var.master_disk_gb
  platform   = "Ubuntu 22.04"
  comments   = "K8s control-plane — provisionado via Terraform | lab_id=${var.lab_id} | env=${var.environment} | managed_by=terraform | project=hybrid-infra | owner=jose.mussauer"
  tags       = [var.lab_id, var.environment, "k8s", "master"]

  depends_on = [proxmox_virtual_environment_vm.k8s_master]
}

# ─────────────────────────────────────────────────────────
# Interface de rede do nó master no NetBox
# ─────────────────────────────────────────────────────────
resource "netbox_interface" "k8s_master" {
  name               = "eth0"
  virtual_machine_id = netbox_virtual_machine.k8s_master.id
}

# IP associado à interface do master (referencia o IP já reservado)
resource "netbox_ip_address" "master_iface" {
  ip_address                   = netbox_ip_address.master.ip_address
  status                       = "active"
  virtual_machine_interface_id = netbox_interface.k8s_master.id

  lifecycle {
    ignore_changes = [ip_address]
  }
}

# Define o IP primário da VM master no NetBox
resource "netbox_primary_ip" "k8s_master" {
  virtual_machine_id = netbox_virtual_machine.k8s_master.id
  ip_address_id      = netbox_ip_address.master_iface.id
}

# ─────────────────────────────────────────────────────────
# CMDB — VMs dos nós worker
# ─────────────────────────────────────────────────────────
resource "netbox_virtual_machine" "k8s_workers" {
  count      = var.worker_count
  name       = proxmox_virtual_environment_vm.k8s_workers[count.index].name
  cluster_id = netbox_cluster.k8s.id
  status     = "active"
  vcpus      = var.worker_cpu_cores
  memory_mb  = var.worker_memory_mb
  disk_gb    = var.worker_disk_gb
  platform   = "Ubuntu 22.04"
  comments   = "K8s worker-0${count.index + 1} — provisionado via Terraform | lab_id=${var.lab_id} | env=${var.environment} | managed_by=terraform | project=hybrid-infra | owner=jose.mussauer"
  tags       = [var.lab_id, var.environment, "k8s", "worker"]

  depends_on = [proxmox_virtual_environment_vm.k8s_workers]
}

# ─────────────────────────────────────────────────────────
# Interfaces de rede dos workers no NetBox
# ─────────────────────────────────────────────────────────
resource "netbox_interface" "k8s_workers" {
  count              = var.worker_count
  name               = "eth0"
  virtual_machine_id = netbox_virtual_machine.k8s_workers[count.index].id
}

# IPs associados às interfaces dos workers
resource "netbox_ip_address" "workers_iface" {
  count                        = var.worker_count
  ip_address                   = netbox_ip_address.workers[count.index].ip_address
  status                       = "active"
  virtual_machine_interface_id = netbox_interface.k8s_workers[count.index].id

  lifecycle {
    ignore_changes = [ip_address]
  }
}

# Define o IP primário de cada worker no NetBox
resource "netbox_primary_ip" "k8s_workers" {
  count              = var.worker_count
  virtual_machine_id = netbox_virtual_machine.k8s_workers[count.index].id
  ip_address_id      = netbox_ip_address.workers_iface[count.index].id
}
