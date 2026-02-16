#!/usr/bin/env python3
"""Search the web using Jina AI's search API (POST)."""

import json
import os
import sys
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError


def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print("Error: search query is required", file=sys.stderr)
        sys.exit(1)

    api_key = os.environ.get("JINA_API_KEY", "")
    if not api_key:
        print("Error: JINA_API_KEY not configured", file=sys.stderr)
        sys.exit(1)

    query = sys.argv[1].strip()
    body = json.dumps({"q": query}).encode("utf-8")

    req = Request("https://s.jina.ai/", data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    req.add_header("User-Agent", "Steward/1.0")
    req.add_header("Authorization", f"Bearer {api_key}")
    req.add_header("X-Retain-Images", "none")
    req.add_header("X-Respond-With", "no-content")

    try:
        with urlopen(req, timeout=55) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")[:500]
        print(f"Search API error (HTTP {e.code}): {body_text}", file=sys.stderr)
        sys.exit(1)
    except URLError as e:
        print(f"Connection error: {e.reason}", file=sys.stderr)
        sys.exit(1)

    results = data.get("data", [])
    if not results:
        print("No results found.")
        return

    for i, r in enumerate(results[:10], 1):
        title = r.get("title", "No title")
        result_url = r.get("url", "")
        description = r.get("description", "")
        print(f"{i}. {title}")
        print(f"   URL: {result_url}")
        if description:
            print(f"   {description}")
        print()


if __name__ == "__main__":
    main()
