---
name: gog
description: Access Google Workspace services (Gmail, Calendar, Drive, Contacts, Tasks, Sheets, Docs) via the gog CLI tool.
---

# Google Workspace Access (gog)

You have a `google` tool that runs gog CLI commands against the user's Google account. The user's account is injected automatically — never specify an account or email.

## Usage

Pass the gog subcommand as the `command` parameter. Always omit account/email flags — the system handles authentication.

## Quick Reference

### Gmail
```
gmail search is:unread newer_than:7d          # Search messages
gmail search from:boss@company.com            # Search by sender
gmail read <message_id>                       # Read a specific message
gmail send --to user@example.com --subject "Hi" --body "Hello"  # Send email
gmail labels                                  # List labels
```

### Calendar
```
calendar events --today                       # Today's events
calendar events --days 7                      # Next 7 days
calendar events --from 2026-02-14 --to 2026-02-15  # Date range
calendar create --title "Meeting" --start "2026-02-14 14:00" --end "2026-02-14 15:00"
calendar delete <event_id>                    # Delete an event
calendar calendars                            # List calendars
```

### Drive
```
drive ls                                      # List files in root
drive ls <folder_id>                          # List files in folder
drive search "quarterly report"               # Search files
drive download <file_id> --output /tmp/file   # Download a file
drive upload /path/to/file --parent <folder_id>  # Upload a file
drive info <file_id>                          # File metadata
```

### Contacts
```
contacts list                                 # List contacts
contacts search "John"                        # Search contacts
contacts show <contact_id>                    # Contact details
```

### Tasks
```
tasks lists                                   # List task lists
tasks list <list_id>                          # List tasks in a list
tasks create <list_id> --title "Buy groceries"  # Create a task
tasks complete <list_id> <task_id>            # Mark task complete
```

### Sheets
```
sheets read <spreadsheet_id> --range "Sheet1!A1:D10"   # Read cells
sheets write <spreadsheet_id> --range "Sheet1!A1" --values "hello,world"  # Write cells
sheets info <spreadsheet_id>                           # Spreadsheet metadata
```

### Docs
```
docs read <document_id>                       # Read document content
docs info <document_id>                       # Document metadata
```

## Important Notes

- Output is always JSON (`--json` flag is automatic)
- Do NOT include `--account` or email flags — the user's account is pre-configured
- For long-running operations (large downloads, bulk searches), be aware of the 60-second timeout
- If you get a credentials error, tell the user their Google account needs to be set up by an admin
