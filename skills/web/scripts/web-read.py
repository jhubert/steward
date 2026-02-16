#!/usr/bin/env python3
"""Read web page content using Jina AI's reader API (POST)."""

import json
import os
import sys
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

MAX_LENGTH = 40_000


def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print("Error: URL is required", file=sys.stderr)
        sys.exit(1)

    api_key = os.environ.get("JINA_API_KEY", "")

    target_url = sys.argv[1].strip()
    body = json.dumps({"url": target_url}).encode("utf-8")

    req = Request("https://r.jina.ai/", data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    req.add_header("User-Agent", "Steward/1.0")
    req.add_header("X-Retain-Images", "none")
    req.add_header("X-Engine", "direct")
    req.add_header("X-Timeout", "20")
    if api_key:
        req.add_header("Authorization", f"Bearer {api_key}")

    try:
        with urlopen(req, timeout=25) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")[:500]
        print(f"Reader API error (HTTP {e.code}): {body_text}", file=sys.stderr)
        sys.exit(1)
    except URLError as e:
        print(f"Connection error: {e.reason}", file=sys.stderr)
        sys.exit(1)

    page = data.get("data", {})
    title = page.get("title", "")
    url = page.get("url", target_url)
    content = page.get("content", "")

    if title:
        print(f"# {title}")
        print(f"URL: {url}")
        print()

    if not content:
        print("(No content extracted)")
        return

    if len(content) > MAX_LENGTH:
        content = content[:MAX_LENGTH] + "\n\n... (content truncated)"

    print(content)


if __name__ == "__main__":
    main()
