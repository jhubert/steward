#!/usr/bin/env python3
"""
Boardwise API client for AI agents.

Usage:
    boardwise-api.py auth                    # Initiate device auth flow
    boardwise-api.py auth-poll <code>        # Poll for token after user approval
    boardwise-api.py me                      # Get authenticated user info
    boardwise-api.py tools                   # List available API tools
    boardwise-api.py <tool> --org <slug> ... # Call a Boardwise API tool
    boardwise-api.py download_document --org <slug> id=<doc_id> [dest=<path>]

Examples:
    boardwise-api.py list_groups --org 888488
    boardwise-api.py list_meetings --org 888488 status=upcoming
    boardwise-api.py create_meeting --org 888488 title="Q1 Board Meeting" starts_at="2026-03-15T14:00:00Z" ends_at="2026-03-15T16:00:00Z"
    boardwise-api.py download_document --org 888488 id=<doc_id> dest=/tmp/doc.pdf
"""

import json
import os
import re
import sys
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from urllib.parse import urlencode

BASE_URL = "https://app.boardwise.co"
CONFIG_PATH = Path.home() / ".config" / "boardwise" / "config.json"

def load_config():
    """Load config from file."""
    if CONFIG_PATH.exists():
        return json.loads(CONFIG_PATH.read_text())
    return {}

def save_config(config):
    """Save config to file."""
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(config, indent=2))

def get_token():
    """Get the stored access token."""
    config = load_config()
    token = config.get("access_token")
    if not token:
        print("Error: Not authenticated. Run 'boardwise-api.py auth' first.", file=sys.stderr)
        sys.exit(1)
    return token

def api_request(method, path, data=None, token=None):
    """Make an API request."""
    url = f"{BASE_URL}{path}"
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "Boardwise-API-Client/1.0 (OpenClaw)"
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    
    body = json.dumps(data).encode() if data else None
    req = Request(url, data=body, headers=headers, method=method)
    
    try:
        with urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except HTTPError as e:
        error_body = e.read().decode()
        try:
            error_json = json.loads(error_body)
            print(f"Error {e.code}: {json.dumps(error_json, indent=2)}", file=sys.stderr)
        except:
            print(f"Error {e.code}: {error_body}", file=sys.stderr)
        sys.exit(1)

def cmd_auth(args):
    """Start device authorization flow."""
    client_name = "OpenClaw Assistant"
    for arg in args:
        if arg.startswith("--client-name="):
            client_name = arg.split("=", 1)[1]
    
    result = api_request("POST", "/api/v1/auth/device", {
        "client_name": client_name
    })
    
    print(f"\n{'='*50}")
    print("AUTHORIZATION REQUIRED")
    print(f"{'='*50}")
    print(f"\n1. Go to: {result['verification_uri']}")
    print(f"2. Enter code: {result['user_code']}")
    print(f"\nCode expires in {result['expires_in'] // 60} minutes.")
    print(f"\nAfter approving, run:")
    print(f"  boardwise-api.py auth-poll {result['device_code']}")
    
    # Also output JSON for programmatic use
    print(f"\n--- JSON ---")
    print(json.dumps(result, indent=2))

def cmd_auth_poll(args):
    """Poll for token after user approval."""
    if not args:
        print("Error: device_code required", file=sys.stderr)
        sys.exit(1)
    
    device_code = args[0]
    result = api_request("POST", "/api/v1/auth/device/token", {
        "device_code": device_code
    })
    
    if "access_token" in result:
        config = load_config()
        config["access_token"] = result["access_token"]
        save_config(config)
        print("Successfully authenticated!")
        print(f"Token saved to {CONFIG_PATH}")
    else:
        print(json.dumps(result, indent=2))

def cmd_me():
    """Get authenticated user info."""
    token = get_token()
    result = api_request("GET", "/api/v1/auth/me", token=token)
    print(json.dumps(result, indent=2))

def cmd_tools():
    """List available API tools."""
    token = get_token()
    result = api_request("GET", "/api/v1/tools", token=token)
    print(json.dumps(result, indent=2))

def parse_args(args):
    """Parse key=value args into a dict, extract --org."""
    org = None
    params = {}
    
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--org" and i + 1 < len(args):
            org = args[i + 1]
            i += 2
            continue
        elif arg.startswith("--org="):
            org = arg.split("=", 1)[1]
            i += 1
            continue
        elif "=" in arg:
            key, value = arg.split("=", 1)
            # Try to parse as JSON for arrays/objects
            try:
                value = json.loads(value)
            except:
                pass
            params[key] = value
        i += 1
    
    return org, params

def cmd_call_tool(tool_name, args):
    """Call a Boardwise API tool."""
    token = get_token()
    
    # First, get the tool definition
    tools_result = api_request("GET", "/api/v1/tools", token=token)
    tool = next((t for t in tools_result["tools"] if t["name"] == tool_name), None)
    
    if not tool:
        print(f"Error: Unknown tool '{tool_name}'", file=sys.stderr)
        print("\nAvailable tools:", file=sys.stderr)
        for t in tools_result["tools"]:
            print(f"  - {t['name']}: {t['description']}", file=sys.stderr)
        sys.exit(1)
    
    # Parse args
    org, params = parse_args(args)
    
    if not org:
        print("Error: --org is required", file=sys.stderr)
        sys.exit(1)
    
    # Parse the endpoint
    endpoint = tool["endpoint"]
    method, path_template = endpoint.split(" ", 1)
    
    # Build the path with org slug
    if "{organization_slug}" in path_template:
        path = path_template.replace("{organization_slug}", str(org))
    else:
        # Insert /orgs/{org} after the API version prefix (e.g. /api/v1)
        # Correct URL pattern: /api/v1/orgs/{org}/meetings/{id}
        path = re.sub(r"^(/api/v\d+)", rf"\1/orgs/{org}", path_template)

    # Handle path parameters (like {id}, {meeting_id})
    for param in tool["parameters"]:
        param_name = param["name"]
        placeholder = f"{{{param_name}}}"
        if placeholder in path:
            if param_name in params:
                path = path.replace(placeholder, str(params.pop(param_name)))
            elif param["required"]:
                print(f"Error: Required path parameter '{param_name}' not provided", file=sys.stderr)
                sys.exit(1)
    
    # Make the request
    if method == "GET":
        # Add query params
        if params:
            path += "?" + urlencode(params)
        result = api_request(method, path, token=token)
    else:
        # POST/PUT/PATCH - send as body
        result = api_request(method, path, data=params, token=token)
    
    print(json.dumps(result, indent=2))

def cmd_download_document(args):
    """Download a document to a local file."""
    token = get_token()
    org, params = parse_args(args)

    if not org:
        print("Error: --org is required", file=sys.stderr)
        sys.exit(1)

    doc_id = params.get("id")
    if not doc_id:
        print("Error: id=<document_id> is required", file=sys.stderr)
        sys.exit(1)

    dest = params.get("dest", f"/tmp/{doc_id}")

    path = f"/api/v1/orgs/{org}/documents/{doc_id}/download"
    url = f"{BASE_URL}{path}"
    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": "Boardwise-API-Client/1.0 (OpenClaw)"
    }
    req = Request(url, headers=headers, method="GET")

    try:
        with urlopen(req) as resp:
            # Extract filename from Content-Disposition if available
            content_disp = resp.headers.get("Content-Disposition", "")
            filename = None
            if 'filename="' in content_disp:
                filename = content_disp.split('filename="')[1].split('"')[0]

            # If dest has no extension and we know the filename, use it
            dest_path = Path(dest)
            if not dest_path.suffix and filename:
                dest_path = dest_path.parent / filename

            dest_path.parent.mkdir(parents=True, exist_ok=True)
            data = resp.read()
            dest_path.write_bytes(data)

            result = {
                "status": "downloaded",
                "path": str(dest_path),
                "size": len(data),
                "content_type": resp.headers.get("Content-Type", "unknown"),
            }
            if filename:
                result["filename"] = filename
            print(json.dumps(result, indent=2))
    except HTTPError as e:
        error_body = e.read().decode()
        try:
            error_json = json.loads(error_body)
            print(f"Error {e.code}: {json.dumps(error_json, indent=2)}", file=sys.stderr)
        except:
            print(f"Error {e.code}: {error_body}", file=sys.stderr)
        sys.exit(1)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    command = sys.argv[1]
    args = sys.argv[2:]

    if command == "auth":
        cmd_auth(args)
    elif command == "auth-poll":
        cmd_auth_poll(args)
    elif command == "me":
        cmd_me()
    elif command == "tools":
        cmd_tools()
    elif command == "download_document":
        cmd_download_document(args)
    elif command in ("-h", "--help"):
        print(__doc__)
    else:
        # Treat as a tool call
        cmd_call_tool(command, args)

if __name__ == "__main__":
    main()
