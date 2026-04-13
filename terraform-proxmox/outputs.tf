# ─────────────────────────────────────────────────────────
# Outputs do cluster Kubernetes
# Estes valores são consumidos pelo script generate_inventory.sh
# para gerar automaticamente o inventário Ansible.
# ─────────────────────────────────────────────────────────

output "master_ip" {
  description = "IP do nó master do cluster Kubernetes"
  value       = var.master_ip
}

output "master_hostname" {
  description = "Hostname do nó master conforme registrado no Proxmox"
  value       = proxmox_virtual_environment_vm.k8s_master.name
}

output "master_vmid" {
  description = "VMID do nó master no Proxmox"
  value       = proxmox_virtual_environment_vm.k8s_master.vm_id
}

output "worker_ips" {
  description = "Lista de IPs dos nós worker em ordem de índice"
  value       = var.worker_ips
}

output "worker_hostnames" {
  description = "Lista de hostnames dos nós worker"
  value       = proxmox_virtual_environment_vm.k8s_workers[*].name
}

output "worker_vmids" {
  description = "Lista de VMIDs dos workers no Proxmox"
  value       = proxmox_virtual_environment_vm.k8s_workers[*].vm_id
}

output "vm_user" {
  description = "Usuário SSH criado via cloud-init em todas as VMs"
  value       = var.vm_user
}

output "ssh_private_key" {
  description = "Caminho da chave SSH privada para acesso às VMs"
  value       = var.proxmox_ssh_private_key
}

output "cluster_name" {
  description = "Nome do cluster Kubernetes provisionado"
  value       = var.cluster_name
}

output "kubeconfig_path" {
  description = "Caminho sugerido para salvar o kubeconfig após a instalação"
  value       = "~/.kube/config-${var.cluster_name}-lab"
}

# Output estruturado em JSON para consumo pelo generate_inventory.sh
output "ansible_vars" {
  description = "Bloco JSON com todas as variáveis necessárias para o inventário Ansible"
  value = jsonencode({
    cluster_name    = var.cluster_name
    master_ip       = var.master_ip
    master_hostname = proxmox_virtual_environment_vm.k8s_master.name
    worker_ips      = var.worker_ips
    worker_hostnames = proxmox_virtual_environment_vm.k8s_workers[*].name
    vm_user         = var.vm_user
    ssh_private_key = var.proxmox_ssh_private_key
    lab_id          = var.lab_id
    environment     = var.environment
  })
}
