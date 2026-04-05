---
name: health-data-pull
description: Pull Jeremy's Apple Health data from Google Drive for daily fitness email integration
---

# Health Data Pull

## When to Use
Before composing Jeremy's daily fitness email, run the health data pull script to get yesterday's metrics and recent trends.

## Steps
1. Run `scripts/pull_health_data.py` with the target date (defaults to yesterday)
2. The script outputs a JSON summary with:
   - Yesterday's key metrics (steps, active calories, exercise minutes, distance, flights, RHR, HRV)
   - 7-day averages for comparison
   - Week-over-week trends
3. Use this data to personalize the daily email with actual numbers and coaching insights

## Integration with Daily Emails
- Reference actual step counts, calories, exercise minutes
- Call out big days or low days
- Note RHR/HRV trends for recovery coaching
- Compare week-over-week progress
