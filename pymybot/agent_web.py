"""Bounded web fetch and SearXNG search tools for the agent harness.

The tools are deliberately narrow: HTTPS only (loopback HTTP only under an
explicit test policy), private/link-local/reserved addresses rejected, manual
redirects re-validated on every hop, content-type/size/time limits, and no
cookies or credentials. HTML extraction uses BeautifulSoup; a configured
SearXNG endpoint is the only search provider, and it never fabricates results.
"""
from __future__ import annotations

from dataclasses import dataclass
import ipaddress
import socket
from urllib.parse import urljoin, urlsplit

from . import __version__

ALLOWED_CONTENT = {"text/html", "application/xhtml+xml", "text/plain", "application/json"}
MAX_BYTES = 512 * 1024
MAX_TEXT = 16 * 1024
MAX_RESULTS = 5
MAX_REDIRECTS = 3


class WebError(ValueError):
    """A web request was refused or failed; the message is safe to show."""


@dataclass(frozen=True)
class WebPolicy:
    allow_loopback: bool = False
    timeout: float = 15.0
    max_bytes: int = MAX_BYTES
    max_chars: int = MAX_TEXT


def _httpx():
    try:
        import httpx
    except ImportError:
        raise WebError("Web tools require the optional web extra: pip install pymybot[web]") from None
    return httpx


def _validate_target(url, policy):
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        raise WebError("Invalid URL") from None
    if parts.scheme not in {"http", "https"}:
        raise WebError("Only http(s) URLs are supported")
    if parts.username or parts.password:
        raise WebError("URL credentials are not allowed")
    if not parts.hostname:
        raise WebError("URL must include a host")
    if parts.scheme == "http" and not policy.allow_loopback:
        raise WebError("Plain HTTP is refused; use HTTPS")
    effective_port = port or (443 if parts.scheme == "https" else 80)
    if not policy.allow_loopback and effective_port not in {80, 443}:
        raise WebError("Only standard HTTP(S) ports are allowed")
    try:
        infos = socket.getaddrinfo(parts.hostname, effective_port, type=socket.SOCK_STREAM)
    except OSError:
        raise WebError("DNS resolution failed") from None
    if not infos:
        raise WebError("DNS resolution returned no address")
    for info in infos:
        address = info[4][0]
        try:
            ip = ipaddress.ip_address(address)
        except ValueError:
            raise WebError("URL resolved to an invalid address") from None
        if ip.is_loopback:
            if policy.allow_loopback:
                continue
            raise WebError("URL resolves to a loopback address")
        if not ip.is_global or ip.is_multicast:
            raise WebError("URL resolves to a private, link-local or reserved address")


def _extract(body, content_type, max_chars, charset="utf-8"):
    text = body.decode(charset, errors="replace")
    title = ""
    if content_type in {"text/plain", "application/json"}:
        return title, " ".join(text.split())[:max_chars]
    try:
        from bs4 import BeautifulSoup
    except ImportError:
        raise WebError("HTML extraction requires the optional web extra: pip install pymybot[web]") from None
    soup = BeautifulSoup(text, "html.parser")
    for tag in soup(["script", "style", "noscript", "svg", "template"]):
        tag.decompose()
    if soup.title is not None:
        title = " ".join(soup.title.get_text(" ", strip=True).split())[:300]
    return title, " ".join(soup.get_text(" ", strip=True).split())[:max_chars]


def fetch(url, *, policy=None):
    """Fetch one URL with bounded redirects, size, time and extraction."""
    policy = policy or WebPolicy()
    httpx = _httpx()
    client = httpx.Client(follow_redirects=False, timeout=policy.timeout, trust_env=False,
                          headers={"User-Agent": f"pymybot/{__version__} (agent web tool)"})
    current = str(url or "")
    try:
        for _ in range(MAX_REDIRECTS + 1):
            _validate_target(current, policy)
            with client.stream("GET", current) as response:
                if response.is_redirect:
                    location = response.headers.get("location")
                    if not location:
                        raise WebError("Redirect response has no Location header")
                    current = urljoin(current, location)
                    continue
                if response.status_code >= 400:
                    raise WebError(f"HTTP {response.status_code}")
                content_type = (response.headers.get("content-type") or "").split(";", 1)[0].strip().lower()
                if content_type not in ALLOWED_CONTENT:
                    raise WebError(f"Unsupported content type: {content_type or 'unknown'}")
                data = bytearray()
                truncated = False
                for chunk in response.iter_bytes():
                    room = policy.max_bytes - len(data)
                    if room <= 0:
                        truncated = True
                        break
                    data.extend(chunk[:room])
                    if len(chunk) > room:
                        truncated = True
                        break
                charset = response.charset_encoding or "utf-8"
                body = bytes(data)
                title, text = _extract(body, content_type, policy.max_chars, charset)
                return {
                    "url": str(url), "final_url": current, "status": response.status_code,
                    "content_type": content_type, "title": title, "text": text,
                    "bytes": len(body), "truncated": truncated,
                }
        raise WebError("Too many redirects")
    finally:
        client.close()


def search(query, *, endpoint, policy=None):
    """Query a configured SearXNG instance; no provider means no results."""
    policy = policy or WebPolicy()
    query = str(query or "").strip()
    if not query or len(query) > 512 or "\x00" in query:
        raise WebError("Search query must be 1..512 characters")
    base = str(endpoint or "").strip().rstrip("/")
    if not base:
        raise WebError("Web search is not configured; set a SearXNG endpoint")
    httpx = _httpx()
    url = base + "/search"
    _validate_target(url, policy)
    client = httpx.Client(follow_redirects=False, timeout=policy.timeout, trust_env=False,
                          headers={"User-Agent": f"pymybot/{__version__} (agent web tool)"})
    try:
        response = client.get(url, params={"q": query, "format": "json", "safesearch": "1"})
    finally:
        client.close()
    if response.status_code >= 400:
        raise WebError(f"Search endpoint returned HTTP {response.status_code}")
    try:
        payload = response.json()
    except ValueError:
        raise WebError("Search endpoint did not return JSON") from None
    results = []
    for item in (payload.get("results") or [])[:MAX_RESULTS]:
        if not isinstance(item, dict):
            continue
        link = str(item.get("url") or "")
        if not link.startswith(("http://", "https://")):
            continue
        results.append({"title": str(item.get("title") or "")[:300], "url": link,
                        "snippet": str(item.get("content") or "")[:500]})
    return {"query": query, "provider": "searx", "results": results}


def run_tool(name, arguments, *, timeout, search_endpoint=""):
    """Dispatch a web tool call; blocking I/O runs in a worker thread."""
    if not isinstance(arguments, dict):
        raise WebError("Web tool arguments must be an object")
    policy = WebPolicy(timeout=max(1.0, min(float(timeout), 60.0)))
    if name == "web_fetch":
        url = arguments.get("url")
        if not isinstance(url, str) or not url.strip():
            raise WebError("url must be a non-empty string")
        return fetch(url.strip(), policy=policy)
    if name == "web_search":
        return search(arguments.get("query"), endpoint=search_endpoint, policy=policy)
    raise WebError(f"Unknown web tool: {name}")
