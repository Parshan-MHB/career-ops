#!/usr/bin/env bash
set -euo pipefail

# career-ops batch runner — standalone orchestrator for provider-backed workers
# Reads batch-input.tsv, delegates each offer to a Claude or Codex worker,
# tracks state in batch-state.tsv for resumability.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BATCH_DIR="$SCRIPT_DIR"
INPUT_FILE="$BATCH_DIR/batch-input.tsv"
STATE_FILE="$BATCH_DIR/batch-state.tsv"
PROMPT_FILE="$BATCH_DIR/batch-prompt.md"
WORKER_SCHEMA_FILE="$BATCH_DIR/worker-result.schema.json"
LOGS_DIR="$BATCH_DIR/logs"
TRACKER_DIR="$BATCH_DIR/tracker-additions"
REPORTS_DIR="$PROJECT_DIR/reports"
APPLICATIONS_FILE="$PROJECT_DIR/data/applications.md"
LOCK_FILE="$BATCH_DIR/batch-runner.pid"
STATE_LOCK_DIR="$BATCH_DIR/.batch-state.lock"
STATE_LOCK_PID_FILE="$STATE_LOCK_DIR/pid"
STATE_LOCK_TIMEOUT_SECONDS=30
MAIN_PID="${BASHPID:-$$}"

# Defaults
PARALLEL=1
DRY_RUN=false
RETRY_FAILED=false
START_FROM=0
MAX_RETRIES=2
MIN_SCORE=0
PROVIDER="${CAREER_OPS_BATCH_PROVIDER:-auto}"
SELECTED_PROVIDER=""
WORKER_SCHEMA_JSON=""

usage() {
  cat <<'USAGE'
career-ops batch runner — process job offers in batch via Claude or Codex workers
Auto mode preserves backward compatibility by preferring Claude when both CLIs are installed.

Usage: batch-runner.sh [OPTIONS]

Options:
  --provider NAME     Worker provider: auto, claude, or codex (default: auto)
  --parallel N         Number of parallel workers (default: 1)
  --dry-run            Show what would be processed, don't execute
  --retry-failed       Only retry offers marked as "failed" in state
  --start-from N       Start from offer ID N (skip earlier IDs)
  --max-retries N      Max retry attempts per offer (default: 2)
  --min-score N        Skip PDF/tracker for offers scoring below N (default: 0 = off)
  -h, --help           Show this help

Files:
  batch-input.tsv      Input offers (id, url, source, notes)
  batch-state.tsv      Processing state (auto-managed)
  batch-prompt.md      Prompt template for workers
  logs/                Per-offer logs
  tracker-additions/   Tracker lines for post-batch merge

Examples:
  # Dry run to see pending offers
  ./batch-runner.sh --dry-run

  # Process all pending
  ./batch-runner.sh

  # Retry only failed offers
  ./batch-runner.sh --retry-failed

  # Process 2 at a time starting from ID 10
  ./batch-runner.sh --parallel 2 --start-from 10

  # Force Codex workers
  ./batch-runner.sh --provider codex
USAGE
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --retry-failed) RETRY_FAILED=true; shift ;;
    --start-from) START_FROM="$2"; shift 2 ;;
    --max-retries) MAX_RETRIES="$2"; shift 2 ;;
    --min-score) MIN_SCORE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# Lock file to prevent double execution
acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local old_pid
    old_pid=$(cat "$LOCK_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
      echo "ERROR: Another batch-runner is already running (PID $old_pid)"
      echo "If this is stale, remove $LOCK_FILE"
      exit 1
    else
      echo "WARN: Stale lock file found (PID $old_pid not running). Removing."
      rm -f "$LOCK_FILE"
    fi
  fi
  echo "$MAIN_PID" > "$LOCK_FILE"
}

release_lock() {
  if [[ "${BASHPID:-$$}" != "$MAIN_PID" ]]; then
    return
  fi
  rm -f "$LOCK_FILE"
}

trap release_lock EXIT

resolve_provider() {
  case "$PROVIDER" in
    auto)
      if command -v claude &>/dev/null; then
        SELECTED_PROVIDER="claude"
      elif command -v codex &>/dev/null; then
        SELECTED_PROVIDER="codex"
      else
        echo "ERROR: No supported batch worker CLI found. Install 'claude' or 'codex'."
        exit 1
      fi
      ;;
    claude|codex)
      SELECTED_PROVIDER="$PROVIDER"
      ;;
    *)
      echo "ERROR: Invalid provider '$PROVIDER'. Use auto, claude, or codex."
      exit 1
      ;;
  esac
}

load_worker_schema() {
  if [[ ! -f "$WORKER_SCHEMA_FILE" ]]; then
    echo "ERROR: $WORKER_SCHEMA_FILE not found."
    exit 1
  fi

  WORKER_SCHEMA_JSON=$(node -e 'const fs=require("fs"); process.stdout.write(JSON.stringify(JSON.parse(fs.readFileSync(process.argv[1], "utf8"))));' "$WORKER_SCHEMA_FILE" 2>/dev/null || true)
  if [[ -z "$WORKER_SCHEMA_JSON" ]]; then
    echo "ERROR: Failed to parse worker schema JSON at $WORKER_SCHEMA_FILE."
    exit 1
  fi
}

# Validate prerequisites
check_prerequisites() {
  resolve_provider
  load_worker_schema

  if [[ ! -f "$INPUT_FILE" ]]; then
    echo "ERROR: $INPUT_FILE not found. Add offers first."
    exit 1
  fi

  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "ERROR: $PROMPT_FILE not found."
    exit 1
  fi

  if ! command -v "$SELECTED_PROVIDER" &>/dev/null; then
    echo "ERROR: '$SELECTED_PROVIDER' CLI not found in PATH."
    exit 1
  fi

  mkdir -p "$LOGS_DIR" "$TRACKER_DIR" "$REPORTS_DIR"
}

# Initialize state file if it doesn't exist
init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    printf 'id\turl\tstatus\tstarted_at\tcompleted_at\treport_num\tscore\terror\tretries\n' > "$STATE_FILE"
  fi
}

acquire_state_lock() {
  local waited=0
  local max_waits=$((STATE_LOCK_TIMEOUT_SECONDS * 10))

  while true; do
    if mkdir "$STATE_LOCK_DIR" 2>/dev/null; then
      if printf '%s\n' "${BASHPID:-$$}" > "$STATE_LOCK_PID_FILE"; then
        return 0
      fi
      rm -f "$STATE_LOCK_PID_FILE" 2>/dev/null || true
      rmdir "$STATE_LOCK_DIR" 2>/dev/null || true
      echo "ERROR: Failed to initialize state lock metadata at $STATE_LOCK_DIR"
      return 1
    fi

    if [[ ! -d "$STATE_LOCK_DIR" ]]; then
      echo "ERROR: Failed to create state lock directory $STATE_LOCK_DIR"
      return 1
    fi

    if [[ -f "$STATE_LOCK_PID_FILE" ]]; then
      local lock_pid
      lock_pid=$(cat "$STATE_LOCK_PID_FILE" 2>/dev/null || true)
      if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -f "$STATE_LOCK_PID_FILE"
        if rmdir "$STATE_LOCK_DIR" 2>/dev/null; then
          echo "WARN: Recovered stale state lock (PID $lock_pid not running)."
          continue
        fi
      fi
    fi

    if (( waited >= max_waits )); then
      echo "ERROR: Timed out waiting for state lock at $STATE_LOCK_DIR"
      echo "If no batch-runner worker is active, remove the stale lock directory."
      return 1
    fi

    sleep 0.1
    ((waited += 1))
  done
}

release_state_lock() {
  rm -f "$STATE_LOCK_PID_FILE" 2>/dev/null || true
  rmdir "$STATE_LOCK_DIR" 2>/dev/null || true
}

run_with_state_lock() {
  acquire_state_lock || return $?

  local status=0
  if "$@"; then
    status=0
  else
    status=$?
  fi

  release_state_lock
  return "$status"
}

# Get status of an offer from state file
get_status() {
  local id="$1"
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "none"
    return
  fi
  local status
  status=$(awk -F'\t' -v id="$id" '$1 == id { print $3 }' "$STATE_FILE")
  echo "${status:-none}"
}

# Get retry count for an offer
get_retries() {
  local id="$1"
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "0"
    return
  fi
  local retries
  retries=$(awk -F'\t' -v id="$id" '$1 == id { print $9 }' "$STATE_FILE")
  echo "${retries:-0}"
}

# Calculate next report number.
# Caller must hold STATE_LOCK_DIR while this runs.
next_report_num_unlocked() {
  local max_num=0
  if [[ -d "$REPORTS_DIR" ]]; then
    for f in "$REPORTS_DIR"/*.md; do
      [[ -f "$f" ]] || continue
      local basename
      basename=$(basename "$f")
      local num="${basename%%-*}"
      num=$((10#$num)) # Remove leading zeros for arithmetic
      if (( num > max_num )); then
        max_num=$num
      fi
    done
  fi
  # Also check state file for assigned report numbers
  if [[ -f "$STATE_FILE" ]]; then
    while IFS=$'\t' read -r _ _ _ _ _ rnum _ _ _; do
      [[ "$rnum" == "report_num" || "$rnum" == "-" || -z "$rnum" ]] && continue
      local n=$((10#$rnum))
      if (( n > max_num )); then
        max_num=$n
      fi
    done < "$STATE_FILE"
  fi
  printf '%03d' $((max_num + 1))
}

# Update or insert state for an offer.
# Caller must hold STATE_LOCK_DIR while this runs.
update_state_unlocked() {
  local id="$1" url="$2" status="$3" started="$4" completed="$5" report_num="$6" score="$7" error="$8" retries="$9"

  if [[ ! -f "$STATE_FILE" ]]; then
    init_state
  fi

  local tmp="$STATE_FILE.tmp"
  local found=false

  # Write header
  head -1 "$STATE_FILE" > "$tmp"

  # Process existing lines
  while IFS=$'\t' read -r sid surl sstatus sstarted scompleted sreport sscore serror sretries; do
    [[ "$sid" == "id" ]] && continue  # skip header
    if [[ "$sid" == "$id" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$url" "$status" "$started" "$completed" "$report_num" "$score" "$error" "$retries" >> "$tmp"
      found=true
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$sid" "$surl" "$sstatus" "$sstarted" "$scompleted" "$sreport" "$sscore" "$serror" "$sretries" >> "$tmp"
    fi
  done < "$STATE_FILE"

  if [[ "$found" == "false" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$url" "$status" "$started" "$completed" "$report_num" "$score" "$error" "$retries" >> "$tmp"
  fi

  mv "$tmp" "$STATE_FILE"
}

update_state() {
  run_with_state_lock update_state_unlocked "$@"
}

reserve_report_num_unlocked() {
  local id="$1" url="$2" started="$3" retries="$4"

  local report_num=""
  if report_num=$(next_report_num_unlocked); then
    update_state_unlocked "$id" "$url" "processing" "$started" "-" "$report_num" "-" "-" "$retries"
  fi

  printf '%s\n' "$report_num"
}

reserve_report_num() {
  run_with_state_lock reserve_report_num_unlocked "$@"
}

resolve_project_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    return 1
  fi
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$PROJECT_DIR/$path"
  fi
}

path_exists() {
  local path="$1"
  local resolved
  resolved=$(resolve_project_path "$path" 2>/dev/null || true)
  [[ -n "$resolved" && -f "$resolved" ]]
}

remove_if_exists() {
  local path="$1"
  local resolved
  resolved=$(resolve_project_path "$path" 2>/dev/null || true)
  if [[ -n "$resolved" && -e "$resolved" ]]; then
    rm -f "$resolved"
  fi
}

parse_worker_result() {
  local result_file="$1"

  node - "$result_file" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const clean = (value) => {
  if (value === undefined || value === null) return '';
  return String(value).replace(/\t/g, ' ').replace(/\r?\n/g, ' ');
};
process.stdout.write([
  clean(data.status),
  clean(data.score),
  clean(data.report_path),
  clean(data.pdf_path),
  clean(data.tracker_path),
  clean(data.error),
].join('\t'));
NODE
}

recover_worker_artifacts() {
  local id="$1" report_num="$2"

  node - "$PROJECT_DIR" "$id" "$report_num" <<'NODE'
const fs = require('fs');
const path = require('path');

const [projectDir, batchId, expectedReportNum] = process.argv.slice(2);
const reportsDir = path.join(projectDir, 'reports');

if (!fs.existsSync(reportsDir)) process.exit(1);

const clean = (value) => {
  if (value === undefined || value === null) return '';
  return String(value).replace(/\t/g, ' ').replace(/\r?\n/g, ' ').trim();
};

const files = fs.readdirSync(reportsDir)
  .filter((name) => name.endsWith('.md') && !name.startsWith('.'))
  .map((name) => {
    const fullPath = path.join(reportsDir, name);
    const stat = fs.statSync(fullPath);
    return { name, fullPath, mtimeMs: stat.mtimeMs };
  })
  .sort((a, b) => b.mtimeMs - a.mtimeMs);

let best = null;

for (const file of files) {
  const content = fs.readFileSync(file.fullPath, 'utf8');
  const hasBatchId = new RegExp(`\\*\\*Batch ID:\\*\\*\\s*${batchId}\\b`).test(content);
  const hasReportNum = file.name.startsWith(`${expectedReportNum}-`);

  if (!hasBatchId && !hasReportNum) continue;

  const titleMatch = content.match(/^#\s*Evaluaci[oó]n:\s*(.+?)\s+[—-]\s+(.+)$/m);
  const scoreMatch = content.match(/^\*\*Score:\*\*\s*([0-9.]+)\/5/m);
  const legitimacyMatch = content.match(/^\*\*Legitimacy:\*\*\s*(.+)$/m);
  const pdfMatch = content.match(/^\*\*PDF:\*\*\s*(.+)$/m);
  const reportNumMatch = file.name.match(/^(\d+)-/);

  best = {
    reportNum: reportNumMatch ? reportNumMatch[1] : expectedReportNum,
    reportPath: path.relative(projectDir, file.fullPath),
    pdfPath: pdfMatch ? clean(pdfMatch[1]) : '',
    score: scoreMatch ? clean(scoreMatch[1]) : '',
    company: titleMatch ? clean(titleMatch[1]) : 'Unknown Company',
    role: titleMatch ? clean(titleMatch[2]) : 'Unknown Role',
    legitimacy: legitimacyMatch ? clean(legitimacyMatch[1]) : '',
  };
  break;
}

if (!best) process.exit(1);

process.stdout.write([
  clean(best.reportNum),
  clean(best.reportPath),
  clean(best.pdfPath),
  clean(best.score),
  clean(best.company),
  clean(best.role),
  clean(best.legitimacy),
].join('\t'));
NODE
}

next_tracker_num() {
  node - "$APPLICATIONS_FILE" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const text = fs.readFileSync(file, 'utf8');
const rows = text.split(/\r?\n/).filter((line) => /^\|\s*\d+\s*\|/.test(line));
const nums = rows
  .map((line) => parseInt(line.split('|')[1].trim(), 10))
  .filter(Number.isFinite);
process.stdout.write(String(nums.length ? Math.max(...nums) + 1 : 1));
NODE
}

create_recovery_tracker() {
  local id="$1" recovered_report_num="$2" report_path="$3" score="$4" company="$5" role="$6" legitimacy="$7" pdf_path="$8"
  local tracker_path="batch/tracker-additions/${id}.tsv"
  local next_num
  next_num=$(next_tracker_num)
  local pdf_emoji="❌"
  if [[ -n "$pdf_path" ]] && path_exists "$pdf_path"; then
    pdf_emoji="✅"
  fi

  local notes="Review report before applying."
  case "$legitimacy" in
    "Proceed with Caution")
      notes="Validate company identity and compensation before applying."
      ;;
    "Suspicious")
      notes="Do not apply until posting legitimacy is verified."
      ;;
    "High Confidence")
      notes="Strong fit; review report and move quickly."
      ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s/5\t%s\t[%s](%s)\t%s\n' \
    "$next_num" \
    "$(date +%Y-%m-%d)" \
    "$company" \
    "$role" \
    "Evaluated" \
    "$score" \
    "$pdf_emoji" \
    "$recovered_report_num" \
    "$report_path" \
    "$notes" \
    > "$PROJECT_DIR/$tracker_path"

  printf '%s\n' "$tracker_path"
}

recover_offer_completion() {
  local id="$1" report_num="$2"
  local recovered=""
  recovered=$(recover_worker_artifacts "$id" "$report_num" 2>/dev/null || true)
  [[ -n "$recovered" ]] || return 1

  local recovered_report_num recovered_report_path recovered_pdf_path recovered_score recovered_company recovered_role recovered_legitimacy
  IFS=$'\t' read -r recovered_report_num recovered_report_path recovered_pdf_path recovered_score recovered_company recovered_role recovered_legitimacy <<< "$recovered"

  [[ -n "$recovered_report_path" ]] || return 1
  path_exists "$recovered_report_path" || return 1
  [[ -n "$recovered_pdf_path" ]] || return 1
  path_exists "$recovered_pdf_path" || return 1

  local tracker_path="batch/tracker-additions/${id}.tsv"
  if ! path_exists "$tracker_path"; then
    tracker_path=$(create_recovery_tracker "$id" "$recovered_report_num" "$recovered_report_path" "$recovered_score" "$recovered_company" "$recovered_role" "$recovered_legitimacy" "$recovered_pdf_path")
  fi

  path_exists "$tracker_path" || return 1

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$recovered_report_num" \
    "$recovered_report_path" \
    "$recovered_pdf_path" \
    "$tracker_path" \
    "$recovered_score" \
    "$recovered_company" \
    "$recovered_role"
}

run_claude_worker() {
  local resolved_prompt="$1" prompt="$2" result_file="$3" log_file="$4"
  local system_prompt
  system_prompt=$(cat "$resolved_prompt")

  claude -p \
    --dangerously-skip-permissions \
    --no-session-persistence \
    --json-schema "$WORKER_SCHEMA_JSON" \
    --append-system-prompt "$system_prompt" \
    --add-dir /tmp \
    "$prompt" \
    > "$result_file" 2> "$log_file"
}

run_codex_worker() {
  local resolved_prompt="$1" prompt="$2" result_file="$3" log_file="$4"
  local worker_input_file="$5"

  {
    cat "$resolved_prompt"
    printf '\n\n## Invocation Context\n\n%s\n' "$prompt"
  } > "$worker_input_file"

  codex exec \
    --cd "$PROJECT_DIR" \
    --dangerously-bypass-approvals-and-sandbox \
    --ephemeral \
    --skip-git-repo-check \
    --add-dir /tmp \
    --output-schema "$WORKER_SCHEMA_FILE" \
    --output-last-message "$result_file" \
    --json \
    - \
    < "$worker_input_file" \
    > "$log_file" 2>&1
}

run_worker() {
  local resolved_prompt="$1" prompt="$2" result_file="$3" log_file="$4" worker_input_file="$5"

  case "$SELECTED_PROVIDER" in
    claude)
      run_claude_worker "$resolved_prompt" "$prompt" "$result_file" "$log_file"
      ;;
    codex)
      run_codex_worker "$resolved_prompt" "$prompt" "$result_file" "$log_file" "$worker_input_file"
      ;;
    *)
      echo "ERROR: Unsupported provider '$SELECTED_PROVIDER'"
      return 1
      ;;
  esac
}

# Process a single offer
process_offer() {
  local id="$1" url="$2" source="$3" notes="$4"

  local started_at
  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local retries
  retries=$(get_retries "$id")
  local report_num
  report_num=$(reserve_report_num "$id" "$url" "$started_at" "$retries")
  local date
  date=$(date +%Y-%m-%d)
  local jd_file="/tmp/batch-jd-${id}.txt"

  echo "--- Processing offer #$id: $url (report $report_num, attempt $((retries + 1)))"

  # Build the prompt with placeholders replaced
  local prompt
  prompt="Procesa esta oferta de empleo. Ejecuta el pipeline completo: evaluación A-F + report .md + PDF + tracker line."
  prompt="$prompt URL: $url"
  prompt="$prompt JD file: $jd_file"
  prompt="$prompt Report number: $report_num"
  prompt="$prompt Date: $date"
  prompt="$prompt Batch ID: $id"

  local log_file="$LOGS_DIR/${report_num}-${id}.log"
  local result_file="$LOGS_DIR/${report_num}-${id}.result.json"
  local worker_input_file="$BATCH_DIR/.worker-input-${id}.md"

  # Prepare system prompt with placeholders resolved
  local resolved_prompt="$BATCH_DIR/.resolved-prompt-${id}.md"
  # Escape sed delimiter characters in variables to prevent substitution breakage
  local esc_url esc_jd_file esc_report_num esc_date esc_id
  esc_url="${url//\\/\\\\}"
  esc_url="${esc_url//|/\\|}"
  esc_jd_file="${jd_file//\\/\\\\}"
  esc_jd_file="${esc_jd_file//|/\\|}"
  esc_report_num="${report_num//|/\\|}"
  esc_date="${date//|/\\|}"
  esc_id="${id//|/\\|}"
  sed \
    -e "s|{{URL}}|${esc_url}|g" \
    -e "s|{{JD_FILE}}|${esc_jd_file}|g" \
    -e "s|{{REPORT_NUM}}|${esc_report_num}|g" \
    -e "s|{{DATE}}|${esc_date}|g" \
    -e "s|{{ID}}|${esc_id}|g" \
    "$PROMPT_FILE" > "$resolved_prompt"

  local exit_code=0
  run_worker "$resolved_prompt" "$prompt" "$result_file" "$log_file" "$worker_input_file" || exit_code=$?

  # Cleanup transient prompt files
  rm -f "$resolved_prompt"
  rm -f "$worker_input_file"

  local completed_at
  completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [[ $exit_code -eq 0 ]]; then
    local parsed_result
    if ! parsed_result=$(parse_worker_result "$result_file" 2>/dev/null); then
      local recovered_result
      if recovered_result=$(recover_offer_completion "$id" "$report_num" 2>/dev/null); then
        local recovered_report_num recovered_report_path recovered_pdf_path recovered_tracker_path recovered_score
        IFS=$'\t' read -r recovered_report_num recovered_report_path recovered_pdf_path recovered_tracker_path recovered_score _ _ <<< "$recovered_result"
        update_state "$id" "$url" "completed" "$started_at" "$completed_at" "$recovered_report_num" "$recovered_score" "-" "$retries"
        echo "    ✅ Completed via artifact recovery (score: $recovered_score, report: $recovered_report_num)"
        return 0
      fi
      retries=$((retries + 1))
      update_state "$id" "$url" "failed" "$started_at" "$completed_at" "$report_num" "-" "invalid-worker-json" "$retries"
      echo "    ❌ Failed (worker returned invalid JSON)"
      return 0
    fi

    local result_status score report_path pdf_path tracker_path worker_error
    IFS=$'\t' read -r result_status score report_path pdf_path tracker_path worker_error <<< "$parsed_result"

    if [[ "$result_status" != "completed" ]]; then
      local recovered_result
      if recovered_result=$(recover_offer_completion "$id" "$report_num" 2>/dev/null); then
        local recovered_report_num recovered_report_path recovered_pdf_path recovered_tracker_path recovered_score
        IFS=$'\t' read -r recovered_report_num recovered_report_path recovered_pdf_path recovered_tracker_path recovered_score _ _ <<< "$recovered_result"
        update_state "$id" "$url" "completed" "$started_at" "$completed_at" "$recovered_report_num" "$recovered_score" "-" "$retries"
        echo "    ✅ Completed via artifact recovery (score: $recovered_score, report: $recovered_report_num)"
        return 0
      fi
      retries=$((retries + 1))
      local structured_error="${worker_error:-worker-reported-failure}"
      update_state "$id" "$url" "failed" "$started_at" "$completed_at" "$report_num" "-" "$structured_error" "$retries"
      echo "    ❌ Failed ($structured_error)"
      return 0
    fi

    if ! path_exists "$report_path"; then
      retries=$((retries + 1))
      update_state "$id" "$url" "failed" "$started_at" "$completed_at" "$report_num" "-" "missing-report-artifact" "$retries"
      echo "    ❌ Failed (missing report artifact)"
      return 0
    fi

    if ! path_exists "$tracker_path"; then
      retries=$((retries + 1))
      update_state "$id" "$url" "failed" "$started_at" "$completed_at" "$report_num" "-" "missing-tracker-artifact" "$retries"
      echo "    ❌ Failed (missing tracker artifact)"
      return 0
    fi

    if [[ -n "$pdf_path" ]] && ! path_exists "$pdf_path"; then
      retries=$((retries + 1))
      update_state "$id" "$url" "failed" "$started_at" "$completed_at" "$report_num" "-" "missing-pdf-artifact" "$retries"
      echo "    ❌ Failed (missing PDF artifact)"
      return 0
    fi

    if [[ -z "${score:-}" ]]; then
      score="-"
    fi

    # Check min-score gate
    if [[ "$score" != "-" && -n "$score" ]] && (( $(echo "$MIN_SCORE > 0" | bc -l) )); then
      if (( $(echo "$score < $MIN_SCORE" | bc -l) )); then
        remove_if_exists "$tracker_path"
        remove_if_exists "$pdf_path"
        update_state "$id" "$url" "skipped" "$started_at" "$completed_at" "$report_num" "$score" "below-min-score" "$retries"
        echo "    ⏭️  Skipped (score: $score < min-score: $MIN_SCORE)"
        return 0
      fi
    fi

    update_state "$id" "$url" "completed" "$started_at" "$completed_at" "$report_num" "$score" "-" "$retries"
    echo "    ✅ Completed (score: $score, report: $report_num)"
  else
    local recovered_result
    if recovered_result=$(recover_offer_completion "$id" "$report_num" 2>/dev/null); then
      local recovered_report_num recovered_report_path recovered_pdf_path recovered_tracker_path recovered_score
      IFS=$'\t' read -r recovered_report_num recovered_report_path recovered_pdf_path recovered_tracker_path recovered_score _ _ <<< "$recovered_result"
      update_state "$id" "$url" "completed" "$started_at" "$completed_at" "$recovered_report_num" "$recovered_score" "-" "$retries"
      echo "    ✅ Completed via artifact recovery (score: $recovered_score, report: $recovered_report_num)"
      return 0
    fi
    retries=$((retries + 1))
    local error_msg
    error_msg=$(tail -5 "$log_file" 2>/dev/null | tr '\n' ' ' | cut -c1-200 || echo "Unknown error (exit code $exit_code)")
    update_state "$id" "$url" "failed" "$started_at" "$completed_at" "$report_num" "-" "$error_msg" "$retries"
    echo "    ❌ Failed (attempt $retries, exit code $exit_code)"
  fi
}

# Merge tracker additions into applications.md
merge_tracker() {
  echo ""
  echo "=== Merging tracker additions ==="
  node "$PROJECT_DIR/merge-tracker.mjs"
  echo ""
  echo "=== Verifying pipeline integrity ==="
  node "$PROJECT_DIR/verify-pipeline.mjs" || echo "⚠️  Verification found issues (see above)"
}

# Print summary
print_summary() {
  echo ""
  echo "=== Batch Summary ==="

  if [[ ! -f "$STATE_FILE" ]]; then
    echo "No state file found."
    return
  fi

  local total=0 completed=0 failed=0 pending=0
  local score_sum=0 score_count=0

  while IFS=$'\t' read -r sid _ sstatus _ _ _ sscore _ _; do
    [[ "$sid" == "id" ]] && continue
    total=$((total + 1))
    case "$sstatus" in
      completed) completed=$((completed + 1))
        if [[ "$sscore" != "-" && -n "$sscore" ]]; then
          score_sum=$(echo "$score_sum + $sscore" | bc 2>/dev/null || echo "$score_sum")
          score_count=$((score_count + 1))
        fi
        ;;
      failed) failed=$((failed + 1)) ;;
      *) pending=$((pending + 1)) ;;
    esac
  done < "$STATE_FILE"

  echo "Total: $total | Completed: $completed | Failed: $failed | Pending: $pending"

  if (( score_count > 0 )); then
    local avg
    avg=$(echo "scale=1; $score_sum / $score_count" | bc 2>/dev/null || echo "N/A")
    echo "Average score: $avg/5 ($score_count scored)"
  fi
}

# Main
main() {
  check_prerequisites

  if [[ "$DRY_RUN" == "false" ]]; then
    acquire_lock
  fi

  init_state

  # Count input offers (skip header, ignore blank lines)
  local total_input
  total_input=$(tail -n +2 "$INPUT_FILE" | grep -c '[^[:space:]]' 2>/dev/null || true)
  total_input="${total_input:-0}"

  if (( total_input == 0 )); then
    echo "No offers in $INPUT_FILE. Add offers first."
    exit 0
  fi

  echo "=== career-ops batch runner ==="
  echo "Provider: $SELECTED_PROVIDER (requested: $PROVIDER)"
  echo "Parallel: $PARALLEL | Max retries: $MAX_RETRIES"
  echo "Input: $total_input offers"
  echo ""

  # Build list of offers to process
  local -a pending_ids=()
  local -a pending_urls=()
  local -a pending_sources=()
  local -a pending_notes=()

  while IFS=$'\t' read -r id url source notes; do
    [[ "$id" == "id" ]] && continue  # skip header
    [[ -z "$id" || -z "$url" ]] && continue

    # Guard against non-numeric id values
    [[ "$id" =~ ^[0-9]+$ ]] || continue

    # Skip if before start-from
    if (( id < START_FROM )); then
      continue
    fi

    local status
    status=$(get_status "$id")

    if [[ "$RETRY_FAILED" == "true" ]]; then
      # Only process failed offers
      if [[ "$status" != "failed" ]]; then
        continue
      fi
      # Check retry limit
      local retries
      retries=$(get_retries "$id")
      if (( retries >= MAX_RETRIES )); then
        echo "SKIP #$id: max retries ($MAX_RETRIES) reached"
        continue
      fi
    else
      # Skip completed offers
      if [[ "$status" == "completed" ]]; then
        continue
      fi
      # Skip failed offers that hit retry limit (unless --retry-failed)
      if [[ "$status" == "failed" ]]; then
        local retries
        retries=$(get_retries "$id")
        if (( retries >= MAX_RETRIES )); then
          echo "SKIP #$id: failed and max retries reached (use --retry-failed to force)"
          continue
        fi
      fi
    fi

    pending_ids+=("$id")
    pending_urls+=("$url")
    pending_sources+=("$source")
    pending_notes+=("$notes")
  done < "$INPUT_FILE"

  local pending_count=${#pending_ids[@]}

  if (( pending_count == 0 )); then
    echo "No offers to process."
    print_summary
    exit 0
  fi

  echo "Pending: $pending_count offers"
  echo ""

  # Dry run: just list
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "=== DRY RUN (no processing) ==="
    for i in "${!pending_ids[@]}"; do
      local status
      status=$(get_status "${pending_ids[$i]}")
      echo "  #${pending_ids[$i]}: ${pending_urls[$i]} [${pending_sources[$i]}] (status: $status)"
    done
    echo ""
    echo "Would process $pending_count offers"
    exit 0
  fi

  # Process offers
  if (( PARALLEL <= 1 )); then
    # Sequential processing
    for i in "${!pending_ids[@]}"; do
      process_offer "${pending_ids[$i]}" "${pending_urls[$i]}" "${pending_sources[$i]}" "${pending_notes[$i]}"
    done
  else
    # Parallel processing with job control
    local running=0
    local -a pids=()
    local -a pid_ids=()

    for i in "${!pending_ids[@]}"; do
      # Wait if we're at parallel limit
      while (( running >= PARALLEL )); do
        # Wait for any child to finish
        for j in "${!pids[@]}"; do
          if ! kill -0 "${pids[$j]}" 2>/dev/null; then
            wait "${pids[$j]}" 2>/dev/null || true
            unset 'pids[j]'
            unset 'pid_ids[j]'
            running=$((running - 1))
          fi
        done
        # Compact arrays
        pids=("${pids[@]}")
        pid_ids=("${pid_ids[@]}")
        sleep 1
      done

      # Launch worker in background
      process_offer "${pending_ids[$i]}" "${pending_urls[$i]}" "${pending_sources[$i]}" "${pending_notes[$i]}" &
      pids+=($!)
      pid_ids+=("${pending_ids[$i]}")
      running=$((running + 1))
    done

    # Wait for remaining workers
    for pid in "${pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
  fi

  # Merge tracker additions
  merge_tracker

  # Print summary
  print_summary
}

main "$@"
