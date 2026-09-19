# Roadmap

This is the authoritative, intentionally short project plan. The full historical
record lives in git history, `CHANGELOG.md`, the ADRs under `docs/adr/`, and —
for everything removed in the 2026-06-19 lean-core reset — the
`pre-cleanup-2026-06-19` tag and the `archive/research-machinery` branch.

## What this is

delegate-local is a Claude Code skill that routes "gather context once, send one
prompt, return text" tasks to a locally-installed model (Ollama or MLX) over a
shell pipe. The runtime is deliberately tiny: `scripts/pick-model.sh` resolves a
tier to the best installed model, and `scripts/delegate.sh` posts the prompt to
the backend and returns clean text plus a metrics row. Everything else — the
recipe library, the install/onboarding probes, the calibration feedback loop,
and the CI gates — exists to make that one path reliable and self-correcting.

The discriminator for what belongs here is the local-brain insight: local models
are strong summarisers and weak agents. If a task needs multi-step reasoning,
repo-wide context, or tool-calling, it does not belong in this skill even if the
surface looks textual.

## Where we are (2026-06-19)

Shipped and stable. The skill installs via `npx skills add` (or `cp -r`), routes
across the `code` / `prose` / `reasoning` / `long-context` tiers (with `vision`,
`embedding`, `premium-general`, and `reasoning-vision` scaffolded), auto-selects
Ollama or MLX, ships 21 calibrated recipes led by `commit-message`, records
hit/miss verdicts that feed `metrics-summary.sh`, and gates every PR on a
frontmatter + content + trigger-eval CI pipeline plus the bash test suite.

The 2026-06-19 lean-core reset returned the repo to that core after a period of
heavy accretion. It archived the maintainer-facing research machinery out of the
installed tree (the `experiments/` accuracy framework, the Python MCP server,
the verdict-automation hooks, the maintainer analysis tools, and the
faithfulness-grounding prototype),
trimmed the accreted verify-and-
escalate gate out of `delegate.sh`, cut the `commit-message` recipe from 62KB to
~14KB by removing inline calibration history, and pruned the dead recipe tail.
The principle of the reset: recover quality by shrinking what a model and a
reader have to take in, not by adding more gates. All of it is recoverable from
the tag and archive branch named at the top of this file.

The OpenTelemetry → Loki/Grafana observability pipeline is explicitly retained,
not archived: `scripts/lib/otel.sh` span emission (opt-in via
`DELEGATE_OTEL_ENDPOINT`), the `sync-metrics-to-loki.sh` and `backfill-otel.sh`
exporters, the Grafana `dashboards/`, `observability/`, and the
`docs/observability/` guides are the maintainer's live visibility into
delegation traffic and stay in the core.

## Reply recipes: visible failures, then a lift (milestone, 2026-09-16)

The two reply recipes are the library's weak end, and the 2026-09-16 spike
(ADR 0031) showed that no agent framework, critic stage or loop moves them: the
failures are judgment (a missing verdict, facts echoed back, the reader asked to
confirm what the facts state), and the calibration loop cannot even see them,
because almost no rejection carries a failed check. The milestone works in that
order: make the failures visible and stop paying for retries that do not
repair, then move the judgment to the caller and measure a bigger model. Each
issue carries a goal the self-improvement session can read off
`metrics.jsonl`; the baseline is the thirty days to 2026-09-16, computed by
joining feedback rows to their delegate rows.

| | maintainer-reply | maintainer-review-reply |
|---|---|---|
| tracked delegations | 133 | 75 |
| kept as-is | 1% | 0% |
| usable (kept + scaffold) | 47% | 48% |
| rejections carrying a failed check | 3 of 132 | 8 of 75 |
| rejections mentioning confirm/question that carry one | 1 of 65 | 0 of 16 |
| retries that still failed afterwards | 3 of 13 | 8 of 12, all `no_context_echo` |
| blind grade ≥ 4 on the 26-case spike set | 12% | 20 to 40% (n=5) |

1. #513, check `no_fact_as_question` on `maintainer-reply`. Goal: rejections
   whose reason mentions confirm or question and that carry `checks_failed > 0`
   from 1 of 65 to at least 80% over the next 30 tracked delegations, with 0
   flags on replies later kept and 0 on stored finals.
2. #514, no retry on `no_context_echo` and `min_context_chars: 900` on
   `maintainer-review-reply`. Goal: retried rows still failing echo from 8 of 12
   to 0; `retry_chars` for echo on that recipe to 0; stored `.final.txt` files
   failing `max_context_ratio` from 2 of 5 to 0.
3. #516, store the rendered input beside the draft. Goal: rows with
   `draft_file` that also carry `input_file` from 0% to 100%; `self-improve.sh`
   names dropped anchors per rejection from the stored input.
4. #517, `maintainer-reply` takes the lead sentence from the caller. Goal on the
   18-case set: question-count mismatches from 13 to at most 6 and blind grade
   ≥ 4 from 12% to at least 25%; then kept from 1% to at least 10% and usable
   from 47% to at least 65% over the next 30 tracked delegations.
5. #515, measure the reply recipes on `premium-general`
   (`Qwen3.5-122B-A10B-4bit`, untested) and route them there if grade ≥ 4
   reaches 20% at a median under 10 s. Goal after the switch: usable to at least
   65% and 60%, kept to at least 10%, p50 `duration_ms` at or under 10000.
6. #518, this section and ADR 0031. Goal: every self-improvement bundle for the
   two recipes quotes these goals beside the current numbers.

Status, 2026-09-16 evening. All six issues are closed. v0.36.0 (13:10Z)
shipped #513, #514 and #516 together with #520 (the `{{recipient}}`
placeholder out of the instruction text) and #497 (the PostToolUse credit
confirmation, ADR 0032); #517 and #521 (pr-review-body enforced by default)
followed on main. Offline results: `no_fact_as_question` flags 8 of the 11
target rejections (the three left share words with the caller's own ask) and
0 of 16 shipped finals; the 900 floor clears all 5 graded review-reply finals
where 400 failed 2, and an echo-only failure no longer dispatches a retry; the
lead var took question-count mismatches from 13 to 2 of 16 and blind grade ≥ 4
from 0 to 6 of 16 (38%) with the same leads on both arms. #515 was measured and
closed as not planned: on the post-#517 template `Qwen3.5-122B-A10B-4bit`
graded 6% and 0% at ≥ 4 against 38% and 20% for the 35B, generated at p50
6.8 s and 5.7 s, and its 65 GB residency put the 125 GB machine into memory
pressure; the lift came from the template, not the model, and the tier stays
`prose`. The first rows after the release (n=8 and n=2, the delegate rows with
`ts >= 2026-09-16T13:10:54Z` joined to their feedback rows; `metrics-summary.sh
--since 2026-09-16` takes a date and reads the whole day, so it is the
next-day read) already show the visibility goals holding: every recipe row carries `input_file`, 4 of the 5 maintainer-reply
rejections carry a failed check (was 3 of 132), and the one echo failure on
the review recipe spent no retry. The kept and usable goals need 30 tracked
rows per recipe and are the next self-improvement session's read.

The milestone is done when both recipes read usable ≥ 65% and 60% and kept
≥ 10% on `metrics-summary.sh --days 30`, or when the remaining gap is shown to
be the task definition rather than the draft, in which case the recipes are
narrowed further or retired.

## Replay-gated self-improvement (milestone, 2026-09-19)

The calibration loop had a procedure and no measurement. Online, the agent's
verdicts need about 134 tracked delegations per arm to tell a fifteen-point
lift in usable rate from noise, which at the reply recipes' volume is weeks
per edit, and the session meant to run the loop every two hours had been dead
since 2026-08-27 (session-bound cron). ADR 0031 as amended keeps a replay
harness as maintainer tooling: `delegate.sh` stores each recipe call's
structured inputs and stamps the template hash on the row, `replay-recipe.sh`
re-renders stored cases under the live and a candidate template and decides
with a paired sign test, and `self-improve.sh` splits outcomes by template
hash for the post-merge read. Goals, read off `metrics.jsonl`:

1. Every recipe row written after this lands carries `template_sha` and, when
   capture is on, `inputs_file`; the bundle's capture-coverage line stays at
   `with input=` equal to `with draft=`.
2. The first recipe edit proposed by the loop after this lands quotes a replay
   verdict in its PR; no recipe edit merges on an `INCONCLUSIVE` or absent
   replay.
3. Within thirty tracked rows of any merged edit, the per-template section
   prints the new hash beside the old with both rates, and a drop past the
   resolvable margin produces a revert PR rather than a second edit.
4. The loop runs on a schedule that outlives a session: one calibration pass a
   day, each pass either quiet (exit 10), a PR with a replay line, or a report
   saying the evidence is thin.

The milestone is done when a full cycle has happened at least once: an edit
accepted by replay, merged, and read online at thirty rows, whichever way that
read went.

## Where we're going (next, priority-ordered)

1. Decide on a deeper recipe prune. The reset kept every recipe with real usage
   or a SKILL.md trigger; a further cut to the ~10-recipe high-usage head is
   available if the maintainer wants the library leaner still.
2. Re-verify the install on a genuinely clean machine (not the dev symlink) and
   keep the install path covered as the headline trust surface.
3. Sweep the few in-code comments in `delegate.sh` that still reference the
   removed escalate gate.

Anything beyond this is a fresh, evidence-gated decision. Re-introducing an
archived capability (MCP, experiments) should be driven by a real consumer
asking for it, not by default.

## Out of scope

- Code edits, refactors, or feature implementation. Local models are weak agents and the skill description explicitly rejects these. The local-brain finding stands: "they didn't need Smolagents, they needed `git status | ollama run model`".
- Auto-pulling models without confirmation. Multi-GB downloads stay user-decided; the audit script suggests, never installs.
- A general-purpose router that competes with Claude on routing decisions. This skill picks a model within Ollama; it does not decide whether to call Claude vs Ollama. That decision belongs in the skill description, evaluated by Claude itself.
- A critic, judge or multi-round loop on the same local model, and agent frameworks around the wrapper. Measured on real cases in ADR 0031: the loop oscillates and never converges, structured output enforces shape only, and docker agent cannot cycle without the local model's cooperation, which it does not give. Revisit only on a new lever (a different model, a narrower task, or docker agent as a zero-install runner once it can send `chat_template_kwargs`).
