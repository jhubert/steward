---
name: web
description: Search the web and read web pages. Uses Jina AI for search and content extraction.
---

# Web Search & Browse

You have two web tools:

- **web_search** — Search the web for information. Returns titles, URLs, and descriptions.
- **web_read** — Read the content of a specific URL. Returns the page as clean markdown.

## Workflow

1. Use `web_search` to find relevant pages
2. Use `web_read` to read promising results in detail

## Tips

- Keep search queries concise and specific (like you'd type into Google)
- When a search result looks relevant, use `web_read` on its URL to get the full content
- `web_read` works on any public URL — articles, docs, blog posts, etc.
- Pages are truncated at ~40,000 characters. For very long pages, key content is usually near the top.
