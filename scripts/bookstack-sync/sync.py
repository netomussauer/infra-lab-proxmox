#!/usr/bin/env python3
"""
sync.py — BookStack Sync (Python refactor de bookstack-sync-docs.sh)

Sincroniza docs/adr/*.md e docs/guide/*.md para o BookStack do laboratório
infra-lab-proxmox, dentro da Prateleira "infra-lab-proxmox".

Hierarquia: Shelf → Book → Page (sem Chapters)

Uso:
    python sync.py [--dry-run] [--verbose] [--force]

Variáveis de ambiente obrigatórias:
    BOOKSTACK_URL           ex: http://10.10.0.6:80
    BOOKSTACK_TOKEN_ID
    BOOKSTACK_TOKEN_SECRET
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import httpx
import markdown as md_lib
from dotenv import load_dotenv
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

# ---------------------------------------------------------------------------
# Carrega .env opcional (ignorado se não existir)
# ---------------------------------------------------------------------------
load_dotenv()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

LOG_FORMAT = "%(message)s"


def setup_logging(verbose: bool) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(level=level, format=LOG_FORMAT, stream=sys.stdout)


def _tag(prefix: str, msg: str) -> str:
    return f"[{prefix}] {msg}"


def log_new(msg: str) -> None:
    logging.info(_tag("NEW", msg))


def log_update(msg: str) -> None:
    logging.info(_tag("UPDATE", msg))


def log_skip(msg: str) -> None:
    logging.info(_tag("SKIP", msg))


def log_dryrun(msg: str) -> None:
    logging.info(_tag("DRY-RUN", msg))


def log_warn(msg: str) -> None:
    logging.warning(_tag("WARN", msg))


def log_error(msg: str) -> None:
    logging.error(_tag("ERROR", msg))


def log_info(msg: str) -> None:
    logging.info(_tag("INFO", msg))


def log_verbose(msg: str) -> None:
    logging.debug(_tag("VERBOSE", msg))


# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------

class Counters:
    def __init__(self) -> None:
        self.files: int = 0
        self.new: int = 0
        self.update: int = 0
        self.skip: int = 0
        self.errors: int = 0

    def print_summary(self, dry_run: bool) -> None:
        mode = "DRY-RUN" if dry_run else "PUBLICADO"
        print("")
        print("+------------------------------------------------------+")
        print("|      BookStack Sync -- Resumo da sincronizacao       |")
        print("+------------------------------------------------------+")
        print(f"|  Modo                  :  {mode}")
        print(f"|  Arquivos processados  :  {self.files}")
        print(f"|  Pages novas (NEW)     :  {self.new}")
        print(f"|  Pages atualizadas     :  {self.update}")
        print(f"|  Pages sem alteracao   :  {self.skip}")
        print(f"|  Erros                 :  {self.errors}")
        print("+------------------------------------------------------+")


# ---------------------------------------------------------------------------
# Config / Env validation
# ---------------------------------------------------------------------------

class Config:
    """Configuração centralizada lida de variáveis de ambiente."""

    def __init__(self) -> None:
        self.url: str = ""
        self.token_id: str = ""
        self.token_secret: str = ""
        self.dry_run: bool = False
        self.verbose: bool = False
        self.force: bool = False
        self.project_root: Path = Path()


def validate_env(config: Config) -> None:
    """
    Verifica que as variáveis de ambiente obrigatórias estão definidas.
    Aborta com mensagem clara se alguma estiver ausente.
    """
    missing: list[str] = []

    config.url = os.environ.get("BOOKSTACK_URL", "").rstrip("/")
    config.token_id = os.environ.get("BOOKSTACK_TOKEN_ID", "")
    config.token_secret = os.environ.get("BOOKSTACK_TOKEN_SECRET", "")

    if not config.url:
        missing.append("BOOKSTACK_URL")
    if not config.token_id:
        missing.append("BOOKSTACK_TOKEN_ID")
    if not config.token_secret:
        missing.append("BOOKSTACK_TOKEN_SECRET")

    if missing:
        log_error(
            f"Variáveis de ambiente obrigatórias ausentes: {', '.join(missing)}\n"
            "  Configure via export ou arquivo .env antes de executar."
        )
        sys.exit(1)

    # Mascara o secret nos logs — exibe apenas os 4 primeiros caracteres
    secret_preview = (
        config.token_secret[:4] + "..." if len(config.token_secret) > 4 else "***"
    )
    log_info(f"BookStack URL  : {config.url}")
    log_info(f"Token ID       : {config.token_id}")
    log_info(f"Token Secret   : {secret_preview}")
    log_info(f"Dry-run        : {config.dry_run}")
    log_info(f"Force          : {config.force}")
    log_info(f"Verbose        : {config.verbose}")


# ---------------------------------------------------------------------------
# HTTP client
# ---------------------------------------------------------------------------

def build_client(config: Config) -> httpx.Client:
    """
    Constrói o cliente httpx com autenticação e SSL inseguro (self-signed).
    O aviso de SSL desativado é emitido aqui uma única vez.
    """
    import warnings
    import urllib3  # type: ignore

    warnings.warn(
        "[WARN] SSL certificate verification desativada (verify=False). "
        "Adequado apenas para ambientes de laboratório com certificados self-signed.",
        stacklevel=2,
    )
    # Suprime o aviso repetido do urllib3 para não poluir o log
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    headers = {
        "Authorization": f"Token {config.token_id}:{config.token_secret}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    return httpx.Client(headers=headers, verify=False, timeout=30.0)


# ---------------------------------------------------------------------------
# API helpers — paginação e retry
# ---------------------------------------------------------------------------

_RETRYABLE_EXCEPTIONS = (
    httpx.ConnectError,
    httpx.ReadTimeout,
    httpx.ConnectTimeout,
    httpx.RemoteProtocolError,
)


def _retry_decorator():  # type: ignore
    return retry(
        retry=retry_if_exception_type(_RETRYABLE_EXCEPTIONS),
        wait=wait_exponential(multiplier=1, min=2, max=30),
        stop=stop_after_attempt(4),
        reraise=True,
    )


@_retry_decorator()
def _get(client: httpx.Client, url: str) -> httpx.Response:
    log_verbose(f"GET {url}")
    resp = client.get(url)
    log_verbose(f"HTTP {resp.status_code} <- GET {url}")
    return resp


@_retry_decorator()
def _post(client: httpx.Client, url: str, payload: dict) -> httpx.Response:
    log_verbose(f"POST {url}")
    resp = client.post(url, json=payload)
    log_verbose(f"HTTP {resp.status_code} <- POST {url}")
    return resp


@_retry_decorator()
def _put(client: httpx.Client, url: str, payload: dict) -> httpx.Response:
    log_verbose(f"PUT {url}")
    resp = client.put(url, json=payload)
    log_verbose(f"HTTP {resp.status_code} <- PUT {url}")
    return resp


def _raise_for_status(resp: httpx.Response, context: str) -> None:
    """Lança exceção com mensagem informativa para respostas de erro HTTP."""
    if resp.status_code >= 400:
        body_preview = resp.text[:500] if resp.text else "(sem body)"
        raise RuntimeError(
            f"HTTP {resp.status_code} em {context} — body: {body_preview}"
        )


def find_by_name(
    client: httpx.Client,
    api_base: str,
    endpoint: str,
    name: str,
) -> Optional[dict]:
    """
    Busca paginada por nome exato em endpoint da API BookStack.

    Percorre todas as páginas de resultados (?count=100&offset=N) até encontrar
    o item com correspondência exata no campo 'name'. Retorna o dict do item
    encontrado ou None se não existir.

    Args:
        client:    cliente httpx autenticado
        api_base:  URL base da API (ex: http://host/api)
        endpoint:  recurso (ex: "shelves", "books", "pages")
        name:      nome exato a localizar

    Returns:
        dict com os dados do item ou None
    """
    page_size = 100
    offset = 0

    while True:
        url = f"{api_base}/{endpoint}?count={page_size}&offset={offset}"
        resp = _get(client, url)

        if resp.status_code != 200:
            log_warn(
                f"find_by_name: GET {endpoint} retornou HTTP {resp.status_code} "
                f"(offset={offset}) — encerrando busca"
            )
            return None

        data = resp.json()
        items: list[dict] = data.get("data", [])

        for item in items:
            if item.get("name") == name:
                return item

        # Se retornou menos que page_size, chegamos ao fim
        if len(items) < page_size:
            return None

        offset += page_size


# ---------------------------------------------------------------------------
# Shelf / Book management
# ---------------------------------------------------------------------------

def ensure_shelf(
    client: httpx.Client,
    api_base: str,
    name: str,
    description: str,
    dry_run: bool,
    _cache: dict[str, int] = {},
) -> Optional[int]:
    """
    Garante que a Prateleira (Shelf) existe no BookStack.

    Busca por nome exato via find_by_name. Cria se não encontrada.
    Usa cache em memória para evitar chamadas repetidas.

    Returns:
        ID da shelf ou None em caso de falha
    """
    if name in _cache:
        return _cache[name]

    existing = find_by_name(client, api_base, "shelves", name)
    if existing:
        shelf_id: int = existing["id"]
        log_skip(f"Shelf '{name}' já existe (id={shelf_id})")
        _cache[name] = shelf_id
        return shelf_id

    if dry_run:
        log_dryrun(f"Criaria shelf '{name}'")
        _cache[name] = 0
        return 0

    resp = _post(client, f"{api_base}/shelves", {"name": name, "description": description})
    if resp.status_code in (200, 201):
        shelf_id = resp.json()["id"]
        log_new(f"Shelf '{name}' criada (id={shelf_id})")
        _cache[name] = shelf_id
        return shelf_id

    # Conflito: tentar buscar novamente antes de declarar erro
    log_warn(f"POST shelf '{name}' retornou HTTP {resp.status_code} — verificando novamente")
    existing = find_by_name(client, api_base, "shelves", name)
    if existing:
        shelf_id = existing["id"]
        log_skip(f"Shelf '{name}' já existe (id={shelf_id}) — usando existente")
        _cache[name] = shelf_id
        return shelf_id

    log_error(f"Falha ao criar/encontrar shelf '{name}' — HTTP {resp.status_code}")
    return None


def _link_book_to_shelf(
    client: httpx.Client,
    api_base: str,
    shelf_id: int,
    book_id: int,
    book_name: str,
) -> None:
    """
    Vincula um Livro a uma Prateleira de forma idempotente.

    Lê os books atualmente associados ao shelf antes de fazer o PUT,
    para preservar vínculos existentes e evitar substituí-los por lista vazia.
    """
    resp = _get(client, f"{api_base}/shelves/{shelf_id}")
    if resp.status_code != 200:
        log_warn(
            f"Não foi possível verificar books do shelf id={shelf_id} "
            f"(HTTP {resp.status_code}) — pulando vinculação"
        )
        return

    shelf_data = resp.json()
    current_book_ids: list[int] = [b["id"] for b in shelf_data.get("books", [])]

    if book_id in current_book_ids:
        log_skip(f"Book '{book_name}' já está vinculado ao shelf id={shelf_id}")
        return

    merged = current_book_ids + [book_id]
    shelf_name = shelf_data.get("name", "")
    put_resp = _put(
        client,
        f"{api_base}/shelves/{shelf_id}",
        {"name": shelf_name, "books": merged},
    )
    if put_resp.status_code == 200:
        log_info(f"Book '{book_name}' vinculado ao shelf '{shelf_name}' (id={shelf_id})")
    else:
        log_warn(
            f"Falha ao vincular book '{book_name}' ao shelf id={shelf_id} "
            f"— HTTP {put_resp.status_code}"
        )


def ensure_book(
    client: httpx.Client,
    api_base: str,
    name: str,
    shelf_id: int,
    description: str,
    dry_run: bool,
    _cache: dict[str, int] = {},
) -> Optional[int]:
    """
    Garante que o Livro (Book) existe e está vinculado à Prateleira.

    Busca por nome exato. Cria se não encontrado. Vincula à shelf
    de forma idempotente após criação ou quando já existia desvinculado.

    Returns:
        ID do book ou None em caso de falha
    """
    if name in _cache:
        return _cache[name]

    existing = find_by_name(client, api_base, "books", name)
    if existing:
        book_id: int = existing["id"]
        log_skip(f"Book '{name}' já existe (id={book_id})")
        _cache[name] = book_id
        if not dry_run and shelf_id != 0:
            _link_book_to_shelf(client, api_base, shelf_id, book_id, name)
        return book_id

    if dry_run:
        log_dryrun(f"Criaria book '{name}' no shelf id={shelf_id}")
        _cache[name] = 0
        return 0

    resp = _post(client, f"{api_base}/books", {"name": name, "description": description})
    if resp.status_code in (200, 201):
        book_id = resp.json()["id"]
        log_new(f"Book '{name}' criado (id={book_id})")
        _cache[name] = book_id
        if shelf_id != 0:
            _link_book_to_shelf(client, api_base, shelf_id, book_id, name)
        return book_id

    # Conflito: buscar novamente
    if resp.status_code == 409 or "already exists" in resp.text.lower():
        log_skip(f"Book '{name}' já existe (conflict) — buscando novamente")
        existing = find_by_name(client, api_base, "books", name)
        if existing:
            book_id = existing["id"]
            _cache[name] = book_id
            return book_id

    log_error(f"Falha ao criar book '{name}' — HTTP {resp.status_code}")
    return None


# ---------------------------------------------------------------------------
# Markdown processing
# ---------------------------------------------------------------------------

def md_to_html(content: str) -> str:
    """
    Converte conteúdo Markdown para HTML usando a lib `markdown`.

    Extensões habilitadas:
    - fenced_code: blocos ```lang ... ``` com syntax highlight
    - tables: tabelas GFM
    - toc: âncoras automáticas para headings

    Args:
        content: texto em Markdown

    Returns:
        HTML renderizado como string
    """
    return md_lib.markdown(
        content,
        extensions=["fenced_code", "tables", "toc", "codehilite"],
        extension_configs={
            "codehilite": {
                "linenums": False,
                "guess_lang": False,
            }
        },
    )


def extract_title(file_path: Path) -> str:
    """
    Deriva o título da página.

    Estratégia (por precedência):
    1. Primeiro heading H1 (`# Título`) encontrado no arquivo
    2. Nome do arquivo formatado:
       - Remove extensão
       - Substitui hifens/underscores por espaços
       - Ex: `01-visao-geral.md` → `01 - Visao Geral`
       - Ex: `adr-001-uso-terraform.md` → `Adr 001 Uso Terraform`

    Args:
        file_path: caminho absoluto do arquivo Markdown

    Returns:
        Título como string
    """
    try:
        text = file_path.read_text(encoding="utf-8")
    except OSError:
        text = ""

    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("# "):
            return stripped[2:].strip()

    # Fallback: formatar nome de arquivo
    stem = file_path.stem  # nome sem extensão
    # Separa número prefixo com hífen para legibilidade: "01-visao" → "01 - Visao"
    # Padrão: dígitos seguidos de hífen no início
    stem = re.sub(r"^(\d+)-", r"\1 - ", stem)
    # Demais hifens e underscores viram espaços
    stem = stem.replace("-", " ").replace("_", " ")
    return stem.title()


def detect_local_images(content: str) -> list[str]:
    """
    Detecta imagens referenciadas no Markdown com path local (não URL).

    Uma imagem é considerada local se o src não começar com http:// ou https://.

    Args:
        content: conteúdo Markdown

    Returns:
        Lista de paths locais detectados
    """
    pattern = re.compile(r"!\[[^\]]*\]\(([^)]+)\)")
    local: list[str] = []
    for match in pattern.finditer(content):
        src = match.group(1).strip()
        if not src.startswith(("http://", "https://")):
            local.append(src)
    return local


def content_hash(content: str) -> str:
    """
    Calcula SHA-256 do conteúdo como string hexadecimal.

    Args:
        content: conteúdo a ser hasheado (string UTF-8)

    Returns:
        Hash SHA-256 hex (64 chars)
    """
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# Page sync
# ---------------------------------------------------------------------------

def _find_page_in_book(
    client: httpx.Client,
    api_base: str,
    title: str,
    book_id: int,
) -> Optional[dict]:
    """
    Busca página por título exato dentro de um Livro específico.

    Percorre paginação de GET /api/pages filtrando por book_id localmente,
    pois a API do BookStack pode não filtrar por book_id de forma confiável
    com nomes acentuados.

    Returns:
        dict da página ou None
    """
    page_size = 100
    offset = 0

    while True:
        url = f"{api_base}/pages?count={page_size}&offset={offset}&filter[book_id]={book_id}"
        resp = _get(client, url)

        if resp.status_code != 200:
            log_warn(
                f"GET /pages retornou HTTP {resp.status_code} (offset={offset})"
            )
            return None

        data = resp.json()
        items: list[dict] = data.get("data", [])

        for item in items:
            if item.get("name") == title and item.get("book_id") == book_id:
                return item

        if len(items) < page_size:
            return None

        offset += page_size


def sync_page(
    client: httpx.Client,
    api_base: str,
    book_id: int,
    title: str,
    md_content: str,
    html_content: str,
    dry_run: bool,
    force: bool,
    counters: Counters,
    file_path: Path,
) -> None:
    """
    Sincroniza uma página no BookStack com lógica idempotente de hash.

    Fluxo de decisão:
    1. Calcula SHA-256 do conteúdo local
    2. Busca página existente no Livro pelo título
    3. Se não existe → POST /api/pages  [NEW]
    4. Se existe:
       a. Recupera hash da página atual (campo `markdown` do BookStack)
       b. Hashes iguais e force=False → SKIP
       c. Hashes diferentes ou force=True → PUT /api/pages/{id}  [UPDATE]

    Args:
        client:       cliente httpx autenticado
        api_base:     URL base da API
        book_id:      ID do Livro destino
        title:        título da página
        md_content:   conteúdo Markdown
        html_content: conteúdo HTML (pré-convertido)
        dry_run:      se True, apenas loga sem escrever
        force:        se True, republica mesmo sem mudança de hash
        counters:     acumulador de métricas
        file_path:    path do arquivo (para logging)
    """
    counters.files += 1
    rel = str(file_path)

    # Detectar imagens locais e avisar
    local_imgs = detect_local_images(md_content)
    for img in local_imgs:
        log_warn(f"Imagem local detectada: {img} — upload manual necessário ({rel})")

    local_hash = content_hash(md_content)

    existing_page = _find_page_in_book(client, api_base, title, book_id)

    if existing_page is None:
        # Página não existe → criar
        if dry_run:
            log_dryrun(f"Criaria page '{title}' no book id={book_id} ({rel})")
            counters.new += 1
            return

        payload = {
            "book_id": book_id,
            "name": title,
            "markdown": md_content,
            "html": html_content,
        }
        resp = _post(client, f"{api_base}/pages", payload)
        if resp.status_code in (200, 201):
            page_id = resp.json().get("id")
            log_new(f"Page id={page_id} '{title}' criada em book id={book_id} ({rel})")
            counters.new += 1
        else:
            log_error(
                f"Falha ao criar page '{title}' — HTTP {resp.status_code} | "
                f"{resp.text[:300]}"
            )
            counters.errors += 1
        return

    # Página existe → verificar necessidade de update
    page_id = existing_page["id"]

    if not force:
        # Recupera conteúdo atual para comparação de hash
        detail_resp = _get(client, f"{api_base}/pages/{page_id}")
        if detail_resp.status_code == 200:
            remote_md = detail_resp.json().get("markdown", "")
            remote_hash = content_hash(remote_md) if remote_md else ""
        else:
            # Não conseguiu ler — forçar update preventivo
            remote_hash = ""
            log_warn(
                f"Não foi possível ler page id={page_id} para hash "
                f"(HTTP {detail_resp.status_code}) — forçando update"
            )

        if remote_hash == local_hash:
            log_skip(f"Page '{title}' sem alterações (hash idêntico) ({rel})")
            counters.skip += 1
            return

    # Hash diferente ou force → atualizar
    if dry_run:
        log_dryrun(f"Atualizaria page id={page_id} '{title}' ({rel})")
        counters.update += 1
        return

    payload = {
        "name": title,
        "markdown": md_content,
        "html": html_content,
    }
    resp = _put(client, f"{api_base}/pages/{page_id}", payload)
    if resp.status_code == 200:
        log_update(f"Page id={page_id} '{title}' atualizada ({rel})")
        counters.update += 1
    else:
        log_error(
            f"Falha ao atualizar page id={page_id} '{title}' "
            f"— HTTP {resp.status_code} | {resp.text[:300]}"
        )
        counters.errors += 1


# ---------------------------------------------------------------------------
# Mapping: docs/ → BookStack
# ---------------------------------------------------------------------------

# Mapeamento de diretório de origem → nome do Livro no BookStack
BOOK_MAPPING: dict[str, str] = {
    "adr": "Architecture Decision Records",
    "guide": "Guias de Operação",
}

# Nome da Prateleira raiz
SHELF_NAME = "infra-lab-proxmox"
SHELF_DESCRIPTION = "Documentação do laboratório infra-lab-proxmox"


def collect_doc_files(project_root: Path) -> list[tuple[Path, str]]:
    """
    Varre docs/adr/*.md e docs/guide/*.md e retorna lista de (path, book_name).

    Arquivos são ordenados por nome dentro de cada diretório para garantir
    ordem determinística de sincronização.

    Args:
        project_root: raiz do projeto

    Returns:
        Lista de tuplas (caminho absoluto, nome do livro BookStack)
    """
    files: list[tuple[Path, str]] = []

    for subdir, book_name in BOOK_MAPPING.items():
        source_dir = project_root / "docs" / subdir
        if not source_dir.is_dir():
            log_warn(f"Diretório não encontrado: {source_dir} — pulando")
            continue

        md_files = sorted(source_dir.glob("*.md"))
        for md_file in md_files:
            files.append((md_file, book_name))

    return files


# ---------------------------------------------------------------------------
# Connectivity check
# ---------------------------------------------------------------------------

def check_api_connectivity(client: httpx.Client, api_base: str) -> None:
    """
    Verifica que a API do BookStack está acessível antes de iniciar a sync.
    Aborta com sys.exit(1) se o endpoint retornar código != 200.

    Args:
        client:   cliente httpx autenticado
        api_base: URL base da API
    """
    log_info("Testando conectividade com a API do BookStack...")
    try:
        resp = _get(client, f"{api_base}/books")
    except Exception as exc:
        log_error(f"Não foi possível conectar ao BookStack: {exc}")
        sys.exit(1)

    if resp.status_code != 200:
        log_error(
            f"API do BookStack não acessível em {api_base}/books "
            f"— HTTP {resp.status_code}\n"
            "  Verifique URL, token e conectividade de rede."
        )
        sys.exit(1)

    log_info("API do BookStack acessível (HTTP 200)")


# ---------------------------------------------------------------------------
# Main orchestration
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Sincroniza docs/adr/*.md e docs/guide/*.md para o BookStack "
            "do laboratório infra-lab-proxmox."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Variáveis de ambiente obrigatórias:
  BOOKSTACK_URL           URL base do BookStack (ex: http://10.10.0.6:80)
  BOOKSTACK_TOKEN_ID      ID do token API
  BOOKSTACK_TOKEN_SECRET  Secret do token API

Exemplos:
  python sync.py
  python sync.py --dry-run
  python sync.py --force --verbose
        """,
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Simula sem escrever no BookStack; exibe o que seria feito",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        default=False,
        help="Detalha cada operação com HTTP response codes",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        default=False,
        help="Ignora comparação de hash e republica todos os arquivos",
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=None,
        help=(
            "Raiz do projeto (padrão: detectada automaticamente como "
            "dois níveis acima de sync.py)"
        ),
    )
    return parser.parse_args()


def detect_project_root(script_path: Path) -> Path:
    """
    Detecta a raiz do projeto a partir da localização do script.

    scripts/bookstack-sync/sync.py  →  ../../  →  raiz do projeto
    Fallback: diretório de trabalho atual.

    Args:
        script_path: Path do próprio sync.py

    Returns:
        Path absoluto da raiz do projeto
    """
    # sync.py está em <root>/scripts/bookstack-sync/
    candidate = script_path.resolve().parent.parent.parent

    if (candidate / "docs").is_dir() or (candidate / "README.md").is_file():
        return candidate

    cwd = Path.cwd()
    log_warn(
        f"Não foi possível detectar raiz do projeto automaticamente "
        f"— usando diretório atual: {cwd}"
    )
    return cwd


def main() -> None:
    args = parse_args()

    setup_logging(args.verbose)

    # Resolve raiz do projeto
    project_root: Path
    if args.project_root:
        project_root = args.project_root.resolve()
        if not project_root.is_dir():
            log_error(f"--project-root não existe: {project_root}")
            sys.exit(1)
    else:
        project_root = detect_project_root(Path(__file__))

    log_info(f"Raiz do projeto : {project_root}")

    # Configuração
    config = Config()
    config.dry_run = args.dry_run
    config.verbose = args.verbose
    config.force = args.force
    config.project_root = project_root

    # Valida variáveis de ambiente — aborta se ausentes
    validate_env(config)

    if config.dry_run:
        log_dryrun("Modo dry-run ativo — nenhuma alteração será feita no BookStack")
    if config.force:
        log_warn("Modo force ativo — todos os arquivos serão re-publicados")

    api_base = f"{config.url}/api"
    counters = Counters()

    # Inicializa o cliente HTTP
    with build_client(config) as client:

        # Verifica conectividade antes de qualquer operação
        check_api_connectivity(client, api_base)

        # Garante que a Prateleira raiz existe
        log_info(f"Verificando/criando shelf '{SHELF_NAME}'...")
        shelf_id = ensure_shelf(
            client, api_base, SHELF_NAME, SHELF_DESCRIPTION, config.dry_run
        )
        if shelf_id is None:
            log_error(f"Não foi possível garantir shelf '{SHELF_NAME}' — abortando")
            sys.exit(1)

        # Garante que cada Livro existe e está vinculado à Prateleira
        book_ids: dict[str, int] = {}
        for book_name in BOOK_MAPPING.values():
            log_info(f"Verificando/criando book '{book_name}'...")
            book_id = ensure_book(
                client,
                api_base,
                book_name,
                shelf_id,
                f"Documentação: {book_name}",
                config.dry_run,
            )
            if book_id is None:
                log_error(f"Não foi possível garantir book '{book_name}' — abortando")
                sys.exit(1)
            book_ids[book_name] = book_id

        # Coleta arquivos Markdown
        doc_files = collect_doc_files(project_root)
        if not doc_files:
            log_warn("Nenhum arquivo Markdown encontrado em docs/ — encerrando")
            counters.print_summary(config.dry_run)
            return

        log_info(f"Iniciando sincronização de {len(doc_files)} arquivo(s)...")

        # Sincroniza cada arquivo
        for file_path, book_name in doc_files:
            title = extract_title(file_path)
            log_verbose(f"Processando: {file_path.name} → book '{book_name}' | título: '{title}'")

            try:
                md_content = file_path.read_text(encoding="utf-8")
            except OSError as exc:
                log_error(f"Não foi possível ler {file_path}: {exc}")
                counters.errors += 1
                counters.files += 1
                continue

            html_content = md_to_html(md_content)
            target_book_id = book_ids[book_name]

            try:
                sync_page(
                    client=client,
                    api_base=api_base,
                    book_id=target_book_id,
                    title=title,
                    md_content=md_content,
                    html_content=html_content,
                    dry_run=config.dry_run,
                    force=config.force,
                    counters=counters,
                    file_path=file_path,
                )
            except Exception as exc:
                log_error(f"Erro inesperado ao sincronizar '{title}' ({file_path}): {exc}")
                counters.errors += 1
                counters.files += 1

    # Relatório final
    counters.print_summary(config.dry_run)

    # Código de saída: 1 se houve erros
    if counters.errors > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
