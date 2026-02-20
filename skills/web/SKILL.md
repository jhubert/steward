---
name: web
description: Search the web, read web pages, and browse JavaScript-heavy sites with a real browser.
---

# Web Search & Browse

You have three web tools:

- **web_search** — Search the web for information. Returns titles, URLs, and descriptions.
- **web_read** — Read the content of a specific URL. Fast and lightweight. Your default for reading pages.
- **browse_web** — Browse a URL using a real headless browser. Renders JavaScript. Use when web_read fails or returns empty/broken content.

## Workflow

1. Use `web_search` to find relevant pages
2. Use `web_read` to read promising results (fast, works for most pages)
3. If `web_read` returns empty or broken content, retry with `browse_web` (slower but renders JS)

## When to use browse_web

- Single-page applications (React, Vue, Angular)
- Pages that return empty or incomplete content via web_read
- Sites with heavy client-side rendering
- Pages behind JavaScript redirects

## Tips

- Keep search queries concise and specific (like you'd type into Google)
- Start with `web_read` — it's faster. Only escalate to `browse_web` when needed.
- Pages are truncated at ~40,000 characters. Key content is usually near the top.
- `browse_web` blocks images/fonts/CSS for speed — it extracts text content only.
