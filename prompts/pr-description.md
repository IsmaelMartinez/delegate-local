# pr-description

## When to use

The user has a branch with one or more commits and wants a GitHub PR description ready to paste into `gh pr create --body "..."`. Standard project shape: `## Summary` bullet list at the top, optional narrative subsections in flowing prose, `## Test plan` checkbox list at the end.

## Context to gather first

```bash
gh pr list --repo <owner>/<repo> --state merged --limit 1 \
  --json title,body,number \
  --jq '.[] | "<<<EXAMPLE_BEGIN PR #\(.number)>>>\nTITLE: \(.title)\nBODY:\n\(.body)\n<<<EXAMPLE_END>>>\n"'
git diff <base-branch> --stat                    # what changed
git log <base-branch>..HEAD --pretty=oneline    # commit-by-commit shape
```

The recent merged-PR body is the load-bearing context. The model learns the project's bullet-vs-prose shape, the standard subsection headings, and the test-plan-checkbox convention from the literal, not from descriptors.

**The failure axis is model parameter count at recipe-sized prompts, not body bytes.** The 2026-05-10 timeout was triggered at `--limit 2` (~5 KB of combined PR bodies); the 2026-05-11 follow-up at `--limit 1` against a single ~1.5 KB body still stalled past 30 s on the same 35B prose-tier host; issue #110's 2026-05-13 follow-up further measured the 35B stalling on ~3-4 KB recipe-shaped prompts on both Ollama and MLX while a 0.6B-class model returned in 1 second on the same shape. On hosts where the prose tier resolves to a 35B-class model, treat this recipe as known-flaky regardless of body size and hand-write the PR description; the recipe stays useful on hosts where prose resolves to a smaller model. Routing to the `long-context` tier (Qwen3-Next 80B-A3B on the reference host) does not rescue the 35B case either — the 2026-05-11 calibration note records an 8-minute hang on the same shape via that tier too. The pre-flight canary in `delegate.sh --recipe` (2026-05-18) catches the stall-at-load case loudly with `exit 3` before any input is sunk; it does *not* catch the warm-model-stalls-on-recipe-shape case, so the hand-write fallback remains the active mitigation on this host class — see the 2026-05-18 calibration note.

The `<<<EXAMPLE_BEGIN ... EXAMPLE_END>>>` envelope around each example is intentional — without explicit delimiters the model bleeds content from one example into the next or treats the whole block as one example with confused shape.

## Prompt template

```
Draft a GitHub PR description matching the SHAPE of the recent merged-PR examples below.
Required sections in this order: '## Summary' (3-bullet list of what the PR does), then ANY narrative sections you want (use ### subheaders, flowing prose paragraphs), then '## Test plan' as a checkbox list at the end.
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

```bash
bash scripts/delegate.sh --recipe pr-description \
  --var recent_prs="$(gh pr list --repo OWNER/REPO --state merged --limit 1 \
    --json title,body,number \
    --jq '.[] | "<<<EXAMPLE_BEGIN PR #\(.number)>>>\nTITLE: \(.title)\nBODY:\n\(.body)\n<<<EXAMPLE_END>>>\n"')" \
  --var diff_stat="$(git diff main --stat)" \
  --var context="<3-5 sentences>" \
  prose "Match the example PR description exactly in shape and tone. NO invented example output."
```

## Anti-hallucination guards (each line addresses a real past MISS)

- "Required sections in this order" — without explicit ordering the model puts the test plan first or skips the summary.
- "3-bullet list" — caps summary length; without it, summary expands into 8 bullets that duplicate the narrative section.
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

Verify before recording verdict: no `PR #NN` prefix in any heading, no fabricated tool output (any code block claiming to show CLI / metrics output should be cross-checked against the actual format), test-plan items are concrete and verifiable rather than aspirational.

## Calibration notes

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

The 2026-05-11 framing above ("if the body alone is > 1 KB, expect a stall") was empirically refined by issue [#110](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/110). Two follow-up reports sharpened the conclusion:

- 2026-05-12: full recipe with a **612-byte** PR body (well under the 1 KB heuristic) hung past 6 minutes on `qwen3.6:35b-a3b-q8_0` (Ollama prose tier). Body-size alone is not the discriminator.
- 2026-05-13 (cooler load, MLX backend tested): full recipe (~3-4 KB total prompt) hung past 10 minutes on `mlx-community/Qwen3.6-35B-A3B-8bit` (MLX prose tier — same weights, different runtime). The same recipe-shaped prompt against `mlx-community/Qwen3-0.6B-4bit` (0.6B params) returned clean output in **1 second**. A 200-byte non-recipe canary against the MLX 35B returned in 5 seconds.

The discriminator is **model parameter count at recipe-sized prompts**, not the backend and not the body-size threshold. Both backends hang the 35B-class prose-tier model on the recipe's combined input + structured output budget; a 0.6B-class model handles the same prompt shape in seconds with quality good enough for the "summarise this PR" task. The 1 KB body framing in the 2026-05-11 note is retracted as not the right axis.

Active mitigation on hosts where the 35B is the prose-tier leader: treat the recipe as known-flaky regardless of body size and hand-write the PR description. The `~6 paragraphs` heuristic from issue #110's closing comment covers the small-PR end of the range where the setup-vs-payoff ratio is unfavourable; the recipe also stalls on larger inputs because of the combined input + structured output budget, so the same conclusion (hand-write) holds at both ends of the size range.

### 2026-05-18 — pre-flight canary ships

The pre-flight canary suggestion deferred in the 2026-05-13 issue #110 thread is now in `scripts/delegate.sh`. On every `--recipe` call, the wrapper sends a 1-token probe (`num_predict:1` on Ollama, `max_tokens:1` on MLX) to the resolved model with `curl --max-time ${DELEGATE_PREFLIGHT_TIMEOUT:-10}` before the full templated request leaves the agent. If the probe does not return within the timeout the wrapper exits 3 with a stderr message naming the model, the backend, and recovery options (raise `DELEGATE_PREFLIGHT_TIMEOUT`, route to a smaller-parameter model, hand-write the output, or opt out with `DELEGATE_NO_PREFLIGHT=1`). A metrics row tagged `exit_status:3` is written so `audit-metrics.sh` can pivot on stalls later.

What the canary catches: the cold-load / unreachable-backend / model-stuck-at-load cases from issue #110's original report — the user no longer sinks 6–10 minutes into a recipe before learning the model isn't going to respond. What the canary does *not* catch: the case where the model returns one token cleanly but then stalls on the full recipe-shaped prompt (the 2026-05-12 report's `delegate.sh prose "Write HELLO."` canary succeeded in 2 minutes while the same model hung indefinitely on the full recipe). Hand-writing remains the active mitigation on hosts where the 35B is the prose-tier leader; the canary is a faster failure mode, not an elimination of the failure.

The other deferred suggestion in issue #110 (scaffold a `small` tier into `pick-model.sh` preferring 0.6B-class models, with recipe metadata to opt in) is still open as future work — it would let hosts with a small MLX-quantised model trade quality for reliability on this recipe shape rather than falling through to hand-writing.

**Caveat (shell-var expansion):** the `--var context="<sentences>"` argument is double-quoted in the invocation example, so any literal `$VARNAME` token in the context paragraph (e.g. a sentence mentioning `$CI_COMMIT_REF_NAME`, `$PR_AGENT_GITLAB_TOKEN`, or `$AWS_*` by name) will be silently substituted by the surrounding shell before `delegate.sh` sees it — unset variables expand to empty and the token vanishes from the prompt, while set variables expand to their literal value and leak the secret into both the model prompt and the metrics JSONL row. Switch the affected `--var` arg to single quotes, escape the dollar as `\$VARNAME` inside the double quotes, or pass the value via a `<<'EOF'` heredoc. See SKILL.md's Pattern-section pitfall callout.

Provenance also lives in the `feedback_delegate_prose_prompt_anchoring.md` memory file.
