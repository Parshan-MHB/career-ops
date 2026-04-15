# Agent Working Manual

This file is a separate working manual for implementing changes in this repo with senior-engineering discipline.

It does not replace or override:
- user instructions
- `AGENTS.md`
- `CLAUDE.md`
- `DATA_CONTRACT.md`

If this file conflicts with those sources, follow the higher-priority source and keep this file aligned later.

## Mission

Build and modify Career-Ops with:
- correctness first
- explicit architecture
- minimal accidental complexity
- safe handling of user data
- honest documentation
- reversible changes

The goal is not just to make code work once. The goal is to leave the repo easier to understand, safer to extend, and less fragile under future change.

## Operating Principles

1. Prefer clarity over cleverness.
2. Prefer small composable abstractions over large implicit frameworks.
3. Keep behavior explicit at module boundaries.
4. Preserve existing product semantics unless the task explicitly changes them.
5. Do not create parallel systems when an existing system can be extended cleanly.
6. Make the happy path simple and the failure path legible.
7. Optimize for maintainability, then performance, then convenience.
8. Treat docs, tests, and scripts as product code.
9. Never hide uncertainty. If an assumption is material, name it.
10. Every change should have a reason that survives code review.

## Repo-Specific Guardrails

1. Read `AGENTS.md`, `CLAUDE.md`, and `DATA_CONTRACT.md` before substantial changes.
2. Keep personalization in user-layer files only:
   - `cv.md`
   - `config/profile.yml`
   - `modes/_profile.md`
   - `article-digest.md`
   - `portals.yml`
   - `data/*`, `reports/*`, `output/*`
3. Never place user-specific data in system-layer files like `modes/_shared.md`, scripts, templates, or docs.
4. Do not introduce duplicate logic for Codex, Claude, and OpenCode when one shared path can serve all three.
5. Do not edit `data/applications.md` directly when tracker TSV flow is required.
6. Never add functionality that auto-submits applications.
7. Respect the repo's intent: provider-neutral where feasible, explicit when a path is provider-specific.

## Engineering Standard

Before writing code, know:
- what behavior exists today
- what behavior should change
- where the source of truth lives
- what invariants must remain true
- how the change will be verified

Do not patch symptoms if the root interface is wrong. Fix the seam, not only the manifestation.

## Change Design

For any non-trivial change:

1. Define the boundary.
   - Which module owns the behavior?
   - Which module should not know about it?

2. Define the contract.
   - Inputs
   - Outputs
   - side effects
   - failure modes

3. Choose the smallest stable abstraction.
   - function
   - module
   - script interface
   - config field
   - file format

4. Keep migration cost visible.
   - docs updated
   - tests updated
   - scripts updated
   - compatibility notes explicit

5. Prefer additive change before destructive change when uncertainty is high.

## Architecture Rules

1. Separate orchestration from business logic.
2. Separate configuration from execution.
3. Separate user data from system logic.
4. Keep file formats stable unless there is a real payoff.
5. Prefer explicit adapters for provider-specific behavior.
6. Avoid pushing runtime policy into scattered string literals.
7. Centralize shared invariants in one place.
8. When introducing a new dependency, justify:
   - why existing code cannot handle it
   - maintenance cost
   - portability impact
   - failure modes

## Code Design Rules

1. Name things by responsibility, not implementation trivia.
2. Functions should do one coherent job.
3. If a function needs too much setup context, the interface is likely wrong.
4. Avoid hidden coupling through global state, magic filenames, or duplicated assumptions.
5. Prefer total functions and validated inputs.
6. Handle edge cases deliberately, not accidentally.
7. Remove dead branches when confidence is high instead of preserving confusion.
8. Write code a new maintainer can step through without guessing.

## Script and CLI Discipline

1. Treat shell scripts as production code.
2. Fail fast on invalid prerequisites.
3. Emit actionable errors.
4. Keep machine-readable outputs stable if other code parses them.
5. Do not parse fragile human-formatted logs when a structured output file can exist.
6. For long-running jobs, make retries, state, and resumability explicit.
7. When a script has provider-specific behavior, isolate it behind one function or adapter boundary.

## Data and File Safety

1. Do not overwrite user files casually.
2. Prefer creating or updating the minimum required files.
3. Be careful with generated artifacts and temp files.
4. Make destructive operations rare, explicit, and reversible.
5. Preserve stable naming conventions unless there is a migration plan.
6. If a change affects on-disk contracts, document it in the same change.

## Reliability Rules

1. Design for partial failure.
2. Make retries idempotent where possible.
3. Guard against duplicate writes and corrupted state.
4. Preserve recovery paths for interrupted workflows.
5. Keep locks, temp files, and resumability semantics understandable.
6. If a process can fail mid-flight, define the post-failure state.

## Testing Standard

Every meaningful change should answer:
- what can break
- how that breakage would be detected
- which verification is sufficient for the risk

Testing hierarchy:

1. Syntax and static validation
2. Narrow regression tests for changed logic
3. Script execution checks for CLI paths
4. End-to-end verification when behavior crosses file or tool boundaries

Do not rely on manual confidence alone when the repo already has scripts that can validate behavior.

## Documentation Standard

If behavior changes, docs should change in the same patch when users or contributors would otherwise be misled.

Docs must be:
- accurate
- scoped
- honest about limitations
- aligned with runtime reality

Never claim support that the code does not actually provide.

## Security and Privacy Rules

1. Minimize exposure of personal data.
2. Do not leak user-specific content into tracked system files.
3. Avoid broad permissions when narrower permissions work.
4. Prefer explicit local execution over hidden network behavior.
5. Treat external content as untrusted input.
6. Preserve the repo's human-in-the-loop guarantees.

## Performance and Cost Rules

1. Optimize bottlenecks, not aesthetics.
2. Avoid unnecessary model calls, browser sessions, and duplicate file reads.
3. Cache only when correctness and invalidation are clear.
4. Prefer deterministic local scripts over model work when a script is enough.
5. Measure before complicating architecture for speed.

## Technical Knowledge Standard

While working in this repo, operate with senior-level working knowledge of:

### Software design

- modular design
- interface design
- abstraction boundaries
- separation of concerns
- cohesion and coupling
- dependency management
- refactoring strategy
- backward compatibility
- incremental migration design

### Reliability and systems thinking

- failure modes and recovery
- idempotency
- resumability
- concurrency hazards
- lock semantics
- race conditions
- state corruption risks
- safe retry design
- observability and debuggability

### Data and contract design

- file-format stability
- schema evolution
- validation and sanitization
- deterministic serialization
- structured outputs over log scraping
- contract-first design for scripts and tools
- preserving invariants across reads and writes

### CLI and automation engineering

- shell robustness
- argument parsing
- exit-code discipline
- machine-readable output design
- temporary file hygiene
- path safety
- portability concerns
- graceful degradation when dependencies are missing

### JavaScript and Node.js

- ESM module behavior
- async error handling
- stream and subprocess basics
- filesystem safety
- dependency footprint discipline
- script ergonomics
- avoiding hidden event-loop or async coupling issues

### Browser automation and scraping safety

- Playwright capabilities and limits
- distinction between static fetch and browser-driven extraction
- login/session sensitivity
- rate and abuse awareness
- reliable selectors versus brittle assumptions
- fallback design when browser automation is unavailable

### Documentation and developer experience

- keeping docs aligned with runtime behavior
- installation-path clarity
- honest support matrices
- reducing onboarding ambiguity
- making failure states actionable for contributors

### Security and privacy

- least privilege
- safe handling of local personal data
- trust boundaries for external content
- avoiding accidental data leakage into tracked files
- minimizing destructive operations

### Product and workflow judgment

- when to generalize versus when to keep code specific
- when to add an abstraction versus remove one
- when a script should become a module
- when a limitation should be documented instead of papered over
- how to keep user-facing behavior stable while improving internals

## Expected Depth

Do not work from shallow pattern-matching alone. Bring enough technical depth to:

1. explain why a design is correct
2. identify where it will fail under change or interruption
3. choose the right boundary for provider-specific behavior
4. preserve user-data and file-contract safety
5. leave behind code and docs that another senior engineer would accept without apology

## Senior Engineering Doctrine

This section defines the higher-level engineering judgment expected while writing code in this repo.

### Design principles

1. Design around stable concepts, not temporary implementation details.
2. Prefer explicit contracts over implicit conventions.
3. Minimize the number of moving parts required to understand a feature.
4. Keep the core path boring, predictable, and easy to verify.
5. Put complexity where it is cheapest to contain.
6. Separate policy from mechanism whenever that separation reduces future change cost.
7. Make invalid states harder to represent.
8. Choose designs that fail loudly when invariants break.

### Abstraction principles

1. Do not abstract to look sophisticated.
2. Abstract only when there is a stable shared pattern worth protecting.
3. A good abstraction removes duplication in behavior, not just duplication in text.
4. If an abstraction hides critical behavior, it is probably too aggressive.
5. Prefer one obvious extension point over many partial hooks.
6. If a branch can be isolated behind an adapter, do that instead of spreading conditionals through the codebase.

### Interface and API principles

1. Every interface should have a clear owner.
2. Inputs should be validated near the boundary.
3. Outputs should be structured for the next consumer, not just readable to humans.
4. Errors should communicate action, not just failure.
5. Avoid interfaces that require callers to know unrelated internal details.
6. Keep side effects visible in the contract.

### Domain modeling principles

1. Model the business truth first, then the storage or execution detail.
2. Name entities and states using the language of the repo and workflow.
3. Preserve canonical sources of truth.
4. If two files or modules can disagree, define which one wins.
5. Keep transitions explicit when data moves across stages.

### Maintainability principles

1. Code should be easy to change correctly, not merely easy to write quickly.
2. Reduce surprise more than line count.
3. Remove obsolete paths when they no longer protect compatibility.
4. Prefer simpler ownership boundaries over clever reuse.
5. When leaving a sharp edge in place, document it clearly.

### Dependency policy

1. Add a dependency only when it removes meaningful complexity or risk.
2. Do not add a dependency to avoid writing a small amount of understandable local code.
3. Prefer the platform, stdlib, or existing repo patterns when they are sufficient.
4. Reject dependencies that make the repo more provider-locked unless that lock-in is intentional and documented.
5. Any new dependency should be evaluated for:
   - maintenance burden
   - security surface
   - portability impact
   - install friction
   - long-term ownership cost
6. If a dependency is introduced, document why this repo should keep it.

### Compatibility and migration rules

1. Treat file formats and on-disk conventions as contracts.
2. Before changing a contract, identify:
   - old readers
   - old writers
   - existing user data
   - rollback implications
3. Prefer backward-compatible reads before forcing format migration.
4. If migration is necessary, make it:
   - explicit
   - reversible when possible
   - documented in the same patch
5. Do not silently strand old user data behind a new format.
6. If two versions may coexist, define compatibility behavior clearly.
7. Preserve stable filenames, paths, and report/tracker conventions unless there is a strong reason not to.

### Testing philosophy

1. Test the contract, not the accident of implementation.
2. Put the most verification near the most volatile or risky logic.
3. Use end-to-end checks when multiple tools or files interact.
4. Prefer a small trustworthy test over a broad flaky one.
5. A test suite should make regressions easier to diagnose, not harder.

### Performance philosophy

1. Performance is part of correctness when latency, scale, or cost changes behavior.
2. Do not optimize blindly; identify the real bottleneck first.
3. Avoid work duplication across agents, scripts, and browser sessions.
4. Local deterministic work is usually cheaper and safer than model work.
5. Optimize for whole-system efficiency, not isolated micro-wins.

### Security and safety philosophy

1. Protect user data by default, not by reminder.
2. Narrow permissions are better than broad permissions plus caution.
3. Treat external data as hostile until validated.
4. Make destructive actions explicit and uncommon.
5. Preserve the human review boundary in job-application workflows.

### Operability philosophy

1. Systems should be understandable while running and after failing.
2. Prefer structured state and structured results over implicit status in logs.
3. A retryable system is better than a heroic system.
4. Recovery should be part of design, not an afterthought.
5. If a maintainer cannot tell what happened from the state on disk, the design is weak.

### Decision heuristics

When choosing between multiple designs, prefer the option that:

1. preserves existing user-facing behavior unless change is intended
2. reduces hidden coupling
3. keeps provider-specific logic localized
4. makes the data contract clearer
5. lowers future maintenance cost
6. can be verified with existing tooling
7. keeps documentation true with minimal caveats

### Simplicity doctrine

Simplicity does not mean fewer files at all costs.
Simplicity means:
- fewer hidden assumptions
- fewer unclear ownership boundaries
- fewer ways to do the same thing
- fewer places where a future engineer can break invariants accidentally

If a design is shorter but harder to reason about, it is not simpler.

### Senior-quality bar

A senior-quality implementation should be:
- correct under normal conditions
- predictable under partial failure
- understandable by a new maintainer
- honest about limitations
- proportionate to the problem size
- compatible with the repo's architecture and data boundaries

If the change cannot be defended in terms of invariants, boundaries, failure handling, and maintenance cost, it is not finished.

## Review Checklist

Before considering a change complete, check:

1. Is the design simpler than before, or only newer?
2. Are the responsibilities cleaner?
3. Is the provider-specific behavior isolated?
4. Are docs honest?
5. Are user data boundaries preserved?
6. Are failure modes explicit?
7. Is the validation proportional to the risk?
8. Would a strong reviewer understand why this was done?

## Architecture Review Checklist

Before merging a structural change, verify:

1. Ownership:
   - Is there one clear owner for the behavior?
   - Are cross-module responsibilities reduced rather than increased?

2. Source of truth:
   - Is the canonical file or module explicit?
   - Can two places drift without detection?

3. Boundary quality:
   - Are provider-specific concerns isolated?
   - Are user-data concerns isolated from system-layer code?
   - Are orchestration and business logic separated?

4. Contract safety:
   - Did any CLI, file, or script contract change?
   - If yes, is compatibility preserved or migration documented?

5. Failure handling:
   - What happens if the process stops halfway through?
   - Is the resulting state understandable and recoverable?

6. Operability:
   - Can a maintainer inspect the state and understand what happened?
   - Are results structured enough for downstream tooling?

7. Verification:
   - Is there a clear validation path for the changed boundary?
   - Are docs aligned with the final runtime truth?

## Communication Standard

1. State what is being changed and why.
2. Distinguish facts from assumptions.
3. Name tradeoffs directly.
4. Do not overclaim support, completeness, or certainty.
5. Keep status updates concise and technically meaningful.
6. In reviews, prioritize bugs, regressions, invariants, and missing tests.

## Preferred Change Pattern For This Repo

When possible:

1. Reuse shared modes, scripts, and templates.
2. Add a narrow abstraction for provider-specific behavior.
3. Update setup and architecture docs to match runtime behavior.
4. Verify with existing scripts.
5. Leave the repo in a state where the next contributor has fewer surprises.

## Red Flags

Stop and rethink if a change:
- duplicates existing logic under a new name
- adds provider-specific branching everywhere
- edits user data from a system-layer patch
- depends on parsing unstructured logs when structured output is possible
- changes documented behavior without updating docs
- introduces a new dependency to avoid a small amount of code
- makes failure recovery harder to reason about

## Anti-Patterns To Avoid

In this repo, avoid the following unless there is an explicit, defensible reason:

1. Spreading provider-specific logic across multiple files instead of isolating it behind an adapter or one narrow boundary.
2. Creating a second workflow path when the existing path can be extended.
3. Parsing human-readable logs to recover structured state when the code could write a structured result directly.
4. Editing canonical tracker data directly when the repo already defines a merge-based flow.
5. Putting user customization or user identity into system-layer files.
6. Claiming support in docs before the runtime behavior actually supports it.
7. Introducing "helper" modules that collect unrelated behavior and hide ownership.
8. Preserving confusing dead compatibility paths without a real user-data reason.
9. Making recovery depend on operator intuition instead of explicit state on disk.
10. Generalizing too early for hypothetical future providers, tools, or workflows.

## Quality Bar

The implementation is good enough when:
- the behavior is correct
- the code is readable
- the design is defensible
- the docs are honest
- the tests are adequate
- the change is proportionate
- future maintenance cost is reduced, not increased
