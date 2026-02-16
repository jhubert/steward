---
name: http
description: Make HTTP requests to external APIs. Supports GET, POST, PUT, PATCH, DELETE for ad-hoc API calls, OAuth flows, and webhooks.
---

# HTTP Request

Make HTTP requests to external APIs. Use the `http_request` tool for ad-hoc API calls, OAuth flows, webhooks, or any HTTP interaction not covered by other tools.

Pass parameters as a JSON string with at minimum a `url` key. Optional keys: `method`, `headers`, `body`, `content_type`.
