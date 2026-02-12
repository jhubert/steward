#!/usr/bin/env python3
"""General-purpose HTTP request tool for AI agents.

Makes HTTP requests and returns the status code + response body.
Accepts method, URL, headers, and body as a JSON params argument.

Usage:
    http-request.py <json_params>

Params:
    url (required): The full URL to request
    method: HTTP method (GET, POST, PUT, PATCH, DELETE). Default: GET
    headers: Object of header key-value pairs
    body: Request body (string or JSON object)
    content_type: Shorthand for Content-Type header (e.g. "application/json")

Examples:
    http-request.py '{"url": "https://api.example.com/data"}'
    http-request.py '{"url": "https://api.example.com/auth", "method": "POST", "body": {"client_name": "Steward"}, "content_type": "application/json"}'
"""

import json
import sys
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError


def main():
    if len(sys.argv) < 2:
        print("Usage: http-request.py <json_params>", file=sys.stderr)
        sys.exit(1)

    raw = sys.argv[1]
    if raw == "params" or not raw:
        print("Error: params required. Provide JSON with at least a 'url' key.", file=sys.stderr)
        sys.exit(1)

    try:
        params = json.loads(raw)
    except json.JSONDecodeError:
        try:
            params = json.loads(raw.replace("=>", ":"))
        except json.JSONDecodeError as e:
            print(f"Error parsing JSON params: {e}", file=sys.stderr)
            sys.exit(1)

    url = params.get("url")
    if not url:
        print("Error: 'url' parameter is required.", file=sys.stderr)
        sys.exit(1)

    method = params.get("method", "GET").upper()
    headers = params.get("headers", {})
    body = params.get("body")
    content_type = params.get("content_type")

    # Set content type
    if content_type:
        headers["Content-Type"] = content_type

    # Encode body
    data = None
    if body is not None:
        if isinstance(body, (dict, list)):
            data = json.dumps(body).encode("utf-8")
            if "Content-Type" not in headers:
                headers["Content-Type"] = "application/json"
        elif isinstance(body, str):
            data = body.encode("utf-8")
        else:
            data = str(body).encode("utf-8")

    req = Request(url, data=data, headers=headers, method=method)

    try:
        with urlopen(req, timeout=25) as resp:
            status = resp.status
            resp_headers = dict(resp.headers)
            body_bytes = resp.read()
    except HTTPError as e:
        status = e.code
        resp_headers = dict(e.headers)
        body_bytes = e.read()
    except URLError as e:
        print(f"Connection error: {e.reason}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Request failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Try to decode as text
    try:
        body_text = body_bytes.decode("utf-8")
    except UnicodeDecodeError:
        body_text = f"(binary response, {len(body_bytes)} bytes)"

    # Try to pretty-print JSON
    try:
        parsed = json.loads(body_text)
        body_text = json.dumps(parsed, indent=2)
    except (json.JSONDecodeError, ValueError):
        pass

    print(f"HTTP {status}")
    print(body_text)


if __name__ == "__main__":
    main()
