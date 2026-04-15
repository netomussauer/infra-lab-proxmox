# =============================================================================
# netbox.tf — Integração IPAM + CMDB com o NetBox (stack CI/CD)
#
# Fluxo:
#   1. data "external" consulta 1 IP disponível no NetBox (somente leitura)
#   2. netbox_ip_address reserva o IP no IPAM
#   3. proxmox_virtual_environment_vm usa o IP reservado (em main.tf)
#   4. netbox_virtual_machine registra cicd-server-01 no CMDB
#   5. netbox_interface + netbox_primary_ip associam o IP à interface
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
# Consulta de 1 IP disponível via script externo (somente leitura)
# ─────────────────────────────────────────────────────────
data "external" "available_ip" {
  program = ["bash", "${path.module}/../scripts/netbox-get-available-ips.sh"]

  query = {
    netbox_url   = var.netbox_url
    netbox_token = var.netbox_token
    prefix_cidr  = var.network_cidr
    count        = "1"
    insecure     = tostring(var.netbox_insecure)
  }
}

# ─────────────────────────────────────────────────────────
# Local: extrai o IP e ID do prefixo do resultado do script
# ─────────────────────────────────────────────────────────
locals {
  netbox_cicd_ip   = data.external.available_ip.result["ip_0"]
  netbox_prefix_id = tonumber(data.external.available_ip.result["prefix_id"])
}

# ─────────────────────────────────────────────────────────
# IPAM — Reserva o IP da VM CI/CD
# lifecycle.ignore_changes evita recriação se o IP já foi alocado
# ─────────────────────────────────────────────────────────
resource "netbox_ip_address" "cicd" {
  ip_address  = "${local.netbox_cicd_ip}/${var.network_prefix}"
  status      = "active"
  description = "cicd-server-01"
  tags        = [var.lab_id, var.environment]

  lifecycle {
    ignore_changes = [ip_address]
  }
}

# ─────────────────────────────────────────────────────────
# CMDB — VM do servidor CI/CD
# depends_on garante que a VM existe no Proxmox antes do registro
# ─────────────────────────────────────────────────────────
resource "netbox_virtual_machine" "cicd" {
  name      = proxmox_virtual_environment_vm.cicd_server.name
  status    = "active"
  vcpus     = var.cicd_cpu_cores
  memory_mb = var.cicd_memory_mb
  disk_gb   = var.cicd_disk_gb
  platform  = "Ubuntu 22.04"
  comments  = "Stack CI/CD (Gitea + Registry + Act Runner) — provisionado via Terraform | lab_id=${var.lab_id} | env=${var.environment} | managed_by=terraform | project=hybrid-infra | owner=jose.mussauer"
  tags      = [var.lab_id, var.environment, "cicd", "gitea"]

  depends_on = [proxmox_virtual_environment_vm.cicd_server]
}

# ─────────────────────────────────────────────────────────
# Interface de rede da VM CI/CD no NetBox
# ─────────────────────────────────────────────────────────
resource "netbox_interface" "cicd" {
  name               = "eth0"
  virtual_machine_id = netbox_virtual_machine.cicd.id
}

# IP associado à interface (referencia o IP já reservado acima)
resource "netbox_ip_address" "cicd_iface" {
  ip_address                   = netbox_ip_address.cicd.ip_address
  status                       = "active"
  virtual_machine_interface_id = netbox_interface.cicd.id

  lifecycle {
    ignore_changes = [ip_address]
  }
}

# Define o IP primário da VM CI/CD no NetBox
resource "netbox_primary_ip" "cicd" {
  virtual_machine_id = netbox_virtual_machine.cicd.id
  ip_address_id      = netbox_ip_address.cicd_iface.id
}
