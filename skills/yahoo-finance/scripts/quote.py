#!/usr/bin/env python3
"""Fetch Yahoo Finance quotes without a browser.

The quote page is a SvelteKit app that embeds the responses it prefetched from
Yahoo's own API as <script data-sveltekit-fetched data-url="..."> blobs. Reading
those gives the same numbers the rendered page would show, for the cost of one
HTTP GET — no Chromium, no JS execution.

Calling query1.finance.yahoo.com directly would be simpler still, but it answers
429 from this host; the HTML page does not.

Usage: quote.py <symbol>[,<symbol>...]
"""

import html
import json
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

TIMEOUT = 20
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36")

# Yahoo intermittently answers 404 for symbols that plainly exist — measured at
# 30% of requests for SHOP.TO while AAPL returned 200 on 20 of 20, so it tracks
# dotted non-US tickers rather than load. Retrying collapses that; a genuinely
# unknown symbol still 404s on every attempt and is reported as such.
ATTEMPTS = 3
BACKOFF = 0.4

FETCHED_RE = re.compile(
    r'<script[^>]*data-sveltekit-fetched[^>]*data-url="([^"]+)"[^>]*>(.*?)</script>',
    re.S,
)


def fetch_page(symbol):
    url = f"https://finance.yahoo.com/quote/{symbol}/"
    req = Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml",
        "Accept-Language": "en-US,en;q=0.9",
    })

    last = None
    for attempt in range(ATTEMPTS):
        try:
            with urlopen(req, timeout=TIMEOUT) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except (HTTPError, URLError, TimeoutError) as e:
            last = e
            if isinstance(e, HTTPError) and e.code not in (404, 429, 500, 502, 503, 504):
                raise
            if attempt < ATTEMPTS - 1:
                time.sleep(BACKOFF * (attempt + 1))
    raise last


def embedded_quotes(page):
    """Yield every quote record embedded in the page, in document order."""
    for match in FETCHED_RE.finditer(page):
        if "v7/finance/quote" not in html.unescape(match.group(1)):
            continue
        try:
            body = json.loads(match.group(2))
        except json.JSONDecodeError:
            continue
        inner = body.get("body", body) if isinstance(body, dict) else body
        if isinstance(inner, str):
            try:
                inner = json.loads(inner)
            except json.JSONDecodeError:
                continue
        if not isinstance(inner, dict):
            continue
        for record in (inner.get("quoteResponse") or {}).get("result", []) or []:
            if isinstance(record, dict) and record.get("symbol"):
                yield record


def find_quote(page, symbol):
    """The page carries several quote blobs — the requested symbol, the market
    summary strip, and 'related' tickers. Match on symbol rather than position."""
    wanted = symbol.upper()
    for record in embedded_quotes(page):
        if record["symbol"].upper() == wanted:
            return record
    return None


def val(field):
    """Fields arrive as {"raw": .., "fmt": ".."} or as a bare scalar."""
    if isinstance(field, dict):
        return field.get("fmt") or field.get("raw")
    return field


def raw(field):
    if isinstance(field, dict):
        return field.get("raw")
    return field


def render(q):
    name = q.get("longName") or q.get("shortName") or q.get("symbol")
    lines = [f"{name} ({q.get('symbol')})"]

    price = val(q.get("regularMarketPrice"))
    currency = q.get("currency") or ""
    change, pct = val(q.get("regularMarketChange")), val(q.get("regularMarketChangePercent"))
    if price is not None:
        head = f"  Price: {price} {currency}".rstrip()
        if change is not None:
            head += f"   Change: {change} ({pct})"
        lines.append(head)

    state = q.get("marketState")
    when = val(q.get("regularMarketTime"))
    if state or when:
        lines.append(f"  Market: {state or 'unknown'}" + (f" (as of {when})" if when else ""))

    # Only meaningful outside regular hours, and absent for many instruments.
    if raw(q.get("postMarketPrice")) is not None:
        lines.append(f"  Post-market: {val(q.get('postMarketPrice'))} "
                     f"({val(q.get('postMarketChange'))}, {val(q.get('postMarketChangePercent'))})")

    for label, key in (
        ("Open", "regularMarketOpen"),
        ("Previous close", "regularMarketPreviousClose"),
        ("Day range", "regularMarketDayRange"),
        ("52-week range", "fiftyTwoWeekRange"),
        ("Volume", "regularMarketVolume"),
        ("Market cap", "marketCap"),
    ):
        v = val(q.get(key))
        if v not in (None, ""):
            lines.append(f"  {label}: {v}")

    exch = q.get("fullExchangeName") or q.get("exchange")
    if exch:
        delay = q.get("exchangeDataDelayedBy")
        suffix = f" (delayed {delay}m)" if delay else ""
        lines.append(f"  Exchange: {exch}{suffix}")

    return "\n".join(lines)


def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print("Error: at least one symbol is required (e.g. AAPL or AAPL,MSFT)", file=sys.stderr)
        return 1

    symbols = [s.strip() for s in sys.argv[1].replace(" ", ",").split(",") if s.strip()]
    if not symbols:
        print("Error: no valid symbols given", file=sys.stderr)
        return 1
    if len(symbols) > 10:
        print("Error: at most 10 symbols per call", file=sys.stderr)
        return 1

    blocks, failures = [], []
    for symbol in symbols:
        try:
            page = fetch_page(symbol)
        except HTTPError as e:
            failures.append(f"{symbol}: HTTP {e.code} after {ATTEMPTS} attempts"
                            + (" — symbol probably does not exist" if e.code == 404 else ""))
            continue
        except (URLError, TimeoutError) as e:
            failures.append(f"{symbol}: {e}")
            continue

        quote = find_quote(page, symbol)
        if quote is None:
            # Yahoo served a page but no embedded quote for this symbol: a bad
            # ticker, or the page shape changed. Say which, so the agent can
            # fall back to browse_web rather than silently reporting nothing.
            failures.append(f"{symbol}: no quote data found in the page "
                            f"(unknown symbol, or Yahoo changed the page layout)")
            continue
        blocks.append(render(quote))

    if blocks:
        print("\n\n".join(blocks))
    if failures:
        stream = sys.stderr if not blocks else sys.stdout
        print(("\n" if blocks else "") + "Could not fetch:", file=stream)
        for f in failures:
            print(f"  {f}", file=stream)

    return 0 if blocks else 1


if __name__ == "__main__":
    sys.exit(main())
