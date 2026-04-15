terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.50"
    }
    netbox = {
      source  = "netbox-community/netbox"
      version = "~> 3.5"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_token_id}=${var.proxmox_token_secret}"
  insecure  = var.proxmox_tls_insecure

  ssh {
    agent       = false
    username    = "root"
    private_key = file(var.proxmox_ssh_private_key)
  }
}

# ─────────────────────────────────────────────────────────
# Nó Master (1x) — control-plane do cluster Kubernetes
# ─────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_vm" "k8s_master" {
  name      = "${var.cluster_name}-master-01"
  node_name = var.proxmox_node
  vm_id     = var.master_vmid
  tags      = ["k8s", "master", var.lab_id, var.environment]

  # Clona o template cloud-init definido em var.template_vmid
  clone {
    vm_id     = var.template_vmid
    node_name = var.proxmox_node
    full      = true   # clone completo (não linked clone)
    retries   = 3
  }

  # Habilita o agente QEMU para melhor integração com Proxmox
  agent {
    enabled = true
    trim    = true
  }

  cpu {
    cores   = var.master_cpu_cores
    sockets = 1
    type    = "x86-64-v2-AES"
    numa    = false
  }

  memory {
    dedicated = var.master_memory_mb
  }

  # Disco principal clonado do template
  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.master_disk_gb
    file_format  = "raw"
    discard      = "on"
    ssd          = true
    cache        = "writeback"
  }

  network_device {
    bridge   = var.network_bridge
    model    = "virtio"
    firewall = false
  }

  operating_system {
    type = "l26"   # Linux kernel 2.6+
  }

  # Cloud-init: injeta IP estático, gateway, DNS e chave SSH
  initialization {
    datastore_id = var.cloudinit_storage

    dns {
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        # IP alocado dinamicamente pelo NetBox IPAM (netbox.tf → local.netbox_master_ip)
        address = "${local.netbox_master_ip}/${var.network_prefix}"
        gateway = var.network_gateway
      }
    }

    user_account {
      username = var.vm_user
      keys     = [trimspace(file(var.ssh_public_key_file))]
    }
  }

  # Evita que mudanças no clone disparem recriação da VM
  lifecycle {
    ignore_changes = [clone, initialization[0].user_account[0].keys]
  }
}

# ─────────────────────────────────────────────────────────
# Nós Worker (2x por padrão) — data-plane do cluster
# ─────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_vm" "k8s_workers" {
  count     = var.worker_count
  name      = "${var.cluster_name}-worker-0${count.index + 1}"
  node_name = var.proxmox_node
  vm_id     = var.worker_vmid_start + count.index
  tags      = ["k8s", "worker", var.lab_id, var.environment]

  clone {
    vm_id     = var.template_vmid
    node_name = var.proxmox_node
    full      = true
    retries   = 3
  }

  agent {
    enabled = true
    trim    = true
  }

  cpu {
    cores   = var.worker_cpu_cores
    sockets = 1
    type    = "x86-64-v2-AES"
    numa    = false
  }

  memory {
    dedicated = var.worker_memory_mb
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.worker_disk_gb
    file_format  = "raw"
    discard      = "on"
    ssd          = true
    cache        = "writeback"
  }

  network_device {
    bridge   = var.network_bridge
    model    = "virtio"
    firewall = false
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = var.cloudinit_storage

    dns {
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        # IP alocado dinamicamente pelo NetBox IPAM (netbox.tf → local.netbox_worker_ips)
        address = "${local.netbox_worker_ips[count.index]}/${var.network_prefix}"
        gateway = var.network_gateway
      }
    }

    user_account {
      username = var.vm_user
      keys     = [trimspace(file(var.ssh_public_key_file))]
    }
  }

  lifecycle {
    ignore_changes = [clone, initialization[0].user_account[0].keys]
  }
}
