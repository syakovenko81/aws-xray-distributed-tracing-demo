import logging
import os
import time
import uuid

import boto3

from telemetry import annotate, extract, mark_error, span, trace_ids


logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ.get("TABLE_NAME", "local-records"))

CONTROLLED_FAILURE_CONDITION = "attribute_exists(record_id) AND attribute_not_exists(record_id)"


def _troubleshooting_options(event):
    if os.environ.get("ENABLE_TROUBLESHOOTING_HOOKS", "false").lower() != "true":
        return {}

    options = event.get("troubleshooting")
    if options is None:
        return {}
    if not isinstance(options, dict):
        raise ValueError("troubleshooting must be an object")

    allowed_keys = {"delay_ms", "dependency_error"}
    unknown_keys = set(options) - allowed_keys
    if unknown_keys:
        raise ValueError("unsupported troubleshooting option")

    delay_ms = options.get("delay_ms", 0)
    if isinstance(delay_ms, bool) or not isinstance(delay_ms, int) or not 0 <= delay_ms <= 30000:
        raise ValueError("delay_ms must be an integer from 0 to 30000")

    dependency_error = options.get("dependency_error", False)
    if not isinstance(dependency_error, bool):
        raise ValueError("dependency_error must be a boolean")

    return {"delay_ms": delay_ms, "dependency_error": dependency_error}


def lambda_handler(event, context):
    parent_context = extract(event.get("_trace_context", {})) if isinstance(event, dict) else None

    with span("lambda_b.process", context=parent_context) as process_span:
        correlation_id = event.get("correlation_id") if isinstance(event, dict) else None
        annotate(
            process_span,
            correlation_id=correlation_id or "unknown",
            operation="write_record",
            function_name=os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "lambda-b"),
            request_type="lambda",
        )

        try:
            if not isinstance(event, dict):
                raise ValueError("event must be an object")
            if event.get("simulate_error"):
                raise RuntimeError("controlled DynamoDB failure for tracing demo")
            message = event.get("message")
            if not isinstance(message, str) or not message.strip():
                raise ValueError("message is required")
            if not isinstance(correlation_id, str) or not correlation_id:
                raise ValueError("correlation_id is required")

            troubleshooting = _troubleshooting_options(event)
            delay_ms = troubleshooting.get("delay_ms", 0)
            if delay_ms:
                logger.info(
                    "troubleshooting delay_ms=%s correlation_id=%s",
                    delay_ms,
                    correlation_id,
                )
                time.sleep(delay_ms / 1000)

            record_id = f"{correlation_id}-{uuid.uuid4().hex[:12]}"
            put_kwargs = {
                "Item": {
                    "record_id": record_id,
                    "correlation_id": correlation_id,
                    "message": message,
                }
            }
            if troubleshooting.get("dependency_error", False):
                logger.warning(
                    "troubleshooting dependency_error=true correlation_id=%s",
                    correlation_id,
                )
                put_kwargs["ConditionExpression"] = CONTROLLED_FAILURE_CONDITION

            table.put_item(**put_kwargs)
        except Exception as error:
            mark_error(process_span, error)
            logger.exception("Lambda B failed correlation_id=%s trace=%s", correlation_id, trace_ids())
            raise

        logger.info("stored record correlation_id=%s trace=%s", correlation_id, trace_ids())
        return {"record_id": record_id, "correlation_id": correlation_id}
