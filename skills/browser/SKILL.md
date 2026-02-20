---
name: browser
description: Interactive browser for navigating websites, clicking, typing, filling forms, and maintaining login sessions.
---

# Interactive Browser

You have a **browser** tool that controls a real Chromium browser. Unlike `browse_web` (read-only), this tool lets you interact with pages — click links, fill forms, log in, and maintain sessions across calls.

## Commands

| Command | Example | Description |
|---------|---------|-------------|
| `open <url>` | `open https://basecamp.com` | Navigate to URL, returns page snapshot |
| `snapshot` | `snapshot` | Re-read current page with interactive element refs |
| `click <ref>` | `click 6` | Click element by ref number |
| `type <ref> <text>` | `type 3 hello world` | Clear field then type text |
| `fill <ref> <text>` | `fill 3 hello world` | Fill input field (triggers change events) |
| `select <ref> <value>` | `select 8 Canada` | Select dropdown option by visible text |
| `check <ref>` | `check 5` | Check a checkbox |
| `uncheck <ref>` | `uncheck 5` | Uncheck a checkbox |
| `scroll <direction>` | `scroll down` | Scroll page (down/up) |
| `back` | `back` | Browser back button |
| `forward` | `forward` | Browser forward button |
| `refresh` | `refresh` | Reload current page |
| `wait` | `wait` | Wait 2 seconds for content to load |
| `text` | `text` | Get full page text content (no refs) |
| `url` | `url` | Get current page URL |
| `close` | `close` | Close browser session |

## Workflow

1. **Open** a URL: `open https://example.com` — returns a snapshot with interactive elements
2. **Read** the snapshot — each interactive element has a numbered `[ref]`
3. **Interact** — use `click`, `type`, `fill`, `select` with the ref number
4. **Re-snapshot** after navigation — refs change when the page changes

## Important

- **Refs are ephemeral**: they reset after every action that returns a snapshot. Always use refs from the MOST RECENT snapshot.
- **Sessions persist**: login state, cookies, and storage are saved between calls. If you log into a site, you'll stay logged in next time.
- **After clicking a link or submitting a form**, the response includes a fresh snapshot. Read it before acting again.
- **For login flows**: open the login page → fill email/password fields → click the submit button. Check the snapshot to see if login succeeded.
- **If a page has too many elements**, only the first 100 are shown. Use `text` to read the full page content.

## Tips

- Use `fill` for form inputs (it properly triggers change events)
- Use `type` when you need to simulate actual key-by-key typing
- Use `snapshot` to refresh your view if the page changed dynamically
- Use `wait` before `snapshot` if content loads asynchronously
- Use `text` to read long page content without interactive element overhead
