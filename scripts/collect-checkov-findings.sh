#!/usr/bin/env bash
###############################################################################
# collect-checkov-findings.sh — run Checkov across a list of repos, produce CSVs
# for import into Google Sheets or the tracker workbook.
#
# Outputs:
#   findings.csv       — one row per finding (raw data, matches Findings sheet)
#   summary.csv        — aggregate counts per check × repo (pivot-friendly)
#   run-metadata.json  — run info: date, repos scanned, checkov version, etc.
#   json/<repo>.json   — raw Checkov output per repo (for debugging)
#
# Usage:
#   ./collect-checkov-findings.sh --list repos.txt
#
# Env vars:
#   ORG               GitHub org               (default: -IT)
#   REPORT_DIR        output directory         (default: ./checkov-reports)
#   GH_TOKEN          auth token (App or PAT)  (required for private repos)
#   CHECKOV_VERSION   checkov version          (default: 3.3.0, reported only)
#   CHECKOV_ARGS      scan flags               (default: unfiltered, see below)
#
# Checkov runs UNFILTERED — no config file, no severity filter, no skip list.
# This measures the real backlog, not what the pipeline surfaces, so counts will
# be higher than a CI run. Do not point it at a shared .checkov.yaml.
#
# Requires: git, jq, checkov.
###############################################################################

set -euo pipefail

ORG="${ORG:-IT}"
REPORT_DIR="${REPORT_DIR:-$PWD/checkov-reports}"
CHECKOV_VERSION="${CHECKOV_VERSION:-3.3.0}"
CHECKOV_ARGS="${CHECKOV_ARGS:---framework terraform --compact --soft-fail --download-external-modules false}"
RUN_DATE="$(date +%Y-%m-%d)"
RUN_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Args
REPO_LIST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)   REPO_LIST="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,27p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$REPO_LIST" ]]; then
  echo "ERROR: --list <repos.txt> is required" >&2
  exit 2
fi

WORK_DIR="$(mktemp -d -t checkov-collect-XXXXXX)"
JSON_DIR="$REPORT_DIR/json"
FINDINGS_CSV="$REPORT_DIR/findings.csv"
SUMMARY_CSV="$REPORT_DIR/summary.csv"
METADATA_JSON="$REPORT_DIR/run-metadata.json"

mkdir -p "$REPORT_DIR" "$JSON_DIR"

trap 'rm -rf "$WORK_DIR"' EXIT

echo "==================================================="
echo "Checkov findings collector"
echo "==================================================="
echo "Org:             $ORG"
echo "Report dir:      $REPORT_DIR"
echo "Checkov version: $(checkov --version 2>/dev/null || echo "$CHECKOV_VERSION")"
echo "Scan args:       $CHECKOV_ARGS"
echo "Run:             $RUN_TIME"
echo

# ---------------------------------------------------------------------------
# Load repos
# ---------------------------------------------------------------------------

mapfile -t REPOS < <(
  grep -v '^#' "$REPO_LIST" | grep -v '^$' | \
    while read -r r; do
      if [[ "$r" == */* ]]; then echo "$r"; else echo "${ORG}/${r}"; fi
    done
)

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "ERROR: repo list is empty" >&2
  exit 1
fi

echo "Repos to scan: ${#REPOS[@]}"
echo

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Checkov has no severity without a Prisma API key, and check IDs are too
# numerous to enumerate, so category is derived from the check description.
categorise() {
  local n="${1,,}"
  case "$n" in
    *tag*)                                              echo "Tagging" ;;
    *secret*|*credential*|*password*|*hard-coded*|*hard\ coded*) echo "Secrets" ;;
    *encrypt*|*kms*|*cmk*|*at\ rest*|*tls*|*ssl*)       echo "Encryption" ;;
    *log*|*audit*|*x-ray*|*trace*|*monitor*|*alarm*)    echo "Logging" ;;
    *vpc*|*subnet*|*security\ group*|*public*|*ingress*|*egress*|*internet*) echo "Networking" ;;
    *iam*|*policy*|*policies*|*privilege*|*principal*|*role*) echo "IAM" ;;
    *backup*|*snapshot*|*retention*|*versioning*|*point-in-time*) echo "Backup" ;;
    *dead\ letter*|*concurren*|*multi-az*|*rotation*|*deletion\ protection*) echo "Resilience" ;;
    *)                                                  echo "Other" ;;
  esac
}

csv_escape() {
  local v="$1"
  if [[ "$v" == *,* || "$v" == *\"* || "$v" == *$'\n'* ]]; then
    v="${v//\"/\"\"}"
    printf '"%s"' "$v"
  else
    printf '%s' "$v"
  fi
}

# CSV header — columns align with the tracker workbook's Findings sheet order,
# so the file pastes straight in. run_date is added at the front, category is
# derived from the check description, and skip_reason carries the justification
# from an inline #checkov:skip comment when result is SKIPPED.
echo "run_date,repo,file,line,resource,check,result,category,message,skip_reason" > "$FINDINGS_CSV"

CLONE_FAILURES=()
NO_TERRAFORM=()
SCAN_FAILURES=()

# Checkov emits a bare object for one framework and an array for several.
NORMALISE='if type == "array" then .[] else . end | select(.check_type != null)'

# ---------------------------------------------------------------------------
# Loop through repos
# ---------------------------------------------------------------------------

for repo in "${REPOS[@]}"; do
  safe_name="${repo//\//__}"
  repo_dir="$WORK_DIR/$safe_name"
  report_file="$JSON_DIR/${safe_name}.json"

  echo "::group::$repo"

  if [[ -n "${GH_TOKEN:-}" ]]; then
    clone_url="https://x-access-token:${GH_TOKEN}@github.com/${repo}.git"
  else
    clone_url="https://github.com/${repo}.git"
  fi

  if ! git clone --depth=1 --quiet "$clone_url" "$repo_dir" 2>/dev/null; then
    echo "  ❌ clone failed"
    CLONE_FAILURES+=("$repo")
    echo "::endgroup::"
    continue
  fi

  pushd "$repo_dir" >/dev/null

  if ! find . -name '*.tf' -not -path './.terraform/*' -print -quit | grep -q .; then
    echo "  ⏭  no terraform files"
    NO_TERRAFORM+=("$repo")
    popd >/dev/null
    echo "::endgroup::"
    continue
  fi

  set +e
  # shellcheck disable=SC2086
  checkov -d . $CHECKOV_ARGS -o json > "$report_file" 2>/dev/null
  set -e

  if ! jq empty "$report_file" 2>/dev/null; then
    echo "  ⚠️  invalid JSON"
    SCAN_FAILURES+=("$repo")
    popd >/dev/null
    echo "::endgroup::"
    continue
  fi

  failed_count=$(jq "[$NORMALISE | .summary.failed] | add // 0"  "$report_file")
  skipped_count=$(jq "[$NORMALISE | .summary.skipped] | add // 0" "$report_file")
  echo "  findings: $failed_count  (already skipped: $skipped_count)"

  # One jq call per repo rather than per finding — a full org scan produces
  # thousands of rows and per-field jq calls do not scale.
  jq -r "
    $NORMALISE
    | (.results.failed_checks[]?  | . + {result: \"FAILED\"}),
      (.results.skipped_checks[]? | . + {result: \"SKIPPED\"})
    | [ (.file_path // \"\"),
        ((.file_line_range // [null])[0] | tostring),
        (.resource // \"\"),
        .check_id,
        .result,
        (.check_name // \"\"),
        (.check_result.suppress_comment // \"\") ]
    | @tsv
  " "$report_file" | while IFS=$'\t' read -r file line_num resource check result message skip_reason; do
    category=$(categorise "$message")

    {
      printf '%s,' "$RUN_DATE"
      printf '%s,' "$(csv_escape "$repo")"
      printf '%s,' "$(csv_escape "$file")"
      printf '%s,' "$line_num"
      printf '%s,' "$(csv_escape "$resource")"
      printf '%s,' "$(csv_escape "$check")"
      printf '%s,' "$(csv_escape "$result")"
      printf '%s,' "$(csv_escape "$category")"
      printf '%s,' "$(csv_escape "$message")"
      printf '%s\n' "$(csv_escape "$skip_reason")"
    } >> "$FINDINGS_CSV"
  done

  popd >/dev/null
  echo "::endgroup::"
done

# ---------------------------------------------------------------------------
# Summary CSV
# ---------------------------------------------------------------------------

{
  echo "check,result,category,repo,count"
  tail -n +2 "$FINDINGS_CSV" | \
    awk -F',' '{ print $6","$7","$8","$2 }' | \
    sort | uniq -c | \
    awk '{ count=$1; $1=""; sub(/^ /, ""); print $0","count }'
} > "$SUMMARY_CSV"

# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------

total_findings=$(($(wc -l < "$FINDINGS_CSV") - 1))
total_failed=$(tail -n +2 "$FINDINGS_CSV"  | awk -F',' '$7 == "FAILED"'  | wc -l)
total_skipped=$(tail -n +2 "$FINDINGS_CSV" | awk -F',' '$7 == "SKIPPED"' | wc -l)

jq -n \
  --arg run_time "$RUN_TIME" \
  --arg org "$ORG" \
  --arg checkov_version "$CHECKOV_VERSION" \
  --arg checkov_args "$CHECKOV_ARGS" \
  --argjson repos_scanned "${#REPOS[@]}" \
  --argjson total_findings "$total_findings" \
  --argjson total_failed "$total_failed" \
  --argjson total_skipped "$total_skipped" \
  --argjson clone_failures "$(printf '%s\n' "${CLONE_FAILURES[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  --argjson no_terraform "$(printf '%s\n' "${NO_TERRAFORM[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  --argjson scan_failures "$(printf '%s\n' "${SCAN_FAILURES[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{
    run_time: $run_time,
    org: $org,
    checkov_version: $checkov_version,
    checkov_args: $checkov_args,
    repos_scanned: $repos_scanned,
    total_findings: $total_findings,
    total_failed: $total_failed,
    total_skipped: $total_skipped,
    clone_failures: $clone_failures,
    no_terraform: $no_terraform,
    scan_failures: $scan_failures
  }' > "$METADATA_JSON"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

echo
echo "==================================================="
echo "Findings CSV:  $FINDINGS_CSV"
echo "Summary CSV:   $SUMMARY_CSV"
echo "Metadata:      $METADATA_JSON"
echo "==================================================="
echo
echo "Total findings: $total_findings across ${#REPOS[@]} repos"
echo "  failed:       $total_failed"
echo "  already skipped: $total_skipped"
[[ ${#CLONE_FAILURES[@]} -gt 0 ]] && echo "Clone failures: ${#CLONE_FAILURES[@]}"
[[ ${#NO_TERRAFORM[@]}  -gt 0 ]] && echo "No terraform:   ${#NO_TERRAFORM[@]}"
[[ ${#SCAN_FAILURES[@]} -gt 0 ]] && echo "Scan failures:  ${#SCAN_FAILURES[@]}"
echo
echo "Top 10 checks by finding count:"
tail -n +2 "$FINDINGS_CSV" | awk -F',' '{ print $6 }' | sort | uniq -c | sort -rn | head -10
echo
echo "Findings per repo:"
tail -n +2 "$FINDINGS_CSV" | awk -F',' '{ print $2 }' | sort | uniq -c | sort -rn
