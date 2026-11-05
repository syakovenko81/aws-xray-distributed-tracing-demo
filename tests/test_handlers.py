import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
LAMBDA_A = ROOT / "lambda" / "lambda_a"
LAMBDA_B = ROOT / "lambda" / "lambda_b"
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")


class FakePayload:
    def __init__(self, value):
        self.value = value

    def read(self):
        return json.dumps(self.value).encode("utf-8")


class FakeLambdaClient:
    def __init__(self, response):
        self.response = response
        self.calls = []

    def invoke(self, **kwargs):
        self.calls.append(kwargs)
        return {"Payload": FakePayload(self.response)}


class FakeTable:
    def __init__(self):
        self.items = []

    def put_item(self, **kwargs):
        self.items.append(kwargs["Item"])


class HandlerTests(unittest.TestCase):
    def test_lambda_a_success(self):
        sys.path.insert(0, str(LAMBDA_A))
        try:
            import handler

            fake_client = FakeLambdaClient({"record_id": "demo-123-abcd", "correlation_id": "demo-123"})
            with patch.object(handler, "lambda_client", fake_client), patch.object(
                handler, "lambda_b_name", "test-lambda-b"
            ):
                response = handler.lambda_handler(
                    {"body": json.dumps({"message": "hello", "correlation_id": "demo-123"})}, None
                )

            self.assertEqual(response["statusCode"], 200)
            self.assertEqual(json.loads(response["body"])["correlation_id"], "demo-123")
            request = json.loads(fake_client.calls[0]["Payload"])
            self.assertIsInstance(request["_trace_context"], dict)
        finally:
            sys.modules.pop("handler", None)
            sys.modules.pop("telemetry", None)
            sys.path.remove(str(LAMBDA_A))

    def test_lambda_a_rejects_invalid_json(self):
        sys.path.insert(0, str(LAMBDA_A))
        try:
            import handler

            response = handler.lambda_handler({"body": "not-json"}, None)
            self.assertEqual(response["statusCode"], 400)
        finally:
            sys.modules.pop("handler", None)
            sys.modules.pop("telemetry", None)
            sys.path.remove(str(LAMBDA_A))

    def test_lambda_b_writes_record(self):
        sys.path.insert(0, str(LAMBDA_B))
        try:
            import handler

            fake_table = FakeTable()
            with patch.object(handler, "table", fake_table):
                result = handler.lambda_handler(
                    {"message": "hello", "correlation_id": "demo-123", "_trace_context": {}}, None
                )

            self.assertEqual(result["correlation_id"], "demo-123")
            self.assertEqual(fake_table.items[0]["correlation_id"], "demo-123")
        finally:
            sys.modules.pop("handler", None)
            sys.modules.pop("telemetry", None)
            sys.path.remove(str(LAMBDA_B))

    def test_lambda_b_controlled_error(self):
        sys.path.insert(0, str(LAMBDA_B))
        try:
            import handler

            with self.assertRaisesRegex(RuntimeError, "controlled DynamoDB failure"):
                handler.lambda_handler(
                    {
                        "message": "hello",
                        "correlation_id": "demo-error",
                        "simulate_error": True,
                        "_trace_context": {},
                    },
                    None,
                )
        finally:
            sys.modules.pop("handler", None)
            sys.modules.pop("telemetry", None)
            sys.path.remove(str(LAMBDA_B))


if __name__ == "__main__":
    unittest.main()
