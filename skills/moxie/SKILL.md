---
name: moxie
description: Moxie CRM API integration for managing clients, contacts, projects, invoices, expenses, tasks, tickets, opportunities, time tracking, calendar events, and pipeline stages. Use when working with Moxie freelancer/agency CRM data — listing clients, searching contacts, creating invoices, logging time entries, managing projects, or any Moxie workspace operations.
---

# Moxie CRM

Interact with the Moxie CRM API via `scripts/moxie.sh`.

## Setup

Set environment variables:
- `MOXIE_API_KEY` — from Workspace Settings → Connected Apps → Integrations
- `MOXIE_POD_URL` — full base URL, e.g. `https://pod00.withmoxie.dev/api/public`

## Usage

```bash
moxie.sh <resource> <action> [options]
```

### Read Operations

```bash
moxie.sh clients list
moxie.sh clients search "acme"
moxie.sh contacts search "john"
moxie.sh projects search "clientname"
moxie.sh invoices search "clientname"
moxie.sh templates email
moxie.sh templates invoice
moxie.sh vendors list
moxie.sh forms list
moxie.sh pipeline stages
moxie.sh tasks stages
moxie.sh users list
```

### Create Operations

```bash
# Via named flags
moxie.sh clients create --name "Acme Corp" --type Client --currency USD
moxie.sh contacts create --first John --last Doe --email john@acme.com --client "Acme Corp"
moxie.sh time create --start "2024-01-15T09:00:00+00:00" --end "2024-01-15T17:00:00+00:00" --email user@example.com

# Via JSON (--data flag or stdin)
moxie.sh projects create --data '{"name":"Website","clientName":"Acme","feeSchedule":{"feeType":"Hourly","amount":150}}'
echo '{"name":"Task1","clientName":"Acme","projectName":"Website"}' | moxie.sh tasks create

# Calendar
moxie.sh calendar create --data '{"eventId":"evt1","startTime":"2024-01-15T09:00:00","endTime":"2024-01-15T10:00:00","timezone":"America/New_York","summary":"Meeting"}'
moxie.sh calendar delete evt1
```

### Key Notes

- Most create endpoints require **exact name matches** for clientName, projectName, etc.
- Rate limit: 100 requests per 5 minutes
- File attachments use multipart/form-data (use `--file` flag)
- See `references/api-spec.md` for full field details and response schemas
- Run `moxie.sh --help` for complete command reference
