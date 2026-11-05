"""Optional OpenTelemetry tracing for agent turns, model calls and tools.

The harness must run without the observability extra. Importing this module is
safe in either case; when the API is unavailable the context manager is a no-op
and ``current_trace_id`` returns None.
"""
from __future__ import annotations

from contextlib import contextmanager

try:  # pragma: no cover - exercised by the optional extra
    from opentelemetry import trace
    _TRACER = trace.get_tracer("pymybot.agent")
except Exception:  # pragma: no cover - base install
    trace = None
    _TRACER = None


def enabled():
    return _TRACER is not None


@contextmanager
def span(name, **attributes):
    """Create one span; exceptions are recorded and re-raised."""
    if _TRACER is None:
        yield None
        return
    with _TRACER.start_as_current_span(name) as current:
        for key, value in attributes.items():
            if value is not None:
                current.set_attribute(key, value if isinstance(value, (str, bool, int, float)) else str(value))
        try:
            yield current
        except BaseException as exc:
            current.record_exception(exc)
            raise


def current_trace_id():
    if trace is None:
        return None
    try:
        context = trace.get_current_span().get_span_context()
    except Exception:
        return None
    if not context.is_valid:
        return None
    return format(context.trace_id, "032x")
