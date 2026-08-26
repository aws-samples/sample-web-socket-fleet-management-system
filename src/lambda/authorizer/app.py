import os


def handler(event, context):
    """API key authorizer for API Gateway."""
    api_key = os.environ.get("API_KEY")
    if not api_key:
        print("ERROR: API_KEY environment variable not set")
        return {"isAuthorized": False}

    # Get API key from request header
    request_key = event.get("headers", {}).get("x-api-key", "")

    if request_key and request_key == api_key:
        return {"isAuthorized": True}

    return {"isAuthorized": False}
