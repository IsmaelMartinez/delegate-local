---
inputs:
  style_anchor: string
  facts: string
---
# roadmap-status

## When to use

The user is drafting a forward-looking "what's next" status for a long-running project plan / roadmap file (typically `ROADMAP.md`, `docs/plans/current-plan.md`, or similar) — a short brief over the open work, spanning several unshipped, blocked, and deferred items, derived from the plan plus the priority judgement the agent has already made. The shape is one or two flowing-prose paragraphs that read consistently with the rest of the file and lead with the most actionable item. The recipe is the right fit when the caller can supply two things: a structured fact list (the not-yet-done items with their gating, ordered by the agent who did the prioritising) and an existing entry from the same file to anchor tone, length, technical density, and prose-vs-bullets balance.

This recipe is the multi-item forward-looking sibling of two narrower recipes. Use `roadmap-entry.md` for a past-tense "shipped" log entry (one heading plus prose recording merged PRs with hashes and dates). Use `plan-section-intro.md` for a single new phase's intro paragraph (where the prose must read as original framing, not a restatement of the planning notes). Use this recipe for the "what comes next across the plan" status that spans multiple open items and has no PR numbers yet — here, faithfully tracking the supplied facts is the goal, not avoiding echo.

## Context to gather first

Run both of these before invoking the recipe:

```bash
# 1. Verbatim style anchor — an existing prose paragraph from the target plan
#    file (a "Next Up" entry or a recent narrative paragraph). Extract it as-is
#    so the model copies the spelling variant, prose-vs-bullets density, and
#    paragraph length rather than an abstract description. Adjust the heading
#    regex to your plan file's convention before running.
awk '/^### / { if (flag) exit; if ($0 ~ /Next Up|Up Next/) flag=1 } flag' ROADMAP.md

# 2. Structured fact list — the unshipped / blocked / deferred items with their
#    gating, ordered by the agent who did the prioritising. Author this in a
#    scratch file. The ordering is the agent's call, not the model's:
cat <<'EOF' > /tmp/facts.md
MOST ACTIONABLE: <item> — <why it is ready / continuous with recent work>
GATED: <item> — <what gates it, and when it becomes due>
BLOCKED: <item> — <the blocker>
UNSTARTED: <item> — <the next concrete sub-step>
LATER (not commitments): <items>
EOF
```

The style anchor is load-bearing — abstract descriptors like "match the plan's voice" reliably yield bullet lists or American-English drift when the file uses prose and British English. The ordering in the facts list is the agent's prioritisation: the model converts facts to prose in that order, it does not re-rank.

## Prompt template

```
Draft a forward-looking "what's next" status for a long-running project plan / roadmap file. Do not invent items, PR numbers, dates, or gating that are not in the FACTS below.

Output 1-2 short flowing-prose paragraphs (NO bullet lists unless the STYLE ANCHOR below uses bullet lists). Lead with the most actionable item, then gated items, then unstarted work, then later ideas — keep the order of the FACTS block; do NOT re-rank.

Write forward-looking. These items are NOT done. Do NOT write past-tense "shipped" / "landed" / "merged" / "completed" sentences and do NOT describe any item as finished; every item is open work. Describe what remains and what gates it.

Preserve every item and its gating from the FACTS block. Do NOT drop an item, do NOT merge two distinct items into one, and do NOT invent gating that is not stated. Two adjacent items with similar identifiers stay distinct.

Match the STYLE ANCHOR exactly in: spelling variant (American vs British), prose-vs-bullets balance, paragraph length, technical density, and tone. If the anchor uses British spelling (organisation, behaviour, optimise), use British. If it uses American (organization, behavior, optimize), use American. Detect from the anchor; do NOT default to either.

Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "ensuring", "allowing", "enabling", "reflecting", "providing", "supporting", "keeping", "setting up"). Do NOT end with a declarative rephrase ("This means", "This sets up", "The result is", "Overall", "In summary", "This positions", "This unblocks"). Do NOT end with restating phrases ("going forward", "moving forward", "closes the loop", "closing the loop"). End on a finite verb introducing new content, or stop.
Wrong: The team migrates the cache layer next, setting up the eventual read-through rollout.
Correct: The team migrates the cache layer next; the read-through rollout is gated on that migration.
Wrong: First the parser is rewritten, which closes the loop on the grammar work.
Correct: First the parser is rewritten, then the grammar tests are re-enabled.

Output ONLY the status itself, no preamble, no "Here's the status:".

=== STYLE ANCHOR (verbatim — match its shape and spelling variant) ===
{{style_anchor}}

=== FACTS (the open items, in priority order — preserve each, keep distinct) ===
{{facts}}
```

## Variables

- `{{style_anchor}}` — verbatim block, an existing prose paragraph from the same plan file. Load-bearing. Without it the prose-tier default is numbered bullet lists and quiet Americanisation. Use `awk`/`sed` to extract a real entry verbatim.
- `{{facts}}` — structured fact list authored by the agent: the unshipped / blocked / deferred items with their gating, ordered by priority. The model converts this into prose in the given order; the agent's job is to make the facts accurate, complete, and correctly ordered.

## Invocation

```bash
PLAN_FILE=ROADMAP.md
ANCHOR=$(awk '/^### / { if (flag) exit; if ($0 ~ /Next Up|Up Next/) flag=1 } flag' "$PLAN_FILE")
bash scripts/delegate.sh --recipe roadmap-status \
  --var style_anchor="$ANCHOR" \
  --var facts="$(cat /tmp/facts.md)" \
  prose "Match the STYLE ANCHOR exactly in spelling variant and prose-vs-bullets balance. Forward-looking only — no past-tense 'shipped' sentences. Preserve every item in order; do not merge two into one."
```

The trailing prompt arg reinforces the three highest-signal rules (spelling mirror, forward-looking tense, no-merge). The recipe template carries the structural directives and the anti-padding guard.

## Anti-hallucination guards (each line addresses a real drift)

- "Write forward-looking ... do NOT write past-tense 'shipped' sentences" — the nearest recipe, `roadmap-entry.md`, is past-tense, and a prose-tier model handed roadmap facts defaults to the log-entry shape it has seen most. Without the explicit tense flip the status reads as a changelog of done work. This is the inverse of `roadmap-entry.md`'s genre.
- "Lead with the most actionable item ... keep the order of the FACTS block; do NOT re-rank" — the priority call is the agent's, made in the facts ordering; the prose tier otherwise reorders or buries the actionable item under whichever fact reads most fluently first.
- "Preserve every item ... do NOT merge two distinct items into one" — addresses a 2026-06-08 bare-prose MISS that conflated two distinct backlog items (`AI-128`, `AI-129`) into one theme. A forward-looking status over several open items is exactly where the prose tier blurs adjacent items together; unlike `plan-section-intro.md`, the concern here is faithful preservation, not anti-echo.
- "Match the STYLE ANCHOR exactly in spelling variant" with explicit British/American detection — mirrors `roadmap-entry.md` and `plan-section-intro.md`; the same prose-tier quiet-Americanisation prior applies to plan files.
- "NO bullet lists unless the STYLE ANCHOR uses bullet lists" — addresses the prose tier defaulting to numbered lists when the facts phrasing implies enumeration, even when the anchor is flowing prose.
- "Stop after the substantive content ..." anti-padding block — a status is a factual brief; a "this sets up the next phase going forward" tail reads especially wrong. The Wrong/Correct examples use domain-neutral content (cache migration, parser rewrite) so the model does not copy them into a real status, per the library's domain-neutral-anchor convention.

## Expected output shape

```
1-2 flowing-prose paragraphs, forward-looking throughout, British or American
consistently per the anchor, leading with the most-actionable item and then
moving through gated, unstarted, and later items in the FACTS order — each item
from FACTS preserved and distinct, no past-tense "shipped"/"merged" framing, no
closing flourish.
```

Verify before recording verdict: forward-looking throughout (no past-tense "shipped" / "merged" / "done" framing), every FACTS item present and not merged with another, the most-actionable item leads, spelling variant matches the anchor (British or American consistently), prose-vs-bullets matches the anchor, no closing "this sets up … going forward" flourish, no preamble.

## Calibration notes

This recipe originates from issue #278, filed 2026-06-08. The forward-looking "what's next in ROADMAP.md" shape came up twice in a single repo-butler maintenance session — compose a maintainer-facing status from the plan's unshipped, blocked, and deferred items plus the agent's priority judgement — and both ran through the bare `prose` tier with no recipe, recording HITs (`mlx-community/Qwen3.6-35B-A3B-8bit`, ~4.4 and 4.8s). The nearest recipe, `roadmap-entry.md`, is explicitly past-tense (a shipped log entry with PR hashes and dates), and `plan-section-intro.md` targets a single phase's intro paragraph, so the multi-item "what comes next" shape had no recipe and fell back to a bare-tier call — the weaker trigger surface, with the anti-drift directives re-specified by hand each time and no per-recipe calibration accumulating.

The recipe reuses `roadmap-entry.md`'s spelling-mirror, no-bullets, and anti-padding guards with the tense flipped, and adds three directives: lead with the most-actionable item in the FACTS order, do NOT write past-tense "shipped" sentences (the inverse of `roadmap-entry.md`), and preserve every item without merging distinct ones (anchored on the 2026-06-08 `AI-128`/`AI-129` conflation MISS). It deliberately does NOT import `plan-section-intro.md`'s FACTS-BLOCK-REPHRASE anti-echo machinery: that recipe needs the model to rewrite planning notes into original intro prose, whereas a status brief should track the supplied facts faithfully — the failure mode here is dropping or merging items, not echoing them.

### 2026-06-08 — initial recipe + first dogfood (HIT)

First dogfood ran against a verbatim repo-butler `ROADMAP.md` prose anchor (the "PROPOSE on a schedule" out-of-scope paragraph) and a six-item priority-ordered FACTS list (Phase 10 stage 4 as MOST ACTIONABLE through the LATER ideas), delegated to `mlx-community/Qwen3.6-35B-A3B-8bit` (prose tier) — 2 reps, deterministic and identical. Recorded HIT. All three new directives bound: the output was forward-looking throughout (`populates`, `flips`, `stays out of scope`, `remains paused`, `waits on`, `awaits`, `remain later ideas` — no past-tense "shipped" framing), led with the Phase 10 stage 4 item in the FACTS order, and preserved all six items distinctly with the conflation-prone adjacent items (Phase 9 live emission vs Phase 10 stage 5) kept separate. Prose-vs-bullets matched the flowing-prose anchor, no closing flourish, no preamble. The faithful-tracking design held — the model closely followed the supplied facts (the goal for a status brief) rather than the FACTS-echo failure `plan-section-intro.md` fights, confirming the two shapes warrant separate recipes.

If a later dogfood surfaces a drift not enumerated above, follow the established pattern: extend the directive with a v5/v7 contrastive Wrong/Correct one-shot grounded in the failing output (with domain-neutral Correct content), add a dated entry under this section, and name the failure shape literally rather than abstractly.
