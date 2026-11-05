"""Small ADOT/OpenTelemetry adapter with a no-op fallback for local unit tests."""

from contextlib import contextmanager

try:
    from opentelemetry import propagate, trace
    from opentelemetry.trace import Status, StatusCode
except ImportError:  # pragma: no cover - only used outside the Lambda layer
    propagate = None
    trace = None
    Status = None
    StatusCode = None


class _NoopSpan:
    def set_attribute(self, _key, _value):
        return None

    def record_exception(self, _error):
        return None

    def set_status(self, _status):
        return None


ANNOTATION_KEYS = ["correlation_id", "operation", "function_name", "request_type"]


@contextmanager
def span(name, context=None):
    if trace is None:
        yield _NoopSpan()
        return

    tracer = trace.get_tracer("aws-xray-distributed-tracing-demo")
    with tracer.start_as_current_span(name, context=context) as current:
        yield current


def inject(carrier):
    if propagate is not None:
        propagate.inject(carrier)
    return carrier


def extract(carrier):
    if propagate is None:
        return None
    return propagate.extract(carrier=carrier)


def annotate(current_span, **attributes):
    for key, value in attributes.items():
        current_span.set_attribute(key, str(value))
    current_span.set_attribute("aws.xray.annotations", ANNOTATION_KEYS)


def mark_error(current_span, error):
    current_span.record_exception(error)
    if Status is not None:
        current_span.set_status(Status(StatusCode.ERROR, str(error)))


def trace_ids():
    if trace is None:
        return {"trace_id": "unavailable", "span_id": "unavailable"}
    span_context = trace.get_current_span().get_span_context()
    if not span_context.is_valid:
        return {"trace_id": "unavailable", "span_id": "unavailable"}
    return {
        "trace_id": format(span_context.trace_id, "032x"),
        "span_id": format(span_context.span_id, "016x"),
    }
