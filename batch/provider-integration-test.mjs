#!/usr/bin/env node

/**
 * batch/provider-integration-test.mjs
 *
 * End-to-end synthetic integration test for the batch orchestrator. It creates
 * isolated temporary workspaces, injects fake `claude` and `codex` CLIs, and
 * verifies that both providers converge on the same repository-visible result:
 * completed batch state, report artifact, PDF artifact, and merged tracker row.
 *
 * The Codex scenario intentionally omits the final structured payload so the
 * runner has to complete through artifact recovery.
 */

import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, chmodSync, cpSync, rmSync, readdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { execFileSync } from 'child_process';

const ROOT = process.cwd();

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function read(path) {
  return readFileSync(path, 'utf8');
}

function makeWorkspace(name) {
  const dir = mkdtempSync(join(tmpdir(), `career-ops-${name}-`));
  mkdirSync(join(dir, 'batch'), { recursive: true });
  mkdirSync(join(dir, 'templates'), { recursive: true });
  mkdirSync(join(dir, 'data'), { recursive: true });
  mkdirSync(join(dir, 'reports'), { recursive: true });
  mkdirSync(join(dir, 'output'), { recursive: true });
  mkdirSync(join(dir, 'batch', 'logs'), { recursive: true });
  mkdirSync(join(dir, 'batch', 'tracker-additions', 'merged'), { recursive: true });

  for (const rel of [
    'batch/batch-runner.sh',
    'batch/batch-prompt.md',
    'batch/worker-result.schema.json',
    'merge-tracker.mjs',
    'verify-pipeline.mjs',
    'templates/states.yml',
  ]) {
    cpSync(join(ROOT, rel), join(dir, rel));
  }

  chmodSync(join(dir, 'batch/batch-runner.sh'), 0o755);

  writeFileSync(
    join(dir, 'data/applications.md'),
    [
      '# Applications Tracker',
      '',
      '| # | Date | Company | Role | Score | Status | PDF | Report | Notes |',
      '|---|------|---------|------|-------|--------|-----|--------|-------|',
      '',
    ].join('\n'),
    'utf8'
  );

  writeFileSync(
    join(dir, 'batch/batch-input.tsv'),
    ['id\turl\tsource\tnotes', '1\thttps://example.com/job\tSynthetic\tfixture'].join('\n') + '\n',
    'utf8'
  );

  return dir;
}

function makeProviderShims(dir) {
  const binDir = join(dir, 'bin');
  mkdirSync(binDir, { recursive: true });

  const claudeShim = `#!/usr/bin/env bash
set -euo pipefail
prompt="\${@: -1}"
report_num=$(printf '%s' "$prompt" | sed -n 's/.*Report number: \\([0-9][0-9][0-9]*\\).*/\\1/p')
date_value=$(printf '%s' "$prompt" | sed -n 's/.*Date: \\([0-9-][0-9-]*\\).*/\\1/p')
batch_id=$(printf '%s' "$prompt" | sed -n 's/.*Batch ID: \\([0-9][0-9]*\\).*/\\1/p')
company_slug="shim-company"
report_path="reports/\${report_num}-\${company_slug}-\${date_value}.md"
pdf_path="output/cv-candidate-\${company_slug}-\${date_value}.pdf"
tracker_path="batch/tracker-additions/\${batch_id}.tsv"
mkdir -p reports output batch/tracker-additions
cat > "$report_path" <<EOF
# Evaluación: Shim Company — Staff Platform Engineer

**Fecha:** \${date_value}
**Arquetipo:** Agentic / Automation
**Score:** 4.7/5
**Legitimacy:** High Confidence
**URL:** https://example.com/job
**PDF:** \${pdf_path}
**Batch ID:** \${batch_id}
EOF
printf 'synthetic pdf' > "$pdf_path"
printf '1\t%s\tShim Company\tStaff Platform Engineer\tEvaluated\t4.7/5\t✅\t[%s](%s)\tSynthetic tracker row\n' "$date_value" "$report_num" "$report_path" > "$tracker_path"
cat <<EOF
{"status":"completed","id":"\${batch_id}","report_num":"\${report_num}","company":"Shim Company","company_slug":"\${company_slug}","role":"Staff Platform Engineer","score":4.7,"legitimacy":"High Confidence","pdf_path":"\${pdf_path}","report_path":"\${report_path}","tracker_path":"\${tracker_path}","error":null}
EOF
`;

  const codexShim = `#!/usr/bin/env bash
set -euo pipefail
project_dir=""
output_last_message=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd)
      project_dir="$2"
      shift 2
      ;;
    --output-last-message)
      output_last_message="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
input="$(cat)"
report_num=$(printf '%s' "$input" | sed -n 's/.*Report number: \\([0-9][0-9][0-9]*\\).*/\\1/p' | tail -n 1)
date_value=$(printf '%s' "$input" | sed -n 's/.*Date: \\([0-9-][0-9-]*\\).*/\\1/p' | tail -n 1)
batch_id=$(printf '%s' "$input" | sed -n 's/.*Batch ID: \\([0-9][0-9]*\\).*/\\1/p' | tail -n 1)
company_slug="shim-company"
report_path="$project_dir/reports/\${report_num}-\${company_slug}-\${date_value}.md"
pdf_rel="output/cv-candidate-\${company_slug}-\${date_value}.pdf"
pdf_path="$project_dir/\${pdf_rel}"
mkdir -p "$project_dir/reports" "$project_dir/output"
cat > "$report_path" <<EOF
# Evaluación: Shim Company — Staff Platform Engineer

**Fecha:** \${date_value}
**Arquetipo:** Agentic / Automation
**Score:** 4.6/5
**Legitimacy:** Proceed with Caution
**URL:** https://example.com/job
**PDF:** \${pdf_rel}
**Batch ID:** \${batch_id}
EOF
printf 'synthetic pdf' > "$pdf_path"
if [[ -n "$output_last_message" ]]; then
  : > "$output_last_message"
fi
echo 'synthetic codex worker exited before final JSON on purpose'
exit 1
`;

  writeFileSync(join(binDir, 'claude'), claudeShim, 'utf8');
  writeFileSync(join(binDir, 'codex'), codexShim, 'utf8');
  chmodSync(join(binDir, 'claude'), 0o755);
  chmodSync(join(binDir, 'codex'), 0o755);

  return binDir;
}

function runScenario(provider) {
  const workspace = makeWorkspace(provider);
  const binDir = makeProviderShims(workspace);

  try {
    execFileSync(
      'bash',
      [join(workspace, 'batch/batch-runner.sh'), '--provider', provider],
      {
        cwd: workspace,
        encoding: 'utf8',
        env: {
          ...process.env,
          PATH: `${binDir}:${process.env.PATH || ''}`,
        },
        stdio: 'pipe',
        timeout: 30000,
      }
    );

    const state = read(join(workspace, 'batch/batch-state.tsv'));
    assert(/\tcompleted\t/.test(state), `${provider}: batch state should mark offer as completed`);

    const reportFiles = readdirSync(join(workspace, 'reports')).filter((name) => name.endsWith('.md'));
    assert(reportFiles.length === 1, `${provider}: expected exactly one report artifact`);

    const pdfFiles = readdirSync(join(workspace, 'output')).filter((name) => name.endsWith('.pdf'));
    assert(pdfFiles.length === 1, `${provider}: expected exactly one PDF artifact`);

    const apps = read(join(workspace, 'data/applications.md'));
    assert(apps.includes('Shim Company'), `${provider}: applications tracker should include synthetic company`);
    assert(apps.includes('Staff Platform Engineer'), `${provider}: applications tracker should include synthetic role`);

    const mergedFiles = readdirSync(join(workspace, 'batch/tracker-additions/merged')).filter((name) => name.endsWith('.tsv'));
    assert(mergedFiles.length === 1, `${provider}: expected merged tracker TSV`);

    const pendingTracker = readdirSync(join(workspace, 'batch/tracker-additions')).filter((name) => name.endsWith('.tsv'));
    assert(pendingTracker.length === 0, `${provider}: expected no pending tracker TSVs after merge`);

    return `${provider} integration scenario passed`;
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
}

const results = [runScenario('claude'), runScenario('codex')];
for (const line of results) {
  console.log(line);
}
console.log('batch provider integration test passed');
