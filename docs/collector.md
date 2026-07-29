# Collector

`scripts/collect-checkov-findings.sh` runs Checkov across a list of repos and
writes CSVs for the findings tracker.

It is a **reporting tool**. It changes nothing, gates nothing, and opens no PRs.
It exists to answer three questions:

1. What is Checkov flagging across our Terraform?
2. Which checks have teams already suppressed, and why?
3. Where are there issues nobody has looked at yet?

---

## Prerequisites

| Tool | Notes |
|---|---|
| `git` | Any recent version |
| `jq` | 1.6+ |
| `checkov` | `pip install checkov==3.3.0` |
| `gh` | Only needed to build a repo list; the collector itself uses `git` |

```bash
# macOS
brew install jq gh
pip install checkov==3.3.0

# Ubuntu / WSL
sudo apt-get install -y jq
pip install checkov==3.3.0
```

Private repos need `GH_TOKEN` exported — a PAT with `repo` scope, or a GitHub
App installation token.

---

## Running it

The collector takes an explicit repo list. Build one first:

```bash
export ORG=LBHackney-IT
export GH_TOKEN=$(gh auth token)

gh repo list "$ORG" --limit 1000 --no-archived \
  --json nameWithOwner --jq '.[].nameWithOwner' > repos.txt

./scripts/collect-checkov-findings.sh --list repos.txt
```

Output lands in `./checkov-reports/`.

Budget roughly 1–3 minutes per repo containing Terraform. Repos with no `.tf`
files are skipped in seconds.

### Testing on a few repos

```bash
cat > repos.txt <<'EOF'
LBHackney-IT/ce-datahub
LBHackney-IT/ce-some-other-repo
EOF

./scripts/collect-checkov-findings.sh --list repos.txt
```

Bare repo names work too — anything without a `/` gets `$ORG/` prefixed.

---

## Running in CI

`.github/workflows/collect-checkov-findings.yaml` runs the same thing via
**Actions → Collect Checkov findings → Run workflow**. Manual trigger only.

| Input | Purpose |
|---|---|
| `repos_override` | Comma-separated repo list. Blank scans everything. |
| `checkov_version` | Checkov version to install. Defaults to `3.3.0`. |

It authenticates with the CE GitHub App rather than `GITHUB_TOKEN`, because the
default token cannot read other private repos in the org:

| Name | Type | Purpose |
|---|---|---|
| `CE_TF_APP_ID` | org variable | GitHub App ID |
| `CE_TF_APP_PRIVATE_KEY` | org secret | GitHub App private key |

The App installation must cover every repo you expect to scan — a selected-repos
installation silently produces clone failures for everything outside it.

Results upload as artifact `checkov-findings-<run_number>` (90-day retention)
alongside `repos.txt`. The job summary shows totals, the top 10 checks and the
20 noisiest repos.

---

## Outputs

Everything lands in `$REPORT_DIR` (default `./checkov-reports`):

| File | Contents |
|---|---|
| `findings.csv` | One row per finding. Columns match the tracker's Findings sheet. |
| `summary.csv` | Aggregate counts per check × result × category × repo. Pivot-friendly. |
| `run-metadata.json` | Audit trail: run time, versions, repos scanned, failures. |
| `json/<repo>.json` | Raw Checkov output per repo, for debugging. |

### findings.csv schema

```
run_date,repo,file,line,resource,check,result,category,message,skip_reason
```

| Column | Source | Notes |
|---|---|---|
| `run_date` | collector | Date of the scan |
| `repo` | collector | `LBHackney-IT/ce-datahub` |
| `file` | Checkov | Path from repo root |
| `line` | Checkov | First line of the resource block |
| `resource` | Checkov | `aws_lambda_function.ssl_checker` |
| `check` | Checkov | `CKV_AWS_116` |
| `result` | collector | `FAILED` or `SKIPPED` |
| `category` | collector | Derived from the check description |
| `message` | Checkov | The check description |
| `skip_reason` | Checkov | Justification from an inline `#checkov:skip`, on `SKIPPED` rows |

`SKIPPED` rows are suppressions that already exist in the code. They are
collected deliberately — a check that several teams independently suppressed for
the same reason is a decision waiting to be made once, centrally, rather than
repeatedly in each repo.

### run-metadata.json

```json
{
  "run_time": "2026-07-29T06:00:00Z",
  "org": "LBHackney-IT",
  "checkov_version": "3.3.0",
  "checkov_args": "--framework terraform --compact --soft-fail --download-external-modules false",
  "repos_scanned": 312,
  "total_findings": 2649,
  "total_failed": 2469,
  "total_skipped": 180,
  "clone_failures": [],
  "no_terraform": ["LBHackney-IT/some-docs-repo"],
  "scan_failures": []
}
```

Check `clone_failures` and `scan_failures` on every run. A repo that failed to
clone is not a repo with no findings.

---

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `ORG` | `LBHackney-IT` | Org prefix for bare repo names |
| `REPORT_DIR` | `./checkov-reports` | Output directory |
| `GH_TOKEN` | unset | Auth for private repos |
| `CHECKOV_VERSION` | `3.3.0` | Recorded in metadata; install the matching version |
| `CHECKOV_ARGS` | see below | Scan flags |

```
--framework terraform --compact --soft-fail --download-external-modules false
```

### Why the scan is unfiltered

`CHECKOV_ARGS` deliberately does not point at a config file and applies no
`--skip-check` or severity filter. The scan reports the complete picture, not
what any pipeline currently surfaces.

Counts will therefore be higher than a CI run. That is the point: you cannot
decide what to suppress if the scan is already suppressing it. Do not "fix" this
by pointing the collector at a shared config.

External module downloading is off so the scan needs no credentials for private
module sources. Checks that depend on resolving a module's contents may
under-report as a result — worth knowing if a lot of your Terraform is
module-heavy.

### Severity

Checkov only exposes severities through the Prisma Cloud platform integration,
which needs an API key. Without one, `--check MEDIUM` and similar are not
severity filters — Checkov treats the value as a check ID, matches nothing, and
runs no checks at all while still exiting zero.

That is why `result` (`FAILED` / `SKIPPED`) is used in place of a severity
column, and why triage is driven by frequency and category instead.

### Categorisation

`category` is derived from the check description by the `categorise()` function,
because check IDs are opaque and there are several hundred of them:

| Category | Matches on |
|---|---|
| Tagging | tag |
| Secrets | secret, credential, password, hard-coded |
| Encryption | encrypt, kms, cmk, at rest, tls, ssl |
| Logging | log, audit, x-ray, trace, monitor, alarm |
| Networking | vpc, subnet, security group, public, ingress, egress, internet |
| IAM | iam, policy, policies, privilege, principal, role |
| Backup | backup, snapshot, retention, versioning, point-in-time |
| Resilience | dead letter, concurrency, multi-az, rotation, deletion protection |
| Other | anything else |

Order matters — the first match wins. Secrets Manager encryption checks land in
Secrets rather than Encryption because `*secret*` is tested first. Reorder the
`case` branches if the team prefers otherwise.

---

## Troubleshooting

**`ERROR: --list <repos.txt> is required`** — the collector does not discover
repos itself. Build `repos.txt` with `gh repo list` first.

**Lots of `❌ clone failed`** — the token cannot see those repos. Locally, check
`gh auth status` and org SSO authorisation. In CI, check the GitHub App
installation covers all repos rather than a selected subset.

**`⚠️ invalid JSON`** — usually a Terraform parse error. Check
`checkov-reports/json/` and re-run against that repo directly:

```bash
checkov -d /path/to/repo --framework terraform --compact
```

**Counts differ between runs by different people** — compare
`checkov_version` in `run-metadata.json`. Check IDs come and go between
versions, so pin the same one.

**Workflow times out** — raise `timeout-minutes`, or split the org across
several runs using `repos_override`.

**A repo shows zero findings but has Terraform** — confirm it is not in
`no_terraform` or `scan_failures` in the metadata before believing it.
