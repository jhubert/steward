---
name: boardwise
description: Interact with Boardwise board portal software — manage meetings, agendas, action items, messages, and documents for boards and committees. Use when working with board governance tasks, scheduling board meetings, sending messages to board members, tracking action items, or any Boardwise-related operations.
---

# Boardwise API Skill

Boardwise is a modern board portal for managing board and committee governance — meetings, documents, action items, and member communications.

## Authentication

Token is stored at `~/.config/boardwise/config.json`. If not authenticated:

```bash
python3 skills/boardwise/scripts/boardwise-api.py auth
```

This returns a `user_code` and `verification_uri`. Tell the user to visit the URL and enter the code. Then poll for the token:

```bash
python3 skills/boardwise/scripts/boardwise-api.py auth-poll <device_code>
```

## Get User Info & Organizations

```bash
python3 skills/boardwise/scripts/boardwise-api.py me
```

Returns user details and list of organizations with their `slug` values. The slug is required for all API calls.

## API Usage

All tool calls require `--org <slug>`:

```bash
python3 skills/boardwise/scripts/boardwise-api.py <tool_name> --org <slug> [key=value ...]
```

## Available Tools

### Organizations & Groups

**list_groups** — List all boards and committees
```bash
python3 skills/boardwise/scripts/boardwise-api.py list_groups --org 888488
```

**get_group** — Get group details with members
```bash
python3 skills/boardwise/scripts/boardwise-api.py get_group --org 888488 id=<group_id>
```

### Meetings

**list_meetings** — List meetings (filterable)
```bash
# All meetings
python3 skills/boardwise/scripts/boardwise-api.py list_meetings --org 888488

# Upcoming only
python3 skills/boardwise/scripts/boardwise-api.py list_meetings --org 888488 status=upcoming

# For specific group
python3 skills/boardwise/scripts/boardwise-api.py list_meetings --org 888488 group_id=<id>
```

**get_meeting** — Get meeting details with agenda, attendees, documents
```bash
python3 skills/boardwise/scripts/boardwise-api.py get_meeting --org 888488 id=<meeting_id>
```

**create_meeting** — Create a new meeting
```bash
python3 skills/boardwise/scripts/boardwise-api.py create_meeting --org 888488 \
  title="Q1 Board Meeting" \
  starts_at="2026-03-15T14:00:00Z" \
  ends_at="2026-03-15T16:00:00Z" \
  group_id=<board_id> \
  location="Board Room" \
  time_zone="America/Vancouver"
```

Parameters:
- `title` (required): Meeting title
- `starts_at` (required): ISO 8601 datetime
- `ends_at` (required): ISO 8601 datetime
- `group_id`: Board or committee ID
- `location`: Physical location or video link
- `time_zone`: IANA timezone (default: UTC)
- `person_ids`: JSON array of person IDs to invite

### Agenda Items

**create_agenda_item** — Add agenda item to meeting
```bash
python3 skills/boardwise/scripts/boardwise-api.py create_agenda_item --org 888488 \
  meeting_id=<id> \
  title="Financial Report" \
  duration_minutes=15 \
  description="Q4 results review"
```

Parameters:
- `meeting_id` (required): Meeting ID
- `title` (required): Agenda item title
- `duration_minutes` (required): Duration in minutes
- `description`: Optional description
- `position`: Order position (auto-assigned if omitted)

### People

**list_people** — List organization directory
```bash
python3 skills/boardwise/scripts/boardwise-api.py list_people --org 888488
```

### Action Items

**list_action_items** — List tasks
```bash
# Pending items
python3 skills/boardwise/scripts/boardwise-api.py list_action_items --org 888488

# All items
python3 skills/boardwise/scripts/boardwise-api.py list_action_items --org 888488 status=all

# For specific group
python3 skills/boardwise/scripts/boardwise-api.py list_action_items --org 888488 group_id=<id>
```

**create_action_item** — Create a task
```bash
python3 skills/boardwise/scripts/boardwise-api.py create_action_item --org 888488 \
  title="Review audit report" \
  due_by="2026-03-01" \
  group_id=<board_id> \
  'assigned_person_ids=["person-uuid-1","person-uuid-2"]'
```

### Documents

**list_documents** — List documents
```bash
python3 skills/boardwise/scripts/boardwise-api.py list_documents --org 888488
python3 skills/boardwise/scripts/boardwise-api.py list_documents --org 888488 group_id=<id>
```

**download_document** — Download a document file to local disk
```bash
# Download with explicit destination path
python3 skills/boardwise/scripts/boardwise-api.py download_document --org 888488 id=<document_id> dest=/tmp/report.pdf

# Download with auto-filename (saves to /tmp/<original_filename>)
python3 skills/boardwise/scripts/boardwise-api.py download_document --org 888488 id=<document_id>
```

Parameters:
- `id` (required): Document ID
- `dest`: Destination file path (default: /tmp/<document_id>, uses original filename if no extension given)

### Messages

**list_messages** — List board/committee messages
```bash
python3 skills/boardwise/scripts/boardwise-api.py list_messages --org 888488
python3 skills/boardwise/scripts/boardwise-api.py list_messages --org 888488 group_id=<id>
```

**get_message** — Get message with read receipts
```bash
python3 skills/boardwise/scripts/boardwise-api.py get_message --org 888488 id=<message_id>
```

**create_message** — Send message to group
```bash
python3 skills/boardwise/scripts/boardwise-api.py create_message --org 888488 \
  group_id=<board_id> \
  subject="Important Update" \
  body="<p>Please review the attached materials before our next meeting.</p>"
```

## Workflow Examples

### Schedule a Board Meeting

```bash
# 1. Get the board ID
python3 skills/boardwise/scripts/boardwise-api.py list_groups --org 888488

# 2. Create the meeting
python3 skills/boardwise/scripts/boardwise-api.py create_meeting --org 888488 \
  title="March Board Meeting" \
  starts_at="2026-03-20T09:00:00-08:00" \
  ends_at="2026-03-20T11:00:00-08:00" \
  group_id=<board_id> \
  location="Conference Room A"

# 3. Add agenda items
python3 skills/boardwise/scripts/boardwise-api.py create_agenda_item --org 888488 \
  meeting_id=<meeting_id> title="Call to Order" duration_minutes=5

python3 skills/boardwise/scripts/boardwise-api.py create_agenda_item --org 888488 \
  meeting_id=<meeting_id> title="CEO Report" duration_minutes=20

python3 skills/boardwise/scripts/boardwise-api.py create_agenda_item --org 888488 \
  meeting_id=<meeting_id> title="Financial Review" duration_minutes=30
```

### Send Update to Board

```bash
# 1. Get the board ID
python3 skills/boardwise/scripts/boardwise-api.py list_groups --org 888488

# 2. Send message
python3 skills/boardwise/scripts/boardwise-api.py create_message --org 888488 \
  group_id=<board_id> \
  subject="Meeting Materials Available" \
  body="<p>The board package for our upcoming meeting is now available in Boardwise.</p>"
```

## Notes

- All times should be ISO 8601 format
- The `--org` parameter uses the numeric slug from the `me` command
- Array parameters use JSON format: `'assigned_person_ids=["id1","id2"]'`
- HTML is supported in message bodies
