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

NO-HEADING-LINE (priority 1, non-negotiable): the first character of your
output must be the first letter of the first sentence of the paragraph.
NOT `#`, NOT `*`, NOT `-`, NOT a bullet marker, NOT a numbered-list prefix,
NOT a heading line of any depth (`#`, `##`, `###`, `####`). Do NOT emit
`### Phase NN — title`, `## Phase NN — title`, or any formatting prefix
before the paragraph. The agent positions the heading separately in the
target document; the recipe output is the prose paragraph only.
Wrong (heading line prepended, observed on dogfood ts=2026-05-22T11:12:12Z
and reproduced on dogfood ts=2026-05-22T11:43:18Z):
  ### Phase 13 — Cross-machine calibration aggregation

  This phase extends Phase 11's OTLP exporter with…
Correct (paragraph only, heading omitted): the output begins with
  `This phase extends Phase 11's OTLP exporter with…` and contains no
  `###`/`##`/`#` line anywhere.

The STYLE ANCHOR below is provided ONLY to calibrate voice, length, British
vs American spelling, prose-vs-bullets balance, technical density, and
paragraph rhythm. Do NOT echo any of its sentences. Do NOT repeat its scope.
Do NOT begin the output by summarising what the anchor was about. Produce a
NEW intro paragraph for the NEW phase named in the FACTS block. The anchor
is style guidance, not content.

Wrong: "Phase 8 was about telemetry. Phase NN will [new content]…"
Wrong: "[verbatim anchor paragraph]. In contrast, Phase NN…"
Correct: "[NEW paragraph describing only Phase NN, in the anchor's voice]"

FACTS-BLOCK-REPHRASE (priority 2, non-negotiable): each line under SCOPE,
ANCHORS, and SUB-TRACKS in the FACTS block is a CONSTRAINT, not a sentence
to copy. Restate every fact in your own voice using the STYLE ANCHOR's
vocabulary and rhythm. Do NOT include any FACTS sentence verbatim or
near-verbatim in the output. The FACTS block tells you WHAT the phase is
about; the STYLE ANCHOR tells you HOW to phrase it. Both channels apply
simultaneously — the anti-echo rule applies to the FACTS block too, not
only to the STYLE ANCHOR.
Wrong (verbatim FACTS-sentence echo, observed on dogfood
ts=2026-05-22T11:43:18Z where the SCOPE last sentence was passed through
unchanged): FACTS contains `SCOPE: The aggregator is opt-in, single-user,
and writes to a local rollup file.` and the output paragraph contains the
sentence `The aggregator is opt-in, single-user, and writes to a local
rollup file.` verbatim.
Correct (rephrased in anchor's voice): the same fact is rewritten as
`An opt-in single-user aggregator collects each host's rollup into a
local file, keeping the cross-machine path under one workstation's
control.` — same content, the anchor's prose rhythm.

Match the STYLE ANCHOR exactly in: spelling variant (American vs British),
prose-vs-bullets balance, paragraph length, technical density, and tone.
If the anchor uses British spelling (organisation, behaviour, optimise), use
British. If it uses American (organization, behavior, optimize), use American.
Detect from the anchor; do NOT default to either.

Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.

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

- NO-HEADING-LINE (priority 1, non-negotiable) with positive-shape directive ("the first character of your output must be the first letter of the first sentence") and Wrong/Correct contrastive example grounded in the actual 2026-05-22 dogfood outputs — addresses the heading-line drift confirmed across two independent dogfoods (ts=2026-05-22T11:12:12Z and ts=2026-05-22T11:43:18Z, both verdicts recorded MISS at ts=2026-05-22T11:12:47Z and ts=2026-05-22T11:43:47Z respectively). The original buried negation at the end of the "Output ONLY..." line did not bind; promoting the prohibition to its own priority-1 directive line with a v5/v7 directive-rule-plus-example pattern follows the discipline the commit-message recipe's `(#NN)` and SUBJECT_LEN iterations established. The positive-shape framing ("first character must be the first letter of the first sentence — NOT `#`, NOT `*`, NOT a bullet marker") gives the model a concrete construction rule rather than relying on the model to infer the prohibition from a negated descriptor.

- FACTS-BLOCK-REPHRASE (priority 2, non-negotiable) with Wrong/Correct contrastive example — addresses the FACTS-block-echo drift observed on dogfood ts=2026-05-22T11:12:12Z (both output paragraphs near-verbatim copies of the SCOPE/ANCHORS blocks) and reproduced in weaker form on dogfood ts=2026-05-22T11:43:18Z (one SCOPE sentence passed through unchanged). The original directive frame told the model to calibrate voice from the STYLE ANCHOR but did not name the FACTS block as content-to-rewrite; the model honoured the anti-echo rule against the STYLE ANCHOR (the named target) and silently passed FACTS through as a separate channel that no rule covered. Same compliance-literally-with-the-rule-it-knows pattern that the 2026-05-11 declarative-form extension in `commit-message.md` was filed against. The fix names the FACTS block as a constraint-to-rephrase, makes the anti-echo rule symmetric across both channels (STYLE ANCHOR for voice, FACTS for content), and anchors the rule to the actual observed Wrong shape (the verbatim SCOPE last sentence from the second dogfood).

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

### 2026-05-22 — second dogfood verdict (MISS, confirms heading-line drift; FACTS-echo partial)

A PR-review-time dogfood against the real Phase 8 intro as STYLE ANCHOR and an invented Phase 14 "Cross-host metrics aggregation" scope as FACTS, delegated to `qwen3.6:35b-a3b-q8_0` (prose tier) at `ts=2026-05-22T11:43:18Z`. Recorded as MISS. Same primary-calibration result as the first dogfood: the anti-echo directive against the STYLE ANCHOR DID bind (no Phase 8 sentence appeared verbatim in the output). The two drifts named in the first dogfood entry reappeared with different severities:

- **Heading line emitted despite "no heading line" directive — confirming second observation.** The output prepended `Phase 14 — Cross-host metrics aggregation (single user, multi-machine)` as a heading line above the prose paragraph, exact same shape as the first dogfood's `Phase 13 —` heading. Two independent dogfoods on different invented FACTS payloads produced the identical drift, which clears the "single observation might be session-specific" bar the previous entry named. The drift is pattern-level rather than session-specific; the next recipe iteration should promote the heading prohibition to a standalone directive line with a Wrong/Correct contrastive example built from these two observations (e.g. Wrong: `Phase 14 — Title\n\n[prose]`, Correct: `[prose only, no heading]`). Same v5/v7 directive-rule-plus-example pattern that closed the `(#NN)` gap in `commit-message.md`.

- **FACTS-block echo without rephrasing — weaker second observation (1/4 sentences near-verbatim vs 2/2 in dogfood 1).** The second dogfood's output rewrote three of four FACTS-derived sentences in prose voice and left one (the closing "The aggregator is opt-in, single-user…") near-verbatim from the SCOPE block. The first dogfood was more severe (both paragraphs near-verbatim). The directional improvement may reflect the FACTS block's structural difference (this dogfood's SCOPE was a single sentence, dogfood 1's SCOPE was richer) rather than calibration progress; a third dogfood with a SCOPE block more comparable to dogfood 1's would discriminate. The drift remains logged for future iteration but the second observation is not as cleanly confirming as the heading-line drift.

Both dogfoods together establish the heading-line drift as the higher-priority guard to add next; the FACTS-echo drift remains a single strong observation plus one partial. The recipe's calibration history now matches the library discipline pattern (`commit-message.md`'s pre-PR-#85 anti-padding work waited for repeated declarative-form evidence before promoting it to a guard separate from the participial one).

### 2026-05-22 — heading-line and FACTS-echo tightening

Two confirming observations across the first two dogfoods (ts=2026-05-22T11:12:12Z with feedback verdict at ts=2026-05-22T11:12:47Z; ts=2026-05-22T11:43:18Z with feedback verdict at ts=2026-05-22T11:43:47Z) cleared the recipe's own calibration-notes-stated bar for sharpening: pattern-level rather than session-specific, the second observation reproduced the same failure shape as the first. The heading-line drift is the load-bearing failure — both dogfoods emitted `### Phase NN — title` as the first output line despite the original buried `no heading line` directive at the end of the "Output ONLY..." line. The FACTS-echo drift is the weaker pattern — first dogfood was two paragraphs near-verbatim from the FACTS block, second dogfood was one SCOPE-last-sentence passed through unchanged.

The fix applies the v5/v7 directive-rule-plus-Wrong/Correct-example pattern that closed the `(#NN)` gap in `commit-message.md` and the OMIT-EMPTY gap in `summarise-issue.md`, promoted to two priority-ordered standalone directives at the head of the template body:

- **NO-HEADING-LINE (priority 1).** Recast from the buried negation into a promoted directive line with a positive-shape construction rule ("the first character of your output must be the first letter of the first sentence — NOT `#`, NOT `*`, NOT a bullet marker, NOT a numbered-list prefix") plus a Wrong/Correct contrastive example grounded in the actual observed failure (the `### Phase 13 — Cross-machine calibration aggregation` heading from the first dogfood, cited verbatim alongside the second dogfood's `Phase 14 —` reproduction). Positive shape + Wrong/Correct contrastive together rather than either alone — the positive shape gives the model a concrete construction rule, the Wrong/Correct grounds it in real failure rather than abstract prohibition.

- **FACTS-BLOCK-REPHRASE (priority 2).** New directive naming the FACTS block as a constraint-to-rephrase rather than content to copy. The original template only framed the STYLE ANCHOR as calibration data and did not name the FACTS block as a separate channel subject to its own anti-echo rule; the model honoured the directive it knew (anchor anti-echo bound on both dogfoods) and silently passed FACTS through. The fix makes the anti-echo rule symmetric across both channels and anchors the Wrong shape to the actual observed verbatim sentence from the second dogfood's SCOPE block. Severity is weaker than the heading-line drift (the recipe lists this as priority 2 rather than priority 1), but the second observation still clears the "two confirming data points" bar the library applies before promoting a failure mode to a guard.

The two new directives sit at the head of the structural-directives block, ahead of the existing STYLE-ANCHOR anti-echo directive, so they survive any future preamble inflation that nudges the model's attention away from later content in the template. Same directive-promotion pattern that `commit-message.md`'s 2026-05-10 `(#NN)` iteration applied to its own buried-negation history.

If the heading-line drift recurs a third time after both v5/v7-pattern guards have been applied, the next iteration's plan is to either gate the recipe to a specific known-good model rather than a tier, or accept the failure mode as fundamental and document a post-processing strip in the recipe's invocation example. The third-dogfood result below answers the empirical question.

### 2026-05-22 — third dogfood verdict (HIT on NO-HEADING-LINE, MISS on FACTS-BLOCK-REPHRASE)

The post-sharpening dogfood ran against the real Phase 9 intro as STYLE ANCHOR and an invented Phase 15 "Recipe coverage gap auto-discovery" scope as FACTS, delegated to `qwen3.6:35b-a3b-q8_0` (prose tier) at `ts=2026-05-22T12:53:05Z` (verdict recorded MISS at the same ref_ts). Both anchor and facts were intentionally distinct from the first two dogfoods (Phase 11 anchor + Phase 13 facts on dogfood 1; Phase 8 anchor + Phase 14 facts on dogfood 2) so the heading-line and FACTS-echo drifts could be discriminated from session-specific artefacts. The two new directives split cleanly on the empirical gate:

- **NO-HEADING-LINE — HIT.** The output's first character was the letter `P` (the start of `Phase 15 closes the recipe coverage gap by automating…`), with no `### Phase 15 —` heading, no `**Phase 15:**` markdown bold prefix, no bullet marker, no preamble. Both prior dogfoods produced exactly the prepended `### Phase NN — title` heading the recipe was filed against; the third dogfood under the promoted priority-1 directive plus Wrong/Correct contrastive example produced none. Same v5/v7 directive-rule-plus-example pattern that closed the `(#NN)` gap in `commit-message.md` after a 3-of-3 MISS reproduction — promoted to priority 1, grounded in the actual observed Wrong shape, paired with a positive-shape construction rule ("the first character of your output must be the first letter of the first sentence"). Single-dogfood evidence rather than the 5-of-5 reproduction the `commit-message.md` PR #74 fix measured, but the directional signal is strong: the buried negation did not bind on either prior dogfood, the promoted directive bound on the first post-sharpening dogfood.

- **FACTS-BLOCK-REPHRASE — MISS.** The output contained at least eight distinct sentences or clauses near-verbatim from the FACTS block: the SCOPE statement "scan the rolling 30-day MISS window for task-shape clusters that no existing recipe covers" appeared unchanged; the ANCHORS sentence "The Phase 8 recurring-MISS nudge (#91) established the directive-rule shape the new gap-detector follows" appeared unchanged; the three SUB-TRACK descriptions ("extends `scripts/audit-metrics.sh` with a clustering pass over MISS reasons that match no current `prompts/<task>.md` filename token", "pre-targets the `prompt-pattern` label and pre-fills the issue body from the cluster's representative MISS reasons", "introduces the `DELEGATE_FEEDBACK_NO_GAP_NUDGE=1` opt-out env var") were each near-verbatim from the SUB-TRACKS list, only superficially rewritten into third-person enumeration. The model honoured the now-promoted NO-HEADING-LINE rule and silently passed FACTS content through as a separate channel — same compliance-literally-with-the-rule-it-knows pattern that the original recipe's STYLE-ANCHOR anti-echo directive triggered when FACTS was not yet named as a parallel constraint. The new FACTS-BLOCK-REPHRASE directive named the FACTS block as constraint-to-rephrase, but its Wrong/Correct example anchored only ONE specific verbatim sentence ("The aggregator is opt-in, single-user…") rather than describing the family of paraphrases the model produces. The single-literal anchor functions as a copyable crib — the model recognises THAT specific sentence as the rejected shape and avoids it, but does not generalise the rule to other FACTS sentences of similar shape. Same verbatim-crib hypothesis the `summarise-issue.md` 2026-05-22 PR #180 review-pass mitigation surfaced and fixed via the family-of-paraphrases framing.

The split outcome is informative rather than contradictory. The two failure modes have different shapes: heading-line drift is a single literal token prepended to the output (an easy-to-anchor structural prohibition), where FACTS-block echo is a content-mapping decision the model makes per-sentence (a semantic rephrase requirement). The promoted-directive-plus-Wrong/Correct pattern that closed the heading-line gap is necessary but not sufficient for the FACTS-echo gap — the FACTS-echo directive needs a different shape, mirroring how `summarise-issue.md`'s OMIT-EMPTY-SECTION rule needed the family-of-paraphrases framing on PR #180 after the substring-blocklist and positive-form recasts both failed. The next iteration's FACTS-BLOCK-REPHRASE refinement should replace the single-literal Wrong anchor with a family-of-paraphrases description listing the actual observed near-verbatim sentences from this dogfood, framing them as a shape pattern rather than a specific forbidden string.

The heading-line drift can be declared converged on single-dogfood evidence (the failure shape was binary — emit a heading or not — and the post-sharpening dogfood unambiguously did not emit one). The FACTS-echo drift requires a fourth dogfood after the family-of-paraphrases refinement to confirm whether the same pattern that closed the OMIT-EMPTY-SECTION verbatim-crib bypass on `summarise-issue.md` transfers to this recipe. The deferred action item is filed in the calibration history rather than blocking this PR — the heading-line sharpening is the higher-severity failure mode (two dogfoods produced it; one PR-iteration fix closed it), and the FACTS-echo refinement has a clear directional pattern from `summarise-issue.md`'s parallel calibration history rather than needing fresh discovery.
