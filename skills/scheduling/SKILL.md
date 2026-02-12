---
name: scheduling
description: Find available meeting times by checking ALL calendars for each person. Use when scheduling meetings, proposing times to prospects/customers, or checking availability. Prevents calendar conflicts by checking work, personal, and family calendars. ALWAYS use this before proposing any meeting times.
---

# Scheduling Skill

Find available meeting times by checking all calendars for each attendee.

## Why This Exists

Scheduling requires checking ALL calendars for each person — not just their work calendar. Missing a personal calendar or kids' sports schedule leads to proposing times that don't work, which looks unprofessional.

## Quick Start

```bash
# Find 30-minute slots for Jeremy and Bruce next week
python3 skills/scheduling/scripts/find-availability.py jeremy,bruce --duration 30 --from tomorrow --to +7d

# Find 60-minute slots for just Jeremy
python3 skills/scheduling/scripts/find-availability.py jeremy --duration 60 --from 2026-02-10 --to 2026-02-14

# Output as JSON
python3 skills/scheduling/scripts/find-availability.py jeremy,bruce --duration 30 --json
```

## Known People

| Name | Calendars Checked |
|------|-------------------|
| jeremy | work (jeremy@boardwise.co), personal (jhubert@gmail.com), kids' sports |
| bruce | work (bruce@boardwise.co) |
| jenn | work (jennifer@boardwise.co) |

To add more people, edit `scripts/find-availability.py` and update the `CALENDARS` dict.

## Output Format

The tool outputs available slots grouped by day:

```
Available 30-minute slots (America/Vancouver):

**Monday, Feb 10:**
  • 09:00 - 11:30
  • 14:00 - 17:00

**Tuesday, Feb 11:**
  • 09:00 - 12:00
  • 15:30 - 17:00
```

## Validation Built In

- Checks ALL calendars for each person
- Skips weekends automatically
- Respects business hours (9 AM - 5 PM PT)
- Handles all-day events (travel, PTO)
- Day names always match dates (no "Thursday Feb 6" when Feb 6 is Friday)

## Workflow

1. **Always run this tool first** before proposing meeting times
2. Pick slots from the output
3. **For external meetings (prospects, customers):** Message Jeremy/Bruce to confirm the times work before sending
4. Propose 2-3 options to the other party
5. Double-check the day name matches the date before sending

**Why the confirmation step?** Calendars don't capture everything. Someone might be unavailable due to travel fatigue, personal commitments, or just needing a break. A quick "proposing Wed 10am or Thu 2pm for the X call — any conflicts?" takes 30 seconds and prevents embarrassment.

## Manual Fallback

If the tool fails, check calendars manually with:

```bash
# Jeremy's calendars
gog calendar events jeremy@boardwise.co --from <start> --to <end>
gog calendar events jhubert@gmail.com --from <start> --to <end>
gog calendar events 3cot98uqhqeb2r901b09r97p6o@group.calendar.google.com --from <start> --to <end>

# Bruce's calendar
gog calendar events bruce@boardwise.co --from <start> --to <end>
```

Then verify day-of-week:
```bash
python3 -c "from datetime import date; d = date(2026, 2, 6); print(f'{d} is a {d.strftime(\"%A\")}')"
```
