import json

from version import APP_VERSION


def lambda_handler(event, context):
    """Return a small, versioned response for API and direct Lambda events."""
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "message": "AWS Code Suite Lambda PoC is running",
                "version": APP_VERSION,
            }
        ),
    }
