# Codex Setup

Career-Ops supports Codex through the root `AGENTS.md` file.

If your Codex client reads project instructions automatically, `AGENTS.md`
is enough for routing and behavior. Codex should reuse the same checked-in
mode files, templates, tracker flow, scripts, and output contracts that
already power the Claude and OpenCode workflows.

## Prerequisites

- A Codex client that can work with project `AGENTS.md`
- Node.js 18+
- Playwright Chromium installed for PDF generation and reliable job verification
- Go 1.21+ if you want the TUI dashboard

## Install

```bash
npm install
npx playwright install chromium
```

## Recommended Starting Prompts

- `Evaluate this job URL with Career-Ops and run the full pipeline.`
- `Scan my configured portals for new roles that match my profile.`
- `Generate the tailored ATS PDF for this role using Career-Ops.`

## What Works Today

- Single-offer evaluation and the full auto-pipeline
- Portal scan and pipeline inbox processing
- PDF generation and tracker maintenance
- Repo customization through the shared `modes/*`, scripts, and templates
- Batch processing through `batch/batch-runner.sh --provider codex`

## Parity Goal

Codex support is not meant to be a reduced path. The repository contract is:

- the same routing and decision rules as Claude Code
- the same `modes/*` and local scripts
- the same report, PDF, tracker, and merge outputs
- the same personalization boundaries from `DATA_CONTRACT.md`

Provider-specific CLI flags, sandbox settings, and worker launch details are
implementation details only. If Codex and Claude produce different repository
behavior for the same request, treat that as a bug.

Batch execution note: the standalone runner invokes Codex workers in non-interactive full-access mode so Playwright-backed PDF generation can succeed. Treat batch runs as trusted local automation, not as a sandboxed browsing mode.

## Routing Map

| User intent | Files Codex should read |
|-------------|-------------------------|
| Raw JD text or job URL | `modes/_shared.md` + `modes/auto-pipeline.md` |
| Single evaluation only | `modes/_shared.md` + `modes/oferta.md` |
| Multiple offers | `modes/_shared.md` + `modes/ofertas.md` |
| Portal scan | `modes/_shared.md` + `modes/scan.md` |
| PDF generation | `modes/_shared.md` + `modes/pdf.md` |
| Live application help | `modes/_shared.md` + `modes/apply.md` |
| Pipeline inbox processing | `modes/_shared.md` + `modes/pipeline.md` |
| Tracker status | `modes/tracker.md` |
| Deep company research | `modes/deep.md` |
| Training / certification review | `modes/training.md` |
| Project evaluation | `modes/project.md` |

The key point: Codex support is additive. It routes into the existing
Career-Ops modes and scripts rather than introducing a parallel automation
layer.

## Behavioral Rules

- Treat raw JD text or a job URL as the full auto-pipeline path unless the user explicitly asks for evaluation only.
- Keep all personalization in `config/profile.yml`, `modes/_profile.md`, `article-digest.md`, or `portals.yml`.
- Never verify a job’s live status with generic web fetch when Playwright is available.
- Never submit an application for the user.
- Never add new tracker rows directly to `data/applications.md`; use the TSV addition flow and `merge-tracker.mjs`.
- When using batch mode, prefer `./batch/batch-runner.sh --provider codex` if you want explicit Codex workers instead of auto-selection.

## Verification

```bash
npm run verify
npm run test:providers

# optional dashboard build
cd dashboard && go build ./...
```

OpenAI references:
- Codex terminal overview: https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan/
- AGENTS.md behavior: https://openai.com/index/introducing-codex/
