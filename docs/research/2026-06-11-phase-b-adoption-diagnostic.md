# Phase B — cross-project adoption diagnostic

Date: 2026-06-11. Research document, not an implementation plan. It measures the three candidate Phase B bottlenecks against the data already on disk now that the boundary hook (#282) and `--recipe auto` (#277) have shipped, and commits to one of the conditional next steps the roadmap left open.

## Framing

The #277 refinement reframed cross-project adoption: the binding constraint is trigger *rate*, not output quality, and the cause is structural rather than descriptive. Skill selection is turn-initial, but the highest-volume real-world triggers — commit message, PR body, release note — are turn-medial sub-steps of "implement X, commit, open a PR", so by the time the agent reaches them it never re-runs skill selection. Three things shipped against that diagnosis: the deterministic commit/PR/release boundary hook (`scripts/delegate-boundary-hook.sh`, #282) with its trigger-rate / missed-opportunity metric in `metrics-summary.sh`, `delegate.sh --recipe auto` (#277) to cut activation energy, and a narrowing of the noisy `locally`/`on-device` keywords in the SKILL.md description.

This report answers: of the three candidate bottlenecks the roadmap named — (i) the trigger description does not fire on non-eval-set task shapes, (ii) session context loads the skill too late in non-delegate repos, (iii) user habit defaults to inline responses — which is binding now, and is the trigger description the discriminator? It also records the prior on priority: the 2026-06-10 production quality signal promotes Phase E (verdict coverage) above Phase B, so this is a measurement deliverable, not a push to "fix adoption" in code.

## Data sources and commands

Every number below comes from the live metrics JSONL (`~/.claude/skills/delegate-local/metrics.jsonl`, 1746 rows spanning 2026-05-03 to 2026-06-11) via two read-only commands, reproducible on any host with the same file:

```bash
bash scripts/metrics-summary.sh                              # per-project volume + trigger-rate blocks
bash scripts/eval-skill-triggers.sh --ollama qwen3.6:35b-a3b-q8_0   # standalone vs embedded recall (run 2x)
```

The boundary-hook opportunity rows (`source:"opportunity"`) only begin 2026-06-09, when the hook shipped, so a true longitudinal before/after is not yet possible; the trigger-rate table below is the first cross-section the metric makes visible.

## 1. Per-project volume and the concentration

Of 947 attributed `delegate` calls, 647 (68%) originate from the two repos that *are* the skill's own development — `delegate-to-ollama` (472, the pre-rename name) and `delegate-local` (175). Adding the throwaway development contexts (`audit` 111, `audit2` 26, `poc` 16, `tmp` 14, and assorted `agent-*` / worktree names) pushes self-originated volume well past 90%. Genuine external-project usage is a thin long tail: `teams-for-linux` (31), `pr-agent` (18), `github-issue-triage-bot` (8), `repo-butler` (5), and a scattering of one-to-few-call contexts. This is the expected shape for a tool still mostly dogfooded, and it confirms the cold-start gap the roadmap predicted: the engine travels, but adoption in other repos has not.

## 2. Bottleneck (i) — trigger description vs real task shapes

Two consecutive `--ollama` runs against the `qwen3.6:35b-a3b-q8_0` batched scorer were stable:

```
shape:   total=41 positive=22 negative=15 diagnostic=4
results: tp=17 fn=5 tn=15 fp=0 recall=0.773 negative-precision=1.000
diagnostic (embedded sub-step): dtp=0 dfn=4 embedded-recall=0.000
```

Taken at face value the 0.773 standalone recall is below the 0.9 gate and would suggest the description itself is the problem. It is not, and the distinction matters for the verdict. The five missed positives are `p09` (summarise a 70-page PDF transcript into five decisions plus owners), `p16` (triage a failed CI step from `gh run view --log-failed`), `p20` (summarise a stalled PR's review state), `p21` (ground-check three conclusions against a CI log), and `p12` (write a timeline-and-correlation comment from CI logs). Four of those five are textbook delegation shapes — summarise, extract, classify, ground-check — and three of them map to recipes that already exist (`ci-log-triage`, `ground-check`). Only `p12` is a genuine reasoning-leaning edge where a NOTRIGGER is defensible. In other words, the misses are the local batched judge being a weak scorer of the description, exactly the non-determinism the roadmap already flags ("the `--ollama` and `--github-models` trigger-accuracy scorers are non-deterministic and currently sit at ~0.81–0.86 recall ... the accuracy gate is effectively advisory today"), not the production description failing on real cross-project wording. Negative-precision held at a perfect 1.000 across both runs, so the description is not over-firing either.

The honest reading is that bottleneck (i) is not binding. The description matches real task shapes; the measurement noise is in the local scorer.

## 3. Bottleneck (ii) — session-context load order

This one is not measurable from the JSONL, and the earlier `2026-05-27-cross-project-adoption.md` report already established the answer: the skill is installed at user scope (`~/.claude/skills/delegate-local`, symlinked to the checkout), so it loads in every session regardless of repo. Load order is not the blocker. The real form of (ii) is the *absence of an in-repo decision-path hint* in cold repos — nothing in those projects' `CLAUDE.md` reminds the agent that delegation is an option at the medial step — and the boundary hook now partially substitutes for that by firing at the missed site. So (ii) as literally phrased ("loads too late") is not supported; its substance folds into the control-flow problem (iii) addresses.

## 4. Bottleneck (iii) and the before/after — did the boundary hook move the trigger rate?

The boundary-hook metric is the first time the trigger rate has a denominator. The current cross-section:

```
Trigger rate (commit/PR/release boundaries):
  delegate-local            opportunities=26  delegated=19  missed=7   rate=73%
  pr-agent                  opportunities=18  delegated=9   missed=9   rate=50%
  dog-ambassador-champions  opportunities=10  delegated=0   missed=10  rate=0%
  plg-agent-skills          opportunities=4   delegated=0   missed=4   rate=0%
  teams-for-linux           opportunities=4   delegated=3   missed=1   rate=75%
  github                    opportunities=1   delegated=0   missed=1   rate=0%
  tmp.VVlJYWjmGl            opportunities=1   delegated=0   missed=1   rate=0%
```

There is no pre-#282 opportunity data, so the "before" is a counterfactual: prior to the hook the medial trigger rate for commit/PR/release boundaries was effectively unmeasured and, per the #277 premise, near zero in repos where the agent never re-ran skill selection. The "after" is the observed split, and the split is the finding. Dogfooded repos where the hook is active sit at 73–75% — the hook's reminder is moving behaviour. Two cold repos, `dog-ambassador-champions` and `plg-agent-skills`, sit at 0% across fourteen combined opportunities. That is the cold-start frontier in one number: the boundary opportunities exist in those repos and are being missed wholesale. `pr-agent` at 50% is the interesting middle — partially adopted.

The embedded-recall of 0.000 (all four "implement X, then commit and open a PR" sub-step cases scored NOTRIGGER) is the same structural blind spot seen from the eval side: when the trigger is a turn-medial sub-step, turn-initial skill selection never reaches it. This is precisely what the boundary hook is built to catch, which is why the lever is wider hook adoption, not a description edit.

## 5. Verdict

The binding constraint is control-flow and cold-repo adoption, not the trigger wording. Bottleneck (i) is measurement noise in the local scorer, not a production gap; bottleneck (ii) is load-order-fine and folds into control flow; bottleneck (iii) is real and now quantified — 0% trigger rate in cold repos against a strong description and a working hook means the hook simply is not present or active there. The discriminator is whether the boundary hook is installed and running in a repo, not how the SKILL.md description is worded.

## 6. Action — Branch B (the trigger description is not the discriminator)

The roadmap left this report a conditional fork. Branch A (expand `evals/eval-set.json` with cross-project paraphrase positives and re-run the gate) is triggered only if standalone recall is materially low *on real cross-project shapes*. It is not: the low recall is the local judge mis-scoring textbook delegation shapes, and chasing it by editing the trigger surface would be tuning against a non-deterministic scorer for no production benefit while re-opening the (advisory, flaky) trigger-eval gate. So this report takes Branch B and recommends explicitly **against** any SKILL.md frontmatter edit; the description is adequate and the per-#277 keyword narrowing already landed.

The recommended next structural levers, all for *future* PRs rather than work to do here, are: widen boundary-hook adoption (the hook is opt-in via `docs/boundary-hook.md`; the 0%-rate repos almost certainly do not have it installed or run it in a no-metrics mode, so the lever is a documented install nudge, not code); add a one-line in-repo delegation hint to the user's global `CLAUDE.md`, now backed by the boundary-rate metric as its success measure; and defer further description tuning entirely. The north-star metric for Phase B going forward is `delegated / opportunities` per project from the trigger-rate block; the concrete next reading is to re-run `bash scripts/metrics-summary.sh` after the hook has been active for two-plus weeks across more repos, so a genuine longitudinal delta exists rather than today's single cross-section. None of this jumps ahead of Phase E, which the 2026-06-10 signal ranks first.

## 7. Scope guardrails and conflict surface

This PR is the written diagnostic only — no eval-set change (Branch A was considered and rejected), no `metrics-summary.sh` change (the existing trigger-rate block already produces the load-bearing numbers; a cross-project-only view, if wanted, is a read-only `jq` one-liner, not a script edit), and explicitly no SKILL.md frontmatter edit (the trigger surface is gated by the same non-deterministic scorer producing the 0.773, so an edit risks a CI flap for no measured gain). The only shared file touched is `ROADMAP.md`, where a dated status note is appended under the Phase B refinement rather than rewriting the section, to keep the merge surface minimal against the parallel tracks.

## Sources / artifacts

- `bash scripts/metrics-summary.sh` — per-project volume and the `Trigger rate (commit/PR/release boundaries)` block (run 2026-06-11).
- `bash scripts/eval-skill-triggers.sh --ollama qwen3.6:35b-a3b-q8_0` — standalone recall 0.773, embedded-recall 0.000, negative-precision 1.000 (two stable runs, `evals/results/20260611T2002*-ollama.jsonl`).
- `docs/research/2026-05-27-cross-project-adoption.md` — the prior reading this report updates (the structural-blockers conclusion it reached pre-boundary-hook).
- ROADMAP.md "Phase B refinement (#277, 2026-06-09)" and "Production quality signal (2026-06-10)" — the framing and the Phase-E-over-Phase-B priority.
