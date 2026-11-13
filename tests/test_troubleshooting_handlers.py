import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from botocore.exceptions import ClientError


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
    def __init__(self):
        self.calls = []

    def invoke(self, **kwargs):
        self.calls.append(kwargs)
        return {
            "Payload": FakePayload({"record_id": "demo-123-abcd", "correlation_id": "demo-123"})
        }


class FakeTable:
    def __init__(self, error=None):
        self.items = []
        self.put_calls = []
        self.error = error

    def put_item(self, **kwargs):
        self.put_calls.append(kwargs)
        if self.error is not None:
            raise self.error
        self.items.append(kwargs["Item"])


class TroubleshootingHandlerTests(unittest.TestCase):
    def tearDown(self):
        sys.modules.pop("handler", None)
        sys.modules.pop("telemetry", None)

    def test_lambda_a_ignores_hooks_when_flag_is_disabled(self):
        sys.path.insert(0, str(LAMBDA_A))
        try:
            import handler

            fake_client = FakeLambdaClient()
            with patch.object(handler, "lambda_client", fake_client), patch.dict(
                os.environ, {"ENABLE_TROUBLESHOOTING_HOOKS": "false"}, clear=False
            ):
                response = handler.lambda_handler(
                    {
                        "body": json.dumps(
                            {
                                "message": "hello",
                                "correlation_id": "demo-123",
                                "troubleshooting": {"delay_ms": 2000},
                            }
                        )
                    },
                    None,
                )

            self.assertEqual(response["statusCode"], 200)
            request = json.loads(fake_client.calls[0]["Payload"])
            self.assertNotIn("troubleshooting", request)
        finally:
            sys.path.remove(str(LAMBDA_A))

    def test_lambda_a_passes_enabled_hooks_to_lambda_b(self):
        sys.path.insert(0, str(LAMBDA_A))
        try:
            import handler

            fake_client = FakeLambdaClient()
            with patch.object(handler, "lambda_client", fake_client), patch.dict(
                os.environ, {"ENABLE_TROUBLESHOOTING_HOOKS": "true"}, clear=False
            ):
                response = handler.lambda_handler(
                    {
                        "body": json.dumps(
                            {
                                "message": "hello",
                                "correlation_id": "demo-123",
                                "troubleshooting": {"delay_ms": 2000},
                            }
                        )
                    },
                    None,
                )

            self.assertEqual(response["statusCode"], 200)
            request = json.loads(fake_client.calls[0]["Payload"])
            self.assertEqual(request["troubleshooting"], {"delay_ms": 2000, "dependency_error": False})
        finally:
            sys.path.remove(str(LAMBDA_A))

    def test_lambda_b_disabled_hook_writes_normally(self):
        sys.path.insert(0, str(LAMBDA_B))
        try:
            import handler

            fake_table = FakeTable()
            with patch.object(handler, "table", fake_table), patch.dict(
                os.environ, {"ENABLE_TROUBLESHOOTING_HOOKS": "false"}, clear=False
            ), patch.object(handler.time, "sleep") as sleep:
                result = handler.lambda_handler(
                    {
                        "message": "hello",
                        "correlation_id": "demo-123",
                        "troubleshooting": {"delay_ms": 2000},
                        "_trace_context": {},
                    },
                    None,
                )

            self.assertEqual(result["correlation_id"], "demo-123")
            self.assertEqual(len(fake_table.items), 1)
            self.assertNotIn("ConditionExpression", fake_table.put_calls[0])
            sleep.assert_not_called()
        finally:
            sys.path.remove(str(LAMBDA_B))

    def test_lambda_b_enabled_delay_is_bounded_and_applied(self):
        sys.path.insert(0, str(LAMBDA_B))
        try:
            import handler

            fake_table = FakeTable()
            with patch.object(handler, "table", fake_table), patch.dict(
                os.environ, {"ENABLE_TROUBLESHOOTING_HOOKS": "true"}, clear=False
            ), patch.object(handler.time, "sleep") as sleep:
                handler.lambda_handler(
                    {
                        "message": "hello",
                        "correlation_id": "demo-123",
                        "troubleshooting": {"delay_ms": 2000},
                        "_trace_context": {},
                    },
                    None,
                )

            sleep.assert_called_once_with(2)
        finally:
            sys.path.remove(str(LAMBDA_B))

    def test_lambda_b_enabled_dependency_error_uses_false_condition_on_existing_table(self):
        sys.path.insert(0, str(LAMBDA_B))
        try:
            import handler

            conditional_error = ClientError(
                {
                    "Error": {
                        "Code": "ConditionalCheckFailedException",
                        "Message": "The conditional request failed",
                    }
                },
                "PutItem",
            )
            fake_table = FakeTable(error=conditional_error)
            with patch.object(handler, "table", fake_table), patch.dict(
                os.environ, {"ENABLE_TROUBLESHOOTING_HOOKS": "true"}, clear=False
            ):
                with self.assertRaises(ClientError) as raised:
                    handler.lambda_handler(
                        {
                            "message": "hello",
                            "correlation_id": "demo-123",
                            "troubleshooting": {"dependency_error": True},
                            "_trace_context": {},
                        },
                        None,
                    )

            self.assertEqual(
                raised.exception.response["Error"]["Code"],
                "ConditionalCheckFailedException",
            )
            self.assertEqual(len(fake_table.put_calls), 1)
            self.assertEqual(
                fake_table.put_calls[0]["ConditionExpression"],
                handler.CONTROLLED_FAILURE_CONDITION,
            )
            self.assertEqual(len(fake_table.items), 0)
        finally:
            sys.path.remove(str(LAMBDA_B))

    def test_lambda_b_simulate_error_still_precedes_troubleshooting(self):
        sys.path.insert(0, str(LAMBDA_B))
        try:
            import handler

            fake_table = FakeTable()
            with patch.object(handler, "table", fake_table), patch.dict(
                os.environ, {"ENABLE_TROUBLESHOOTING_HOOKS": "true"}, clear=False
            ):
                with self.assertRaisesRegex(RuntimeError, "controlled DynamoDB failure"):
                    handler.lambda_handler(
                        {
                            "message": "hello",
                            "correlation_id": "demo-error",
                            "simulate_error": True,
                            "troubleshooting": {"dependency_error": True},
                            "_trace_context": {},
                        },
                        None,
                    )

            self.assertEqual(fake_table.put_calls, [])
        finally:
            sys.path.remove(str(LAMBDA_B))


if __name__ == "__main__":
    unittest.main()
