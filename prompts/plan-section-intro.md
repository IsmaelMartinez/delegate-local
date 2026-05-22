---
inputs:
  style_anchor: string
  phase_facts: string
---
# plan-section-intro

## When to use

The user is drafting a forward-looking intro paragraph for a new phase or section in a long-running project plan / roadmap document (typically `ROADMAP.md`, `docs/plans/current-plan.md`, or similar). The shape is one short flowing-prose paragraph that frames what the phase is about, what it ships, and what the research anchors or constraints are — sitting at the top of the phase, ahead of any sub-track bullets. The recipe is the right fit when the caller can supply two things: a verbatim style anchor (an existing phase intro from the same file) plus a structured fact list (the new phase's name and number, scope statement, research anchors or constraints if any, planned sub-tracks if any).

For drafting a single past-tense "shipped" entry rather than a forward-looking intro, use `roadmap-entry.md` — that recipe is calibrated for shipped entries with PR numbers, squash hashes, and dates, where this recipe targets planning prose ahead of any work. The two recipes are deliberately split because the failure modes are different: shipped entries drift toward inventing PR numbers, while forward-looking intros drift toward echoing the style anchor as content.

## Context to gather first

Run both of these before invoking the recipe:

```bash
# 1. Verbatim style anchor — an existing phase intro from the target plan
#    file. Extract the first 1-2 paragraphs under the heading, including the
#    paragraph that frames the phase but NOT the sub-track bullet list. The
#    awk pattern below matches `## Phase N — <title>` headings and prints
#    every line until the first `- ` bullet or the next `## ` heading,
#    whichever comes first; adjust the pattern to your plan file's heading
#    convention before running.
awk '
  /^## Phase / { if (in_phase) exit; in_phase=1; print; next }
  in_phase && /^## / { exit }
  in_phase && /^- / { exit }
  in_phase { print }
' ROADMAP.md

# 2. Structured fact list — the new phase's name and number, scope
#    statement, research anchors or constraints (if any), and planned
#    sub-tracks (if any). Author this in a scratch file:
cat <<'EOF' > /tmp/phase-facts.md
PHASE: Phase NN — <short title>

SCOPE: <one or two sentences naming what this phase is about, what it ships,
  and why it sits where it sits in the roadmap>

ANCHORS: <one or two sentences naming the research, prior phase, or evidence
  that motivates this phase — or omit the section entirely if there isn't one>

SUB-TRACKS (optional): <if this phase splits into named sub-tracks, list each
  one as `Track X — <short label>: <one sentence>`. Omit if there are no sub-tracks.>
EOF
```

The style anchor is load-bearing. Forward-looking intros drift toward whichever shape the model defaults to (clipped declarative sentences with closing flourishes) regardless of the project's actual voice. The verbatim block lets the model copy the spelling variant, the prose-vs-bullets density, the technical density, and the paragraph rhythm without an abstract description doing that work. The structured fact list keeps the model from inventing scope — every phrase in the output should trace back to something in the facts.

## Prompt template

```
Draft a forward-looking ROADMAP phase intro paragraph. Do not invent phases or PR numbers.

Output ONE short flowing-prose paragraph (or 1-2 paragraphs if the STYLE
ANCHOR below uses two paragraphs) that introduces the new phase, names what
it ships, and references the anchors or constraints from the FACTS block.
NO bullet lists, NO sub-track enumeration — sub-tracks belong below this
intro in the actual document, not inside the intro itself.

The STYLE ANCHOR below is provided ONLY to calibrate voice, length, British
vs American spelling, prose-vs-bullets balance, technical density, and
paragraph rhythm. Do NOT echo any of its sentences. Do NOT repeat its scope.
Do NOT begin the output by summarising what the anchor was about. Produce a
NEW intro paragraph for the NEW phase named in the FACTS block. The anchor
is style guidance, not content.

Wrong: "Phase 8 was about telemetry. Phase NN will [new content]…"
Wrong: "[verbatim anchor paragraph]. In contrast, Phase NN…"
Correct: "[NEW paragraph describing only Phase NN, in the anchor's voice]"

Match the STYLE ANCHOR exactly in: spelling variant (American vs British),
prose-vs-bullets balance, paragraph length, technical density, and tone.
If the anchor uses British spelling (organisation, behaviour, optimise), use
British. If it uses American (organization, behavior, optimize), use American.
Detect from the anchor; do NOT default to either.

Stop after the substantive content sentences. Do NOT add a closing sentence
that restates the point. Restating happens in two shapes, both rejected:
participial form (", ensuring that…", ", enabling…", ", allowing…",
", providing…", ", keeping…", ", reflecting…", ", supporting…") and
declarative form ("This ensures…", "This enables…", "This prevents…",
"This guarantees…", "This delivers…", "This is crucial/essential",
"…closing the gap in X", "…closes the loop", "…going/moving forward").
Forward-looking phase intros are factual planning prose where closing
"ensuring proper rollout" or "going forward" sentences read especially wrong.

Preserve every phase number, PR reference, and identifier from the FACTS
block exactly as written. Do NOT invent phase numbers; do NOT invent PR
numbers; do NOT round identifiers. If the FACTS block names "Phase 13" and
"issue #200", the output must contain those tokens unchanged.

Output ONLY the intro paragraph(s) itself, no preamble, no heading line,
no "Here's the intro:" prefix.

=== STYLE ANCHOR (verbatim — calibrates voice and shape ONLY, do NOT echo) ===
{{style_anchor}}

=== FACTS (the new phase's content — preserve every identifier exactly) ===
{{phase_facts}}
```

## Variables

- `{{style_anchor}}` — verbatim block, an existing phase intro from the same plan file. Load-bearing for voice and shape. Without this anchor the prose-tier default is short declarative sentences with closing flourishes regardless of the project's actual prose density. The anti-echo directive in the template keeps the model from treating this block as content; the verbatim extraction keeps the spelling variant, the prose-vs-bullets balance, and the paragraph rhythm intact.
- `{{phase_facts}}` — structured fact list authored by the agent. Conventional shape: a `PHASE:` line naming the new phase number and title, a `SCOPE:` block describing what this phase is about, an optional `ANCHORS:` block naming research or prior-phase evidence that motivates the work, and an optional `SUB-TRACKS:` block listing planned sub-tracks. The model converts this into prose; the agent's job is to make the facts accurate and complete.

## Invocation

```bash
PLAN_FILE=ROADMAP.md
ANCHOR=$(awk '
  /^## Phase / { if (in_phase) exit; in_phase=1; print; next }
  in_phase && /^## / { exit }
  in_phase && /^- / { exit }
  in_phase { print }
' "$PLAN_FILE")
bash scripts/delegate.sh --recipe plan-section-intro \
  --var style_anchor="$ANCHOR" \
  --var phase_facts="$(cat /tmp/phase-facts.md)" \
  prose "Match the STYLE ANCHOR's voice and shape only. Do NOT echo its sentences. Produce a NEW intro for the phase named in FACTS."
```

The trailing prompt arg reinforces the highest-signal rule — the anti-echo directive — because that was the failure mode that triggered this recipe. The recipe template carries the structural directives and the anti-padding guard.

## Anti-hallucination guards (each line addresses a real observed drift)

- "The STYLE ANCHOR below is provided ONLY to calibrate voice... Do NOT echo any of its sentences" with the Wrong/Correct contrastive example — addresses the 2026-05-21 MISS where the prose-tier model interpreted a verbatim Phase 8 anchor as content and emitted it verbatim at the head of the output before appending the new Phase 11 content. Same v5/v7 directive-rule-plus-example pattern that closed the `(#NN)` gap in `commit-message.md`. The bare "match the style" framing did not bind; the explicit "this is calibration data, not content; do NOT echo" directive plus contrastive examples does.

- "NO bullet lists, NO sub-track enumeration — sub-tracks belong below this intro in the actual document, not inside the intro itself" — addresses the related drift where the model latches onto the `SUB-TRACKS:` fact-list section as a structural cue and emits a bullet list inside the intro paragraph. Sub-track listings belong below the intro in the actual document; the intro should frame them in prose if at all, not enumerate them.

- "Match the STYLE ANCHOR exactly in spelling variant" with an explicit British/American detection rule — same guard as `roadmap-entry.md`'s equivalent line, mirrored here because the failure mode (quiet Americanisation under British source) is identical across both recipes. Plan files lean British in this project; the prose-tier default drifts American without the explicit detect-and-mirror directive.

- "Stop after the substantive content sentences. Do NOT add a closing sentence that restates the point" with both participial AND declarative form enumeration — mirrors the established SKILL.md anti-padding directive. Forward-looking phase intros are factual planning prose where closing "ensuring proper rollout" or "delivering value going forward" sentences read especially wrong (a plan-section intro is framing, not a deliverable summary). The guard names both shapes because `commit-message.md`'s calibration history showed the participial-only version was strictly weaker than the failure modes.

- "Preserve every phase number, PR reference, and identifier from the FACTS block exactly as written" with a concrete example — addresses the same drift `roadmap-entry.md` documents: prose-tier models pattern-match against identifier shapes and occasionally invent adjacent ones (round `#178` to `#180`, drop a phase number that doesn't fit the rhythm). The example clause anchors the rule to a recognisable identifier shape.

- "Output ONLY the intro paragraph(s) itself, no preamble, no heading line" — without this the model wraps in "Here's the intro for Phase 13:" prose plus a `## Phase 13 — Title` heading that has to be stripped. The heading belongs in the document, not in the recipe output; the agent positions the heading separately.

## Expected output shape

```
This phase extends Phase 11's OTLP exporter with workload-aware sampling so
high-volume hosts can keep telemetry coverage representative without inflating
the collector cost. An opt-in sampler, gated behind a new
`DELEGATE_OTEL_SAMPLE_RATE` env var, downsamples successful-delegate spans
proportionally while preserving every feedback span and every exit-status-3
canary failure verbatim, on the principle that anomalies and verdicts are the
load-bearing signals while routine HITs are the long tail. The research anchor
is the Phase 11 dashboard data showing that one workstation generated 70% of
the rolling-week trace volume while contributing nothing to the cross-machine
calibration loop. The phase splits into three independently shippable tracks
covering the sampler implementation, the OTel SDK-compatible header pass-
through, and the dashboard panels that show the sample-rate-adjusted counts.
```

Verify before recording verdict: one short flowing-prose paragraph (or 1-2 if the anchor uses two), spelling variant matches the anchor consistently (no mixed British/American), no echoed sentence from the anchor, no bullet list, no heading line, every identifier from FACTS appears unchanged, no trailing "this delivers…" / "going forward" / "closes the loop" flourish, no preamble.

## Calibration notes

This recipe originates from issue #150, filed 2026-05-22 after a same-day session drafted a forward-looking Phase 11 intro by passing the Phase 8 intro as a verbatim style anchor. The prose-tier model (`qwen3.6:35b-a3b-q8_0`) interpreted the anchor as content to preserve and emitted it verbatim at the head of the output, then appended the new Phase 11 content. The cleanly-usable portion was the second half; the first paragraph had to be stripped by hand. MISS recorded against `ts=2026-05-21T21:56:18Z` with the reason "prose-tier duplicated the verbatim STYLE ANCHOR into the output as content rather than using it as style guidance only".

The failure is the symmetric counterpart to the calibration history `roadmap-entry.md` opens with — that recipe's anchor is also a verbatim block, but its prompt frames the anchor as style guidance with a strong "do NOT echo the anchor; produce a NEW entry" directive. Forward-looking phase intros need the same explicit framing; without it the prose-tier model treats any leading verbatim block as a "preserve this" cue rather than a "match this shape" cue. The recipe lifts the directive-rule-plus-Wrong/Correct-example pattern that closed the `(#NN)` gap in `commit-message.md` and applies it to the echo failure shape: the Wrong example shows the exact bug observed (anchor echoed then new content appended), and the Correct example anchors what the intended output looks like.

The four calibration guards above all originate from real or directly-symmetric observed drifts:

- **Style-anchor echo** — the failure mode that triggered this recipe. The directive frames the anchor as calibration data with an explicit Wrong/Correct contrastive example built from the 2026-05-21 MISS shape.
- **Sub-track enumeration drift** — extrapolated from how prose-tier models latch onto structured fact-list sections as enumeration cues. Same pattern observed in `roadmap-entry.md`'s prose-vs-bullets drift; tying the rule to the anchor's actual shape rather than to an abstract descriptor is the documented fix.
- **Quiet Americanisation** — mirrored from `roadmap-entry.md`'s equivalent guard. The two recipes share the same source style (plan files in this project lean British) and the same prose-tier drift mode, so the guard text is parallel.
- **Trailing-padding sentence** — the SKILL.md anti-padding directive applies, and is re-asserted here specifically because forward-looking phase intros are factual planning prose where a closing "ensuring proper rollout" or "delivering value going forward" tail reads especially wrong. Participial-AND-declarative enumeration mirrors `commit-message.md`'s post-T4 calibration history.

### 2026-05-22 — initial recipe and first dogfood verdict (MISS, two new drifts surfaced)

This recipe shipped with a dogfood against the real Phase 11 intro as STYLE ANCHOR and an invented Phase 13 "Cross-machine calibration aggregation" scope as FACTS, delegated to `qwen3.6:35b-a3b-q8_0` (prose tier) at `ts=2026-05-22T11:12:12Z`. Recorded as MISS. The primary calibration (the anti-echo directive against the STYLE ANCHOR) DID bind — the model did not echo any sentence from the Phase 11 intro into the output, which is the failure mode the recipe was filed against. Two new MISS shapes surfaced that the initial directive set did not name:

- **FACTS-block echo without rephrasing in the anchor's voice.** The model emitted both output paragraphs as near-verbatim copies of the `SCOPE:` and `ANCHORS:` blocks from the fact list rather than rewriting them in the prose voice the STYLE ANCHOR established. The recipe directed "calibrate voice... from the STYLE ANCHOR" but did not explicitly tell the model "rewrite the FACTS content in the anchor's voice; do not copy FACTS prose verbatim". Same compliance-literally-with-the-rule-it-knows pattern that the 2026-05-11 declarative-form extension in `commit-message.md` was filed against — the model honoured the anti-echo rule against the STYLE ANCHOR (the named target) and silently passed FACTS through as a separate channel that no rule covered. The fix shape is a symmetric directive: the STYLE ANCHOR is voice calibration AND the FACTS block is content to rewrite (not copy). Deferred to a separate iteration rather than bundled into this PR — the recipe's primary calibration goal (anti-echo on STYLE ANCHOR) is achieved, and the FACTS-echo failure mode is a less severe shape (the content is correct, just stylistically flat) than the STYLE-ANCHOR echo it replaced.

- **Heading line emitted despite "no heading line" directive.** The output prepended `Phase 13 — Cross-machine calibration aggregation` as a heading line above the prose paragraphs, even though the template body said "Output ONLY the intro paragraph(s) itself, no preamble, no heading line". The directive was buried at the end of the "Output ONLY..." line rather than promoted to its own line; the model treated the heading as natural framing context the directive permitted. Same shape as the SUBJECT_LEN drift in `commit-message.md` — bare negation in a long directive sentence is strictly weaker than a promoted standalone rule. The fix shape is to promote the heading prohibition to its own line in the directive block with a Wrong/Correct contrastive example built from this dogfood's exact output. Same deferral — primary calibration goal achieved, secondary drift logged for the next iteration.

Both new MISS shapes are filed against the recipe's calibration history so the next iteration has a literal target rather than re-discovering them from scratch. Pattern follows the established library discipline: every recurring HIT graduates to a guard, every MISS that names a new failure mode gets one logged. The two open drifts will graduate to directive-rule-plus-Wrong/Correct-example guards on the next session that produces a confirming second MISS observation against the same shapes — single observations occasionally turn out to be session-specific rather than pattern-level, so the library waits for a second confirming data point before extending the directive set.

The Phase 12 Track B `inputs:` frontmatter block (`style_anchor: string`, `phase_facts: string`) declares both inputs as required strings so `delegate.sh --recipe plan-section-intro` validates them pre-flight rather than letting a missing `--var` surface later as an unsubstituted-placeholder error. The identity-and-scope opener at the top of the template body ("Draft a forward-looking ROADMAP phase intro paragraph. Do not invent phases or PR numbers.") consolidates the recipe's two most-repeated forbidden actions — invent-phases and invent-PR-numbers — into one upfront sentence the model encounters before the structural directives. Both conventions follow the worked example in `prompts/commit-message.md`'s 2026-05-22 calibration entry.
