#!/usr/bin/env python3
"""Wrapper for boardwise-api.py that accepts a JSON params argument.

Used by Steward's tool executor which passes each {placeholder} as a single argv element.

Usage:
    boardwise-tool.py <command> <json_params>

Examples:
    boardwise-tool.py list_meetings '{"org": "888488", "status": "upcoming"}'
    boardwise-tool.py create_meeting '{"org": "888488", "title": "Q1 Board Meeting", "starts_at": "2026-03-15T14:00:00Z"}'
    boardwise-tool.py me '{}'
"""

import json
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
API_SCRIPT = os.path.join(SCRIPT_DIR, "boardwise-api.py")


def main():
    if len(sys.argv) < 2:
        print("Usage: boardwise-tool.py <command> [json_params]", file=sys.stderr)
        sys.exit(1)

    command = sys.argv[1]
    params = {}
    if len(sys.argv) > 2:
        raw = sys.argv[2]
        # Executor falls back to literal "params" when LLM omits the field
        if raw and raw != "params":
            try:
                params = json.loads(raw)
            except json.JSONDecodeError:
                # Might be Ruby hash syntax from .to_s on a Hash — try converting
                try:
                    params = json.loads(raw.replace("=>", ":"))
                except json.JSONDecodeError as e:
                    print(f"Error parsing JSON params: {e}", file=sys.stderr)
                    sys.exit(1)

    args = [sys.executable, API_SCRIPT, command]

    # Commands that take a single positional argument (not key=value)
    POSITIONAL_COMMANDS = {
        "auth-poll": "device_code",
    }

    if command in POSITIONAL_COMMANDS:
        key = POSITIONAL_COMMANDS[command]
        value = params.pop(key, None)
        if value:
            args.append(str(value))
        # Pass any remaining params as key=value
        for k, v in params.items():
            args.append(f"{k}={v}")
    else:
        # Extract --org as a named flag
        org = params.pop("org", None)
        if org:
            args.extend(["--org", str(org)])

        # Everything else becomes key=value positional args
        for key, value in params.items():
            if isinstance(value, (list, dict)):
                args.append(f"{key}={json.dumps(value)}")
            else:
                args.append(f"{key}={value}")

    result = subprocess.run(args, capture_output=True, text=True)
    if result.stdout:
        sys.stdout.write(result.stdout)
    if result.stderr:
        sys.stderr.write(result.stderr)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
