# bookstack-sync

Script Python que sincroniza a documentação do projeto `infra-lab-proxmox` para o
BookStack do laboratório.

Origem → destino:

| Diretório local     | Livro no BookStack                  |
|---------------------|-------------------------------------|
| `docs/adr/*.md`     | Architecture Decision Records       |
| `docs/guide/*.md`   | Guias de Operação                   |

Ambos os livros ficam dentro da Prateleira `infra-lab-proxmox`.

Hierarquia BookStack: **Prateleira (Shelf) → Livro (Book) → Página (Page)**

---

## Pré-requisitos

- Python 3.10 ou superior
- pip (gerenciador de pacotes Python)
- Acesso de rede ao BookStack com token de API válido

Instale as dependências:

```bash
pip install -r scripts/bookstack-sync/requirements.txt
```

---

## Configuração de variáveis de ambiente

O script requer três variáveis obrigatórias. Configure via export ou crie um
arquivo `.env` na raiz do projeto (nunca comite este arquivo).

```bash
export BOOKSTACK_URL="http://10.10.0.6:80"
export BOOKSTACK_TOKEN_ID="seu-token-id"
export BOOKSTACK_TOKEN_SECRET="seu-token-secret"
```

Exemplo de `.env` (opcional, carregado automaticamente pelo script):

```dotenv
BOOKSTACK_URL=http://10.10.0.6:80
BOOKSTACK_TOKEN_ID=seu-token-id
BOOKSTACK_TOKEN_SECRET=seu-token-secret
```

---

## Execução local

### Sincronização completa

```bash
python scripts/bookstack-sync/sync.py
```

### Dry-run (simula sem escrever)

```bash
python scripts/bookstack-sync/sync.py --dry-run
```

### Dry-run com detalhamento de operações

```bash
python scripts/bookstack-sync/sync.py --dry-run --verbose
```

### Forcar re-publicação de todos os arquivos (ignora cache de hash)

```bash
python scripts/bookstack-sync/sync.py --force
```

### Especificar raiz do projeto manualmente

```bash
python scripts/bookstack-sync/sync.py --project-root /caminho/para/infra-lab-proxmox
```

---

## Flags disponíveis

| Flag             | Descrição                                                          |
|------------------|--------------------------------------------------------------------|
| `--dry-run`      | Simula sem escrever no BookStack; exibe o que seria feito          |
| `--verbose`      | Detalha cada operação HTTP (método, URL, status code)             |
| `--force`        | Ignora comparação de hash e republica todos os arquivos            |
| `--project-root` | Caminho da raiz do projeto (padrão: detectado automaticamente)     |

---

## Comportamento de idempotência

O script é seguro para executar múltiplas vezes:

1. A Prateleira `infra-lab-proxmox` é criada apenas se não existir
2. Cada Livro é criado apenas se não existir e vinculado à Prateleira
3. Para cada arquivo `.md`:
   - Se a página não existe no Livro → cria `[NEW]`
   - Se a página existe e o conteúdo mudou (hash SHA-256 diferente) → atualiza `[UPDATE]`
   - Se a página existe e o conteúdo é idêntico → ignora `[SKIP]`
   - Com `--force` → atualiza sempre, independente do hash

---

## Prefixos de log

| Prefixo     | Significado                               |
|-------------|-------------------------------------------|
| `[NEW]`     | Recurso criado pela primeira vez          |
| `[UPDATE]`  | Recurso atualizado (conteúdo mudou)       |
| `[SKIP]`    | Sem alterações detectadas                 |
| `[DRY-RUN]` | Operação simulada (modo dry-run ativo)    |
| `[WARN]`    | Aviso não bloqueante                      |
| `[ERROR]`   | Erro durante a sincronização              |
| `[INFO]`    | Informação geral de progresso             |
| `[VERBOSE]` | Detalhe HTTP (visível apenas com --verbose)|

---

## Imagens em documentos

Imagens com path local (não URL) não são enviadas automaticamente.
O script detecta essas referências e emite um aviso `[WARN]`, mas não
bloqueia a sincronização. O upload de imagens deve ser feito manualmente
no BookStack.

---

## CI/CD — GitHub Actions

Adicione ao workflow de CI/CD para sincronizar automaticamente a cada push
na branch `main`:

```yaml
name: Sync docs to BookStack

on:
  push:
    branches:
      - main
    paths:
      - 'docs/**'

jobs:
  bookstack-sync:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: Install dependencies
        run: pip install -r scripts/bookstack-sync/requirements.txt

      - name: Sync docs to BookStack
        env:
          BOOKSTACK_URL: ${{ secrets.BOOKSTACK_URL }}
          BOOKSTACK_TOKEN_ID: ${{ secrets.BOOKSTACK_TOKEN_ID }}
          BOOKSTACK_TOKEN_SECRET: ${{ secrets.BOOKSTACK_TOKEN_SECRET }}
        run: |
          pip install -r scripts/bookstack-sync/requirements.txt
          python scripts/bookstack-sync/sync.py
```

Configure os secrets no repositório:
- `Settings` → `Secrets and variables` → `Actions`
- Adicione `BOOKSTACK_URL`, `BOOKSTACK_TOKEN_ID`, `BOOKSTACK_TOKEN_SECRET`

---

## Estrutura de arquivos

```
scripts/bookstack-sync/
├── sync.py          <- script principal
├── requirements.txt <- dependências Python com versões fixadas
└── README.md        <- este arquivo
```

---

## Dependências

| Pacote          | Versão  | Uso                                     |
|-----------------|---------|-----------------------------------------|
| httpx           | 0.27.0  | Cliente HTTP com suporte a SSL inseguro |
| markdown        | 3.6     | Conversão Markdown para HTML            |
| tenacity        | 8.3.0   | Retry automático em falhas de rede      |
| python-dotenv   | 1.0.1   | Carregamento opcional de arquivo .env   |
