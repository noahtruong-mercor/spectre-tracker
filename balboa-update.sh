#!/bin/bash
# Balboa Tracker — hourly data refresh
export PATH="/Users/noahtruong/.local/bin:/usr/local/bin:/usr/bin:/bin"

LOG="/Users/noahtruong/spectre-tracker/balboa-update.log"
echo "=== $(date) ===" >> "$LOG"

/Users/noahtruong/.local/bin/claude --dangerously-skip-permissions -p "
Update the Project Balboa sourcing tracker at /Users/noahtruong/spectre-tracker/balboa.html with fresh live data from Mercor.

## What to do
Run SQL queries via the execute_sql Mercor MCP tool to fetch the latest data, then update the 'rows' array in balboa.html.

## Database
Schema: ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION
Company: Glowstone (aat0c0ff6-fb18-4248-923c-93f1220e47933)
Project: Project Balboa (proj_AAABmymLbTX3RxGJ8UVJgJzc)

## CRITICAL query rules — follow exactly or counts will be wrong

### ALWAYS filter CANDIDATES with ISMOSTRECENT = TRUE
Without this filter you get every historical pipeline state, inflating counts by 10-40x.

### ALWAYS filter JOBS with ISLATEST = 1
Without this filter, historical versioned job records inflate offer counts 10x+.

### RTH (rth)
WHERE c.LISTINGSTEPCONFIGID = 'ready-to-hire' AND c.ISMOSTRECENT = TRUE

### Offers Pending (pend)
JOBS with STATUS = 'extended', ISLATEST = 1, PROJECTID = 'proj_AAABmymLbTX3RxGJ8UVJgJzc'
Join to PROJECTROLES to get role name. Map extended count → pend per role.

### Offers Accepted (acc)
JOBS with STATUS = 'active', ISLATEST = 1, PROJECTID = 'proj_AAABmymLbTX3RxGJ8UVJgJzc'
Map active count → acc per role.

## P0 roles and their listings

Only update these 8 roles (ignore all others):

Buyers and Purchasing Agents         → no listing (rth always 0)
Accountants and Auditors             → list_AAABmK5s9-TpeQmGq5pAQ4Xc
Real Estate Sales Agents             → list_AAABmhiQhJ5y-RCF0qRAAqEN
Audio and Video Technicians          → list_AAABmhiTwRxw8spGWEFALoQ7
Film and Video Editors               → list_AAABmhzgjXklkTVDxlJB4Lmj
Property, Real Estate, and Community → no listing (rth always 0)
News Analysts, Reporters, and Journalists → no listing (rth always 0)
Producers and Directors              → no listing (rth always 0)

## Milestone HCG

### Current milestone (curr_hcg)
There may be no active milestone. If none, set curr_hcg = 0 for all rows.
SQL to check:
SELECT pr.ROLETITLE, pm.METRICEXACTACTIVENEEDED as curr_hcg
FROM ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTMILESTONES pm
JOIN ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTROLES pr ON pr.ROLEID = pm.ROLEID
WHERE pm.PROJECTID = 'proj_AAABmymLbTX3RxGJ8UVJgJzc'
AND pm.STARTTIMESTAMP <= CURRENT_TIMESTAMP
AND (pm.DEADLINETIMESTAMP >= CURRENT_TIMESTAMP OR pm.DEADLINETIMESTAMP IS NULL)
QUALIFY ROW_NUMBER() OVER (PARTITION BY pm.ROLEID ORDER BY pm.CREATEDAT DESC) = 1

### Next milestone (next_hcg + next_date)
If there IS a current active milestone, use its deadline to find the next one:
WITH curr AS (
  SELECT pm.ROLEID, pm.DEADLINETIMESTAMP as curr_deadline
  FROM ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTMILESTONES pm
  WHERE pm.PROJECTID = 'proj_AAABmymLbTX3RxGJ8UVJgJzc'
  AND pm.STARTTIMESTAMP <= CURRENT_TIMESTAMP
  AND (pm.DEADLINETIMESTAMP >= CURRENT_TIMESTAMP OR pm.DEADLINETIMESTAMP IS NULL)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY pm.ROLEID ORDER BY pm.CREATEDAT DESC) = 1
)
SELECT pr.ROLETITLE, pm.METRICEXACTACTIVENEEDED as next_hcg, pm.STARTTIMESTAMP as next_start
FROM ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTMILESTONES pm
JOIN ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTROLES pr ON pr.ROLEID = pm.ROLEID
JOIN curr c ON c.ROLEID = pm.ROLEID
WHERE pm.PROJECTID = 'proj_AAABmymLbTX3RxGJ8UVJgJzc'
AND pm.STARTTIMESTAMP = c.curr_deadline
QUALIFY ROW_NUMBER() OVER (PARTITION BY pm.ROLEID ORDER BY pm.CREATEDAT DESC) = 1

If there is NO current active milestone, query the nearest future one directly:
SELECT pr.ROLETITLE, pm.METRICEXACTACTIVENEEDED as next_hcg, pm.STARTTIMESTAMP as next_start
FROM ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTMILESTONES pm
JOIN ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTROLES pr ON pr.ROLEID = pm.ROLEID
WHERE pm.PROJECTID = 'proj_AAABmymLbTX3RxGJ8UVJgJzc'
AND pm.STARTTIMESTAMP = (
  SELECT MIN(STARTTIMESTAMP) FROM ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTMILESTONES
  WHERE PROJECTID = 'proj_AAABmymLbTX3RxGJ8UVJgJzc' AND STARTTIMESTAMP > CURRENT_TIMESTAMP
)
QUALIFY ROW_NUMBER() OVER (PARTITION BY pm.ROLEID ORDER BY pm.CREATEDAT DESC) = 1

Only roles that appear in the milestone results will have next_hcg set. Others keep existing values.
Format next_date as 'Mon DD' (e.g. 'Mar 28', 'Apr 1') from the STARTTIMESTAMP.

## Output
Edit /Users/noahtruong/spectre-tracker/balboa.html — update only:
1. The 'rows' array: rth, curr_hcg, next_hcg, next_date, pend, acc fields for each row
Keep all other HTML/CSS/JS exactly as-is.

Log what you updated and any discrepancies to stdout.

## Timestamp
After updating the rows array, also update the last-refreshed timestamp in the HTML.
Find this exact string in balboa.html:
  <span id=\"last-updated\">
and replace the text content between the tags with the current date/time in Pacific Time,
formatted as: YYYY-MM-DD HH:MM PT  (e.g. 2026-03-26 14:33 PT)
" >> "$LOG" 2>&1

PT_TIME=$(TZ="America/Los_Angeles" date "+%Y-%m-%d %H:%M PT")
sed -i '' "s|<span id=\"last-updated\">[^<]*</span>|<span id=\"last-updated\">${PT_TIME}</span>|" /Users/noahtruong/spectre-tracker/balboa.html
echo "Stamped timestamp: ${PT_TIME}" >> "$LOG"

echo "Exit code: $?" >> "$LOG"

cd /Users/noahtruong/spectre-tracker
/usr/bin/git add balboa.html
/usr/bin/git commit -m "Auto-update Balboa $(TZ='America/Los_Angeles' date '+%Y-%m-%d %H:%M PT')"
/usr/bin/git push origin main >> "$LOG" 2>&1
echo "Deployed to GitHub Pages" >> "$LOG"
