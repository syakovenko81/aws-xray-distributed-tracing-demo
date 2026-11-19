import json
import unittest

from handler import lambda_handler


class HandlerTest(unittest.TestCase):
    def test_returns_versioned_http_response(self):
        response = lambda_handler({}, None)

        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(response["headers"]["Content-Type"], "application/json")
        body = json.loads(response["body"])
        self.assertEqual(body["message"], "AWS Code Suite Lambda PoC is running")
        self.assertTrue(body["version"])


if __name__ == "__main__":
    unittest.main()
