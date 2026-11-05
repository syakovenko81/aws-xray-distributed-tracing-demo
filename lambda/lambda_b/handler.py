import logging
import os
import uuid

import boto3

from telemetry import annotate, extract, mark_error, span, trace_ids


logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ.get("TABLE_NAME", "local-records"))


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

            record_id = f"{correlation_id}-{uuid.uuid4().hex[:12]}"
            table.put_item(
                Item={
                    "record_id": record_id,
                    "correlation_id": correlation_id,
                    "message": message,
                }
            )
        except Exception as error:
            mark_error(process_span, error)
            logger.exception("Lambda B failed correlation_id=%s trace=%s", correlation_id, trace_ids())
            raise

        logger.info("stored record correlation_id=%s trace=%s", correlation_id, trace_ids())
        return {"record_id": record_id, "correlation_id": correlation_id}
