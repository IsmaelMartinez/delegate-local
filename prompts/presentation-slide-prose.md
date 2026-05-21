# presentation-slide-prose

## When to use

The agent is building an HTML (or markdown-rendered) presentation deck about a codebase and needs the 2-4 sentence narrative paragraph that lives on each prose-heavy slide. The main agent owns the slide layout, tables, code blocks, headings, exact numbers, and ADR lists; what gets delegated is the flowing paragraph itself, given the slide title and a fact list both authored by the agent. N independent slides fan out into N parallel `delegate.sh` invocations rather than one bundled prompt.

Distinct from adjacent recipes:

- `doc-section.md` produces a paragraph for a technical doc (runbook, ADR, README section). Same prose-tier shape, same anti-padding directive, but doc-section's contextual frame is reference documentation. This recipe's frame is a slide — sentence cap is tighter, the verbatim-fact constraint is harder (slides cannot afford a hallucinated phase number), and parallel-invocation is the default rather than an option.
- `file-summary.md` is one sentence about a whole document.
- `summarise-diff.md` / `summarise-issue.md` summarise existing content.

Typical inputs are a 3-10 word slide title and 4-12 bulleted facts; typical output is 2-4 sentences of plain prose.

## Context to gather first

The agent collects three things before each invocation:

1. The slide's title line, verbatim as it appears in the deck.
2. The fact list the paragraph must cover. Inline every load-bearing detail (phase names, PR numbers, dates, milestone labels) verbatim — the model is not asked to summarise from a longer source, only to weave the supplied facts into prose.
3. The sentence cap: 2, 3, or 4 depending on slide density.

No git or repo introspection is needed at delegation time — the agent does the gathering, the recipe does the prose-weaving. If the underlying fact-gathering produced a long source document, summarise it down to a bullet list *before* invoking; do not pipe the source document in.

## Prompt template

```
Write a {{sentence_count}}-sentence narrative paragraph for a presentation slide titled: {{slide_title}}.

Plain UK English. No bullets, no headings, no bold, no inline code, no markdown. Output ONLY the paragraph itself, nothing else.

HARD RULES (non-negotiable; each addresses a real past MISS):

1. Sentence cap is {{sentence_count}}. Do not exceed it.

2. List-completeness guard. If the facts list below mentions N distinct items (phases, components, steps, milestones), your output MUST reference all N. If you cannot fit all N within {{sentence_count}} sentences, reply with a single line beginning with REFUSE: explaining which item you could not include. Do NOT silently drop an item.

3. Anti-padding directive. Stop after the content sentences. Do not add a closing sentence that restates the point. Do not append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting") that summarises a downstream effect or implication. End on a finite verb introducing new content, or stop.

Wrong (drops one of four items from the fact list — exactly the failure mode the list-completeness guard blocks):
"The kitchen renovation began with demolition of the existing cabinets and counters in March. Electrical and plumbing rough-in followed in April once the studs were exposed. New cabinets and the quartz countertop were installed in June, with the backsplash and final paint completing the project."

Correct (covers all four phases — demolition, rough-in, drywall-and-flooring, cabinets-and-finish — within three sentences):
"The kitchen renovation began with demolition of the existing cabinets and counters in March, followed by electrical and plumbing rough-in once the studs were exposed. Drywall and engineered-oak flooring went in over five weeks in May. New cabinets and the quartz countertop were installed in June, with the backsplash and final paint completing the project."

=== Facts you may use (do not invent others; cover every distinct item or REFUSE) ===
{{facts}}
```

## Variables

- `{{slide_title}}` — the slide's title line, agent-authored. Quoted verbatim from the deck so the model anchors on the same framing the reader will see.
- `{{facts}}` — bulleted list of verbatim facts to use. Authored by the agent. Inline every load-bearing detail.
- `{{sentence_count}}` — 2, 3, or 4. The cap is non-negotiable for the model.

## Invocation

Single slide:

```bash
bash scripts/delegate.sh --recipe presentation-slide-prose \
  --var slide_title="Roadmap so far" \
  --var sentence_count=3 \
  --var facts="$(cat <<'FACTS'
- Phase 1 shipped the Bedrock PoC on 5 repos with OIDC auth.
- Phase 1.5 added per-service cost attribution via Bedrock application inference profiles and tuned suggestion thresholds.
- Phase 2 shipped interactive slash commands via a capability-minimal Lambda webhook shim (no Bedrock IAM) with shared-secret, replay, and access-level checks.
- Phase 3 added /review /improve /analyze /add_docs /update_changelog as interactive commands.
- 2026-05-06 milestone: PoC feature-complete. Three WAR iterations followed: observability and alarms, security hardening, Terraform standards.
FACTS
)" \
  prose "Cover every phase listed. Stop after the content sentences."
```

Parallel fan-out across N slides — independent atomic calls, NOT one bundled prompt. The verdict-nudge contamination caveat applies here (issue #139, fix in PR #140): parallel jobs sharing a TTY can interleave nudge output across delegations. Either pipe via the new TTY-detection behaviour (`delegate.sh` skips the nudge when stderr is not a TTY, so `2>/dev/null` or any pipe suppresses it cleanly), or set `DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE=1` per call. The pattern below uses the env-var approach so output ordering is deterministic even when nudges are wanted on serial calls:

```bash
# Fan out six slides in parallel. Each slide's vars live in slide-<n>.env files
# that the agent prepared from the deck source. Background each call, wait for
# all to finish, then record verdicts individually once the user has reviewed.
for n in 1 2 3 4 5 6; do
  (
    set -a; . "build/slide-$n.env"; set +a
    DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE=1 \
    bash scripts/delegate.sh --recipe presentation-slide-prose \
      --var slide_title="$SLIDE_TITLE" \
      --var sentence_count="$SENTENCE_COUNT" \
      --var facts="$FACTS" \
      prose "Cover every fact listed. Stop after the content sentences." \
      > "build/slide-$n.txt"
  ) &
done
wait
```

xargs alternative for one-liner fan-out:

```bash
printf '1\n2\n3\n4\n5\n6\n' | xargs -n1 -P6 -I{} \
  sh -c 'DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE=1 bash scripts/delegate.sh \
    --recipe presentation-slide-prose \
    --var slide_title="$(jq -r .title build/slide-{}.json)" \
    --var sentence_count="$(jq -r .sentences build/slide-{}.json)" \
    --var facts="$(jq -r .facts build/slide-{}.json)" \
    prose "Cover every fact listed. Stop after the content sentences." \
    > build/slide-{}.txt'
```

After review of each slide's output, record the verdict against the matching delegate row using `--ts`:

```bash
bash scripts/delegate-feedback.sh hit
# or pin to a specific row from a parallel batch:
bash scripts/delegate-feedback.sh --ts 2026-05-20T22:01:03Z hit
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "Plain UK English. No bullets, no headings, no bold, no inline code, no markdown" — the prose tier defaults to bullet lists for "narrative paragraph from a fact list" prompts when the fact list itself is bulleted. The model copies the input shape unless the output shape is named explicitly.
- The sharpened anti-padding directive (HARD RULE 3) — the bare `Stop after the content sentences. Do not add a closing sentence that restates the point.` from SKILL.md reduces but does not eliminate the closing-recap and trailing-participial failure modes (`doc-section.md` calibration notes documented this on 2026-05-20; PR #138 sharpened the directive). The verbatim text adopted here adds the participial-clause prohibition with example triggers ("-ing", "supported by", "leading to", "ensuring", "reflecting") and the positive end-condition ("End on a finite verb introducing new content, or stop"). Same v5/v7 directive-rule pattern from `experiments/sessions/2026-05-03-security-review-delegation/` — keyword-triggered hard rules outperform abstract "don't pad" prose.
- HARD RULE 2 (list-completeness guard with REFUSE hatch) — new for this recipe. The 2026-05-20 dogfood batch produced 6 of 6 HIT against `qwen3.6:35b-a3b-q8_0` but slide 10 silently dropped Phase 3 from a 4-phase narrative even though all four phases were inlined in the prompt. The guard names the failure shape explicitly ("If the facts list mentions N distinct items, your output MUST reference all N") and offers the REFUSE hatch from SKILL.md's adversarial-chain pattern as the honest alternative to silent dropping. Same REFUSE-hatch-plus-verify pattern as the v8 adversarial probes — see "Calibration notes" for the verification step the recipe-caller still owns.
- One-shot example uses a deliberately off-domain pair (kitchen renovation phases) so the example does not leak any codebase-related framing into the slide topic. The Wrong/Correct pair walks through the exact failure mode the list-completeness guard catches: the Wrong version omits "drywall and flooring" from a 4-phase renovation timeline; the Correct version covers all four within the same sentence count. The contrastive anchor is grounded in a concrete failure shape rather than a paraphrase, same approach `doc-section.md` and `commit-message.md` take.
- "do not invent others; cover every distinct item or REFUSE" on the facts fence — the prose tier sometimes invents a connecting fact ("phase 2 enabled phase 3 by stabilising the auth surface") that reads plausibly but is not in the input. The fence text plus the list-completeness guard together close that gap: invent nothing, drop nothing, refuse if neither is possible.

## Expected output shape

```
<2 to {{sentence_count}} sentences of flowing prose, plain UK English, no markup,
 no opening "This slide…" filler, no closing recap, no trailing participial
 padding clause, every distinct item from the facts list referenced>
```

OR, when the list-completeness guard fires:

```
REFUSE: <one-line explanation naming the specific item that could not be included within the sentence cap>
```

Verify before recording verdict via `bash scripts/delegate-feedback.sh hit|miss [reason]`:

- Sentence count is ≤ `sentence_count`.
- Every distinct item from `{{facts}}` is referenced in the paragraph, either by name or by a verbatim phrase from the bullet. **Do not trust the absence of a REFUSE line as proof of coverage — verify item-by-item.** Same independent-signals discipline as the v8 REFUSE-hatch pattern in SKILL.md: a model can produce a confident paragraph that silently drops one item just as readily as a model can produce a REFUSE line paired with a non-compliant patch.
- The final sentence does not end with a participial clause (`-ing` form), `supported by`, `leading to`, `ensuring`, or `reflecting` followed by a downstream-effect summary.
- The final sentence does not paraphrase or restate an earlier sentence.
- No bullets, no headings, no `**bold**`, no inline code fences around plain prose.

If the final sentence trips any of the above, hand-strip it and record the verdict as `miss` with a reason naming the specific trigger so the recipe's calibration notes can grow. If the paragraph silently drops an item, record the verdict as `miss` with a reason naming the dropped item — that signal is what graduates the list-completeness guard into a deterministic scorer later.

## Calibration notes

This recipe is distilled from the 2026-05-20 presentation-deck session that produced six parallel `delegate.sh prose` invocations against `qwen3.6:35b-a3b-q8_0`, all six logged HIT but slide 10 had a list-completeness MISS that drove the new guard. Metrics rows are clustered around `2026-05-20T22:01:03Z` and visible via `bash scripts/metrics-summary.sh --tail 30`.

### 2026-05-20 — session that surfaced the pattern (issue #137)

The session built a six-slide HTML deck about a codebase. Each slide's prose-heavy paragraph was delegated in parallel, with the slide title and a verbatim fact list inlined into each prompt. Five slides came back HIT verbatim. The sixth (slide 10) came back with three plausible sentences that referenced Phase 1, Phase 2, and Phase 4 from a 4-phase narrative — Phase 3 was silently dropped despite being explicitly listed in the `{{facts}}` bullet block. The model produced no REFUSE line and gave no hint of the omission; the failure was caught only on visual review of the rendered deck.

- Metrics rows around `2026-05-20T22:01:03Z` — six parallel prose-tier invocations, all logged. Five verdicts recorded as HIT verbatim; the slide-10 row recorded as MISS with reason `silently dropped Phase 3 from 4-phase narrative — no REFUSE, no hint`. That MISS is what graduated this pattern into a recipe rather than a one-off fix.

### Provenance of each guard

| Guard | Source |
|-------|--------|
| `{{sentence_count}}-sentence narrative paragraph` with explicit cap | The 2026-05-20 HITs all used an explicit sentence cap; the lone MISS held the cap but dropped an item to fit. Cap on its own is necessary but not sufficient — pair with rule 2. |
| `Plain UK English. No bullets, no headings, no bold, no inline code, no markdown` | General prose-tier default in SKILL.md; restated locally for resilience. Inline elements (`**bold**`, `` `code` ``) are listed explicitly because the prose tier sometimes interprets bare "no markdown" as a structural-only constraint and emits inline emphasis. Same wording `doc-section.md` adopted after the PR #135 review. |
| HARD RULE 1 (sentence cap is non-negotiable) | Restated as a numbered rule so it sits alongside the other hard rules rather than being buried in the opening sentence — bare openers are sometimes ignored when the model is in "tell a complete story" mode. |
| HARD RULE 2 (list-completeness with REFUSE hatch) | **New for this recipe.** Drawn from the 2026-05-20 slide-10 silent-drop MISS. The REFUSE hatch shape is borrowed from SKILL.md's v8 adversarial-chain pattern (`prose refused, code complied` warning) — the same independent-signals discipline applies here: a REFUSE line is advisory; the paragraph itself is authoritative. The verification step in "Expected output shape" makes that discipline explicit. |
| HARD RULE 3 (sharpened anti-padding) | The verbatim sharpened text adopted in PR #138 — extends the bare `Stop after the content sentences. Do not add a closing sentence that restates the point.` from SKILL.md with the participial-clause prohibition (`-ing`, `supported by`, `leading to`, `ensuring`, `reflecting`) and the positive end-condition (`End on a finite verb introducing new content, or stop`). The `doc-section.md` 2026-05-20 calibration confirmed the bare directive was insufficient on `qwen3.6:35b-a3b-q8_0`; this is the canonical sharpening being adopted across prose-tier recipes. |
| Off-domain Wrong/Correct one-shot (kitchen renovation) | New for this recipe. The off-domain choice avoids leaking any slide-topic framing (codebase, software project, infrastructure) into the example. The Wrong/Correct pair walks through the exact failure mode the list-completeness guard catches: 4-phase timeline, Wrong drops one phase, Correct covers all four within the same sentence cap. |
| `do not invent others` on the facts fence | Standard verbatim-fact discipline from `doc-section.md` and `commit-message.md`; restated here because the model's tendency to invent connecting facts is especially load-bearing on slides where one invented phrase becomes a confidently-wrong claim in front of an audience. |

### What's not yet measured

This recipe ships with the list-completeness guard and the sharpened anti-padding directive but without a dedicated T-series fixture. The next iteration is a deterministic scorer (`experiments/score-tN.sh`) over a stable fixture — once the recipe has been dogfooded across 5+ sessions and the directive shape has stabilised, the failure-shape regex (item-count from `{{facts}}` versus item-count referenced in the output, plus the existing trailing-participial heuristic from `score-t4.sh`'s `PADDING_REGEXES`) becomes the fixture's pass criterion. Defer until there is enough HIT-class output to calibrate against, mirroring how `doc-section.md`'s calibration notes scope the same deferral.
