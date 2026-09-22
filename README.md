# infra-lab-proxmox (descontinuado)

> **Este repositório foi descontinuado em 2026-09-22 e arquivado (read-only).**
> Era o design original do laboratório (kubeadm + Calico + Docker Compose,
> rede `10.10.0.0/24`) e nunca chegou a ser o ambiente implantado de fato.
> O ambiente real está em
> [`infra-lab`](https://github.com/netomussauer/infra-lab) (K3s + Flannel +
> MetalLB, rede `192.168.1.0/24`). As duas ferramentas ativas daqui —
> `bookstack-sync` e os scripts de NetBox — foram migradas e adaptadas para
> lá (`scripts/bookstack-sync/`, `scripts/netbox-*.sh`). Ver
> [`infra-lab` ADR-014](https://github.com/netomussauer/infra-lab/blob/main/docs/adr.md#adr-014)
> para o racional completo.

Laboratório de infraestrutura híbrida: cluster Kubernetes e stack CI/CD em Proxmox via Terraform e Ansible.

---

## Documentação

### Procedimentos Técnicos (`docs/guide/`)

| # | Documento |
| --- | --- |
| 01 | [Visão Geral do Projeto](docs/guide/01-visao-geral.md) |
| 02 | [Infraestrutura Proxmox — Acesso e Operação](docs/guide/02-infraestrutura-proxmox.md) |
| 03 | [Stack Kubernetes](docs/guide/03-stack-kubernetes.md) |
| 04 | [Stack CI/CD](docs/guide/04-stack-cicd.md) |
| 05 | [NetBox IPAM e BookStack](docs/guide/05-netbox-bookstack.md) |

### Decisões de Arquitetura (`docs/adr/`)

| Documento |
| --- |
| [Índice de ADRs](docs/adr/README.md) |
