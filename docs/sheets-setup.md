# Sheets setup

How to build and maintain `checkov-findings-tracker.xlsx`, the workbook the team
triages findings in.

The collector produces rows. The workbook is where decisions get made and
recorded. Keep it in the team's usual shared location, not in this repo.

---

## Structure

Three sheets:

| Sheet | Purpose |
|---|---|
| README | What the tracker is, what the columns mean, how to use it |
| Findings | One row per finding. Columns A–J are pasted from the scan; K onward are triage |
| Summary | Counts that update automatically from Findings |

---

## Findings sheet

### Columns

Columns A–J match `findings.csv` exactly, so the file pastes straight in.
Do not edit them by hand — the next scan overwrites them.

| Col | Header | Example |
|---|---|---|
| A | Run Date | `2026-07-29` |
| B | Repo | `LBHackney-IT/ce-datahub` |
| C | File | `/lambda.tf` |
| D | Line | `36` |
| E | Resource | `aws_lambda_function.ssl_checker` |
| F | Check | `CKV_AWS_116` |
| G | Result | `FAILED` |
| H | Category | `Resilience` |
| I | Message | `Ensure that AWS Lambda function is configured for a Dead Letter Queue(DLQ)` |
| J | Skip Reason | populated on `SKIPPED` rows only |

Columns K onward are the team's, and survive re-scans:

| Col | Header | Purpose |
|---|---|---|
| K | Decision | What we've decided (dropdown) |
| L | Owner | Team responsible for the repo or fix |
| M | First Seen | Date the finding was first logged |
| N | Last Seen | Date it was last confirmed present |
| O | Notes | Context, justification, ticket links |

### Formatting

Header row: bold white Arial 11 on fill `1F4E78`, left aligned, freeze panes at
`A2`. Body rows: Arial 11.

### Dropdowns

Data validation, list type, applied `<col>2:<col>5000`:

| Column | Values |
|---|---|
| G — Result | `FAILED,SKIPPED` |
| H — Category | `Encryption,Logging,Networking,IAM,Backup,Resilience,Secrets,Tagging,Other` |
| K — Decision | `Fix,Suppress inline,Suppress in central config,Leave,Under review` |

### Conditional formatting

On `G2:G5000`, cell-value-equals rules:

| Value | Fill |
|---|---|
| `FAILED` | `F8CBAD` |
| `SKIPPED` | `D9E1F2` |

---

## Decision values

| Decision | Means |
|---|---|
| Fix | Real issue. Raise remediation work against the owning team. |
| Suppress inline | Genuinely specific to this one repo. Keep or add the inline comment. |
| Suppress in central config | Does not apply to us anywhere. Belongs in a shared `skip-check` list. |
| Leave | Accepted as-is. No action, no suppression. |
| Under review | Parked for the next session. |

The distinction between the two suppress values matters. An inline
`#checkov:skip` silences the build for one repo but the finding still appears in
any SARIF consumed downstream, including the GitHub security panel. A
`skip-check` entry in shared config stops the check running at all, so it
disappears from every output. Anything the team decides does not apply
org-wide should be the latter.

---

## Summary sheet

All counts are formulas over the Findings sheet, so they stay correct as rows
change. Ranges below run to row 5000 — see [Growing the ranges](#growing-the-ranges).

### Totals

| Label | Formula |
|---|---|
| Total findings | `=COUNTA(Findings!B2:B5000)` |
| Failing | `=COUNTIF(Findings!G2:G5000,"FAILED")` |
| Already suppressed | `=COUNTIF(Findings!G2:G5000,"SKIPPED")` |
| Unique repos | `=SUMPRODUCT((Findings!B2:B5000<>"")/COUNTIF(Findings!B2:B5000,Findings!B2:B5000&""))` |
| Unique checks | `=SUMPRODUCT((Findings!F2:F5000<>"")/COUNTIF(Findings!F2:F5000,Findings!F2:F5000&""))` |
| Decisions pending | `=COUNTA(Findings!B2:B5000)-COUNTA(Findings!K2:K5000)` |

### By category

One row per category, name in column D, count in column E:

```
=COUNTIF(Findings!$H$2:$H$5000,$D5)
```

### By decision

One row per decision value, name in column G, count in column H:

```
=COUNTIF(Findings!$K$2:$K$5000,$G5)
```

### Per check

Check ID in column A, starting row 20:

| Column | Formula |
|---|---|
| B — Count | `=COUNTIF(Findings!$F$2:$F$5000,$A20)` |
| C — Failing | `=COUNTIFS(Findings!$F$2:$F$5000,$A20,Findings!$G$2:$G$5000,"FAILED")` |
| D — Repos affected | `=SUMPRODUCT((Findings!$F$2:$F$5000=$A20)/(COUNTIFS(Findings!$B$2:$B$5000,Findings!$B$2:$B$5000,Findings!$F$2:$F$5000,$A20)+(Findings!$F$2:$F$5000<>$A20)))` |

The Repos affected formula is a distinct count with a criterion. The
`+(range<>criteria)` term is what stops it dividing by zero on non-matching and
blank rows — without it the whole thing returns an error once the range extends
past the data.

---

## Growing the ranges

Nothing enforces the row range. It is whatever is typed into each formula.

Past the end of it, the Summary silently stops counting: the sheet looks fine,
the numbers are just wrong. After a scan that grows the row count, widen:

1. Every formula range on the Summary sheet
2. The three dropdown ranges on Findings
3. The two conditional formatting ranges on Findings

All three need to reach the same row. A Decision typed into a row past the
validation range will not match `COUNTIF` exactly, and the count will be wrong
with nothing visibly broken.

Leave headroom — a few hundred rows past the current count.

---

## Loading a new scan

1. Run the collector.
2. Open `checkov-reports/findings.csv`, select everything **except the header row**.
3. In the tracker, select cell `A2` of the Findings sheet and paste.
4. Widen the ranges if the row count has grown past them.

Rows are sorted by check, then repo, then file, so ordering is stable between
runs and the triage columns line up with the same findings as before.

If the row count has changed a lot, alignment will have shifted. Spot-check a
handful of rows — compare the Check and Resource in a few places against the
Decision beside them — before trusting the triage columns.

---

## Working through it

Suggested order for a review session:

1. **Filter Result = `SKIPPED`, sort by Check.** These are decisions teams have
   already made independently, with reasons in Skip Reason. Where several repos
   suppressed the same check for the same reason, mark it *Suppress in central
   config* and it stops being everyone's problem.
2. **Summary → Per check, sorted by count.** Work down. A check failing across
   nine repos is one policy conversation, not nine tickets.
3. **Filter Result = `FAILED` on checks with no suppressions anywhere.** Nobody
   has looked at these. This is the bucket the exercise exists to surface.
4. **Check the metadata.** Confirm every repo in `no_terraform`,
   `clone_failures` and `scan_failures` is expected rather than a coverage gap.

`Decisions pending` on the Summary sheet tracks what is left.
