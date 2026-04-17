# NetBox IPAM e BookStack

Referência técnica para os serviços auxiliares do laboratório: NetBox (IPAM/CMDB) e BookStack (documentação).

---

## NetBox

### Finalidade

NetBox atua como fonte de verdade para endereçamento IP (IPAM) e inventário de VMs (CMDB). Toda VM provisionada consulta e registra endereços no NetBox antes de aplicar configurações de rede.

### Configuração de acesso

```bash
# Token NetBox (nunca versionar)
export TF_VAR_netbox_token="seu-token"
export NETBOX_TOKEN="seu-token"
```

**Permissões mínimas do token:**
- `ipam.prefix` — leitura
- `ipam.ipaddress` — escrita
- `virtualization.*` — escrita completa

**Pré-requisito:** O prefixo `10.10.0.0/24` deve existir no IPAM do NetBox antes de executar o Terraform.

### Integração Terraform

#### `scripts/netbox-get-available-ips.sh`

Script Bash invocado pelo `external` data source do Terraform. Executa dois GETs somente-leitura na API do NetBox:
1. Busca o ID do prefixo por CIDR
2. Lista os próximos IPs disponíveis

Retorna JSON com `ip_0..ip_N` e `prefix_id`. Falha com `exit 1` se o prefixo não existir, houver IPs insuficientes ou a autenticação falhar. Flag `-k` ativada apenas quando `insecure=true`.

#### Recursos provisionados (`netbox.tf`)

| Recurso | Descrição |
|---------|-----------|
| `data "external" "available_ips"` | Chama o script acima; `worker_count+1` IPs (k8s) ou `1` IP (cicd). Somente leitura, sem side effects no `plan`. |
| `netbox_ip_address` | Reserva cada IP com `status = "active"` e `lifecycle { ignore_changes = [ip_address] }`. |
| `netbox_cluster_type` / `netbox_cluster` | Registra o cluster Kubernetes no NetBox. |
| `netbox_virtual_machine` | Registra cada VM com vCPU, RAM, disco e tags obrigatórias. |
| `netbox_interface` / `netbox_primary_ip` | Associa IP primário à interface da VM. |

**Variáveis adicionadas em `variables.tf`:** `netbox_url`, `netbox_token` (sensitive), `netbox_insecure`, `network_cidr`.

**Outputs atualizados:** `master_ip`, `worker_ips`, `cicd_ip` e `ansible_vars` refletem os IPs alocados pelo NetBox.

### Integração Ansible

#### Dependências

```bash
ansible-galaxy collection install netbox.netbox
pip install pynetbox
```

#### Playbooks

| Playbook | Stack | Descrição |
|----------|-------|-----------|
| `ansible-k8s/playbooks/06-register-netbox.yml` | Kubernetes | Atualiza cada nó com `k8s_role: control-plane\|worker` como custom field; associa IP à interface; debug com link de verificação. |
| `ansible-cicd/playbooks/05-register-netbox.yml` | CI/CD | Registra `cicd-server-01` com tags `cicd`/`gitea`/`registry` e 3 serviços: Gitea HTTP (:3000), Gitea SSH (:2222), Registry (:5000). |

#### Variáveis globais (`group_vars/all.yml`)

```yaml
netbox_url: "http://10.10.0.X"
netbox_token: "{{ lookup('env', 'NETBOX_TOKEN') }}"
netbox_validate_certs: false
```

---

## BookStack

### Finalidade

BookStack armazena a documentação do projeto organizada em Prateleiras (Shelves) → Livros (Books) → Páginas (Pages).

### Hierarquia

```
Prateleira: ADRs
└── Livro: <título de cada ADR>
    └── Página: conteúdo do arquivo

Prateleira: Procedimentos Técnicos
└── Livro: <título de cada procedimento>
    └── Página: conteúdo do arquivo
```

### Configuração de acesso

```bash
# Token BookStack (nunca versionar)
export BOOKSTACK_URL="http://10.10.0.6:80"
export BOOKSTACK_TOKEN_ID="seu-token-id"
export BOOKSTACK_TOKEN_SECRET="seu-token-secret"
```

### `scripts/bookstack-sync-docs.sh`

Script de sincronização automática entre o repositório e o BookStack.

**Flags disponíveis:**

| Flag | Descrição |
|------|-----------|
| `--dry-run` | Simula todas as ações sem escrever no BookStack |
| `--verbose` | Exibe detalhes de cada operação |
| `--force` | Ignora hashes, republica todos os arquivos |
| `--state-file <path>` | Caminho alternativo para o arquivo de estado |
| `--project-root <path>` | Raiz alternativa do projeto |

**Arquivo de estado:** `scripts/.bookstack-sync-state.json` — armazena o SHA-256 de cada arquivo para detecção de mudanças. Não versionar.

**Execução:**

```bash
# Dry-run (verificar o que seria publicado)
bash scripts/bookstack-sync-docs.sh --dry-run --verbose

# Publicar arquivos novos e alterados
bash scripts/bookstack-sync-docs.sh

# Forçar republicação de tudo
bash scripts/bookstack-sync-docs.sh --force
```

**Idempotência:**
- Prateleiras: criadas apenas se não existirem; nunca recriadas
- Livros: criados apenas se não existirem; vinculados à prateleira sem duplicação
- Páginas: criadas ou atualizadas com base no hash SHA-256 do conteúdo; página com conteúdo idêntico recebe `[SKIP]`

**Formatação de conteúdo:**
- `.md` → markdown puro
- `.tf`, `.yml`, `.sh` → bloco de código com syntax highlight

**Limpeza de duplicatas:**

```bash
# Remover páginas duplicadas (mantém a mais recente por livro)
bash scripts/bookstack-sync-docs.sh --cleanup-pages

# Remover livros duplicados
bash scripts/bookstack-sync-docs.sh --cleanup-books

# Remover prateleiras duplicadas
bash scripts/bookstack-sync-docs.sh --cleanup-shelves
```
