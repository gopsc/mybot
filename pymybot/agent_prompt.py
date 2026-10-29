"""Layered system instructions with a hard byte budget.

``SOUL`` is the immutable safety contract. ``OPERATOR`` is operator-authored
guidance, ``PROJECT CONTEXT`` is generated inventory from the configured
workspace/structure/scripts and is explicitly labelled as untrusted data, and
``GUIDE`` contains runtime-generated material such as skill indexes and MCP
server descriptions.

Only optional layers are truncated. The safety contract is never dropped.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path

from .security import SecurityError

MAX_OPERATOR_PROMPT = 8 * 1024
MAX_PROMPT_TOTAL = 16 * 1024
DEFAULT_CONTEXT_BYTES = 4 * 1024
_TRUNCATION = "\n[truncated by prompt budget]\n"
SECTION_NAMES = ("SOUL", "OPERATOR", "PROJECT CONTEXT", "GUIDE")


@dataclass(frozen=True)
class PromptResult:
    text: str
    digest: str
    sections: tuple[str, ...]
    truncated: tuple[str, ...]


def read_operator_prompt(path, cap=MAX_OPERATOR_PROMPT):
    """Read an operator-owned UTF-8 prompt file; never follow a directory or NUL."""
    if not path:
        return ""
    candidate = Path(path).expanduser()
    if not candidate.is_file():
        raise SecurityError(f"Operator prompt is not a regular file: {candidate}")
    try:
        data = candidate.read_bytes()
    except OSError as exc:
        raise SecurityError(f"Cannot read operator prompt: {exc.strerror or exc}") from None
    if len(data) > cap:
        raise SecurityError(f"Operator prompt exceeds {cap} bytes")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise SecurityError("Operator prompt must be UTF-8")
    if "\x00" in text:
        raise SecurityError("Operator prompt contains a NUL byte")
    return text.strip()


def _section(title, text):
    body = str(text or "").strip()
    return f"[{title}]\n{body}\n" if body else ""


def build_instructions(soul, *, operator="", project="", guide="", budget=MAX_PROMPT_TOTAL):
    """Compose layers in priority order; truncate only optional sections."""
    if not isinstance(budget, int) or budget <= 0:
        raise ValueError("Prompt budget must be a positive integer")
    mandatory = _section("SOUL", soul)
    if not mandatory:
        raise ValueError("SOUL layer must not be empty")
    if len(mandatory) > budget:
        raise ValueError("Prompt budget is smaller than the SOUL layer")
    text = mandatory
    truncated = []
    sections = ["SOUL"]
    for title, body in (("OPERATOR", operator), ("PROJECT CONTEXT", project), ("GUIDE", guide)):
        if not str(body or "").strip():
            continue
        header = f"\n[{title}]\n"
        remaining = budget - len(text) - len(header) - 1  # trailing newline
        if remaining <= len(_TRUNCATION):
            truncated.append(title)
            continue
        body = str(body).strip()
        if len(body) > remaining:
            body = body[:remaining - len(_TRUNCATION)].rstrip() + _TRUNCATION
            truncated.append(title)
        text += header + body + "\n"
        sections.append(title)
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]
    return PromptResult(text=text, digest=digest, sections=tuple(sections),
                        truncated=tuple(truncated))
