---
inputs:
  stdin: string
---
# ground-check

## When to use

You (the main agent) are about to assert something — "done", "fixed", "this resolves it", "the tests pass" — or you are about to publish prose that states facts about a source you did not write (a PR body, a commit-message body, a release note, a status comment). Before the assertion stands, you want a cheap on-device check that the EVIDENCE in hand actually states each claim. ground-check turns a local model into a closed-form grounding "second brain": given a numbered CLAIMS list and an EVIDENCE block, it returns one verdict per claim — `SUPPORTED — "<verbatim quote>"`, `CONTRADICTED — "<verbatim quote>"`, or `NOT-STATED` — so you can catch an overreach before you ship it.

This recipe is unusual in the library: it operates on YOUR OWN draft claims against an evidence block, NOT on user content. It is not a summariser. The architectural lever is that the model is forced to QUOTE verbatim rather than JUDGE — a local model fabricates when asked "is this true?" (that imports its priors) but is reliable as a quote-finder because it cannot quote what is not there. A deterministic post-check then verifies every quote is an exact substring of the evidence and downgrades any fabricated-quote verdict to `UNVERIFIED`.

It is strictly ADVISORY and never a gate. A `NOT-STATED` / `CONTRADICTED` / `UNVERIFIED` verdict is a cue to re-read the source and soften or drop the claim, not a blocker. Two things are out of scope and must be filtered out of the CLAIMS list before you call it: arithmetic (the model is weak at math — a sum/count/comparison has no verbatim span anyway) and judgment ("is this the right approach", "is this exploitable"). And `SUPPORTED` means a quote exists, NOT that the claim is true in the world — the evidence itself may be wrong, stale, or cherry-picked.

## Context to gather first

Assemble two parts into the single stdin block the wrapper reads:

1. A numbered CLAIMS list — one atomic declarative proposition per line (`C1:`, `C2:`, …), with arithmetic and judgment claims removed first.
2. The SMALLEST EVIDENCE block that could contain the answer — a diff hunk, a failing-log slice, an edited file, an issue body, a doc paragraph. Keep it under the practical recipe-tier ceiling (35B-class models stall on recipe-shaped prompts around 3-4 KB — chunk larger evidence and run per-chunk, or route to the long-context tier; never one oversized block).

The stdin block is the EVIDENCE text, then a line `=== CLAIMS ===`, then the numbered claims. The recipe template supplies the leading `=== EVIDENCE ===` fence, so do not repeat it:

```bash
printf '%s\n\n=== CLAIMS ===\n%s\n' "$evidence" "$claims" | bash scripts/ground-check.sh
```

## Prompt template

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

## Variables

- `{{stdin}}` — the assembled document: the EVIDENCE text, then a line `=== CLAIMS ===`, then the numbered `C1:`/`C2:`/… claims. Piped to `scripts/ground-check.sh` (which forwards it to `delegate.sh --recipe ground-check`).

## Invocation

```bash
# Pre-completion self-check: extract your load-bearing factual assertions as a
# numbered CLAIMS list, point them at the evidence in hand (test output, the
# diff, the edited file), and run the wrapper. It prints per-claim verdicts and
# a GROUND_CHECK_SUMMARY line; exit status is always 0 on a successful run.
evidence=$(git diff --staged)
claims='C1: The change is confined to the auth middleware.
C2: A regression test was added for the empty-input case.'
printf '%s\n\n=== CLAIMS ===\n%s\n' "$evidence" "$claims" | bash scripts/ground-check.sh
```

The wrapper runs `bash scripts/delegate.sh --recipe ground-check reasoning "..."` and then applies the shared substring post-check. To inspect the raw model verdicts without the post-check, call `delegate.sh --recipe ground-check` directly on the same stdin.

## Expected output shape

```
C1: SUPPORTED — "the change is limited to src/auth/middleware.ts"
C2: CONTRADICTED — "no new tests were added in this change"
C3: NOT-STATED
C4: UNVERIFIED — "<quote the model emitted that is NOT a substring of the evidence>"
```

`C1`/`C2` carry an exact span; `C3` is honest silence; `C4` is the post-check's downgrade form — the model claimed a quote that is not in the evidence, so the wrapper rewrote `SUPPORTED`/`CONTRADICTED` to `UNVERIFIED`. Re-read the source for every `CONTRADICTED`, `NOT-STATED`, and `UNVERIFIED` before letting the original assertion stand. `GROUND_CHECK_SUMMARY: clean=false` means at least one claim is not a verified `SUPPORTED`.

## Calibration notes

SCAFFOLD-STAGE — not yet graduated. The recipe, the deterministic scorer (`experiments/score-t9.sh`), the fixtures (`experiments/fixtures/task-9-ground-check-2026-05-31.txt`), and the offline tests are authored, but graduation to "shipped" requires the Phase 7 fixture run across 3+ reps with non-overlapping stdev meeting the acceptance gate in `docs/research/2026-05-31-ground-check-plan.md` §6. Until that run passes, do not assert parity with a measured baseline.

Provenance: on 2026-05-31 a probe ran the fast MLX prose model (`mlx-community/Qwen3.6-35B-A3B-8bit`, thinking OFF, temperature 0) on a 5-claim grounding check and scored 5/5 in 13s — it marked an overreach claim ("the PR fixes the inflated numbers", stated nowhere in the evidence) as `NOT-STATED` instead of rubber-stamping, and caught two `CONTRADICTED` claims with exact quotes. The verbatim working prompt was: «You are a grounding checker. ONLY use the EVIDENCE below — do not use outside knowledge. For each CLAIM, output one line: "<id>: SUPPORTED — \"<exact quote from evidence>\"" if the evidence states it, "<id>: CONTRADICTED — \"<exact quote>\"" if the evidence states the opposite, or "<id>: NOT-STATED" if the evidence neither states nor contradicts it. Do not explain.» This is n=1; the Phase 7 fixture run is the actual ship gate.

Tier: `reasoning`, per SKILL.md line 141 — "the `prose` tier is for generating prose, not for inferring about prose; for analytical work over a diff or log use `reasoning` even if the input is text-heavy." ground-check is inference-about-prose (locate a span supporting/contradicting a claim), the same lane `summarise-issue.md` occupies. The probe happening to resolve well on a prose model is a single n=1 datum that does not transfer across hosts, so the prose-vs-reasoning question is a measured A/B at the Phase 7 step (run both tiers; keep prose only if reasoning's chain-of-thought measurably imports judge-drift on the fixture). Thinking is OFF (delegate.sh default).

No `flaky_on_models:` gate. Convention 4 requires every listed substring be anchored in MEASURED evidence specific to this recipe; the only datum so far is a 5/5 HIT, so there is nothing to anchor. The deterministic post-check already degrades a weak model to more `UNVERIFIED`/`NOT-STATED` lines rather than a silent rubber-stamp, so the gate would buy little. If the Phase 7 A/B measures a class stalling on this recipe shape, add the substring then with the measurement cited.

Post-check parity: the substring rule the scorer's QUOTE_VERBATIM check enforces and the rule the wrapper runs at runtime are byte-identical — both source `experiments/lib/ground-substring.sh` (curly→straight quotes, symmetric whitespace-collapse so a quote spanning a hard line-wrap still verifies, `grep -F` literal containment so glob metacharacters match literally, and a MINLEN floor that cuts coincidental short matches). This guarantees zero fabricated-quote `SUPPORTED`; it does NOT guarantee relevance — a true-but-irrelevant span passes the substring test, which is why the scorer also enforces VERDICT_MATCH against ground truth. `SUPPORTED` is a quote-existence certificate, NOT a truth certificate.

Editor warning: the prompt template uses `=== X ===` delimiters, NOT `## `. Do not introduce a `## `-prefixed line inside the prompt-template fence — `tests/test-prompts-library.sh` extracts the template by treating any `## ` line as the end of the section, so a `## ` inside the fence silently truncates the extracted template and breaks the structural checks.

### 2026-06-01 — Phase 7 graduation A/B (SCAFFOLD retained)

First graduation run: 3 reps per tier against the 2026-05-31 fixture, scored by `experiments/score-t9.sh`.

- prose tier (`mlx-community/Qwen3.6-35B-A3B-8bit`): mean 0.9444, stdev 0, `quote_fab_fails=0`, `supported_recall=1.0`, `contradicted_recall=1.0`. Consistent misses on C6 and C8 only. C6 is the qualifier-drop ("the migrated dashboards render correctly") — the model quoted the real span "render correctly in staging" and marked it SUPPORTED, dropping the load-bearing "in staging". C8 is the arithmetic-adjacent claim ("ninety panels in total") — the model matched the real "90 panels as fully verified" span rather than refusing. Both are VERDICT_MATCH failures with *real* substrings: the quote-finder lever held (zero fabrication) but the relevance/scope judgment under-flagged.
- reasoning tier (`ollama deepseek-r1:32b` — the calibrated reasoning model): mean 0.9166, `supported_recall=0.6666`. Same C6 miss, plus C12 (a plain SUPPORTED control) where the 32b model paraphrased the quote instead of copying it verbatim, so the post-check correctly downgraded it to UNVERIFIED (`quote_fab_fails=3`, one per rep). The quote-fidelity slip is on the 32b itself, not a small-model artifact — a sharper finding, and consistent with the plan's open question of whether the reasoning tier's chain-of-thought imports drift (here it traded verbatim fidelity for a paraphrase).

Gate result (plan §6): NEITHER tier clears the bar. Prose fails (c) — the overreach/arithmetic/qualifier cases must resolve NOT-STATED on every rep, and C6/C8 do not. Reasoning fails (b) (`supported_recall` ≥ 0.90) and (c). The recipe therefore stays SCAFFOLD. The deterministic infrastructure worked exactly as designed: the quote-existence guarantee (a) held on both tiers (zero fabricated-quote SUPPORTED survived the post-check), and the scorer surfaced real under-flagging without any false fabrication alarm.

A/B verdict on the right model class (prose Qwen3.6-35B vs reasoning deepseek-r1:32b): prose LEADS, 0.9444 vs 0.9166. This nuances the SKILL.md line-141 reasoning-default for this specific recipe shape — the reasoning model's verbatim-quote fidelity was worse, not better. The recipe keeps `reasoning` as its documented default tier (the routing rule still stands until graduation), but the measured lead is the signal to revisit: if prose clears the bar after the C6/C8 fixes below, switch the wrapper's tier to prose.

Blockers / next levers (not papered over): (1) C6 qualifier-drop is the hardest case and was flagged as borderline-legitimate in the plan; both tiers read "render correctly in staging" as supporting the unqualified "render correctly". The lever is a contrastive Wrong/Correct anchor on qualifier-dropping (Convention 3), not more enumeration. (2) C8 lets the model match a real "90 panels" span for "ninety in total"; sharpen the claim or add a scope anchor so the arithmetic-refusal is unambiguous. (3) the reasoning tier's C12 quote paraphrase is the quote-fidelity blocker on the 32b; if reasoning is retained, the lever is a stronger verbatim-copy directive in rule 5. One contrastive anchor at a time, re-measure (calibration-loop discipline).
