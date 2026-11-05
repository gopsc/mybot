"""Long-term memory for the autonomous agent, retrieved with lexical RAG.

The store is deliberately dependency-free: entries live in an append-only
JSONL file beside the role, and retrieval is BM25 over ASCII words plus CJK
character bigrams. There is no embedding service, no vector database and no
network call, so a role's memory works offline and stays auditable as text.

This is *long-term* memory, not the per-conversation tiered context in
``agent_memory.py``: entries survive process restarts, are shared by every
mission of one role, and are distilled by the memory agent rather than by
mechanical turn summarising.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, replace
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import secrets
import statistics
import threading

from .agent_utils import clip

KINDS = ("fact", "decision", "preference", "gotcha", "summary", "task")
DEFAULT_MAX_ENTRIES = 4000
DEFAULT_MAX_ENTRY_BYTES = 4096
MAX_TEXT = 2000
MAX_TAGS = 12
MAX_TAG = 32
MAX_QUERY = 2000
MAX_FILE_BYTES = 16 * 1024 * 1024
_ASCII = re.compile(r"[a-z0-9_]{2,}")
_CJK = re.compile(r"[\u4e00-\u9fff]+")
_WS = re.compile(r"\s+")
_BM25_K1 = 1.4
_BM25_B = 0.72
_RECENCY_HALF_LIFE_DAYS = 30.0
_SALIENCE_WEIGHT = 0.25
_RECENCY_WEIGHT = 0.15


class MemoryStoreError(ValueError):
    """Raised for malformed memory input; never a hardware or runtime error."""


def tokenize(text):
    """ASCII words (>= 2 chars) plus overlapping CJK bigrams.

    Bigrams are what make retrieval work for Chinese without a segmenter,
    and they behave well enough for the mixed-language notes this agent
    writes.
    """
    folded = str(text).casefold()
    tokens = _ASCII.findall(folded)
    for run in _CJK.finditer(folded):
        chars = run.group()
        if len(chars) == 1:
            tokens.append(chars)
        else:
            tokens.extend(chars[index:index + 2] for index in range(len(chars) - 1))
    return tokens


def _now():
    return datetime.now(timezone.utc)


def _iso(moment):
    return moment.isoformat(timespec="seconds")


def _parse_time(value):
    try:
        return datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None


def _normalise(text):
    return _WS.sub(" ", str(text)).strip().casefold()


@dataclass(frozen=True)
class MemoryEntry:
    id: str
    ts: str
    kind: str
    text: str
    tags: tuple[str, ...] = ()
    salience: float = 0.5
    mission: str = ""
    step: int = 0

    def as_dict(self):
        return {"id": self.id, "ts": self.ts, "kind": self.kind, "text": self.text,
                "tags": list(self.tags), "salience": self.salience,
                "mission": self.mission, "step": self.step}

    @classmethod
    def from_dict(cls, data):
        if not isinstance(data, dict):
            raise MemoryStoreError("memory entry must be an object")
        text = data.get("text")
        if not isinstance(text, str) or not text.strip():
            raise MemoryStoreError("memory entry text is required")
        kind = data.get("kind") if data.get("kind") in KINDS else "fact"
        tags = data.get("tags") if isinstance(data.get("tags"), list) else []
        clean_tags = tuple(str(tag)[:MAX_TAG] for tag in tags[:MAX_TAGS] if str(tag).strip())
        try:
            salience = float(data.get("salience", 0.5))
        except (TypeError, ValueError):
            salience = 0.5
        salience = min(1.0, max(0.0, salience))
        entry_id = data.get("id")
        if not isinstance(entry_id, str) or not entry_id:
            entry_id = secrets.token_hex(8)
        step = data.get("step") if type(data.get("step")) is int else 0
        return cls(id=entry_id[:32], ts=str(data.get("ts") or _iso(_now())), kind=kind,
                   text=clip(text, MAX_TEXT), tags=clean_tags, salience=salience,
                   mission=str(data.get("mission") or "")[:64], step=max(0, step))


@dataclass
class _Document:
    entry: MemoryEntry
    counts: Counter
    length: int


class MemoryStore:
    """Bounded, thread-safe long-term memory rooted beside one role."""

    def __init__(self, root, *, max_entries=DEFAULT_MAX_ENTRIES,
                 max_entry_bytes=DEFAULT_MAX_ENTRY_BYTES):
        self.root = Path(root)
        self.max_entries = int(max_entries)
        self.max_entry_bytes = int(max_entry_bytes)
        self._lock = threading.RLock()
        self._docs: list[_Document] = []
        self._df: Counter = Counter()
        self._seen: dict[str, MemoryEntry] = {}
        self._rejected = 0
        self._prepare()
        self._load()

    # -- storage -----------------------------------------------------------
    @property
    def path(self):
        return self.root / "entries.jsonl"

    def _prepare(self):
        if self.root.exists() and self.root.is_symlink():
            raise MemoryStoreError("memory root must not be a symbolic link")
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            os.chmod(self.root, 0o700)
        except OSError:
            pass

    def _load(self):
        path = self.path
        if not path.exists():
            return
        if path.is_symlink() or not path.is_file():
            raise MemoryStoreError("memory file must be a regular file")
        if path.stat().st_size > MAX_FILE_BYTES:
            raise MemoryStoreError("memory file exceeds its size limit")
        with path.open("r", encoding="utf-8") as stream:
            for line in stream:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = MemoryEntry.from_dict(json.loads(line))
                except (ValueError, TypeError):
                    self._rejected += 1
                    continue
                self._index(entry)
        with self._lock:
            self._evict_locked()

    def _index(self, entry):
        key = _normalise(entry.text)
        if key in self._seen:
            return False
        counts = Counter(tokenize(entry.text))
        length = sum(counts.values()) or 1
        self._docs.append(_Document(entry, counts, length))
        for token in counts:
            self._df[token] += 1
        self._seen[key] = entry
        return True

    def _evict_locked(self):
        if len(self._docs) <= self.max_entries:
            return
        ranked = sorted(self._docs, key=lambda doc: (doc.entry.salience,
                                                     _parse_time(doc.entry.ts) or _now()))
        drop = len(self._docs) - self.max_entries
        for document in ranked[:drop]:
            self._remove_locked(document)
        self._rewrite()

    def _remove_locked(self, document):
        try:
            self._docs.remove(document)
        except ValueError:
            return
        for token in document.counts:
            self._df[token] -= 1
            if self._df[token] <= 0:
                del self._df[token]
        self._seen.pop(_normalise(document.entry.text), None)

    def consolidate(self):
        """Rewrite the file, dropping duplicates and abandoned rows."""
        with self._lock:
            self._rewrite()
            return len(self._docs)

    def _rewrite(self):
        data = "".join(json.dumps(document.entry.as_dict(), ensure_ascii=False,
                                  allow_nan=False, separators=(",", ":")) + "\n"
                       for document in self._docs)
        temporary = self.root / f".entries.{secrets.token_hex(8)}.tmp"
        descriptor = None
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                descriptor = None
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            try:
                os.chmod(self.path, 0o600)
            except OSError:
                pass
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass

    # -- writing -----------------------------------------------------------
    def append(self, text, *, kind="fact", tags=(), salience=0.5, mission="", step=0):
        """Store one distilled memory; duplicates reinforce instead of repeating."""
        if not isinstance(text, str) or not text.strip():
            raise MemoryStoreError("memory text is required")
        collapsed = _WS.sub(" ", text).strip()
        # Bound the raw input before clipping: truncating first would let an
        # oversized blob through silently.
        if len(collapsed.encode("utf-8")) > self.max_entry_bytes:
            raise MemoryStoreError(f"memory text exceeds {self.max_entry_bytes} bytes")
        clean = clip(collapsed, MAX_TEXT)
        if kind not in KINDS:
            raise MemoryStoreError(f"memory kind must be one of {', '.join(KINDS)}")
        clean_tags = []
        for tag in tags or ():
            tag = clip(str(tag).strip(), MAX_TAG)
            if tag and tag not in clean_tags:
                clean_tags.append(tag)
        try:
            salience = min(1.0, max(0.0, float(salience)))
        except (TypeError, ValueError):
            salience = 0.5
        entry = MemoryEntry(id=secrets.token_hex(8), ts=_iso(_now()), kind=kind, text=clean,
                            tags=tuple(clean_tags[:MAX_TAGS]), salience=salience,
                            mission=str(mission)[:64], step=max(0, int(step or 0)))
        with self._lock:
            existing = self._seen.get(_normalise(clean))
            if existing is not None:
                reinforced = replace(existing, salience=min(1.0, max(existing.salience, salience) + 0.1),
                                     ts=entry.ts, kind=kind, tags=entry.tags or existing.tags)
                self._docs = [_Document(reinforced, doc.counts, doc.length)
                              if doc.entry.id == existing.id else doc for doc in self._docs]
                self._seen[_normalise(clean)] = reinforced
                self._rewrite()
                return reinforced
            if not self._index(entry):
                return self._seen[_normalise(clean)]
            line = json.dumps(entry.as_dict(), ensure_ascii=False, allow_nan=False,
                              separators=(",", ":")) + "\n"
            descriptor = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(line)
            try:
                os.chmod(self.path, 0o600)
            except OSError:
                pass
            # Eviction may drop the row that was just written, so it runs last.
            self._evict_locked()
            return entry

    # -- reading -----------------------------------------------------------
    def entries(self):
        with self._lock:
            return [document.entry for document in self._docs]

    def recent(self, limit=10):
        with self._lock:
            docs = sorted(self._docs, key=lambda doc: (_parse_time(doc.entry.ts) or _now()),
                          reverse=True)
            return [doc.entry for doc in docs[:max(0, int(limit))]]

    def search(self, query, *, k=8, budget_bytes=6000):
        """Return the most relevant memories, bounded by count and bytes."""
        if not isinstance(query, str) or not query.strip():
            return self.recent(k)
        if len(query.encode("utf-8")) > MAX_QUERY:
            query = query.encode("utf-8")[:MAX_QUERY].decode("utf-8", "ignore")
        terms = list(dict.fromkeys(tokenize(query)))
        with self._lock:
            if not self._docs:
                return []
            scored = self._rank_locked(terms)
            return self._bounded(scored, k, budget_bytes)

    def _rank_locked(self, terms):
        total = len(self._docs)
        average = statistics.fmean(doc.length for doc in self._docs) or 1.0
        now = _now()
        ranked = []
        for document in self._docs:
            score = 0.0
            for term in terms:
                frequency = document.counts.get(term, 0)
                if not frequency:
                    continue
                df = self._df.get(term, 0)
                idf = math.log(1 + (total - df + 0.5) / (df + 0.5))
                score += idf * frequency * (_BM25_K1 + 1) / (
                    frequency + _BM25_K1 * (1 - _BM25_B + _BM25_B * document.length / average))
            if terms:
                score /= math.sqrt(len(terms))
            stamp = _parse_time(document.entry.ts)
            days = max(0.0, (now - stamp).total_seconds() / 86400) if stamp else 365.0
            recency = 0.5 ** (days / _RECENCY_HALF_LIFE_DAYS)
            score += _SALIENCE_WEIGHT * document.entry.salience + _RECENCY_WEIGHT * recency
            ranked.append((score, document))
        ranked.sort(key=lambda item: item[0], reverse=True)
        return [document for score, document in ranked if score > 0] or [doc for _, doc in ranked]

    @staticmethod
    def _bounded(documents, k, budget_bytes):
        selected = []
        used = 0
        for document in documents:
            if len(selected) >= max(0, int(k)):
                break
            cost = len(document.entry.text.encode("utf-8")) + 32
            if selected and used + cost > budget_bytes:
                break
            selected.append(document.entry)
            used += cost
        return selected

    def stats(self):
        with self._lock:
            kinds = Counter(document.entry.kind for document in self._docs)
            return {"entries": len(self._docs), "terms": len(self._df),
                    "kinds": dict(kinds), "rejected_lines": self._rejected,
                    "bytes": self.path.stat().st_size if self.path.is_file() else 0}

    @staticmethod
    def render(entries):
        """Render memories as a bounded prompt block."""
        if not entries:
            return ""
        lines = []
        for entry in entries:
            tags = f" #{' #'.join(entry.tags)}" if entry.tags else ""
            lines.append(f"- [{entry.kind} {entry.salience:.2f}]{tags} {entry.text}")
        return "\n".join(lines)
