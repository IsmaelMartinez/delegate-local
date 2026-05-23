---
inputs:
  stdin: string
---
# ci-log-triage

## When to use

The user has a failing CI / build run and wants to know what broke, where, and what to look at next — not a narrative of the run. Input is a CI failure log (typically `gh run view <run-id> --log-failed` on GitHub or `glab ci view --log` on GitLab), output is five structured fields the calling agent can act on directly.

This recipe is the triage sibling of `summarise-issue.md`. Pick this one when the user wants to *fix* the failure (FAILURE_TYPE / ROOT_CAUSE / NEXT_STEP); pick `summarise-issue.md` when the user wants a *timeline* of a multi-event log (What happened / What's blocking / What's next). Both ingest CI logs; the output shape is what decides.

This recipe is the prototypical input-digestion shape: a log slice of 5-100 KB collapses to ~500 bytes of structured fields. Per-call token savings on this task dominate the ~4 KB output-bounded recipes elsewhere in the library by 10-100×. That's the headline economic case for the recipe library expanding in this direction (ROADMAP 2026-05-18 entry).

## Context to gather first

```bash
# GitHub: the failed-steps slice only. The unfiltered --log is 100 KB-MBs of
# pass-noise; --log-failed is the agent's first pre-filter.
gh run view <run-id> --log-failed

# GitLab equivalent: last failing job's log.
glab ci view --log <pipeline-id>

# If --log-failed is still > ~20 KB on a 35B prose-tier host (issue #110:
# recipe-shaped prompts stall at ~3-4 KB on that model class), narrow further
# with a grep-context filter before piping. The right window is usually the
# last error block:
gh run view <run-id> --log-failed | grep -B 2 -A 20 -iE '##\[error\]|FAIL|error:|panic|fatal' | tail -300
```

Do NOT pipe the full unfiltered `--log` — the recipe ingests a slice. The skill discriminator from SKILL.md ("setup overhead dominates below ~4 paragraphs of fresh prose") works the other way for input-digestion: setup wins amortise *above* a threshold of input size, and a pre-filtered slice is still 10× the input size of an output-bounded recipe.

## Prompt template

```
Triage this CI failure log. Output the five fields below in this exact order and format. Each field is one line except ROOT_CAUSE which may span 1-3 lines (verbatim from the log).

FAILURE_TYPE: <one of: test | build | lint | timeout | network | install | permission | missing-file | config | other>
JOB: <the failing job name from the log>
STEP: <the failing step name within the job>
ROOT_CAUSE: <1-3 verbatim lines from the log that pinpoint the failure; do not paraphrase>
NEXT_STEP: <which file in the repo to inspect next, OR a specific command to run, to start fixing this — name an actual path or command, not advice>

Rules:
- ROOT_CAUSE must be VERBATIM text from the log, not your interpretation. Quote the exact line containing the error keyword, optionally with the line above and below for context. Anchor every claim to evidence in the input.
- NEXT_STEP must name an actual file path or shell command, not advice ("review the config", "check permissions"). If the failure is in user code, name the workflow file, test file, or source file actually involved.
- FAILURE_TYPE category boundaries: static-analysis tools (CodeQL, ESLint, semgrep, ruff, mypy) are `lint`, NOT `test`. Test runners (pytest, jest, cargo test, go test) are `test`. Compilation / packaging steps (tsc, webpack, rollup, sam build) are `build`. Dependency-resolution failures (pip install, npm install, cargo fetch) are `install`. The `analyze` job name on its own does not imply `test` — match the tool actually running.
- If the failure type genuinely does not fit the listed categories, use `other` and explain in ROOT_CAUSE.
- Output ONLY the five fields, one per line (ROOT_CAUSE may wrap to additional lines). No preamble, no markdown headers, no trailing summary.

=== CI failure log ===
{{stdin}}
```

## Variables

- `{{stdin}}` — the CI failure log slice (pre-filtered per the "Context to gather first" section), piped to the wrapper. No `--var` flags are needed for the default invocation.

## Invocation

```bash
gh run view <run-id> --log-failed \
  | bash scripts/delegate.sh --recipe ci-log-triage \
      reasoning "Output exactly the five fields in order. ROOT_CAUSE must be verbatim text from the log."
```

For a large `--log-failed` output on a 35B-class prose-tier host (see issue #110), narrow with grep first:

```bash
gh run view <run-id> --log-failed \
  | grep -B 2 -A 20 -iE '##\[error\]|FAIL|error:|panic|fatal' \
  | tail -300 \
  | bash scripts/delegate.sh --recipe ci-log-triage \
      reasoning "Output exactly the five fields in order. ROOT_CAUSE must be verbatim text from the log."
```

After the call, verify (see Expected output shape) and record the verdict:

```bash
bash scripts/delegate-feedback.sh hit
# or
bash scripts/delegate-feedback.sh miss "<reason>"
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "ROOT_CAUSE must be VERBATIM text from the log, not your interpretation. Quote the exact line containing the error keyword" — the highest-volume failure mode on classification-from-log tasks: the model rewrites the error into prose ("the build failed because the JavaScript files were empty") instead of citing the line that says so. The verbatim guard makes the field auditable against the input.
- "Anchor every claim to evidence in the input" — the 2026-05-14 restraint-prompting probe finding (PR #122): on MLX-class prose-tier models the anchoring directive moves citation rate from 0.75 to 1.00 with no claim-count cost. Applies cleanly here because every field except FAILURE_TYPE is meant to be a citation from the input.
- "NEXT_STEP must name an actual file path or shell command, not advice" — without it the model produces "review the workflow configuration" or "check permissions on the runner". The agent then has to do the actual file-finding work the recipe is supposed to do. Naming a concrete path is the recipe's load-bearing output.
- "Output ONLY the five fields ... No preamble, no markdown headers, no trailing summary" — SKILL.md's prose-tier anti-padding directive. Without it, reasoning-tier models wrap the structured output in `## Triage summary` headers or close with "Hope this helps."
- "If the failure type genuinely does not fit the listed categories, use `other`" — the closed-list discipline. Without the `other` escape hatch, the model invents a synonym (`compilation` instead of `build`, `assert` instead of `test`) and the downstream parser breaks. The escape hatch is named per the v6 / v8 "REFUSE hatch" pattern in `SKILL.md`.

The `reasoning` tier (not `prose`) is intentional. Same argument `summarise-issue.md` makes: log triage is filtering and classification, not prose generation. The output is short and structured; the cost is on identifying which line in the log is the load-bearing one, which is reasoning-tier territory.

## Expected output shape

```
FAILURE_TYPE: build
JOB: analyze
STEP: Run github/codeql-action/analyze@v3
ROOT_CAUSE: [build-stderr] Only found JavaScript or TypeScript files that were empty or contained syntax errors.
CodeQL could not process any code written in JavaScript/TypeScript. For more information, review our troubleshooting guide at https://gh.io/troubleshooting-code-scanning/no-source-code-seen-during-build .
NEXT_STEP: .github/workflows/codeql-analysis.yml — verify the `languages:` matrix matches the repo's actual content.
```

Verify before recording verdict: FAILURE_TYPE is one of the listed categories (or `other` with explanation in ROOT_CAUSE); JOB and STEP names match strings present in the log; ROOT_CAUSE lines appear VERBATIM somewhere in the input (grep-check if unsure); NEXT_STEP names an actual path or command; no preamble, no markdown header, no trailing summary line.

## Calibration notes

Initial recipe drafted 2026-05-18 from the ROADMAP 2026-05-18 framing of "input-digestion recipes are where the per-call token savings 10-100× the output-bounded recipes." The triage shape is the cleanest case: large log in, five structured fields out.

The recipe explicitly diverges from `summarise-issue.md`'s OMIT-EMPTY-SECTION pattern, which the 2026-05-10 / 2026-05-11 calibration notes there show fails to bind on `deepseek-r1:32b` (the reasoning-tier default). Triage uses required fields with a closed-list escape hatch (`other`) instead of optional sections. The structural-rules-not-optional-rules choice is informed by that prior calibration: when the OMIT pattern proved resistant to four iterations of progressively stronger directives, the conclusion was that "honest acknowledgement of absence is informative output" is a hard prior to override. Required fields side-step the prior entirely.

### 2026-05-18 dogfoods: HIT-with-edits → recipe revision → HIT × 2

Two dogfood passes against `deepseek-r1:32b` (reasoning tier), each ~6-7 KB input:

**Pass 1 — `gh run view 25653846330 --log-failed`** (CodeQL javascript-extraction failure). First attempt classified FAILURE_TYPE as `test` despite the failure being a static-analysis tool finding no source files to analyse. JOB / STEP / ROOT_CAUSE / NEXT_STEP all correct on first attempt; the only miss was the category boundary — the `analyze` job name plus the "could not process" wording read like a test runner to the model. The recipe's classification rule was extended with an explicit static-analysis-tools-are-`lint`-not-`test` disambiguation listing CodeQL / ESLint / semgrep / ruff / mypy, plus a `the analyze job name on its own does not imply test` clause. Re-run produced FAILURE_TYPE: `lint` with all other fields unchanged. HIT verbatim.

**Pass 2 — a GitHub Models API transport error** (`shape: total=23 ... github_models transport error` log slice). FAILURE_TYPE: `other`, with the ROOT_CAUSE field carrying the verbatim `github_models transport error` line — correct use of the escape hatch since `transport error` doesn't fit `network` cleanly (could be remote-service-down, not the runner's network). JOB / STEP / ROOT_CAUSE / NEXT_STEP all correct on first attempt. HIT.

Both verdicts recorded via `delegate-feedback.sh hit`. The category-disambiguation revision is the load-bearing learning: small reasoning-tier models classify by surface lexical pattern (the word `analyze` → test) rather than by the actual tool running, and the fix is the same v5/v7 directive-rule pattern documented elsewhere in this library — explicit category-boundary clarifications plus the "job name on its own does not imply" override. Future failure shapes that recur will graduate into similar disambiguation lines in the same rule list.
