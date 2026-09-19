---
name: yahoo-finance
description: Fast stock, ETF, index, and crypto quotes from Yahoo Finance without loading a browser.
---

# Yahoo Finance Quotes

You have a `yahoo_quote` tool for looking up market prices. Use it instead of `browse_web` for any Yahoo Finance quote — it returns clean numbers in about half a second, where browsing the same page takes around four.

## Usage

Pass one symbol or several comma-separated (max 10 per call):

```
AAPL                 # US listing
AAPL,MSFT,NVDA       # several at once
BTC-USD              # crypto
SHOP.TO              # Toronto listing
VOD.L                # London listing
```

Symbols use Yahoo's own format: plain tickers for US listings, an exchange suffix elsewhere, `-USD` for crypto.

## What you get

Price, change and percent change, market state, open, previous close, day range, 52-week range, volume, market cap, and exchange. When the market is closed and pre/post-market trading has happened, that price is included too.

Values come back formatted the way Yahoo formats them (`4.906T`, `86.241M`), in the instrument's own currency — a Toronto listing reports CAD, not USD. Don't convert or recompute; quote what you're given.

## What this does not cover

Quote pages only. For anything else on Yahoo Finance — market movers and screeners (`/markets/*`), the earnings calendar, sector pages, or news — use `browse_web` with the URL.

## When it fails

- **"symbol probably does not exist"** — the ticker is wrong, or it needs an exchange suffix. Check the format before telling the user the symbol is invalid.
- **"no quote data found in the page"** — Yahoo served a page but the data wasn't in it, which usually means the page layout changed. Fall back to `browse_web` for that symbol and say you did.

A single lookup that fails for one symbol still returns results for the others; check the output for a "Could not fetch" section listing what was missed.
