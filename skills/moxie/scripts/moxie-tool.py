#!/usr/bin/env python3
"""Wrapper for moxie.sh that accepts a JSON params argument.

Used by Steward's tool executor which passes each {placeholder} as a single argv element.

Usage:
    moxie-tool.py <resource> <action> <json_params>

Examples:
    moxie-tool.py clients search '{"query": "Acme"}'
    moxie-tool.py clients create '{"name": "Acme Corp", "type": "Client"}'
    moxie-tool.py tasks create '{"name": "Follow up", "clientName": "Acme Corp", "dueDate": "2026-03-01"}'
"""

import json
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MOXIE_SCRIPT = os.path.join(SCRIPT_DIR, "moxie.sh")


def main():
    if len(sys.argv) < 3:
        print("Usage: moxie-tool.py <resource> <action> [json_params]", file=sys.stderr)
        sys.exit(1)

    resource = sys.argv[1]
    action = sys.argv[2]
    params = {}
    if len(sys.argv) > 3:
        raw = sys.argv[3]
        if raw and raw != "params":
            try:
                params = json.loads(raw)
            except json.JSONDecodeError:
                try:
                    params = json.loads(raw.replace("=>", ":"))
                except json.JSONDecodeError as e:
                    print(f"Error parsing JSON params: {e}", file=sys.stderr)
                    sys.exit(1)

    args = [MOXIE_SCRIPT, resource, action]

    # "query" is a positional arg for search actions
    query = params.pop("query", None)
    if query:
        args.append(str(query))

    # Check if there's a raw --data payload (for complex creates like invoices)
    data = params.pop("data", None)
    if data:
        if isinstance(data, (dict, list)):
            args.extend(["--data", json.dumps(data)])
        else:
            args.extend(["--data", str(data)])
    else:
        # Convert remaining params to --flag value pairs
        for key, value in params.items():
            args.extend([f"--{key}", str(value)])

    env = os.environ.copy()
    result = subprocess.run(args, capture_output=True, text=True, env=env)
    if result.stdout:
        sys.stdout.write(result.stdout)
    if result.stderr:
        sys.stderr.write(result.stderr)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
