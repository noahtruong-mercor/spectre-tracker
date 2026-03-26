#!/bin/bash
# Spectre Tracker — hourly data refresh
export PATH="/Users/noahtruong/.local/bin:/usr/local/bin:/usr/bin:/bin"

LOG="/Users/noahtruong/spectre-tracker/update.log"
echo "=== $(date) ===" >> "$LOG"

/Users/noahtruong/.local/bin/claude --dangerously-skip-permissions -p "
Update the Project Spectre sourcing tracker at /Users/noahtruong/spectre-tracker/index.html with fresh live data from Mercor.

## What to do
Run SQL queries via the execute_sql Mercor MCP tool to fetch the latest pipeline counts, then update the 'rows' array in index.html. Also update the date in the header from whatever it currently says to today's date.

## Database
Schema: ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION
Company: Mercor Alabaster (company_AAAssev7eQrbVpsfgrMCKsR)
Project: FM - Project Spectre (proj_AAABnFqxHX7B0l2O-IhLrZLh)

## CRITICAL query rules — follow exactly or counts will be wrong

### Table columns
- CANDIDATES: USERID, LISTINGID, LISTINGSTEPCONFIGID, ISMOSTRECENT, STATUS
- CONTRACTORTAGS: USERID, LISTINGID, TAGID  (NO CONTRACTORID column)
- TAGS: TAGID, NAME

### ALWAYS filter CANDIDATES with ISMOSTRECENT = TRUE
Without this filter you get every historical pipeline state a candidate ever passed through,
inflating counts by 10-40x. This is the most important rule.

### Correct join pattern for tagged listings
JOIN CONTRACTORTAGS ct ON ct.USERID = c.USERID AND ct.LISTINGID = c.LISTINGID
JOIN TAGS t ON t.TAGID = ct.TAGID
WHERE t.NAME = '<country>'

### Shortlist for WT (swt) — step ID per listing
Each listing has a step named exactly 'Ready for WT' (LISTINGSTEPCONFIGS.TITLE = 'Ready for WT').
Look up the LISTINGSTEPCONFIGID for that title per listing, then:
WHERE c.LISTINGSTEPCONFIGID = '<that id>' AND c.ISMOSTRECENT = TRUE

### Work Trial (wt)
WHERE c.LISTINGSTEPCONFIGID IN (SELECT LISTINGSTEPCONFIGID FROM LISTINGSTEPCONFIGS WHERE LISTINGID = '<lid>' AND TYPE = 'work-trial') AND c.ISMOSTRECENT = TRUE

### RTH (rth)
WHERE c.LISTINGSTEPCONFIGID = 'ready-to-hire' AND c.ISMOSTRECENT = TRUE

### Offers Pending (pend)
Jobs with STATUS = 'extended' in the project, grouped by role.
ALWAYS filter ISLATEST = 1 on the JOBS table — without this, historical versioned records inflate counts 10x+.

### Offers Accepted (acc)
Jobs with STATUS = 'active' in the project, grouped by role.
ALWAYS filter ISLATEST = 1 on the JOBS table — same reason as above.

## Listings and their country tag mappings

French:    list_AAABnFn39WB7DBCHe7RI1ICx  → France, Canada, Belgium, Switzerland
German:    list_AAABnFnPnsdm9QrAH3hFkIt3  → Germany, Austria, Switzerland
Italian:   list_AAABnFoAEoGQvv4Fy6RMIb-J  → Italy, Switzerland
Japanese:  list_AAABnFoMVAl-QMLOWSNC77AH  → (no tags — use full listing count with ISMOSTRECENT = TRUE)
Korean:    list_AAABnFoVCMZivn_myVlIHqS8  → (no tags — use full listing count with ISMOSTRECENT = TRUE)
Portuguese: list_AAABnFoF-D7KIiKNteFIlbgL → Brazil, Portugal
Simp. Chinese: list_AAABnFoYnNHwPHA6a49ND7Vd → (no tags — use full listing count with ISMOSTRECENT = TRUE)
Trad. Chinese: list_AAABnFodqxMAUX3UiSBNIqtZ → Taiwan, Hong Kong
Spanish:   list_AAABnFnl_G7PQh21fANESqGt  → Spain, Mexico, United States, Chile

## Offers query approach
Query JOBS table: WHERE PROJECTID = 'proj_AAABnFqxHX7B0l2O-IhLrZLh' AND STATUS IN ('extended','active')
Join to PROJECTROLES to get the role name (which contains the language, e.g. 'Bilingual French...')
Map each role's extended count → pend, active count → acc.
Each language listing maps to one project role.

## Milestone HCG — pull BOTH current and next from PROJECTMILESTONES

Each row in the tracker has curr_hcg, next_hcg, and next_date fields.
Run two queries:

### Current milestone (curr_hcg)
The active milestone is the one where STARTTIMESTAMP <= NOW and DEADLINETIMESTAMP >= NOW.
Use QUALIFY ROW_NUMBER() to pick the most recently created row per role (avoids wrong values from MIN/MAX on duplicates).
SQL:
SELECT pr.ROLETITLE, pm.METRICEXACTACTIVENEEDED as curr_hcg
FROM ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTMILESTONES pm
JOIN ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTROLES pr ON pr.ROLEID = pm.ROLEID
WHERE pm.PROJECTID = 'proj_AAABnFqxHX7B0l2O-IhLrZLh'
AND pm.STARTTIMESTAMP <= CURRENT_TIMESTAMP
AND (pm.DEADLINETIMESTAMP >= CURRENT_TIMESTAMP OR pm.DEADLINETIMESTAMP IS NULL)
QUALIFY ROW_NUMBER() OVER (PARTITION BY pm.ROLEID ORDER BY pm.CREATEDAT DESC) = 1

### Next milestone (next_hcg + next_date)
The next milestone is the one that starts at the DEADLINE of the current milestone (not just the nearest future STARTTIMESTAMP).
This correctly skips over any intermediate milestone rows and lands on the true "next" period as shown in the Mercor UI.
SQL:
WITH curr AS (
  SELECT pm.ROLEID, pm.DEADLINETIMESTAMP as curr_deadline
  FROM ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTMILESTONES pm
  WHERE pm.PROJECTID = 'proj_AAABnFqxHX7B0l2O-IhLrZLh'
  AND pm.STARTTIMESTAMP <= CURRENT_TIMESTAMP
  AND (pm.DEADLINETIMESTAMP >= CURRENT_TIMESTAMP OR pm.DEADLINETIMESTAMP IS NULL)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY pm.ROLEID ORDER BY pm.CREATEDAT DESC) = 1
)
SELECT pr.ROLETITLE, pm.METRICEXACTACTIVENEEDED as next_hcg, pm.STARTTIMESTAMP as next_start
FROM ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTMILESTONES pm
JOIN ANALYTICS_DATABASE.AURORA_MERCOR_PRODUCTION.PROJECTROLES pr ON pr.ROLEID = pm.ROLEID
JOIN curr c ON c.ROLEID = pm.ROLEID
WHERE pm.PROJECTID = 'proj_AAABnFqxHX7B0l2O-IhLrZLh'
AND pm.STARTTIMESTAMP = c.curr_deadline
QUALIFY ROW_NUMBER() OVER (PARTITION BY pm.ROLEID ORDER BY pm.CREATEDAT DESC) = 1

The ROLETITLE format is "Bilingual X Generalist Evaluator Expert (Country)".
Map each result to the matching tracker row by language + country.
Format next_date as "Mon DD" (e.g. "Apr 1", "Apr 8") from the STARTTIMESTAMP.

## Output
Edit /Users/noahtruong/spectre-tracker/index.html — update only:
1. The 'rows' array: swt, wt, rth, pend, acc, curr_hcg, next_hcg, next_date fields for each row
2. The date in the header <span> tag to today's date
Keep all other HTML/CSS/JS exactly as-is.

Log what you updated and any discrepancies to stdout.

## Timestamp
After updating the rows array, also update the last-refreshed timestamp in the HTML.
Find this exact string in index.html:
  <span id="last-updated">
and replace the text content between the tags with the current date/time in Pacific Time,
formatted as: YYYY-MM-DD HH:MM PT  (e.g. 2026-03-25 14:33 PT)
" >> "$LOG" 2>&1

PT_TIME=$(TZ="America/Los_Angeles" date "+%Y-%m-%d %H:%M PT")
sed -i '' "s|<span id=\"last-updated\">[^<]*</span>|<span id=\"last-updated\">${PT_TIME}</span>|" /Users/noahtruong/spectre-tracker/index.html
echo "Stamped timestamp: ${PT_TIME}" >> "$LOG"

echo "Exit code: $?" >> "$LOG"

cd /Users/noahtruong/spectre-tracker
/usr/bin/git add index.html
/usr/bin/git commit -m "Auto-update $(TZ='America/Los_Angeles' date '+%Y-%m-%d %H:%M PT')"
/usr/bin/git push origin main >> "$LOG" 2>&1
echo "Deployed to GitHub Pages" >> "$LOG"
