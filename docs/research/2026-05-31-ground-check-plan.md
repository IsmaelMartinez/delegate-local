# `ground-check` recipe — implementation plan

_Generated 2026-05-31 via an 8-agent ultrathink workflow (5 design perspectives → adversarial + conventions critique → synthesis). Forward-looking design; not yet built. See ROADMAP.md Phase 19._

## 1. Goal & rationale

Ship `ground-check`, a delegate-local recipe that turns a LOCAL model into a closed-form grounding/verification "second brain" for the MAIN Claude agent. Given a numbered list of CLAIMS the agent is about to assert plus an EVIDENCE block, it returns one verdict per claim — `SUPPORTED — "<verbatim quote>"`, `CONTRADICTED — "<verbatim quote>"`, or `NOT-STATED` — so the agent can catch itself overreaching before it ships an unsupported assertion. The architectural lever is that the model is forced to QUOTE verbatim rather than JUDGE, and a deterministic post-check then verifies every quote is an exact substring of the evidence, downgrading any fabricated-quote verdict to `UNVERIFIED`. This makes a probabilistic model robust on exactly the answer-in-input class it does well, while staying strictly advisory and never a merge/ship gate. The recipe is unusual in the library: it operates on the agent's own draft claims, not on user content, so the `## When to use` section must say so explicitly to avoid being mistaken for a summarisation recipe.

This plan merges the four sub-designs and applies every blocker and major critique fix. The recipe ships at SCAFFOLD stage: the markdown, scorer, fixtures, and tests are authored, but graduation to "shipped" requires the Phase 7 deterministic-scorer run across 3+ reps with non-overlapping stdev. Until that run passes, the Calibration notes must label the recipe scaffold-stage and must not assert parity with a scorer that has not been committed and exercised.

## 2. Validated evidence

On 2026-05-31 a probe ran the FAST MLX prose model (`mlx-community/Qwen3.6-35B-A3B-8bit`, thinking OFF, temperature 0) on a 5-claim grounding check and scored 5/5 in 13s. It correctly marked an OVERREACH claim ("the PR fixes the inflated numbers" — stated nowhere in the evidence) as `NOT-STATED` instead of rubber-stamping, and caught two `CONTRADICTED` claims with exact quotes. The working prompt was: «You are a grounding checker. ONLY use the EVIDENCE below — do not use outside knowledge. For each CLAIM, output one line: "<id>: SUPPORTED — \"<exact quote from evidence>\"" if the evidence states it, "<id>: CONTRADICTED — \"<exact quote>\"" if the evidence states the opposite, or "<id>: NOT-STATED" if the evidence neither states nor contradicts it. Do not explain.»

The quote-finder lever: local models FABRICATE/OVERREACH when asked to JUDGE ("is this true?") because that imports their priors, but are reliable as QUOTE-FINDERS because they cannot quote what is not in the evidence. The deterministic substring post-check verifies each quote is an exact substring of the evidence and downgrades any `SUPPORTED`/`CONTRADICTED` whose quote is fabricated to `UNVERIFIED`. This is n=1; the Phase 7 fixture run is the actual ship gate.

Honest framing of what the post-check guarantees (adversarial-critique blocker fix): the substring check guarantees zero FABRICATED-QUOTE `SUPPORTED`, which is strictly weaker than "zero false-SUPPORTED." A model can still quote a true-but-irrelevant span (right bytes, wrong claim) and pass the substring test. That residual gap is closed not by the substring check but by ground-truth `VERDICT_MATCH` in the scorer plus a dedicated "right-quote-wrong-claim" fixture. The recipe and SKILL.md must state that `SUPPORTED` is a quote-existence certificate, not a truth certificate.

## 3. Design

### 3.1 Resolved cross-design decisions (both critiques' blockers)

These were the load-bearing contradictions; each is resolved once, here, and all files must agree.

TIER = `reasoning`. The conventions critique recommended prose, but the adversarial critique is correct and overriding: SKILL.md line 141 is explicit and directly on point — "The `prose` tier is for *generating* prose, not for *inferring* about prose. For analytical work over a diff or log, use `reasoning` even if the input is text-heavy." ground-check is inference-about-prose (locate a span in evidence supporting/contradicting a claim), which is exactly the lane `summarise-issue.md` occupies. The prose-tier argument rested on a single n=1 MLX probe where the "fast prose model" happened to resolve well; that does not transfer across hosts. We honor the documented routing rule and treat the prose-vs-reasoning question as a measured A/B at the Phase 7 step (run both tiers across 3+ reps; keep prose only if reasoning's chain-of-thought measurably imports judge-drift on the fixture). Default and shipped tier in the recipe Calibration notes: `reasoning`, with the A/B promoted from open-question to ship-step.

flaky_on_models = NONE at ship. Convention 4 rule 1 requires every listed substring be anchored in MEASURED evidence specific to this recipe; the only datum is a 5/5 HIT, so there is nothing to anchor. The integration design's `qwen3-next:80b`/`qwen3.5:122b` entries are justified by other recipes' history, which is precisely the speculative restriction the convention rejects. The deterministic post-check already degrades a weak model to "more UNVERIFIED/NOT-STATED lines" rather than a silent rubber-stamp, so the gate buys little. If the Phase 7 A/B measures a specific class stalling on THIS recipe shape, add that substring then with the ground-check measurement cited.

SCORER NAME = `experiments/score-t9.sh`, fixture family `experiments/fixtures/task-9-ground-check-<date>.txt`, runner envelope header `===== T9-ground-check rep N =====`. This is the repo's T-numbered convention (`score-t4.sh`, `task-4-commit-message-<date>.txt`, `===== T4-commit-message rep N =====`), and task-9 is the next free number (existing fixtures stop at task-8). This reconciles the recipe-prompt design's `score-t9.sh` reference with the scorer/integration designs' divergent names. All three files — recipe Calibration notes, the scorer, and any wrapper — must name `score-t9.sh` identically.

INPUT SHAPE = single `{{stdin}}` slot, EVIDENCE + CLAIMS concatenated into one delimited document (integration design's shape, conventions-critique minor fix). Frontmatter declares `inputs: { stdin: string }` only — NOT `claims: string`. Rationale: the model sees exactly one delimited document, strengthening the closed-form "cannot quote what is not present" property; and the scorer's fixture format already parses EVIDENCE/CLAIMS/EXPECTED sections, so the runtime input and the fixture align naturally. The agent assembles the envelope (see 3.2).

SCRIPT COUNT = one recipe + one scorer + one test for the scorer + (optionally) one thin wrapper. Drop the separate `ground-verify.sh` post-processor and the "shared sourced lib for two callers" (over-engineering, major critique). The runtime quote-verify is genuinely load-bearing, so it lives in ONE place: either a single small `scripts/ground-check.sh` wrapper that runs `delegate.sh` then does the substring check inline, OR (preferred for v1 minimalism) documented as a post-check step the main agent runs, with the scorer encoding the identical `grep -F` rule for parity. We ship the wrapper because the pre-completion habit (3.5) needs a single command, but it is the only runtime script and it has NO separate verifier sibling.

SUBSTRING ALGORITHM = ONE implementation, used by both scorer and wrapper, sourced from a single shared helper file `experiments/lib/ground-substring.sh` (the parity discipline). Use `grep -F` (literal, metacharacter-safe) — NOT bash case-glob (the integration design's glob approach is a correctness bug: `[`, `]`, `*`, `?` are common in diffs/logs and would silently mis-match). Apply SYMMETRIC whitespace-collapse (runs of whitespace → single space, strip leading/trailing) to BOTH the quote and the evidence before the `grep -F` test, so a quote spanning a hard line-wrap in the evidence still verifies (avoids false `UNVERIFIED` alarms). This is the one shared algorithm test-16's "byte-identical" assertion checks against.

EXIT STATUS = decoupled from verdict outcome (both critiques' blocker). There is NO exit 5. The wrapper exits 0 on any successful run (model answered, post-check ran), surfaces verdicts on stdout, and reports `clean=true|false` as a FIELD in a `GROUND_CHECK_SUMMARY` line — never as an exit code. delegate.sh's 2/3/4 propagate unchanged (real operational failures). A non-zero exit on un-grounded claims is exactly the affordance a contributor would wire into a pre-commit/pre-merge hook, which the scope boundary and the user's no-autonomous-merge rule forbid.

CONTRASTIVE ANCHORS = at most ONE domain-neutral overreach anchor in v1 (Convention 3 ordering, major critique). The validated probe used ZERO anchors and scored 5/5; Convention 3 says escalate to contrastive anchors only WHEN directive enumeration is measured saturating, not pre-emptively. There is no ground-check MISS yet, so v1 ships the validated probe wording plus the required structural sections plus exactly one domain-neutral Wrong/Correct pair on the overreach→NOT-STATED behaviour (the one shape the probe specifically validated). Defer the second/third pair to a real measured MISS.

### 3.2 Recipe prompt shape (`prompts/ground-check.md`)

Frontmatter:
```yaml
---
inputs:
  stdin: string
---
```
No `flaky_on_models:` block (3.1). Title `# ground-check` (must match filename for the structural test). Four required sections: `## When to use`, `## Context to gather first`, `## Prompt template`, `## Calibration notes`, plus `## Variables`, `## Invocation`, and `## Expected output shape` (every shipped recipe carries the last; conventions-critique minor fix).

`## When to use`: the agent is about to assert something and wants a cheap on-device check that the EVIDENCE actually states it. Explicitly: this is a verification second-brain over the agent's OWN draft claims, NOT a recipe over user content. State the closed-form quote-finder framing, the UNVERIFIED downgrade lever, and the two exclusions (arithmetic, judgment) up front, and that it is ADVISORY (NOT-STATED is a cue to verify/soften, never a gate).

`## Context to gather first`: the agent assembles two parts into one stdin block — a numbered CLAIMS list (atomic, one declarative proposition per line, arithmetic/judgment filtered out first) and the SMALLEST EVIDENCE block that contains the answer (a diff hunk, a failing-log slice, an issue body, a doc paragraph), kept under the practical recipe-tier ceiling (SKILL.md/#110: 35B-class models stall on recipe-shaped prompts at ~3-4 KB; chunk larger evidence and run per-chunk, or route to the long-context tier — never one oversized block).

`## Prompt template` (the validated probe core, hardened with Convention 1 opener + ONE domain-neutral anchor; delimiters use `=== X ===` NOT `## ` so the structural extractor and delegate.sh both keep the fence intact — and a Calibration note warns future editors not to introduce `## `-prefixed lines inside the fence):
```
You are a grounding checker. ONLY use the EVIDENCE below — do not use outside
knowledge, do not infer, do not judge whether a claim is good or correct, do not
do arithmetic. You are a quote-finder, not a judge.

For each CLAIM, output exactly one line, in claim-id order, in one of these three
forms and no other:
  <id>: SUPPORTED — "<exact verbatim quote from the evidence>"
  <id>: CONTRADICTED — "<exact verbatim quote from the evidence that states the opposite>"
  <id>: NOT-STATED

Rules:
1. <id> is the claim's number, copied verbatim from the CLAIMS list.
2. SUPPORTED means the EVIDENCE explicitly states the claim. Quote the SHORTEST
   exact span that states it.
3. CONTRADICTED means the EVIDENCE explicitly states the opposite. Quote the
   shortest exact span that states the opposite.
4. NOT-STATED means the EVIDENCE neither states the claim nor its opposite. This
   is the correct answer when the claim goes BEYOND what the evidence says — even
   if the claim sounds plausible or you believe it is true. Plausibility is not
   evidence.
5. A quote MUST be copied character-for-character from the EVIDENCE — same words,
   order, and punctuation. Do NOT paraphrase, normalise, or stitch non-adjacent
   fragments. If no single contiguous exact span fits, the answer is NOT-STATED.
6. Read the WHOLE evidence before answering. Do not stop at the first matching
   sentence; a later sentence may qualify or contradict an early match.
7. Do NOT explain, add a reason, a preamble, or a summary line. Output ONLY the
   per-claim lines, one per claim.

Wrong (the claim is plausible but the evidence does not state it):
  3: SUPPORTED — "the change improves the numbers"
Correct (no such span exists in the evidence; the only honest verdict is silence):
  3: NOT-STATED

=== EVIDENCE ===
{{stdin}}
```
Note the EVIDENCE/CLAIMS envelope is assembled by the agent into `{{stdin}}` (the agent prepends `=== EVIDENCE ===`/`=== CLAIMS ===`); the template's single `{{stdin}}` slot receives the whole document. Rule 6 is the read-to-the-end discipline that the long buried-contradiction fixture (3.4 f9) measures.

`## Variables`: `{{stdin}}` — the assembled EVIDENCE+CLAIMS document piped to the wrapper.

`## Expected output shape`: one example each of `SUPPORTED` with a real quote, `CONTRADICTED` with a real quote, `NOT-STATED`, plus the post-check's `UNVERIFIED` downgrade form, so the agent has a HIT reference before recording a verdict.

`## Calibration notes`: provenance (2026-05-31 probe, 5/5, the verbatim working prompt); explicit SCAFFOLD-STAGE label ("not yet graduated; Phase 7 fixture run pending"); the tier decision (reasoning per SKILL.md line 141, prose-vs-reasoning A/B is the ship step); think OFF; no flaky gate and why; the post-check parity statement describing the identical `grep -F` symmetric-whitespace rule the scorer enforces; the editor warning about `## ` inside the fence; and the honest "SUPPORTED is a quote-existence certificate, not a truth certificate" line.

### 3.3 Deterministic scorer (`experiments/score-t9.sh`)

Mirrors `score-t4.sh` structure (awk rep extractor on `^===== T9-ground-check rep [0-9]+ =====$`, per-rep temp files, `SCORE_SCALE=10000` integer math, identical perl-printf aggregate block, machine-parseable summary line) and `score-t3.sh`'s fixture/`grep -F` pattern. CLI: `score-t9.sh <raw-output-file> [--fixture-date YYYY-MM-DD]`, default date the calibration snapshot; fixture resolved as `repo_root/experiments/fixtures/task-9-ground-check-${date}.txt`; `set -euo pipefail`; unknown `--*` → exit 2; missing/nonexistent file → exit 2; `mktemp -d` + EXIT trap.

Fixture format (self-describing, three sentinel sections so no out-of-band key):
```
===== EVIDENCE =====
<verbatim evidence — multi-line; the closed corpus the model may quote from>
===== CLAIMS =====
C1: <claim text>
C2: <claim text>
...
===== EXPECTED =====
C1: SUPPORTED
C2: CONTRADICTED
C3: NOT-STATED|UNVERIFIED      # accept-set capability (adversarial f5 fix)
...
```
EVIDENCE is written to `evidence.txt` for the shared `grep -F` substring helper. EXPECTED gives canonical per-claim verdict LABELS only (never a canonical quote — the model may legitimately pick a different valid verbatim span). A `|`-separated EXPECTED entry is an accept-SET: `VERDICT_MATCH` passes if the resolved label is any member (this is what lets f5's overreach-with-fabricated-quote resolve to either `NOT-STATED` ideal or `UNVERIFIED` post-check-caught without spuriously failing — the adversarial critique's "scorer cannot represent f5" major fix).

Scoring resolves each emitted verdict through the post-check FIRST (apply the shared substring helper; downgrade any `SUPPORTED`/`CONTRADICTED` whose quote is not an exact substring to `UNVERIFIED`), THEN runs three checks per claim (PASS=1/FAIL=0), denominator fixed at `3 × n_claims` (mirrors score-t4's fixed /6):

1. SHAPE — exactly one verdict line per fixture claim id, parsing to a valid label; separator/quote-style tolerant (em-dash vs `--` vs `-`, straight vs curly quotes normalised) but the label token and id exact. Fails on missing/duplicate id, unrecognised label, or a `SUPPORTED`/`CONTRADICTED` line with no extractable quote.
2. QUOTE_VERBATIM (the load-bearing check) — every `SUPPORTED`/`CONTRADICTED` quote is an exact substring of the evidence via the shared symmetric-whitespace `grep -F` helper. `NOT-STATED` (and post-downgrade `UNVERIFIED`) are vacuously PASS. Additionally enforce the SHORTEST-span discipline the prompt asks for but the model may ignore: reject quotes shorter than a minimum length (cuts coincidental short-substring matches like `200`, `the release stage`) — surfaced as a QUOTE_VERBATIM sub-failure with a `MINLEN` note.
3. VERDICT_MATCH — the resolved label equals (or is in the accept-set of) the fixture EXPECTED label for that id. This is the relevance/correctness axis that catches right-quote-wrong-claim (the substring check provably cannot), and it is the axis the f10 "right-quote-wrong-claim" fixture (3.4) measures.

Claims in EXPECTED but absent from output → all 3 checks FAIL for that id. Extra verdict lines for ids NOT in the fixture claim set are ignored for the denominator but recorded as `EXTRA:Cx` in the per-rep fails note (a fabricated-claim / injection signal). Per-rep line: `rep N: pass=K/(3·n_claims) fails=[C2:VERDICT_MATCH,C4:QUOTE_VERBATIM,...]`. Summary:
```
T9_SUMMARY: reps=N claims=M total_passed=P total_checks=T mean=0.NNNN stdev=0.NNNN min=0.NNNN max=0.NNNN quote_fab_fails=Q verdict_mismatch=V supported_recall=0.NNNN contradicted_recall=0.NNNN
```
`quote_fab_fails` (QUOTE_VERBATIM failures) and `verdict_mismatch` (VERDICT_MATCH failures) are the two pivotable failure-mode axes (like score-t4 splitting SUBJECT_* from BODY_*). `supported_recall` and `contradicted_recall` are DERIVED per-class fields (verdict matches within each expected-label subset over fixed `3×n_claims` integer math) — reconciling the failure-modes design's per-class precision/recall with the flat-denominator scoring model (conventions-critique minor fix): one scoring model, recall as derived summary fields, not a second denominator. They let the gate enforce the under-flagging guard (a degenerate all-NOT-STATED model has zero SUPPORTED/CONTRADICTED recall and fails).

### 3.4 Fixtures (`experiments/fixtures/task-9-ground-check-<date>.txt`)

Ten fixtures (the eight original well-targeted ones, fixed and extended per both critiques). Each mixes at least one control claim of a different verdict type so a degenerate all-NOT-STATED policy scores poorly. Every intended-positive `SUPPORTED`/`CONTRADICTED` carries a quote that is an exact substring of its evidence so the post-check passes genuine spans.

f1 plain SUPPORTED baseline; f2 plain CONTRADICTED with exact quotes (plus a SUPPORTED control); f3 plain NOT-STATED (with a near-miss CONTRADICTED control so silence is distinguished from contradiction); f4 OVERREACH→NOT-STATED (the "PR fixes the inflated numbers" shape the probe caught, plus two SUPPORTED controls); f5 FABRICATED-QUOTE trap, EXPECTED `C1: NOT-STATED|UNVERIFIED` accept-set (real-quote SUPPORTED control); f6 RELABELLED "qualifier-dropping → NOT-STATED" (the short 3-sentence fixture — it tests dropping a load-bearing qualifier, which is legitimate, but it is NO LONGER labelled the long/selective-reading trap, per the adversarial major fix); f7 multi-claim mixed batch exercising all three verdict types with id-aligned independence and an embedded NOT-STATED silence trap; f8 ARITHMETIC out-of-scope, numbers deliberately do NOT sum (95 vs stated 90) so a model that wrongly computes would emit CONTRADICTED — EXPECTED `NOT-STATED` (refuse the arithmetic), with verbatim-quotable controls.

Two NEW fixtures the critiques require:

f9 BURIED-LATE-CONTRADICTION on near-ceiling evidence (adversarial major fix — the gate references this and no original fixture implemented it). A 3-4 KB evidence block at the measured recipe-tier ceiling whose contradicting span sits in the final third; EXPECTED `CONTRADICTED`; required to resolve `CONTRADICTED` on every rep. This is the only fixture that actually exercises the documented selective-reading / read-to-the-end failure mode (prompt rule 6) and the long-evidence stall risk. If it flips to `NOT-STATED`, that blocks ship until chunking guidance or tier routing fixes it.

f10 RIGHT-QUOTE-WRONG-CLAIM (adversarial blocker fix — measures the coincidental-substring gap the post-check cannot close). A claim whose true verdict is `NOT-STATED`, where the evidence contains a true, exact-substring span that is unrelated to the claim; if the model quotes that real-but-irrelevant span as `SUPPORTED`, QUOTE_VERBATIM PASSES (the bytes exist) but VERDICT_MATCH must FAIL against EXPECTED `NOT-STATED`. EXPECTED `NOT-STATED`; required to resolve `NOT-STATED` on every rep. Include a SUPPORTED control whose quote IS relevant.

Plus a whitespace-regression fixture line (adversarial major fix): at least one `SUPPORTED` whose correct quote spans a hard line-wrap in the evidence, so the symmetric-whitespace helper is pinned against a false-`UNVERIFIED` regression, and at least one evidence block containing glob metacharacters (`[`, `]`, `*`) so `grep -F` literal-matching is exercised against the dropped case-glob approach.

### 3.5 Main-agent integration & pre-completion habit

Wrapper `scripts/ground-check.sh` (the single runtime script; NO `ground-verify.sh`): a thin bash-3.2 wrapper taking the assembled evidence+claims block on stdin (or `--evidence-file`/`--claims-file`), running `bash scripts/delegate.sh --recipe ground-check reasoning "..."`, then applying the shared substring helper inline to downgrade fabricated-quote verdicts to `UNVERIFIED` and emit unparseable lines as `Cn: UNPARSEABLE — <raw>`. It prints per-claim verdicts in id order plus a `GROUND_CHECK_SUMMARY: clean=true|false ...` line. Exits 0 on any successful run (delegate.sh 2/3/4 propagate); never encodes verdict outcome in exit status.

Pre-completion habit (advisory, never blocking): the main agent runs ground-check on ITSELF immediately before asserting a strong completion claim ("done", "fixed", "verified", "passing", "this resolves", "now works") and before publishing generated prose that asserts facts about a source it did not write (PR bodies, commit-message bodies, release notes, status comments). The habit: extract the load-bearing factual assertions as a short atomic CLAIMS list (arithmetic and judgment filtered out), point them at the EVIDENCE actually in hand (test output, diff, edited file, CI log), run the wrapper, and re-read the source for every CONTRADICTED/NOT-STATED/UNVERIFIED before letting the assertion stand. This is the mechanical complement to the user's existing verification-before-completion discipline, run locally and off the main context window. It is never wired as a blocking hook or a merge/ship gate.

## 4. File-by-file changes

CREATE `prompts/ground-check.md` — the recipe (3.2). Frontmatter `inputs: { stdin: string }`, no flaky gate; reasoning tier; validated probe prompt + Convention 1 opener + one domain-neutral anchor + read-to-the-end rule 6; `=== X ===` delimiters; Expected output shape with the UNVERIFIED form; Calibration notes labelled SCAFFOLD-STAGE.

CREATE `experiments/lib/ground-substring.sh` — the single shared substring helper: normalise (symmetric whitespace-collapse, curly→straight quotes) then `grep -F -q` literal containment, plus the MINLEN floor. Sourced by both the scorer and the wrapper so they cannot drift (the parity guarantee test-16 asserts).

CREATE `experiments/score-t9.sh` — the deterministic scorer (3.3): SHAPE / QUOTE_VERBATIM / VERDICT_MATCH per claim, post-check resolution before scoring, accept-set EXPECTED, fixed `3×n_claims` denominator, `T9_SUMMARY` line with quote_fab_fails / verdict_mismatch / per-class recall.

CREATE `experiments/fixtures/task-9-ground-check-<date>.txt` — the ten fixtures (3.4) in EVIDENCE/CLAIMS/EXPECTED sentinel format, including f9 near-ceiling buried-contradiction, f10 right-quote-wrong-claim, the line-wrap quote, and the glob-metacharacter evidence.

CREATE `tests/test-score-t9.sh` — offline, model-free scorer tests building synthetic raw outputs (mirrors test-score-t4.sh), asserting every check and the parity property (3.5 / build step 4 below).

CREATE `scripts/ground-check.sh` — the single runtime wrapper (3.5): run delegate, apply shared post-check inline, emit verdicts + GROUND_CHECK_SUMMARY, exit 0 on success.

CREATE `tests/test-ground-check.sh` — offline wrapper tests asserting the UNVERIFIED downgrade, UNPARSEABLE passthrough, clean=true/false field, and exit-0-regardless-of-verdict.

MODIFY `prompts/README.md` — add one line to "Current recipes" describing ground-check as the closed-form quote-finder / grounding second-brain over the agent's own claims (the structural test requires the filename appear in the README).

MODIFY `SKILL.md` — add a one-line Recipes pointer to ground-check, stating it is reasoning-tier, advisory-never-a-gate, excludes arithmetic and judgment, and that SUPPORTED is a quote-existence certificate, not a truth certificate.

MODIFY `evals/eval-set.json` — add a positive paraphrase ("check whether the evidence actually supports these claims", "ground-check these conclusions against the log") so the trigger surface keeps firing on the shape (README graduation flow).

MODIFY `tests/test-prompts-library.sh` — OPTIONAL: add a recipe-specific structural pin (like the commit-message/summarise-issue pins) asserting the prompt template carries the quote-finder identity opener and the read-to-the-end rule, so a future simplification cannot silently drop them. Defer until after graduation if it complicates the scaffold-stage merge.

## 5. Build sequence (TDD: scorer/fixtures before recipe is trusted)

1. Author `experiments/lib/ground-substring.sh` first (the shared algorithm everything depends on). Verify independently with a tiny manual `bash -c` exercising: a clean substring (pass), a paraphrase (fail), a line-wrapped quote (pass via symmetric collapse), evidence containing `[`/`*` (literal `grep -F`, no glob), and a below-MINLEN quote (fail).
2. Author the fixtures `task-9-ground-check-<date>.txt` (3.4). Verify by eye that every intended-positive quote is an exact substring of its evidence and that f9 evidence is genuinely 3-4 KB with the contradiction in the final third.
3. Author `experiments/score-t9.sh` sourcing the helper. Verify the awk extractor and section parser against a hand-built raw file before any model is involved.
4. Author `tests/test-score-t9.sh` and make it green. Required assertions (synthetic raw outputs, no model): clean rep scores `3·n/3·n`; fabricated-quote SUPPORTED fails QUOTE_VERBATIM only and increments quote_fab_fails; correct-quote-wrong-label fails VERDICT_MATCH only and increments verdict_mismatch; OVERREACH NOT-STATED matching EXPECTED scores full; overreach rubber-stamped with fabricated quote fails both; overreach rubber-stamped with fabricated quote BUT downgraded to UNVERIFIED PASSES VERDICT_MATCH against the `NOT-STATED|UNVERIFIED` accept-set (the f5 safety-behaviour test); right-quote-wrong-claim SUPPORTED passes QUOTE_VERBATIM but fails VERDICT_MATCH (f10); NOT-STATED scored on SHAPE+VERDICT_MATCH only; missing claim id fails all three; malformed/duplicate line fails SHAPE; extra id recorded EXTRA:Cx, denominator unchanged; curly-quote/em-dash and line-wrap normalisation parse and substring-match; empty rep → 0; multi-rep aggregation reports reps/min/max/mean/stdev; usage error exit 2; nonexistent fixture-date clear error; supported_recall/contradicted_recall derived correctly; and the parity assertion that the helper gives identical pass/fail to the wrapper on the same quote+evidence pair.
5. Author `prompts/ground-check.md` (3.2) and run `tests/test-prompts-library.sh` — must pass (title matches filename, four sections present, fenced template extracts, `{{stdin}}` placeholder, no `## ` inside the fence).
6. Author `scripts/ground-check.sh` + `tests/test-ground-check.sh` (offline), make green: UNVERIFIED downgrade, UNPARSEABLE passthrough, clean field, exit 0 regardless of verdict mix, delegate.sh 2/3/4 passthrough.
7. Wire SKILL.md, prompts/README.md, evals/eval-set.json; rerun the full `tests/run-tests.sh` suite green.
8. PHASE 7 GRADUATION RUN (the actual ship gate): use the runner to produce 3+ reps of `===== T9-ground-check rep N =====` output on the FAST host, run BOTH `reasoning` and `prose` tiers (the A/B), score each with `score-t9.sh`, confirm the gate (Section 6) is met with non-overlapping stdev. Record the result in Calibration notes, flip the recipe from SCAFFOLD to shipped, and record the tier the A/B selected. If neither tier clears the bar, the recipe stays scaffold and the Calibration notes record the blocker (do not paper over it).

## 6. Acceptance criteria (deterministic gate)

Per Phase 7, ground-check graduates from scaffold to shipped only when, across 3+ reps on the chosen tier (the A/B winner of reasoning vs prose) with NON-OVERLAPPING stdev (mean − stdev clears the bar), `score-t9.sh` reports all of:

(a) ZERO fabricated-quote `SUPPORTED`/`CONTRADICTED` that survive the post-check — i.e. every non-substring quote was downgraded to UNVERIFIED. A surviving fabricated-quote positive is an automatic gate failure (the recipe's core safety property). Stated honestly: this is "zero fabricated-quote SUPPORTED," NOT "zero false-SUPPORTED."
(b) `supported_recall` ≥ 0.90 AND `contradicted_recall` ≥ 0.90 on every rep in the band (under-flagging guard — a degenerate all-NOT-STATED model fails here).
(c) the OVERREACH (f4), arithmetic (f8), and qualifier-dropping (f6) cases resolve to NOT-STATED on every rep (over-flagging guard).
(d) the buried-late contradiction (f9, near-ceiling evidence) resolves to CONTRADICTED on every rep (selective-reading guard).
(e) the right-quote-wrong-claim case (f10) resolves to NOT-STATED on every rep (coincidental-substring / VERDICT_MATCH guard — the gap the substring check provably cannot cover).
(f) no extra verdict for an id absent from the fixture claim set leaks into the parsed/scored output (injection guard).
(g) scorer-recipe parity: the substring/normalisation/MINLEN rule the scorer enforces is byte-identical (shared `ground-substring.sh`) to the rule the wrapper runs and the rule the recipe documents.

The 2026-05-31 probe (5/5, overreach correctly NOT-STATED, two CONTRADICTED with exact quotes, 13s) establishes the target is empirically reachable; it is the seed, not the gate. The `T9_SUMMARY` line is what an acceptance harness greps.

## 7. Failure modes & guardrails

False SUPPORTED via fabricated quote (critical) — forced verbatim quoting (prompt rule 5) is the first line; the deterministic substring post-check downgrading to UNVERIFIED is the authoritative second line; scorer-recipe parity (shared helper) keeps the two from drifting.

False SUPPORTED via coincidental/irrelevant real quote (critical, the substring check CANNOT catch) — addressed by VERDICT_MATCH against ground truth plus the f10 right-quote-wrong-claim fixture and the MINLEN floor that cuts short coincidental matches; and by never overclaiming the safety property (SUPPORTED = quote-exists, not claim-true).

Selective reading / long-evidence stall (high) — prompt rule 6 (read to the end), the f9 near-ceiling buried-contradiction gate metric, and the `## Context to gather first` chunking/long-context-tier guidance; delegate.sh's pre-flight canary (exit 3) catches dynamic stalls.

False UNVERIFIED alarm from whitespace/line-wrap (medium) — symmetric whitespace-collapse on both sides in the single shared helper; pinned by the line-wrap fixture.

Glob-metacharacter mis-match (medium) — `grep -F` literal matching only; the case-glob approach is dropped; pinned by the glob-metacharacter evidence fixture.

Output-format drift (medium) — strict one-line-per-claim grammar, "Do not explain" + anti-preamble tail; the scorer extracts only `^<known-id>:` lines and scores missing/unparseable as per-claim FAIL so drift costs score and surfaces in the gate; UNPARSEABLE lines are emitted loudly, never silently dropped.

Prompt injection via EVIDENCE (high) — `=== EVIDENCE ===` data-fence; scorer/wrapper parse only verdicts for input ids and discard non-input ids; the f-injection check in the gate; and because the tool is advisory-never-a-gate, a compromised run cannot trigger any merge/ship action.

Arithmetic / judgment scope creep (medium) — excluded in the recipe opener, SKILL.md fit text, and `## Context to gather first`; the f8 arithmetic→NOT-STATED fixture pins refusal; the substring check naturally limits damage (a sum-claim has no verbatim span).

Advisory creep into a gate (high) — exit status decoupled from verdict outcome; clean=true/false is a field; header and SKILL.md state exit semantics are advisory-only and never a merge/ship gate.

## 8. Non-goals

NEVER a merge/ship/deploy gate or any blocking check — strictly advisory; exit status never encodes verdict outcome. NO arithmetic, summation, counting, or numeric comparison — the model is weak at math; sum-claims must not be delegated. NO judgment/evaluation ("is this the right approach / true in the world / a good design") — judging imports priors and produces alarmist drift (2026-05-03 retro). SUPPORTED is a quote-existence certificate, NOT a truth certificate — the supplied evidence may be wrong, stale, or cherry-picked, and the agent must still apply its own judgment. NO cross-span synthesis — support requiring two separate sentences combined returns NOT-STATED by design (single contiguous verbatim span only). NOT a replacement for the agent reading the evidence — a second-brain pre-filter for overreach. NOT a recipe over user content — it operates on the agent's own draft claims against an evidence block.

## 9. Open questions & risks

Prose-vs-reasoning tier is resolved to reasoning by SKILL.md line 141 but the n=1 probe was on a prose model; the Phase 7 A/B is the deciding measurement and is a ship step, not an open question. Evidence-size ceiling for reliable grounding on this recipe shape is unmeasured (f9 probes the near-ceiling case but the practical max is host-dependent). Multi-claim batching ceiling: the probe used 5 claims; per-claim verdicts are independent so batching should be safe under SKILL.md's same-shape-items exception, but the count before recall degrades is unmeasured. The coincidental-substring gap is mitigated by VERDICT_MATCH + f10 + MINLEN but not eliminated; if dogfood surfaces a surviving right-quote-wrong-claim SUPPORTED, the next lever is a stricter relevance check or a calibration note, not a stronger substring test. flaky_on_models is empty by Convention 4; if the A/B measures a class stalling on THIS shape, add the substring then with the measurement cited.
