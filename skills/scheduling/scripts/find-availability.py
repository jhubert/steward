#!/usr/bin/env python3
"""
Find available meeting times across multiple people's calendars.

Usage:
    find-availability.py <attendees> --duration <minutes> [--from <date>] [--to <date>] [--tz <timezone>]

Examples:
    find-availability.py jeremy,bruce --duration 30 --from 2026-02-10 --to 2026-02-14
    find-availability.py jeremy --duration 60 --from tomorrow --to +7d
"""

import subprocess
import json
import sys
import argparse
from datetime import datetime, timedelta, date
from zoneinfo import ZoneInfo
import re

# Calendar mapping: person -> list of calendar IDs
CALENDARS = {
    "jeremy": [
        "jeremy@boardwise.co",           # work
        "jhubert@gmail.com",             # personal
        "3cot98uqhqeb2r901b09r97p6o@group.calendar.google.com",  # kids
    ],
    "bruce": [
        "bruce@boardwise.co",            # work
    ],
    "jenn": [
        "jennifer@boardwise.co",         # work
    ],
}

# Business hours (in local timezone)
BUSINESS_HOURS_START = 9   # 9 AM
BUSINESS_HOURS_END = 17    # 5 PM
DEFAULT_TZ = "America/Vancouver"

def parse_date(date_str: str, reference: date = None) -> date:
    """Parse date string, supporting relative dates."""
    if reference is None:
        reference = date.today()
    
    date_str = date_str.lower().strip()
    
    if date_str == "today":
        return reference
    elif date_str == "tomorrow":
        return reference + timedelta(days=1)
    elif date_str.startswith("+") and date_str.endswith("d"):
        days = int(date_str[1:-1])
        return reference + timedelta(days=days)
    else:
        # Try ISO format
        return datetime.strptime(date_str, "%Y-%m-%d").date()

def get_day_name(d: date) -> str:
    """Get day of week name."""
    return d.strftime("%A")

def validate_day_date(day_name: str, d: date) -> bool:
    """Validate that a day name matches the actual date."""
    actual_day = get_day_name(d)
    return actual_day.lower() == day_name.lower()

def get_events(calendar_id: str, start_date: date, end_date: date) -> list:
    """Fetch events from a calendar using gog CLI."""
    cmd = [
        "gog", "calendar", "events", calendar_id,
        "--from", start_date.isoformat(),
        "--to", end_date.isoformat(),
        "--json"
    ]
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            print(f"Warning: Could not fetch {calendar_id}: {result.stderr}", file=sys.stderr)
            return []
        
        data = json.loads(result.stdout)
        return data.get("events", [])
    except subprocess.TimeoutExpired:
        print(f"Warning: Timeout fetching {calendar_id}", file=sys.stderr)
        return []
    except json.JSONDecodeError:
        print(f"Warning: Invalid JSON from {calendar_id}", file=sys.stderr)
        return []

def parse_event_time(event: dict, tz: ZoneInfo) -> tuple:
    """Parse event start/end times, handling all-day events."""
    start = event.get("start", {})
    end = event.get("end", {})
    
    # All-day event
    if "date" in start:
        start_dt = datetime.strptime(start["date"], "%Y-%m-%d").replace(tzinfo=tz)
        start_dt = start_dt.replace(hour=0, minute=0)
        
        end_date = end.get("date", start["date"])
        end_dt = datetime.strptime(end_date, "%Y-%m-%d").replace(tzinfo=tz)
        end_dt = end_dt.replace(hour=23, minute=59)
        
        return start_dt, end_dt, True  # is_all_day
    
    # Timed event
    if "dateTime" in start:
        start_str = start["dateTime"]
        end_str = end.get("dateTime", start_str)
        
        # Parse ISO format with timezone
        start_dt = datetime.fromisoformat(start_str.replace("Z", "+00:00"))
        end_dt = datetime.fromisoformat(end_str.replace("Z", "+00:00"))
        
        return start_dt, end_dt, False
    
    return None, None, False

def get_busy_periods(attendees: list, start_date: date, end_date: date, tz: ZoneInfo) -> list:
    """Get all busy periods for all attendees."""
    busy = []
    
    for person in attendees:
        calendars = CALENDARS.get(person.lower(), [])
        if not calendars:
            print(f"Warning: Unknown person '{person}', skipping", file=sys.stderr)
            continue
        
        for cal_id in calendars:
            events = get_events(cal_id, start_date, end_date)
            for event in events:
                start_dt, end_dt, is_all_day = parse_event_time(event, tz)
                if start_dt and end_dt:
                    busy.append({
                        "start": start_dt,
                        "end": end_dt,
                        "summary": event.get("summary", "Busy"),
                        "person": person,
                        "calendar": cal_id,
                        "all_day": is_all_day
                    })
    
    return busy

def find_free_slots(busy: list, start_date: date, end_date: date, 
                    duration_minutes: int, tz: ZoneInfo) -> list:
    """Find free slots of at least duration_minutes during business hours."""
    free_slots = []
    duration = timedelta(minutes=duration_minutes)
    
    current_date = start_date
    while current_date <= end_date:
        # Skip weekends
        if current_date.weekday() >= 5:
            current_date += timedelta(days=1)
            continue
        
        # Business hours for this day
        day_start = datetime(current_date.year, current_date.month, current_date.day,
                            BUSINESS_HOURS_START, 0, tzinfo=tz)
        day_end = datetime(current_date.year, current_date.month, current_date.day,
                          BUSINESS_HOURS_END, 0, tzinfo=tz)
        
        # Get busy periods for this day
        day_busy = []
        for b in busy:
            # Convert to local timezone for comparison
            b_start = b["start"].astimezone(tz)
            b_end = b["end"].astimezone(tz)
            
            # Check if overlaps with this day
            if b_start.date() <= current_date <= b_end.date():
                # Clip to this day's business hours
                slot_start = max(b_start, day_start)
                slot_end = min(b_end, day_end)
                if slot_start < slot_end:
                    day_busy.append((slot_start, slot_end))
        
        # Sort and merge overlapping busy periods
        day_busy.sort(key=lambda x: x[0])
        merged = []
        for start, end in day_busy:
            if merged and start <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(merged[-1][1], end))
            else:
                merged.append((start, end))
        
        # Find gaps
        cursor = day_start
        for busy_start, busy_end in merged:
            if cursor + duration <= busy_start:
                free_slots.append({
                    "date": current_date,
                    "day": get_day_name(current_date),
                    "start": cursor.strftime("%H:%M"),
                    "end": busy_start.strftime("%H:%M"),
                    "start_dt": cursor,
                    "end_dt": busy_start
                })
            cursor = max(cursor, busy_end)
        
        # Check end of day
        if cursor + duration <= day_end:
            free_slots.append({
                "date": current_date,
                "day": get_day_name(current_date),
                "start": cursor.strftime("%H:%M"),
                "end": day_end.strftime("%H:%M"),
                "start_dt": cursor,
                "end_dt": day_end
            })
        
        current_date += timedelta(days=1)
    
    return free_slots

def format_output(slots: list, duration_minutes: int, tz_name: str, attendees: list) -> str:
    """Format available slots for display."""
    if not slots:
        return "No available slots found in the given date range."
    
    lines = [f"Available {duration_minutes}-minute slots ({tz_name}):\n"]
    
    current_date = None
    for slot in slots:
        if slot["date"] != current_date:
            current_date = slot["date"]
            lines.append(f"\n**{slot['day']}, {slot['date'].strftime('%b %d')}:**")
        
        lines.append(f"  • {slot['start']} - {slot['end']}")
    
    # Add confirmation reminder for external meetings
    lines.append("\n" + "—" * 40)
    lines.append("⚠️  **Before proposing to external parties:**")
    lines.append(f"   Confirm with {', '.join(attendees)} that these times still work.")
    lines.append("   Calendars may not reflect all constraints.")
    
    return "\n".join(lines)

def main():
    parser = argparse.ArgumentParser(description="Find available meeting times")
    parser.add_argument("attendees", help="Comma-separated list of attendees (e.g., jeremy,bruce)")
    parser.add_argument("--duration", "-d", type=int, required=True, help="Meeting duration in minutes")
    parser.add_argument("--from", dest="from_date", default="tomorrow", help="Start date (YYYY-MM-DD, today, tomorrow, +Nd)")
    parser.add_argument("--to", dest="to_date", default="+7d", help="End date (YYYY-MM-DD, today, tomorrow, +Nd)")
    parser.add_argument("--tz", default=DEFAULT_TZ, help=f"Timezone (default: {DEFAULT_TZ})")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    
    args = parser.parse_args()
    
    # Parse inputs
    attendees = [a.strip() for a in args.attendees.split(",")]
    tz = ZoneInfo(args.tz)
    
    today = date.today()
    start_date = parse_date(args.from_date, today)
    end_date = parse_date(args.to_date, today)
    
    if start_date > end_date:
        print("Error: Start date must be before end date", file=sys.stderr)
        sys.exit(1)
    
    # Validate attendees
    unknown = [a for a in attendees if a.lower() not in CALENDARS]
    if unknown:
        print(f"Error: Unknown attendees: {', '.join(unknown)}", file=sys.stderr)
        print(f"Known attendees: {', '.join(CALENDARS.keys())}", file=sys.stderr)
        sys.exit(1)
    
    # Get busy periods
    print(f"Checking calendars for: {', '.join(attendees)}", file=sys.stderr)
    print(f"Date range: {start_date} to {end_date}", file=sys.stderr)
    
    busy = get_busy_periods(attendees, start_date, end_date, tz)
    
    # Find free slots
    slots = find_free_slots(busy, start_date, end_date, args.duration, tz)
    
    if args.json:
        output = {
            "attendees": attendees,
            "duration_minutes": args.duration,
            "timezone": args.tz,
            "date_range": {
                "start": start_date.isoformat(),
                "end": end_date.isoformat()
            },
            "slots": [
                {
                    "date": s["date"].isoformat(),
                    "day": s["day"],
                    "start": s["start"],
                    "end": s["end"]
                }
                for s in slots
            ],
            "reminder": f"Before proposing to external parties, confirm with {', '.join(attendees)} that these times still work."
        }
        print(json.dumps(output, indent=2))
    else:
        print(format_output(slots, args.duration, args.tz, attendees))

if __name__ == "__main__":
    main()
