# roadmap-entry

## When to use

The user is drafting a single "shipped" entry for a long-running project plan / roadmap file (typically `ROADMAP.md`, `docs/plans/current-plan.md`, or similar). The shape is one heading plus one or two flowing-prose paragraphs that read consistently with the rest of the file. The recipe is the right fit when the caller can supply two things: a structured list of facts (PR numbers, squash hashes, dates, per-PR shipped summaries, optional Up-Next pointer) and an existing entry from the same file to anchor tone, length, technical density, and prose-vs-bullets balance.

For drafting a single release-note bullet rather than a roadmap entry (different shape — bullet-led, past tense, external reader), use `release-note.md`. For drafting a commit message (subject + body, internal voice), use `commit-message.md`.

## Context to gather first

Run both of these before invoking the recipe:

```bash
# 1. Verbatim style anchor — the most recent shipped entry in the target plan file.
#    Extract it as-is, including heading and prose. Do NOT paraphrase or trim;
#    the verbatim shape is the calibration signal.
awk '/^### .* — shipped /{flag=1} flag' docs/plans/current-plan.md | sed -n '1,40p'

# 2. Structured fact list — one heading line plus per-PR shipped summary plus
#    optional Up-Next pointer. Author this in a scratch file:
cat <<'EOF' > /tmp/facts.md
HEADING: <date> — <one-line sprint summary>

PRs:
- #NNN (squash <hash>, merged <YYYY-MM-DD>): <one sentence on what shipped>
- #NNN (squash <hash>, merged <YYYY-MM-DD>): <one sentence on what shipped>

Up Next: <one short pointer to what comes after, or omit if the entry doesn't close with one>
EOF
```

The style anchor is load-bearing — abstract descriptors like "match the plan's voice" reliably yield bullet lists or American-English drift when the file uses prose and British English. The verbatim block lets the model copy the spelling variant, the prose-vs-bullets density, and the paragraph length without an abstract description doing that work.

## Prompt template

```
Draft a single "shipped" entry for a long-running project plan / roadmap file.
Output ONE heading line plus 1-2 short flowing-prose paragraphs (NO bullet
lists unless the STYLE ANCHOR below uses bullet lists).

Match the STYLE ANCHOR exactly in: spelling variant (American vs British),
prose-vs-bullets balance, paragraph length, technical density, and tone.
If the anchor uses British spelling (organisation, behaviour, optimise), use
British. If it uses American (organization, behavior, optimize), use American.
Detect from the anchor; do NOT default to either.

Stop after the substantive content sentences. Do NOT add a closing sentence
that restates the point. Restating happens in two shapes, both rejected:
participial form (", ensuring that…", ", enabling…", ", allowing…") and
declarative form ("This ensures…", "This enables…", "…closing the gap in X",
"…closes the loop", "…going forward"). Roadmap entries are factual logs,
and a closing-flourish sentence reads especially wrong in that genre.

Preserve every PR number, squash hash, and date from the FACTS block exactly
as written. Do NOT invent identifiers; do NOT round commit hashes; do NOT
shift dates. If the FACTS block names PR #382 with squash hash e9c560c2 and
merge date 2026-05-16, the output must contain those three tokens unchanged.

Output ONLY the entry itself, no preamble, no "Here's the entry:".

=== STYLE ANCHOR (verbatim — match its shape and spelling variant) ===
{{style_anchor}}

=== FACTS (the new entry's content — preserve every PR number, hash, date) ===
{{facts}}
```

## Variables

- `{{style_anchor}}` — verbatim block, an existing shipped entry from the same plan file. Load-bearing. Without this anchor the prose-tier default is numbered bullet lists and quiet Americanisation (`favor`, `behavior`, `utilize`) regardless of the project's actual style. Use `awk`/`sed` to extract the most recent entry verbatim, including its heading.
- `{{facts}}` — structured fact list authored by the agent. Conventional shape: a `HEADING:` line with the date and one-line sprint summary, a `PRs:` block with one bullet per PR carrying its number, squash hash, merge date, and one-sentence shipped summary, and an optional `Up Next:` pointer line. The model converts this into prose; the agent's job is to make the facts accurate and complete.

## Invocation

```bash
PLAN_FILE=docs/plans/current-plan.md
ANCHOR=$(awk '/^### .* — shipped /{flag=1} flag' "$PLAN_FILE" | sed -n '1,40p')
bash scripts/delegate.sh --recipe roadmap-entry \
  --var style_anchor="$ANCHOR" \
  --var facts="$(cat /tmp/facts.md)" \
  prose "Match the STYLE ANCHOR exactly in spelling variant and prose-vs-bullets balance. Preserve every PR number, hash, and date verbatim."
```

The trailing prompt arg reinforces the two highest-signal rules (spelling mirror, ID preservation); the recipe template carries the structural directives and the anti-padding guard.

## Anti-hallucination guards (each line addresses a real observed drift)

- "Match the STYLE ANCHOR exactly in spelling variant" with an explicit British/American detection rule — addresses quiet Americanisation observed across `bonnie-wee-plot` PRs #372 / #382 / #383: prose-tier models silently flip `organisation` → `organization`, `behaviour` → `behavior`, `optimise` → `optimize` even when British spelling is consistent in the anchor. The bare "match the project's voice" descriptor did not bind; the explicit "detect from the anchor; do NOT default to either" directive does. Same v5/v7 directive-rule pattern that closed the `(#NN)` gap in `commit-message.md`.

- "NO bullet lists unless the STYLE ANCHOR below uses bullet lists" — addresses the recurring drift where the model defaults to numbered lists when the input phrasing mentions "three load-bearing decisions" or similar phrasing-with-implicit-enumeration, even when the explicit anchor is flowing prose. The bare "match the prose-vs-bullets balance" did not hold; tying it to the anchor's actual shape does.

- "Stop after the substantive content sentences. Do NOT add a closing sentence that restates the point" with both participial AND declarative form enumeration — mirrors the established SKILL.md anti-padding directive. Roadmap entries are factual logs where the closing-flourish shape reads especially wrong (a deployment record does not need a "this delivers value going forward" tail). The guard names both shapes because `commit-message.md`'s calibration history showed the participial-only version was strictly weaker than the failure modes (T4 dogfood emitted "This ensures…" and "…closing the gap" after a 6/6 participial-only score).

- "Preserve every PR number, squash hash, and date from the FACTS block exactly as written" with a concrete example — addresses a near-miss observed in the issue author's drafting sessions where the model rounded `e9c560c` slightly. The example clause anchors the rule to a recognisable identifier shape so the model's pattern-matching has a literal target rather than an abstract one.

- "Output ONLY the entry itself, no preamble" — without this the model wraps in "Here's the roadmap entry:" prose that has to be stripped.

## Expected output shape

```
### 2026-05-16 — feature-flag rollout sprint

Shipped four PRs across two days closing out the staged-rollout migration.
PR #372 (squash a4b7c1d, 2026-05-15) wired the flag-evaluation client into
the request-handling middleware so per-tenant flags resolve once per request
rather than per call site. PR #382 (squash e9c560c, 2026-05-16) ported the
existing percentage-rollout tests onto the new client and removed the legacy
flag-reading helpers. PR #383 (squash 1b2e3f4, 2026-05-16) ships the rollout
dashboard's empty-state and the ops runbook entry that points at the
admin-CLI escape hatches. Up Next: the per-region rollout-cap work tracked
in #391.
```

Verify before recording verdict: one heading plus one or two flowing-prose paragraphs (or matching the anchor's bullet density if the anchor uses bullets), spelling variant matches the anchor (British or American consistently — no mixed), every PR number from FACTS appears unchanged, every squash hash unchanged (7-char or full), every date unchanged, no preamble, no trailing "this delivers…" / "going forward" / "closes the loop" flourish.

## Calibration notes

This recipe originates from issue #125, filed 2026-05-18, where the issue author had used the same pattern three times in two days across `bonnie-wee-plot` PRs #372, #382, and #383 plus a fourth invocation in flight. Drafting a shipped entry for a long-running plan file is in the README's Fits table at the intersection of "Reformat or rewrite prose" and "Compose structured prose from a fixed list of items" — the recipe operationalises that intersection rather than discovering it.

The four calibration anchors all originate from real observed drifts in the issue author's sessions:

- **Prose-vs-bullets drift** — the prose tier defaults to numbered lists when the input phrasing mentions "three load-bearing decisions" or similar phrasing-with-implicit-enumeration, even when the style anchor uses flowing prose. The recipe ties the prose-vs-bullets choice to the anchor's actual shape rather than to an abstract descriptor.
- **Quiet Americanisation** — `favor`, `behavior`, `utilize` slip in when British spelling is in the anchor. The explicit "detect from the anchor; do NOT default to either" directive plus enumerated examples (`organisation` / `behaviour` / `optimise`) anchors the rule to literal token patterns the model's prior can latch onto.
- **Trailing-padding sentence** — the SKILL.md anti-padding directive applies, and is re-asserted in this recipe specifically because roadmap entries are factual logs where a closing "ensuring proper…" or "…closing the gap" tail reads especially wrong. The participial-AND-declarative enumeration mirrors `commit-message.md`'s post-T4 calibration history.
- **PR-number / commit-hash typos** — at least one near-miss in the issue author's sessions where the model rounded `e9c560c` slightly. The recipe makes ID preservation a non-negotiable directive with a literal example.

### 2026-05-18 — initial recipe, dogfooding pending

This recipe ships without a same-repo HIT verdict yet. The empirical anchor is the three `bonnie-wee-plot` sessions the issue author named (PRs #372, #382, #383) plus the documented drift patterns above. The first delegate-to-ollama session that uses this recipe should record a HIT/MISS via `scripts/delegate-feedback.sh` so the recipe's local calibration history starts accumulating. If the first dogfood surfaces a fifth drift not enumerated above, follow the established pattern: extend the directive with a v5/v7 contrastive Wrong/Correct one-shot grounded in the failing input, add an entry under this section dating the change, and ensure the new guard names the failure shape literally rather than abstractly.

The issue body offered to PR the recipe; this recipe takes the alternative branch — translating the draft into the calibrated shape inline with the rest of the library so the four anchors are encoded as directive-rule-plus-example pairs rather than left as freeform suggestions.
