import json
import logging
import os
import uuid

import boto3

from telemetry import annotate, inject, mark_error, span, trace_ids


logger = logging.getLogger()
logger.setLevel(logging.INFO)

lambda_client = boto3.client("lambda")
lambda_b_name = os.environ.get("LAMBDA_B_NAME", "local-lambda-b")


def _troubleshooting_options(body):
    if os.environ.get("ENABLE_TROUBLESHOOTING_HOOKS", "false").lower() != "true":
        return None

    options = body.get("troubleshooting")
    if options is None:
        return None
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


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


def _request_body(event):
    raw_body = event.get("body", event)
    if event.get("isBase64Encoded"):
        raise ValueError("base64 encoded requests are not supported in this demo")
    if isinstance(raw_body, str):
        return json.loads(raw_body)
    if isinstance(raw_body, dict):
        return raw_body
    raise ValueError("request body must be a JSON object")


def lambda_handler(event, context):
    with span("lambda_a.request") as request_span:
        annotate(
            request_span,
            operation="api_request",
            function_name=os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "lambda-a"),
            request_type="api",
        )

        try:
            body = _request_body(event)
            if not isinstance(body, dict):
                raise ValueError("request body must be a JSON object")
            message = body.get("message")
            if not isinstance(message, str) or not message.strip() or len(message) > 256:
                raise ValueError("message must be a non-empty string of at most 256 characters")
            correlation_id = body.get("correlation_id") or f"demo-{uuid.uuid4().hex[:16]}"
            if not isinstance(correlation_id, str) or not 1 <= len(correlation_id) <= 64:
                raise ValueError("correlation_id must be a string of 1-64 characters")
            simulate_error = body.get("simulate_error", False)
            if not isinstance(simulate_error, bool):
                raise ValueError("simulate_error must be a boolean")
            troubleshooting = _troubleshooting_options(body)
        except (TypeError, ValueError, json.JSONDecodeError) as error:
            mark_error(request_span, error)
            logger.warning("invalid request: %s", error)
            return _response(400, {"error": "invalid_request"})

        annotate(request_span, correlation_id=correlation_id)
        logger.info("accepted request correlation_id=%s trace=%s", correlation_id, trace_ids())

        with span("lambda_a.invoke_lambda_b") as invoke_span:
            annotate(
                invoke_span,
                correlation_id=correlation_id,
                operation="invoke_lambda_b",
                function_name=os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "lambda-a"),
                request_type="lambda",
            )
            trace_context = inject({})
            request = {
                "message": message,
                "correlation_id": correlation_id,
                "simulate_error": simulate_error,
                "_trace_context": trace_context,
            }
            if troubleshooting is not None:
                request["troubleshooting"] = troubleshooting

            try:
                result = lambda_client.invoke(
                    FunctionName=lambda_b_name,
                    InvocationType="RequestResponse",
                    Payload=json.dumps(request).encode("utf-8"),
                )
                response_payload = json.loads(result["Payload"].read())
                if result.get("FunctionError"):
                    raise RuntimeError("Lambda B returned a handled error")
            except Exception as error:
                mark_error(invoke_span, error)
                logger.exception("Lambda B failed correlation_id=%s", correlation_id)
                return _response(502, {"error": "downstream_failure", "correlation_id": correlation_id})

        return _response(
            200,
            {
                "status": "stored",
                "record_id": response_payload["record_id"],
                "correlation_id": correlation_id,
            },
        )
