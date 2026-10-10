"""Bounded effect adapters for Star-Agent's Star-KB-led REPL.

There is no model, planner, agent memory, or independent ontology here.
Every public effect has a fixed command name and constrained arguments.
"""

from __future__ import annotations

import hashlib
import html
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

MAX_OUTPUT_BYTES = 32_768
MAX_PAGE_BYTES = 196_608
USER_AGENT = "star-agent/0.1 (bounded public research)"
ACTOR_ID = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
DOMAIN = re.compile(
    r"^(?=.{4,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"
)


class EffectError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def required_text(args: dict[str, Any], key: str, limit: int = 2048) -> str:
    value = args.get(key)
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value) > limit
        or "\x00" in value
    ):
        raise EffectError("invalid_argument", f"{key} must be nonempty bounded text")
    return value.strip()


def public_url(url: str, *, trusted_service: bool = False) -> str:
    parts = urlparse(url)
    if (
        parts.scheme not in {"http", "https"}
        or not parts.hostname
        or parts.username
        or parts.password
        or parts.fragment
        or len(url) > 4096
    ):
        raise EffectError("invalid_url", "only credential-free HTTP(S) URLs are supported")
    if trusted_service:
        return url  # only an operator-configured endpoint; never a caller URL
    try:
        addresses = socket.getaddrinfo(
            parts.hostname, parts.port or (443 if parts.scheme == "https" else 80),
            type=socket.SOCK_STREAM,
        )
    except (socket.gaierror, ValueError) as exc:
        raise EffectError("dns_failed", "URL hostname could not be resolved") from exc
    if not addresses:
        raise EffectError("dns_failed", "URL returned no addresses")
    for result in addresses:
        address = ipaddress.ip_address(result[4][0].split("%", 1)[0])
        if not address.is_global:
            raise EffectError("blocked_address", "private and local web destinations are denied")
    return url


class RedirectPolicy(HTTPRedirectHandler):
    def __init__(self, *, trusted_origin: str | None = None):
        self.trusted_origin = trusted_origin
        self.hops = 0

    def redirect_request(
        self, req: Request, fp: Any, code: int, msg: str,
        headers: Any, newurl: str,
    ) -> Request | None:
        self.hops += 1
        if self.hops > 3:
            raise EffectError("redirect_limit", "too many redirects")
        if self.trusted_origin:
            p = urlparse(newurl)
            if (p.scheme, p.netloc) != (
                urlparse(self.trusted_origin).scheme,
                urlparse(self.trusted_origin).netloc,
            ):
                raise EffectError("redirect_denied", "configured service may not redirect off origin")
            public_url(newurl, trusted_service=True)
        else:
            public_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_bytes(
    url: str, *, trusted_origin: str | None = None,
) -> tuple[bytes, str, str]:
    public_url(url, trusted_service=trusted_origin is not None)
    headers = {"User-Agent": USER_AGENT, "Accept": "text/html,application/json,text/plain",
               "Accept-Encoding": "identity"}
    opener = build_opener(RedirectPolicy(trusted_origin=trusted_origin))
    with opener.open(Request(url, headers=headers), timeout=12) as response:
        effective = response.geturl()
        public_url(effective, trusted_service=trusted_origin is not None)
        content_length = response.headers.get("Content-Length")
        if content_length and content_length.isdecimal() and int(content_length) > MAX_PAGE_BYTES:
            raise EffectError("oversized_page", "remote response exceeds page budget")
        payload = response.read(MAX_PAGE_BYTES + 1)
        if len(payload) > MAX_PAGE_BYTES:
            raise EffectError("oversized_page", "remote response exceeds page budget")
        return payload, response.headers.get_content_type(), effective


class PageParser(HTMLParser):
    def __init__(self, origin: str):
        super().__init__(convert_charrefs=True)
        self.origin = origin
        self.title_parts: list[str] = []
        self.chunks: list[str] = []
        self.links: list[str] = []
        self.title_active = False
        self.ignored = 0
        self.content_bytes = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in {"script", "style", "noscript", "svg"}:
            self.ignored += 1
        if tag == "title":
            self.title_active = True
        if tag == "a" and len(self.links) < 30:
            href = dict(attrs).get("href")
            if href:
                url = urljoin(self.origin, href).split("#", 1)[0]
                if urlparse(url).scheme in {"http", "https"} and url not in self.links:
                    self.links.append(url)

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style", "noscript", "svg"}:
            self.ignored = max(0, self.ignored - 1)
        if tag == "title":
            self.title_active = False

    def handle_data(self, data: str) -> None:
        if self.ignored:
            return
        text = " ".join(data.split())
        if not text:
            return
        if self.title_active and len(" ".join(self.title_parts)) < 240:
            self.title_parts.append(text)
        if self.content_bytes + len(text) <= 11000:
            self.chunks.append(text)
            self.content_bytes += len(text)


def web_fetch(args: dict[str, Any]) -> dict[str, Any]:
    url = required_text(args, "url", 4096)
    raw, mime, effective = fetch_bytes(url)
    if mime not in {"text/html", "text/plain", "application/xhtml+xml", "application/json"}:
        raise EffectError("unsupported_media", "web-fetch accepts text and JSON only")
    body = raw.decode("utf-8", errors="replace")
    if mime in {"text/html", "application/xhtml+xml"}:
        parser = PageParser(effective)
        parser.feed(body)
        title = " ".join(parser.title_parts)[:240]
        text = html.unescape(" ".join(parser.chunks))[:11000]
        links = parser.links
    else:
        title, text, links = "", body[:11000], []
    return {"url": effective, "title": title, "text": text, "links": links,
            "contentType": mime, "bytes": len(raw)}


def web_explore(args: dict[str, Any]) -> dict[str, Any]:
    seed = required_text(args, "url", 4096)
    first = web_fetch({"url": seed})
    origin = urlparse(first["url"])
    found: list[dict[str, Any]] = [first]
    visited = {first["url"]}
    for url in first["links"]:
        if len(found) >= 4:
            break
        other = urlparse(url)
        if (other.scheme, other.netloc) != (origin.scheme, origin.netloc):
            continue
        if url in visited:
            continue
        visited.add(url)
        try:
            page = web_fetch({"url": url})
        except (EffectError, URLError, HTTPError):
            continue  # partial exploration is explicitly reported
        found.append(page)
    return {"seed": seed, "pages": found, "visited": len(visited),
            "scope": "same-origin-depth-1", "partial": len(visited) > len(found)}


def web_search(args: dict[str, Any]) -> dict[str, Any]:
    query = required_text(args, "query", 512)
    base = os.getenv("STAR_AGENT_SEARXNG_URL", "").strip()
    if not base:
        raise EffectError("not_configured", "set STAR_AGENT_SEARXNG_URL to a trusted SearXNG service")
    parts = urlparse(base)
    if parts.path not in {"", "/", "/search"} or parts.query or parts.fragment:
        raise EffectError("invalid_configuration", "SearXNG endpoint must be its origin or /search")
    public_url(base, trusted_service=True)
    origin = f"{parts.scheme}://{parts.netloc}"
    path = origin + "/search"
    raw, mime, _ = fetch_bytes(
        path + "?" + urlencode({"q": query, "format": "json"}),
        trusted_origin=origin,
    )
    if mime not in {"application/json", "text/json"}:
        raise EffectError("search_failure", "SearXNG JSON response is required")
    payload = json.loads(raw)
    results = payload.get("results", []) if isinstance(payload, dict) else []
    return {"query": query, "results": [
        {"title": str(row.get("title", ""))[:240],
         "url": str(row.get("url", ""))[:2048],
         "summary": str(row.get("content", ""))[:480]}
        for row in results[:12] if isinstance(row, dict)
    ]}


def intel_search(args: dict[str, Any]) -> dict[str, Any]:
    query = required_text(args, "query", 512)
    base = os.getenv("STAR_AGENT_SERVER_URL", "").strip()
    if not base:
        raise EffectError("not_configured", "STAR_AGENT_SERVER_URL is required")
    try:
        from starintel_client import StarIntelClient
        import httpx
    except ImportError as exc:
        raise EffectError("missing_dependency", "install starintel-client for contracted server search") from exc
    client = StarIntelClient(base, api_key=os.getenv("STARINTEL_API_KEY"), timeout=12.0)
    manifest = client.discover()
    if not manifest.has_operation("documents.search"):
        raise EffectError("missing_contract", "server registry lacks documents.search")
    operation = manifest.operation("documents.search")
    if operation.method.upper() != "GET" or not operation.path.startswith("/api/v1/"):
        raise EffectError("invalid_contract", "documents.search registry entry is invalid")
    # The current starintel-client call() API has no query-parameter argument.
    # Use its DISCOVERED registered GET path; do not invent a legacy endpoint.
    url = base.rstrip("/") + operation.path
    headers = {"Accept": "application/json"}
    token = os.getenv("STARINTEL_API_KEY", "")
    if token:
        headers["Authorization"] = "Bearer " + token
    response = httpx.get(url, params={"q": query, "limit": 12},
                         headers=headers, timeout=12.0, follow_redirects=False)
    response.raise_for_status()
    return {"operation": "documents.search", "response": response.json()}


def _actor_manifests() -> list[dict[str, str]]:
    fixture = os.getenv("STAR_AGENT_ACTOR_MANIFEST_FILE", "").strip()
    if fixture:
        rows = Path(fixture).read_text(encoding="utf-8").splitlines()
    else:
        command = shutil.which("starintel-actor-manifests")
        if command is None:
            raise EffectError("missing_dependency", "install pro-actors or set STAR_AGENT_ACTOR_MANIFEST_FILE")
        result = subprocess.run([command], capture_output=True, text=True, timeout=12, check=False)
        if result.returncode:
            raise EffectError("manifest_failure", "pro-actors manifest discovery failed")
        rows = result.stdout.splitlines()
    if len(rows) > 256:
        raise EffectError("oversized_manifests", "too many manifest records")
    manifests = []
    for line in rows:
        if not line.strip():
            continue
        record = json.loads(line)
        ext = record.get("extensions", {}).get("starintel.actor_manifest.v1", {})
        actor = ext.get("actor_id")
        command = ext.get("cli", {}).get("command")
        service = ext.get("service_mode")
        if not isinstance(actor, str) or not ACTOR_ID.fullmatch(actor):
            raise EffectError("invalid_manifest", "actor id is invalid")
        if command != ["sa-" + actor] or not isinstance(service, str):
            raise EffectError("invalid_manifest", "manifest command or service mode is invalid")
        manifests.append({"actor": actor, "binary": command[0], "serviceMode": service})
    return manifests


def actors(_: dict[str, Any]) -> dict[str, Any]:
    return {"actors": _actor_manifests()}


def target_create(args: dict[str, Any]) -> dict[str, Any]:
    actor = required_text(args, "actor", 100)
    target = required_text(args, "target", 2048)
    dataset = required_text(args, "dataset", 120)
    available = {item["actor"]: item for item in _actor_manifests()}
    manifest = available.get(actor)
    if not manifest:
        raise EffectError("unknown_actor", "actor must be present in installed trusted manifests")
    if manifest["serviceMode"] == "continuous-document-stream":
        raise EffectError("unsupported_actor", "document-stream actor requires JSONL input, not a target")
    server = os.getenv("STAR_AGENT_SERVER_URL", "").strip()
    if not server:
        raise EffectError("not_configured", "STAR_AGENT_SERVER_URL required for live submission")
    binary = shutil.which(manifest["binary"])
    if not binary:
        raise EffectError("missing_dependency", "manifest-advertised actor CLI is not installed")
    fingerprint = hashlib.sha256(
        json.dumps([actor, target, dataset], separators=(",", ":")).encode()
    ).hexdigest()
    command = [binary, target, "--dataset", dataset, "--once",
               "--idempotency-key", "star-agent-" + fingerprint,
               "--server", server]
    result = subprocess.run(command, capture_output=True, text=True, timeout=40, check=False)
    if result.returncode:
        raise EffectError("target_failed", "target CLI rejected the request")
    receipt = json.loads(result.stdout)
    if not isinstance(receipt, dict):
        raise EffectError("bad_receipt", "target response must be a JSON object")
    return {"actor": actor, "target": target, "dataset": dataset,
            "receipt": receipt, "status": "submitted_not_completed"}


def valid_domain(target: str) -> str:
    domain = target.lower().rstrip(".")
    if not DOMAIN.fullmatch(domain):
        raise EffectError("invalid_domain", "OSINT target must be a valid domain")
    return domain


def osint_run(args: dict[str, Any]) -> dict[str, Any]:
    name = required_text(args, "tool", 64)
    target = valid_domain(required_text(args, "target", 253))
    enabled = set(x.strip() for x in os.getenv("STAR_AGENT_OSINT_TOOLS", "dns,whois").split(","))
    commands = {
        "dns": ["dig", "+short", target],
        "whois": ["whois", target],
        "subfinder": ["subfinder", "-silent", "-d", target],
    }
    if name not in commands or name not in enabled:
        raise EffectError("osint_denied", "OSINT tool is not allowlisted")
    executable = shutil.which(commands[name][0])
    if not executable:
        raise EffectError("missing_dependency", "OSINT tool executable is not installed")
    result = subprocess.run([executable, *commands[name][1:]],
                            capture_output=True, text=True, timeout=30, check=False)
    if result.returncode:
        raise EffectError("osint_failure", "OSINT executable failed")
    return {"tool": name, "target": target, "stdout": result.stdout[:12000],
            "truncated": len(result.stdout) > 12000}


OPERATIONS = {
    "web_search": web_search,
    "web_fetch": web_fetch,
    "web_explore": web_explore,
    "intel_search": intel_search,
    "actors": actors,
    "target_create": target_create,
    "osint_run": osint_run,
}


def execute(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    if name not in OPERATIONS:
        return {"status": "error", "code": "unknown_operation"}
    try:
        data = OPERATIONS[name](arguments)
        encoded = json.dumps(data, ensure_ascii=False, default=str)
        if len(encoded.encode("utf-8")) > MAX_OUTPUT_BYTES - 2048:
            raise EffectError("oversized_output", "response exceeded output budget")
        return {"status": "ok", "operation": name, "data": data}
    except EffectError as exc:
        return {"status": "error", "operation": name,
                "code": exc.code, "message": str(exc)}
    except (OSError, ValueError, URLError, HTTPError, subprocess.TimeoutExpired):
        return {"status": "error", "operation": name,
                "code": "adapter_failure", "message": "bounded adapter failed"}


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in OPERATIONS:
        print(json.dumps({"status": "error", "code": "unknown_operation"}))
        return 2
    try:
        raw = sys.stdin.read(16_385)
        if len(raw) > 16_384:
            raise ValueError("input too large")
        arguments = json.loads(raw)
        if not isinstance(arguments, dict):
            raise ValueError("expected object")
    except (ValueError, json.JSONDecodeError):
        print(json.dumps({"status": "error", "code": "invalid_request"}))
        return 2
    reply = execute(sys.argv[1], arguments)
    print(json.dumps(reply, ensure_ascii=False, separators=(",", ":")))
    return 0 if reply["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
