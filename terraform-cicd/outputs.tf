# ─────────────────────────────────────────────────────────
# Outputs da stack CI/CD
# Estes valores são consumidos pelo script generate_inventory.sh
# para gerar automaticamente o inventário Ansible.
# ─────────────────────────────────────────────────────────

output "cicd_ip" {
  description = "IP da VM do servidor CI/CD"
  value       = var.cicd_ip
}

output "cicd_hostname" {
  description = "Hostname da VM CI/CD conforme registrado no Proxmox"
  value       = proxmox_virtual_environment_vm.cicd_server.name
}

output "cicd_vmid" {
  description = "VMID da VM CI/CD no Proxmox"
  value       = proxmox_virtual_environment_vm.cicd_server.vm_id
}

output "gitea_url" {
  description = "URL HTTP de acesso ao Gitea"
  value       = "http://${var.cicd_ip}:${var.gitea_http_port}"
}

output "registry_url" {
  description = "Endereço do Docker Registry v2 (host:porta)"
  value       = "${var.cicd_ip}:${var.registry_port}"
}

output "vm_user" {
  description = "Usuário SSH criado via cloud-init na VM CI/CD"
  value       = var.vm_user
}

output "ssh_private_key" {
  description = "Caminho da chave SSH privada para acesso à VM CI/CD"
  value       = var.proxmox_ssh_private_key
}

# Output estruturado em JSON para consumo pelo generate_inventory.sh
output "ansible_vars" {
  description = "Bloco JSON com todas as variáveis necessárias para o inventário Ansible da stack CI/CD"
  value = jsonencode({
    cicd_hostname   = proxmox_virtual_environment_vm.cicd_server.name
    cicd_ip         = var.cicd_ip
    vm_user         = var.vm_user
    ssh_private_key = var.proxmox_ssh_private_key
    lab_id          = var.lab_id
    environment     = var.environment
    gitea_domain    = var.gitea_domain
    gitea_http_port = var.gitea_http_port
    gitea_ssh_port  = var.gitea_ssh_port
    registry_port   = var.registry_port
  })
}
