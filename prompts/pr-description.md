---
tier: prose
inputs:
  recent_prs: string
  diff_stat: string
  context: string
echo_guard_vars: recent_prs
checks:
  no_invented_task_list: recent_prs
  no_invented_headings: recent_prs
  no_invented_refs: true
---
# pr-description

> **Status (2026-06-28): live — the `flaky_on_models` gate was RETIRED after its premise was falsified.** The 2026-05-24 gate refused this recipe on 35B/80B prose hosts believing those models *generation*-stall on recipe-shaped prompts. A 2026-06-28 probe (see the calibration note at the end) showed the opposite: the MLX 35B emits a grade-A PR description in ~6 s once warm — the only slow part is a one-time ~77 s cold-LOAD, which is the pre-flight canary's job (exit 3), not the structural gate's (exit 4). The same 35B serves `commit-message` 294× with no gate. On a 35B MLX host set `DELEGATE_PREFLIGHT_TIMEOUT=90` for the first (cold) call; warm calls need nothing. The recipe also passes where the prose tier resolves to a smaller model (gemma4:31b-it, qwen3.5:27b, qwen3-coder:30b all graded A). See ADR 0027, which supersedes the ADR 0012/0013 premise for this recipe. The historical 45%-HIT signal predates the fix and is on probation — re-measure via `delegate-feedback.sh` before trusting at volume.

## When to use

The user has a branch with one or more commits and wants a GitHub PR description ready to paste into `gh pr create --body "..."`. There is no standard shape: the merged-PR examples you pass in are the shape authority, and they range from a two-sentence body to a full `## Description` / `## Type of change` / `## Verification` template. Pass real examples from the target repo; the recipe has no sensible default without them.

## Context to gather first

```bash
# TWO examples, with the generated-by footer stripped out of each. Both halves
# matter: see the 2026-08-27 calibration note.
gh pr list --repo <owner>/<repo> --state merged --limit 2 \
  --json title,body,number \
  --jq '.[] | "<<<EXAMPLE_BEGIN PR #\(.number)>>>\nTITLE: \(.title)\nBODY:\n\(.body | split("\n") | map(select(test("^[[:space:]]*🤖 Generated with|^https://claude\\.ai/code/") | not)) | join("\n"))\n<<<EXAMPLE_END>>>\n"'
git diff <base-branch> --stat                    # what changed
git log <base-branch>..HEAD --pretty=oneline    # commit-by-commit shape
```

Two of them, not one, and with the generated-by footer removed. `no_example_echo` classifies a line as shared convention when it appears in more than one exemplar, so a single exemplar leaves the check with nothing to compare and its boilerplate reads as that exemplar's own content; and a footer that only some merged PRs carry defeats the rule even at two, which is why it is stripped rather than left to repetition. The filter is anchored to the start of the line, so it removes the footer itself and never a paragraph that merely mentions it. The recent merged-PR body is the load-bearing context. The model learns the project's bullet-vs-prose shape, the standard subsection headings, and the test-plan-checkbox convention from the literal, not from descriptors.

**Superseded 2026-06-28: the blocker is cold-LOAD latency, not generation (see the 2026-06-28 calibration note).** The earlier 2026-05-10/11/13 measurements timed wall-clock from a cold (or memory-evicted) state on the 35B/80B prose and long-context tiers and attributed the disk-load latency to generation — concluding, wrongly, that the failure axis was model parameter count at recipe-sized prompts. The 2026-06-28 probe showed the MLX 35B generates a grade-A PR body in ~6 s once warm; the only slow part is the ~77 s cold-load. The active mitigation is therefore NOT hand-writing: on a host where the prose tier resolves to a 35B-class MLX model, set `DELEGATE_PREFLIGHT_TIMEOUT=90` on the first (cold) call so the pre-flight canary tolerates the load window — warm calls return in seconds and need nothing. Keep the model resident (Ollama `keep_alive`, or `mlx_lm.server` holding the last model) to avoid paying cold-load repeatedly. The recipe also passes where the prose tier resolves to a smaller model.

The `<<<EXAMPLE_BEGIN ... EXAMPLE_END>>>` envelope around each example is intentional — without explicit delimiters the model bleeds content from one example into the next or treats the whole block as one example with confused shape.

**Pick an example from unrelated work.** The delimiters stop one example bleeding into the next; they do not stop an example bleeding into the answer. Both 2026-08-26 echo events came from passing the immediately preceding PR on the *same* repo and the *same* topic — a self-improvement PR used as the anchor for the next self-improvement PR — and what came back was that PR's paragraphs, describing that PR's work. This is the same rule SKILL.md already states for one-shot examples generally: "the example must use a different finding/item from the actual input so it doesn't leak the answer." A merged PR from a different area of the repo teaches the shape just as well and has nothing plausible to copy.

## Prompt template

```
Draft a GitHub PR description matching the SHAPE of the recent merged-PR examples below.

EVIDENCE — outranks SHAPE, non-negotiable:
Copy the examples' STRUCTURE, never their FACTS. Headings, section order, bullet style and checkbox lists are structure: reproduce them exactly as the examples use them. The VALUES inside them are evidence and are yours to source, never to copy. An example that pastes a command and its output, quotes a pass count or a timing, or ticks a verification box is showing you its LAYOUT, not facts about this PR. You ran nothing. Every factual claim you write MUST come from the Context below.
1. NEVER write a command's output, a pass/fail count, or a timing. If the Context does not state it, it did not happen.
2. NEVER tick a box that asserts a verification ('- [x] Tests pass', '- [x] Verified'). Leave those as '- [ ]'.
3. A box that CLASSIFIES the change ('- [x] Bug fix', '- [x] Documentation') states intent, not a result — tick it when the diff supports it.
4. If the Context names no verification: where the examples carry a verification section, keep that heading and say plainly the checks have not been run; where they carry none (or there are no examples), add nothing. Never introduce a heading to hold a verification the examples did not ask for, and never fill one.
Wrong (the example pasted a pytest log; the Context said nothing about running tests): ## Verification\n```\n$ pytest -q\n24 passed in 1.12s\n```
Correct (same example, same silent Context): ## Verification\n- [ ] Run `pytest tests/unittest/test_token_handler.py` (not run yet)

SHAPE — the examples govern structure, non-negotiable (EVIDENCE above outranks this):
The recent merged-PR examples are the shape authority. Match their length, their section structure, and their register. If those examples are short — a sentence or two of plain prose with no headings — then produce a sentence or two of plain prose with no headings. Do NOT add '## Summary', '## Test plan', or any heading that the examples themselves do not use. Only when the examples DO carry sections should you use them, and then in this order: '## Summary' (3-bullet list of what the PR does), then ANY narrative sections you want (use ### subheaders, flowing prose paragraphs), then '## Test plan' as a checkbox list at the end.
Wrong (examples were two sentences of prose): ## Summary\n- Adds X\n- Refactors Y\n\n### Rationale\n...\n\n## Test plan\n- [ ] Run the suite
Correct (examples were two sentences of prose): Adds X so that Y no longer needs Z. The behaviour is unchanged for existing callers.

TEST-PLAN SOURCING — applies only when the examples use a test plan:
Every test-plan item MUST correspond to something stated in the Context. If the Context names no verifiable checks, omit the section rather than inventing items to fill it.
Wrong: - [x] Verified incremental sync still works (nothing in the Context says this was run)
Correct: - [ ] Run `bash tests/run-tests.sh` (the Context states the suite covers this)

Do NOT invent example output for any tool — only describe what's in the diff.
Do NOT prefix the title with 'PR #NN —' or any PR number reference.
Output ONLY the markdown body, nothing else.
Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.

=== Recent merged-PR examples (shape anchors) ===
{{recent_prs}}

=== This PR's stats ===
{{diff_stat}}

=== Context ===
{{context}}
```

## Variables

- `{{recent_prs}}` — output of the `gh pr list ... --jq '...'` command in "Context to gather first", with the `<<<EXAMPLE_BEGIN ... EXAMPLE_END>>>` envelopes intact.
- `{{diff_stat}}` — output of `git diff <base-branch> --stat`.
- `{{context}}` — 3–5 sentences naming branch, what was added/changed at the script-or-feature level, motivation, edge cases the reader should know about, any cross-PR relationships ("ships alongside #NN"). Authored by the agent — describe, do not include code.

## Invocation

Run the `gh pr list` and `git diff` commands above as their own step, then pass what they printed as literal `--var` values. Keep the `<<<EXAMPLE_BEGIN ... EXAMPLE_END>>>` envelope the `--jq` filter produced — the delimiters are load-bearing:

```bash
bash scripts/delegate.sh --recipe pr-description \
  --var recent_prs="<<<EXAMPLE_BEGIN PR #340>>>
TITLE: <the merged PR's title>
BODY:
<the merged PR's body>
<<<EXAMPLE_END>>>" \
  --var diff_stat="<the git diff <base-branch> --stat output>" \
  --var context="<3-5 sentences>" \
  "Match the example PR description exactly in shape and tone. NO invented example output."
```

## Anti-hallucination guards (each line addresses a real past MISS)

- "EVIDENCE — outranks SHAPE" — added 2026-08-21 after a reproducible fabrication. Anchored on a real pr-agent merged PR (whose template carries `## Type of change` with a ticked box and a `## Verification` section quoting a pytest run), and given a Context that said nothing about testing, the recipe emitted `- [x] Bug fix` *and* a fabricated log: "$ python3 -m pytest ... 24 passed in 1.12s". Deterministic, 3/3 reps. The old wording could not stop it: SHAPE was declared "non-negotiable" and came first, while the evidence rule scoped itself out with "applies only when the examples use a test plan at all" — this example had a *Verification* section, not a test plan. The fix separates structure from values (headings and checkbox lists are copied, the values inside them are sourced), distinguishes a CLASSIFYING box ("- [x] Bug fix" states intent, legitimate) from an ASSERTING one ("- [x] Tests pass" claims a result, forbidden), and states the precedence in the heading. Verified: the fabricated log is gone in every configuration tested, while the sectioned shape and the classification box survive.
- "SHAPE — the examples govern" — observed 2026-07/08 across three MISS rows: the recipe emitted a multi-section `Summary` / `Rationale` / `Test plan` body into projects whose house style (and whose own recent merged PRs) is a one-or-two-sentence summary. The old wording mandated those sections unconditionally, which silently overrode the "match the SHAPE of the examples" instruction directly above it — the model was obeying the recipe, so the recipe was the bug. Ordering is now conditional on the examples actually using sections.
- "3-bullet list" — caps summary length; without it, summary expands into 8 bullets that duplicate the narrative section. Applies only when the examples use a Summary section.
- "TEST-PLAN-EVIDENCE" — observed 2026-07: prose sections graded A and accurate, but the test plan fabricated *pre-checked* `- [x]` items for runs that never happened (a bare "incremental sync still works" check, and a ">2 MB payload" claim phrased as separately executed). The model anchors on the example PR's test-plan shape and fills it with plausible checks rather than restricting itself to the Context var. This is the recipe's most serious failure mode because a checked box asserts a verification to a human reviewer; the numbered rules bind items to supplied facts and permit omitting the section rather than padding it. **Superseded in part 2026-08-21:** this entry's "ban the checked box outright" is no longer what ships. A blanket ban is wrong for repos whose PR template asks the author to tick a change *category*, where `- [x] Bug fix` states intent rather than a result. The directive is now split across the EVIDENCE block above: asserting boxes are banned, classifying boxes are expected. The rest of this entry still holds.
- "Do NOT invent example output for any tool" — observed: the model fabricated metrics-summary output blocks (`hit: 12 miss: 3` — wrong shape, wrong numbers, wrong format) when asked for "implementation details". Bullets and prose are fine to invent in narrative; concrete tool output is not.
- "Do NOT prefix the title with 'PR #NN —'" — observed: the model copies the `<<<EXAMPLE_BEGIN PR #N>>>` delimiter into the actual title.
- "Output ONLY the markdown body" — without this the model adds "Here's the PR description:" preamble.

## Expected output shape

```
## Summary

- <one-line bullet, what the PR does>
- <one-line bullet, what the PR does>
- <one-line bullet, what the PR does>

### <optional narrative subsection — motivation, design choices, tradeoffs>

<flowing prose paragraphs>

### <optional second subsection>

<more prose>

## Test plan

- [ ] <concrete verifiable check>
- [ ] <concrete verifiable check>
```

The block above is the shape to expect **only when the anchor examples themselves carry those sections**. Where the recent merged PRs are short prose, the correct output is short prose with no headings at all:

```
Adds X so that Y no longer needs Z. The behaviour is unchanged for existing callers, and the suite covers the new path.
```

Verify before recording verdict: the output's shape matches the anchor examples' shape (headings only if the examples used headings — a multi-section body against terse examples is a MISS, not a bonus), no `PR #NN` prefix in any heading, no fabricated tool output (any code block claiming to show CLI / metrics output should be cross-checked against the actual format), and — where a test plan is present at all — every item traces to something stated in the Context and no box is pre-checked. A single `- [x]` is an automatic MISS: it asserts a verification that did not happen.

## Calibration notes

### 2026-08-26 — `recent_prs` declared as an echo-guarded exemplar (issue #428)

No new failure here; this recipe inherits a fix made for `commit-message`,
where a shape anchor was verifiably copied out as content (a subject lifted
from a thirteen-day-old commit, carrying the version the change was bumping
away from). `recent_prs` sits in exactly that role, and the AI-815 leak this
recipe already carries guards for was the same shape, so the frontmatter now
declares `echo_guard_vars: recent_prs` and the `no_example_echo` check treats
lines unique to a single supplied PR example as forbidden output. Lines
repeated across several examples are exempt, which is what keeps a shared
trailer or a section heading the description is meant to reproduce from
flagging. Unmeasured: landed with no post-change data, prior keep rate 42% over
n=7.


> **Chronological log — read top to bottom; not all of it is current.** Any entry dated before 2026-06-28 that recommends hand-writing as the active mitigation, or frames the failure as a parameter-count *generation* stall, is SUPERSEDED by the 2026-06-28 entry — the last dated entry below: the gate was retired and the blocker reclassified as a one-time cold-load. The live operating guidance is the status banner at the top of this file plus that final note; the dated entries below run in date order and are retained as the record of how the conclusion was reached.

Distilled from session 2026-05-09 across two attempts:

- **MISS** (ts=2026-05-09T20:18:59Z) — prompt asked for the standard shape and motivation but did not forbid invented output; model fabricated a metrics-summary example block with hallucinated `hit: 12 miss: 3` numbers in the wrong format. Structure was right; one section had to be rewritten by hand.
- **HIT verbatim** (ts=2026-05-09T20:23:58Z) — same recent-examples anchor plus explicit "NO invented example output" guard added in response to the previous MISS. Output used with zero edits.

The "no invented tool output" guard is the recipe's most important addition over the bare anchoring pattern. Recent-examples anchoring alone produces well-shaped HALLUCINATIONS for any concrete-output section; the explicit ban moves narrative into prose where the model has license to summarise but blocks fabricated CLI snippets.

### 2026-05-10 — single-example default after timeout

Attempted on the reference host (`qwen3.6:35b-a3b-q8_0`, prose tier) with `gh pr list --limit 2` producing two full merged-PR bodies (~5 KB combined plus the diff-stat and context vars). The delegation hung past 16 minutes and was killed per SKILL.md's "kill if hung >30 s" rule. The recipe now defaults to `--limit 1`, and the "Context to gather first" section documents the `long-context` tier as the escape hatch when one example doesn't anchor the shape strongly enough. The earlier 2026-05-09 HIT used `--limit 2` and worked; the difference is that this PR's combined inputs were ~2× larger (the `context` paragraph alone was ~1.5 KB). The recipe's load-bearing claim is "one well-delimited example anchors shape" — the 2× input budget for a second example is rarely worth it on the 35B host.

### 2026-05-10 — second timeout reveals output cost is the dominating factor

The `--limit 1` fix above was itself dogfooded against this recipe's own PR (`feat/recipe-library-expansion`). Inputs: `recent_prs` 2078 B (single example), `diff_stat` 360 B, `context` 748 B — total ~3.2 KB plus the ~2 KB recipe template, so ~5.2 KB input. **It still timed out past 5 minutes.** This was a comparable-size input to the earlier commit-message HIT (~4.5 KB total) that completed in ~30 s, so input size alone is not the discriminating factor. The differentiating variable is *output size*: commit-message produces ~500 B of structured output, while pr-description targets ~2–3 KB (Summary + narrative subsections + Test plan). On the 35B MoE prose-tier model, generating 2–3 KB of structured markdown appears to push the wall-clock past the practical budget regardless of input size.

Concrete recommendation pending future work: route `pr-description` to the `long-context` tier (Qwen3-Next 80B-A3B on this host is faster per-token despite being larger because it's an A3B MoE) rather than `prose`. The recipe's `## Invocation` section still calls `prose` because that's the tier the existing tests cover and the safer default to ship; a `## Calibration notes` update with an actual `long-context` HIT measurement would graduate that change into the recipe body. Until then, callers seeing a hang should kill the delegation and route to `long-context` manually, or write the PR description by hand (which is what this PR did).

### 2026-05-11 — `long-context` escape hatch ALSO times out

The 2026-05-10 calibration note above speculated that the `long-context` tier (Qwen3-Next 80B-A3B on the reference host) would be faster per-token than the 35B prose tier on this input shape because A3B MoEs amortise faster. PR #84 (Layer 4 issue template) dogfooded that hypothesis directly. Inputs: `recent_prs` ~2.3 KB (single example), `diff_stat` ~250 B, `context` ~1.1 KB — total ~3.6 KB plus the ~2 KB recipe template, so ~5.6 KB input. **The `long-context` delegation hung past 8 minutes and was killed**, same failure shape as the prose-tier timeouts in the 2026-05-10 notes. The A3B-amortisation hypothesis does not hold on this input/output shape on this host.

The discriminating factor is still output size (PR descriptions target 2–3 KB of structured markdown), not input size, and the bottleneck moves with the host rather than the model family. Until a tier is found that completes this shape reliably, the recipe's de facto default is: write the PR description by hand. Possible next experiments — try splitting the recipe into two atomic calls (Summary bullets + Test plan separately, then concatenate; both outputs are < 800 B individually so should clear the apparent wall-clock budget), or try the `code` tier on a smaller deepseek-r1 distill (the v6 reasoning-architecture finding suggests structured-output work scales down better there). Neither was tried in this session — left as the next iteration's empirical question.

Provisional recommendation: when this recipe is needed, attempt the prose tier with a hard 60-second wall-clock budget enforced by the caller; if it does not return, do not retry on `long-context` — fall back to hand-writing immediately.

### 2026-05-11 — issue #87: framing is size, not count

A separate session against repo-butler PR #210 reproduced the stall at `--limit 1` with a single ~1.5 KB PR body (`diff_stat` ~200 B, `context` ~600 B; ~3–4 KB total prompt) — past 30 s wall-clock, killed by the orchestrator, MISS recorded at ts=2026-05-11T08:44:32Z. Issue #87 argued that the recipe's "Context to gather first" section underplayed the failure by framing `--limit 1` as a safe default and the `--limit 2` stall as the bound. The 2026-05-10 and 2026-05-11 notes above show the discriminating axis is bytes of prompt-plus-output, not count of examples — and the `long-context` escape hatch does not rescue this either.

The "Context to gather first" section is updated to make the size framing explicit: check the chosen example PR's body size before delegating, and if the body alone is > 1 KB, expect a stall and write the PR description by hand from the start. The earlier "rare; most repos have a stable PR shape" caveat is dropped — the observed failure on a typical repo-butler PR body shows it isn't rare.

### 2026-05-13 — issue #110: discriminator is model parameter count, not body bytes

> **Superseded 2026-06-28 (see the note below): the discriminator is cold-LOAD, not parameter count.** The measurements in this section are real but were timed from a cold/evicted model state; the 2026-06-28 re-measurement showed warm generation completes in seconds. Retained as historical record.

The 2026-05-11 framing above ("if the body alone is > 1 KB, expect a stall") was empirically refined by issue [#110](https://github.com/IsmaelMartinez/delegate-local/issues/110). Two follow-up reports sharpened the conclusion:

- 2026-05-12: full recipe with a **612-byte** PR body (well under the 1 KB heuristic) hung past 6 minutes on `qwen3.6:35b-a3b-q8_0` (Ollama prose tier). Body-size alone is not the discriminator.
- 2026-05-13 (cooler load, MLX backend tested): full recipe (~3-4 KB total prompt) hung past 10 minutes on `mlx-community/Qwen3.6-35B-A3B-8bit` (MLX prose tier — same weights, different runtime). The same recipe-shaped prompt against `mlx-community/Qwen3-0.6B-4bit` (0.6B params) returned clean output in **1 second**. A 200-byte non-recipe canary against the MLX 35B returned in 5 seconds.

The discriminator is **model parameter count at recipe-sized prompts**, not the backend and not the body-size threshold. Both backends hang the 35B-class prose-tier model on the recipe's combined input + structured output budget; a 0.6B-class model handles the same prompt shape in seconds with quality good enough for the "summarise this PR" task. The 1 KB body framing in the 2026-05-11 note is retracted as not the right axis.

Active mitigation on hosts where the 35B is the prose-tier leader: treat the recipe as known-flaky regardless of body size and hand-write the PR description. The `~6 paragraphs` heuristic from issue #110's closing comment covers the small-PR end of the range where the setup-vs-payoff ratio is unfavourable; the recipe also stalls on larger inputs because of the combined input + structured output budget, so the same conclusion (hand-write) holds at both ends of the size range.

### 2026-05-18 — pre-flight canary ships

The pre-flight canary suggestion deferred in the 2026-05-13 issue #110 thread is now in `scripts/delegate.sh`. On every `--recipe` call, the wrapper sends a 1-token probe (`num_predict:1` on Ollama, `max_tokens:1` on MLX) to the resolved model with `curl --max-time ${DELEGATE_PREFLIGHT_TIMEOUT:-10}` before the full templated request leaves the agent. If the probe does not return within the timeout the wrapper exits 3 with a stderr message naming the model, the backend, and recovery options (raise `DELEGATE_PREFLIGHT_TIMEOUT`, route to a smaller-parameter model, hand-write the output, or opt out with `DELEGATE_NO_PREFLIGHT=1`). A metrics row tagged `exit_status:3` is written so `audit-metrics.sh` can pivot on stalls later.

What the canary catches: the cold-load / unreachable-backend / model-stuck-at-load cases from issue #110's original report — the user no longer sinks 6–10 minutes into a recipe before learning the model isn't going to respond. What the canary does *not* catch: the case where the model returns one token cleanly but then stalls on the full recipe-shaped prompt (the 2026-05-12 report's `delegate.sh prose "Write HELLO."` canary succeeded in 2 minutes while the same model hung indefinitely on the full recipe). Hand-writing remains the active mitigation on hosts where the 35B is the prose-tier leader; the canary is a faster failure mode, not an elimination of the failure.

The other deferred suggestion in issue #110 (scaffold a `small` tier into `pick-model.sh` preferring 0.6B-class models, with recipe metadata to opt in) is still open as future work — it would let hosts with a small MLX-quantised model trade quality for reliability on this recipe shape rather than falling through to hand-writing.

### 2026-05-24 — Phase 16 Track A: flaky-on-models tier-gate ships

The "promote the recipe to a tier-gated form (refuse on prose tier above N params)" follow-up named in the 2026-05-10 calibration note above and queued as a Phase 11 round-3 leftover is now shipped. The recipe's frontmatter declares a `flaky_on_models:` list of case-insensitive substrings (`qwen3.6:35b`, `qwen3-next:80b`, plus underscore/dash variants for cross-naming-convention coverage). `scripts/delegate.sh` parses the list after model resolution and exits 4 with a stderr message naming the recipe, the resolved model, the matched pattern, and three recovery options (hand-write, route to a different tier, override with `DELEGATE_FORCE_FLAKY=1`). The gate runs BEFORE the pre-flight canary because the refusal is structural ("this recipe will not work reliably on this model class") rather than dynamic ("the model isn't responding right now") — no point probing a model the recipe already classifies as unreliable. The metrics JSONL row is tagged `exit_status:4` so `audit-metrics.sh` can pivot on flaky-gate refusals later.

Empirical verification: on the reference host where prose tier resolves to `qwen3.6:35b-a3b-q8_0` and long-context tier to `qwen3-next:80b-a3b-instruct-q8_0`, both tiers are now refused with exit 4 (matched-pattern `qwen3.6:35b` and `qwen3-next:80b` respectively). Code tier (`qwen3-coder-next:latest`) is NOT refused and the request flows through to dispatch, demonstrating the gate is recipe-specific rather than a wholesale prose-tier ban. The `DELEGATE_FORCE_FLAKY=1` override sends the request anyway, useful for capturing fresh evidence that the flaky-class behaviour has changed across model upgrades. 21 new test assertions in `tests/test-delegate.sh` (467 → 477) cover the match/non-match/back-compat/override/case-insensitive paths.

Why this lands now: the recipe's 45% hit rate (5 HIT / 6 MISS over 11 verdicts in the 22-day rolling window) was the standout weak point in the Phase 15 trend report. The mitigation has been documented since 2026-05-10 but the wiring stayed deferred under "not urgent". Phase 16 Track A operationalises the documented mitigation; the recipe still works on tiers where the empirical evidence supports it and now refuses cleanly on tiers where it doesn't.

The new convention (recipe-level `flaky_on_models:` frontmatter, the `delegate.sh` parser + gate + opt-out env var) is documented in `prompts/README.md` "Convention 4 — flaky_on_models gate" so future recipes can adopt it when a model-class flakiness pattern emerges.

### 2026-06-28 — the gate premise is falsified: the blocker is cold-load, not generation (gate RETIRED)

A controlled re-measurement (the `DELEGATE_FORCE_FLAKY=1` "override once and measure" step that both ADR 0012 and ADR 0013 Topic E prescribe) overturned the premise behind the 2026-05-24 gate. Seven models were probed with a faithful 3.2 KB recipe-shaped prompt (`think:false`, `temperature:0`), warming each with a 1-token call before timing the full generation. All seven are shown — including the two worst performers — because the gate covered every host whose prose tier resolves to a 35B substring, on either backend:

| Model | Backend | Cold-load | Warm gen | Shape grade |
|---|---|---|---|---|
| Qwen3.6-35B-A3B-8bit | MLX (prod path) | 77.2 s | 5.7 s | A |
| qwen3-coder:30b-a3b | Ollama | 7.5 s | 4.1 s | A |
| qwen3.5:27b | Ollama | 6.2 s | 17.4 s | A |
| gemma4:31b-it | Ollama | 9.0 s | 15.7 s | A |
| gemma4:latest | Ollama | 3.9 s | 2.4 s | C (drops Test plan) |
| Qwen3.6-35B (q8_0) | Ollama | 18.4 s | 3.4 s | D (drops Summary) |
| Qwen3-Coder-30B | MLX | >120 s (warmup cap hit) | ~51 s incl. load\* | B (padding tail) |

\* The MLX Coder-30B never got a clean warm timing — its 1-token warmup hit the 120 s cap — but the full recipe probe still completed in ~51 s (load-dominated) and produced gradeable (B) output, so this row reflects an impractical cold-load, not a generation failure.

Every model that got a clean warm timing returned in single-digit-to-teens seconds; the spread is in *shape*, not latency. The premise was that 35B-class prose-tier models *generation*-stall on this shape ("hangs 6–10 min regardless of input size"). They do not: the MLX 35B — the production-path model the gate refused — emits a grade-A, correctly-shaped PR body in **5.7 s once warm**. The only slow part is a one-time ~77 s cold-LOAD. The same 35B weights on the Ollama backend dropped the `## Summary` on this single sample (grade D), and gemma4:latest dropped the `## Test plan` (grade C) — a shape-quality spread the gate and canary never measured. Because the gate is now removed for all `qwen3.6:35b` substrings (both backends), that shape variance is what the re-measurement probation (end of this note) exists to catch; it is a taste signal, not the structural generation failure the gate assumed. The earlier 2026-05-10/11/13 timeouts measured wall-clock from a cold or memory-evicted state (a 35B prose model and an 80B long-context model thrashing each other out of VRAM) and mis-attributed disk-load latency to generation.

Decisive corroboration: `commit-message` shares the **identical** 35B/prose/MLX dispatch path with no `flaky_on_models` block and has logged 294 exit-0 successes (alongside 15 transient exit-3 canary cold-load stalls). If the 35B truly could not generate recipe-shaped prompts, those 294 successes could not exist. So pr-description's failure belongs in the canary's dynamic domain (exit 3, "didn't respond in time → raise the timeout"), not the gate's structural domain (exit 4, "this model class can't do this recipe"). Under ADR 0012's own evidence convention the entry was a misclassification.

Faithfulness was checked on a genuinely novel diff (shape anchor = an unrelated dependabot PR, described subject = a dashboard-panel fix): the warm 35B produced a shape-perfect body that accurately named the real files and the real bug, with **zero** bleed from the anchor — recorded as a HIT (ts 2026-06-28T20:46:14Z). This addresses the prior single-sample caveat.

Resolution: the `flaky_on_models` block is removed (this recipe only — the gate mechanism and the `release-note` / `long-thread-distillation` entries are untouched and remain valid). The cold-load is absorbed with `DELEGATE_PREFLIGHT_TIMEOUT=90` on a cold MLX 35B host (warm calls need nothing) and/or by keeping the model resident. The reclassification is recorded in ADR 0027, which supersedes the premise of ADR 0012's pr-description entry and ADR 0013 Topic E without retracting the gate mechanism. Warm output *quality* (the historical 45% HIT) is still on probation: re-measure across ~10 real PRs via `delegate-feedback.sh`, and revisit removal if it does not clear the library floor.

**Caveat (shell-var expansion):** the `--var context="<sentences>"` argument is double-quoted in the invocation example, so any literal `$VARNAME` token in the context paragraph (e.g. a sentence mentioning `$CI_COMMIT_REF_NAME`, `$PR_AGENT_GITLAB_TOKEN`, or `$AWS_*` by name) will be silently substituted by the surrounding shell before `delegate.sh` sees it — unset variables expand to empty and the token vanishes from the prompt, while set variables expand to their literal value and leak the secret into both the model prompt and the metrics JSONL row. Switch the affected `--var` arg to single quotes, escape the dollar as `\$VARNAME` inside the double quotes, or pass the value via a `<<'EOF'` heredoc. See SKILL.md's Pattern-section pitfall callout.

### 2026-08-03 — the quality probation closed: SHAPE and TEST-PLAN-EVIDENCE added

The "on probation, re-measure across ~10 real PRs" condition set by the 2026-06-28 entry above has now been met, and the recipe failed it. Over the rolling 30-day window the recipe was kept 0 times out of 10. Split by backend across all history it keeps 45% on Ollama against 7% on MLX (n=11 and n=14) — and MLX is now the default backend, so 7% is the live number. `commit-message` over the same split is 70% Ollama / 71% MLX, so this is recipe-specific rather than a backend regression.

Two causes, both addressed here rather than by retiring the recipe. First, three MISS rows were house-style violations — a multi-section `Summary` / `Rationale` / `Test plan` body where the project wanted one or two sentences. That was the recipe's own fault: `Required sections in this order` mandated the sections unconditionally and overrode the `match the SHAPE of the examples` line above it. Shape is now delegated to the anchor examples, which is what the recipe claimed to do all along. Second, and more serious, one row recorded fabricated *pre-checked* `- [x]` test-plan items asserting runs that never happened; TEST-PLAN-EVIDENCE binds items to the Context var, bans the checked box, and allows omitting the section rather than padding it.

Separately, three of the ten rewrites in the window were not quality failures at all but exit-4 refusals from the `flaky_on_models` gate. The gate's status banner claimed retirement on 2026-06-28, but the frontmatter block survived until `6a5c913` on 2026-07-20; refusals continued to 2026-07-26 and have stopped since. No action needed there — recorded so the 0/10 is not read as entirely quality-driven.

Both new directives are pinned in `tests/test-prompts-library.sh`. Re-measure across ~10 real PRs before trusting; if the keep rate does not clear the library floor on MLX, retiring the recipe is the reasonable next step, since the shape it produces is cheap to hand-write.

Provenance also lives in the `feedback_delegate_prose_prompt_anchoring.md` memory file.

### 2026-08-21 — fabricated verification evidence, and what is still open

Found while investigating three `pr-description` verdicts in the post-reset corpus, none of which were clean. The recorded complaint was "recipe emits multi-section PR body with a test-plan checklist; house style is 1-2 sentences plus Refs". Investigation showed that complaint was the recipe working as designed: the caller's own merged-PR examples (pr-agent upstream) genuinely use a sectioned template, and with short examples the SHAPE guard produces two sentences of prose correctly, verified directly.

The real defect was underneath it. Anchored on a real pr-agent merged PR and given a Context silent about testing, the recipe fabricated verification: a ticked `- [x]` box and a pasted `24 passed in 1.12s` pytest log for a run that never happened. Deterministic across reps. Fixed by the EVIDENCE block; see the guard entry above.

Two things are deliberately NOT fixed, with evidence, rather than left unsaid:

**Reference trailers still invent identifiers.** When the examples end in `Refs: AI-812` / `Refs: AI-806` and the Context names no ticket, the model emits `Refs: AI-813`, continuing the numbering. This is the same failure `commit-message` had with `(#NN)`. Four prompt-side attempts were made and reverted: a numbered rule, a promoted block, and two contrastive one-shots. One of them made things worse in an instructive way — the Wrong example contained a literal `AI-815`, and the model then emitted exactly `AI-815`, copying the value out of the prohibition. The baseline is no better (it emits `Refs: <branch-name>`), but its output is obviously wrong to a reviewer while the invented ticket looks real, so shipping the stronger-looking guard would have traded a visible failure for a deceptive one. This needs a deterministic post-generation check, not more prompt text: a trailer whose identifier does not appear in the inputs should be stripped or fail the call, in the manner of the ADR 0014 checks.

**With an empty `recent_prs` the output shape is undefined.** The pre-fix template guessed short prose, this one guesses a sectioned body. Neither is grounded, because with no examples there is no shape to match. The recipe requires examples; passing none is caller misuse.

### 2026-08-26 — the invented test plan became a check, on its third attempt

Asked for the body of PR #433 and given a Context that listed the suites and
their passing counts in prose, the recipe appended a `## Test plan` section of
two unchecked items reading "(not run yet)" — contradicting, four lines later,
a paragraph it had just written naming those same passing counts. The draft is
kept at `20260826T200251Z-0a3abb42.draft.txt`. The same call also reproduced the
closing line of the `recent_prs` exemplar verbatim, which `no_example_echo`
caught; the fabricated task list is the half no guard covered.

This is the third pass at the same failure. TEST-PLAN-EVIDENCE (2026-08-03) tied
items to the Context var and banned the checked box; the EVIDENCE block
(2026-08-21) split that into asserting boxes banned and classifying boxes
expected, after a blanket ban proved wrong for repos whose template asks the
author to tick a change category. Both are prompt text, and
`docs/self-improvement-loop.md` is explicit that a defect surviving two
rewordings gets a check next.

`no_invented_task_list: recent_prs` is that check. It deliberately does not ban
task lists — the 2026-08-21 finding that a `- [x] Bug fix` category box is
correct output still holds. It names the `--var` carrying the shape authority
and fires only when the output has a task list and those examples have none,
which is the case where the model produced a shape it was not shown. A repo
whose merged PRs carry a checklist keeps getting one. Warn-only, like every
declared check except `no_padding_tail`.

Still open and untouched by this: the reference-trailer fabrication recorded in
the 2026-08-21 entry above, which wants the same treatment and a different
check.

### 2026-08-26 — the reference-trailer check the 2026-08-21 entry asked for

The entry above ends by saying the trailer fabrication "needs a deterministic
post-generation check, not more prompt text: a trailer whose identifier does not
appear in the inputs should be stripped or fail the call, in the manner of the
ADR 0014 checks." `no_invented_refs: true` is that check.

The design detail that matters is what counts as grounding. Only the caller's
inputs do — every `--var` value plus the piped context. The recipe template is
deliberately excluded, because the failure the entry documents is a model
copying `AI-815` straight out of a `Wrong:` example that contained it, and
grounding against the template would have licensed exactly that copy. There is
an assertion pinning this: an identifier that appears in the recipe's own text
and nowhere in the caller's inputs still fails.

Only trailer-shaped lines (`Key: value`) are scanned, and two token shapes are
recognised, `#123` and a ticket like `AI-813` with two or more trailing digits.
That keeps `UTF-8` and similar hyphenated prose tokens out of it. Known gap: a
trailer line carrying something like `SHA-256` matches the ticket shape and
would flag if the inputs never mention it. Warn-only, so that costs a line on
stderr.

**The live defect did not reproduce, and that is worth recording rather than
hiding.** Four reps against `mlx-community/Qwen3.6-35B-A3B-8bit` with the exact
2026-08-21 setup — two anchor examples ending in `Refs: AI-812` and
`Refs: AI-806`, a Context naming no ticket, and a trailing instruction asking
explicitly for the trailer — produced no trailer at all, every time. With no
ticket in the Context the only honest options are omit or invent, and the model
omitted, so the EVIDENCE and SHAPE guards appear to have held for this case.
The check is therefore verified by replaying the documented shape and by the
copy-out-of-the-prohibition case, not by a fresh reproduction. Treat it as
regression insurance on a defect that was deterministic three weeks ago and is
not today, on this model.


### 2026-08-26 (later) — exemplar content bleed, and the size hypothesis measured and dropped

`no_example_echo` fired twice on this recipe in one day, at `20:02:51Z` and
`22:11:08Z`. The first returned the closing line of the PR #432 exemplar; the
second returned three paragraphs of PR #433's body, including the
dangling-reference sweep and "no prompt template changed", both of which
belonged entirely to that PR. Neither draft shipped — the check caught both —
so the cost is a wasted call rather than a bad artifact.

The obvious mechanical fix was a cap on exemplar size, and the data does not
support it. Across the nine `pr-description` calls in the live corpus the two
that echoed carried 7,138 and 7,400 `prompt_chars`, while calls at 7,929 and
10,126 did not. There is no threshold to draw. That is the second time an
input-size hypothesis has been measured and dropped on this corpus, after the
same exercise on `maintainer-reply` earlier the same day.

What both echo events did share is topical adjacency: the anchor was the
previous PR in the same series, describing work of the same kind, so its
sentences were plausible answers to the new question. That is a hypothesis, not
a measurement, which is why the fix here is caller-facing guidance in "Context
to gather first" rather than a check. If it recurs with a deliberately
unrelated anchor, the hypothesis is wrong and the next attempt should be
mechanical.

### 2026-08-27 — `#441` is unmeasured, and something else was in the way

`#441` (pick an exemplar from unrelated work) merged at 2026-08-26T23:06:30Z.
Both `no_example_echo` events that motivated it predate it, at `20:02:51Z` and
`22:11:08Z`, so it had taken no calls at all when this was written and its own
rate cannot be quoted.

The one call since, at 2026-08-27T06:44:53Z, followed the new guidance — the
exemplar was PR #422, a parsing fix with nothing in common with the branch
being described — and the content leak the guidance targets did NOT recur. The
draft copied no paragraph of #422 and invented nothing from it. What it did
reproduce was `🤖 Generated with [Claude Code](https://claude.com/claude-code)`,
the trailer every PR in this repo carries and which the output is supposed to
carry, and `no_example_echo` failed the draft for it twice (once on the
generation, once on the retry that `#384` had just added).

That is a different defect, in the check rather than the recipe: its
convention/content split drops any line appearing in more than one exemplar,
and with a single exemplar every line appears exactly once, so boilerplate is
classified as that exemplar's own content. `#441` may well be working; this
call cannot tell us, because the check rejected the draft for something `#441`
was never about. Re-measure after the single-exemplar defect is fixed and
roughly ten more calls have landed.

### 2026-08-27 — two exemplars, and the footer stripped out of them

`no_example_echo` failed the 06:44:53Z draft, and its retry, for reproducing
`🤖 Generated with [Claude Code](https://claude.com/claude-code)` — 62
characters of footer that the answer is supposed to carry. The exemplar was PR
#422, chosen unrelated exactly as `#441` asks, and nothing of #422's content
came back. The check was right that a prompt line was reproduced and wrong that
it mattered.

The mechanism is the convention/content split. A line appearing in more than
one exemplar is dropped from the pattern set, on the reasoning that repetition
means boilerplate the output is meant to reproduce. With ONE exemplar every
line appears exactly once, so the rule cannot fire and the footer is classified
as content. Two exemplars restore it — except that the footer is not in every
merged PR of this repo (measured 2026-08-27: 1 of the last 8), so repetition
alone does not reach it. Hence both halves: `--limit 2`, and a jq filter that
drops the footer lines outright.

A per-line length floor was measured and rejected as the fix. The two true
positives matched 157 B and 697 B against this false positive's 62 B, which
looks separable until `commit-message`'s exemplar case is included: the echo
that motivated `echo_guard_vars` (#428) was a ~53-character commit subject that
MUST still flag. No single floor sits above 62 and below 53.

`--limit 1` was itself a 2026-05-10 decision, taken because `--limit 2` was
believed to stall the 35B prose host. ADR 0027 falsified that premise in June —
the stall was cold LOAD, not generation — and the recipe's own header records
the gate being retired for the same reason. Measured again 2026-08-27 on the
current host: two exemplars at 3.3 KB with a ~1 KB context returned a complete,
accurate PR body in 12.0 s warm. The reason for `--limit 1` no longer exists.

### 2026-08-27 — `no_invented_headings`, and how to write the context

Two findings from writing this repo's own PR bodies, one about the recipe and
one about the caller.

The recipe first. The SHAPE section has said "Do NOT add '## Summary',
'## Test plan', or any heading that the examples themselves do not use" for
several revisions, and it does not hold. Measured with `DELEGATE_NO_RETRY=1` so
the first pass is visible, against `#422` and `#424` (both verified heading-free
by the same scan the check uses): 4 runs of 4 invented at least one markdown
heading. The frontmatter now declares `no_invented_headings: recent_prs`, the
same contract as its sibling — the value names the `--var` holding the shape
authority, and the check fires only when the output has a heading and the
examples have none, so a repo whose merged PRs all carry `## Summary` still gets
that shape back. In the run inspected in full the invented heading was
`## Test plan`, whose items `no_invented_task_list` already catches, so on that
input the two overlap; the heading check earns its place on the section heading
that arrives without checkboxes under it.

A correction worth keeping, because it nearly became the calibration entry. The
first version of this measurement claimed the model invented `### Implementation
Details` and `### Testing` against heading-free exemplars. It did not: `#413`
was one of the two exemplars and carries three `###` headings, so the model was
matching. The check stayed silent, which is how the mistake surfaced. Verify
that an exemplar is heading-free before concluding a heading was invented.

Now the caller. `{{context}}` is not a hint, and it is not a draft. Given facts
written as finished sentences the model reflows and returns them — two calls on
2026-08-27 (12:03 and 14:35) came back as the context file, every line, in
order, with no synthesis. Given the same facts as terse notes it writes a PR
body. Write `context` as notes, one fact per line, the way
`maintainer-review-reply.md` asks for its stdin.
