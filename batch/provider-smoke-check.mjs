#!/usr/bin/env node

/**
 * batch/provider-smoke-check.mjs
 *
 * Static smoke test for batch provider parity. This does not launch Codex or
 * Claude workers. Instead, it validates that the shared worker contract,
 * prompt, and orchestrator wiring still describe the same repository-visible
 * behavior for both providers.
 */

import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

function read(relPath) {
  return readFileSync(join(ROOT, relPath), 'utf-8');
}

function assertIncludes(haystack, needle, context) {
  if (!haystack.includes(needle)) {
    throw new Error(`${context} missing expected text: ${needle}`);
  }
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

const runner = read('batch/batch-runner.sh');
const prompt = read('batch/batch-prompt.md');
const schema = JSON.parse(read('batch/worker-result.schema.json'));

assertIncludes(runner, '--provider NAME', 'batch-runner help');
assertIncludes(runner, 'auto, claude, or codex', 'batch-runner provider selection');
assertIncludes(runner, 'run_claude_worker()', 'batch-runner Claude worker adapter');
assertIncludes(runner, 'run_codex_worker()', 'batch-runner Codex worker adapter');
assertIncludes(runner, 'claude -p', 'batch-runner Claude command');
assertIncludes(runner, 'codex exec', 'batch-runner Codex command');
assertIncludes(runner, '--output-schema "$WORKER_SCHEMA_FILE"', 'batch-runner Codex schema flag');
assertIncludes(runner, 'recover_offer_completion', 'batch-runner artifact recovery');

assertIncludes(prompt, 'devolver el JSON final válido', 'batch prompt completion rule');
assertIncludes(prompt, 'No dependes de ningún otro skill ni sistema.', 'batch prompt self-contained rule');
assertIncludes(prompt, 'status', 'batch prompt JSON contract');
assertIncludes(prompt, 'report_path', 'batch prompt report artifact contract');
assertIncludes(prompt, 'pdf_path', 'batch prompt PDF artifact contract');
assertIncludes(prompt, 'tracker_path', 'batch prompt tracker artifact contract');

const requiredFields = [
  'status',
  'id',
  'report_num',
  'company',
  'company_slug',
  'role',
  'score',
  'legitimacy',
  'pdf_path',
  'report_path',
  'tracker_path',
  'error',
];

assert(schema.type === 'object', 'worker-result schema must be an object');
assert(schema.additionalProperties === false, 'worker-result schema must forbid extra properties');
assert(Array.isArray(schema.required), 'worker-result schema must define required fields');

for (const field of requiredFields) {
  assert(schema.required.includes(field), `worker-result schema missing required field: ${field}`);
  assert(schema.properties && schema.properties[field], `worker-result schema missing property: ${field}`);
}

const statusEnum = schema.properties.status?.enum || [];
assert(statusEnum.includes('completed') && statusEnum.includes('failed'), 'worker-result schema status enum must include completed and failed');

console.log('batch provider smoke check passed');
