# Field notes: delegate-to-ollama in this repo

These are running notes from using the `delegate-to-ollama` skill (https://github.com/.../delegate-to-ollama) during the IP-146 share-readiness pass on this repo. Kept here because the repo owns the artefacts the skill was run against (commit messages, README edits, runbook drafts). The intent is to share this file back to the `delegate-to-ollama` project so its SKILL.md can absorb the bits that are genuinely portable.

## Environment

- Host: macOS 25.4.0 (Darwin arm64).
- Daemon: `ollama serve` from Ollama.app.
- Installed models (partial): `qwen3.6:35b-a3b-q8_0`, `qwen3-next:80b-a3b-instruct-q8_0`, `qwen3.5:122b-a10b-q4_K_M`, `qwen3-coder-next:latest`, `deepseek-r1:32b`, `phi4-reasoning:plus`, `qwen3-coder:30b-a3b-q8_0`, `gemma4:31b-it-q8_0`, `qwq:32b-q8_0`, `deepseek-r1:14b`, `gemma4:latest`.
- Tier used for every call in this pass: `prose` → resolved to `qwen3.6:35b-a3b-q8_0`.

## What worked

Single-paragraph commit-message drafting. Tight prompt (~500 chars), small diff on stdin (~1 KB), exact output contract ("subject starts with `refactor:`", "one paragraph", "no Co-Authored-By", "UK English"). 8.5 s end-to-end. Output was usable with no edits on one call, and with a body rewrite on another where the diff chunk did not carry the full context. This is the sweet spot the skill claims, and this session confirms it.

Atomic single-paragraph prose fills. After the bundled-prompt failure below, splitting a doc section into N separate single-paragraph prompts (~350 chars each, no input) produced N usable outputs in 10–20 s each. Assembly (headings, code blocks, CLI examples, file links) is done by me, not by the model. This matches the skill's "one sub-task per call" discipline but in prose-tier rather than classification-tier context.

## What didn't work

Long bundled prompts on `delegate.sh`. First attempt on the README Status rewrite: one `~1.3k-char` prompt asking for four paragraphs with embedded XML-like `<status>...</status>` input tag. The wrapper appeared to run but produced no output for ~3 min and was killed by the task harness with `exit 144`. Re-issuing with the same prompt repeated the hang. The shell-eval layer itself seemed to be stalling on the quoted payload size — `ps aux` showed the `delegate.sh prose ...` argv string spanning the whole prompt. Whatever the bottleneck is (daemon loading, shell quoting, stdin flush), the practical ceiling on `qwen3.6:35b` via `delegate.sh` on this host is much lower than the skill's stated `≤8k tokens`. Anecdotally closer to `~1–2k chars of prompt + stdin combined` before latency becomes unusable.

Trailing-adverb padding. Every single prose-tier paragraph in this session had the same shape: two solid sentences stating the content, followed by one closing sentence restating the point with a participial clause — "ensuring proper notification routing is established", "this distinction is crucial for determining whether immediate infrastructure correction or security mitigation is required", "to address the identified on-call gap effectively". The content is fine; the close is dead weight. I stripped the last sentence of every generated paragraph. This is pattern-like enough that it could be prompted against directly with a hard rule.

## Recommendations for delegate-to-ollama's SKILL.md

The skill already has the right shape. Two additions worth considering:

1. **A concrete practical-ceiling caveat** under "Prompt scope — closed vs open" or "Red flags". The `≤ 8k tokens` guideline is a theoretical limit; real users on mid-tier hardware will hit a much lower ceiling — this session saw a hang at ~1.3k-char prompts with `qwen3.6:35b`. A sentence like *"if `delegate.sh` appears to hang for more than ~30 s with no streaming, the prompt-plus-stdin is probably too large for your host — break it into smaller sub-tasks rather than waiting"* would save the next user a few minutes. Possibly also worth adding a small in-script timeout + diagnostic on the wrapper: "still waiting on daemon at 30 s…" so the user knows the call is live rather than guessing.

2. **An explicit anti-padding directive in the "closed-form work" discipline block**. The trailing-restatement pattern showed up on 100 % of prose-tier paragraphs in this session. A one-shot example in the prompt telling the model "stop after the content sentences; no closing summary" could cut the padding at source. Matches the skill's existing "directive-shaped hard rules" pattern from the v5 retrospective but applied to prose rather than classification. Something like: *"Do not add a closing sentence that restates the point. Stop when the content is stated."*

3. **A grouping example of "what NOT to delegate", positive-phrased**. The "Fits / Do NOT delegate" list is useful; adding a one-line positive example like *"structure (headings, code blocks, CLI examples, file layout) is always yours to own; models fill prose, not scaffolding"* would make the "paragraph-fill assembly" pattern more discoverable. This session used ollama to draft 4 paragraphs of a new runbook and then hand-wrote the 4 headings and 3 code blocks around them — that split is the natural shape but the skill doc doesn't quite say so.

4. **Mention that the per-call latency has a fixed-cost floor on cold models**. First call to `qwen3.6:35b` in this session was slower than subsequent calls against the same model — the daemon warms up. Not a bug, but worth a line under "Latency expectations" if such a section exists.

## Metrics JSONL — actually useful

`~/.claude/skills/delegate-to-ollama/metrics.jsonl` captured one line per call with tier, model, prompt/context/output chars, duration, estimated tokens avoided. After this pass that file alone would answer "was ollama worth it?" without needing a separate log. The skill already produces this; worth surfacing more loudly in the SKILL.md because it turns the skill into a measurable experiment rather than a vibe call.

## Token cost: are we actually saving money?

Honest answer: the direct token cost is negligible on any realistic task — the token savings chart is a bad reason to reach for this skill. The real reasons to use it are privacy (text stays on-device) and parallelism (the local call doesn't contend for the managed-model context window). Money is a rounding error.

Numbers from the IP-146 share-readiness pass (pulled from `~/.claude/skills/delegate-to-ollama/metrics.jsonl`):

- 21 calls across the session.
- Total wall time against the local daemon: `88.1 s`.
- Sum of `estimated_tokens_avoided` reported by `delegate.sh`: `10,106`.

At current Anthropic list prices, that token volume costs:

- Haiku output (\$1.25 / 1M): `$0.013`.
- Sonnet input (\$3 / 1M): `$0.030`.
- Sonnet output (\$15 / 1M): `$0.152`.
- Opus output (\$75 / 1M): `$0.758`.

So even framing the delegated work as "pure output at Opus rates" puts the saving under a dollar for this session. More realistically, commit-message drafting and short paragraph fills would have run on Sonnet or Haiku in the managed-model turn, and the saving is in the range of `$0.01–0.15` total. It would take ~100 sessions of this density to save a lunch.

Where the skill does pay for itself, and it really does, is in indirect costs that the metrics file does not count. Three of them:

1. Main-agent context protection. Every paragraph the local model drafts is one less round-trip the managed model carries in its context window. On a long session — this one is ~30 messages deep and includes four sub-agent research outputs totalling several thousand tokens — the context savings add up faster than the per-call token savings. Context compaction is slow and lossy; deferring it by a few turns is worth more than the 3-cent token delta.

2. Latency under parallel load. When the managed model is the long pole on a review, an 8 s local call that runs in parallel to the main chain removes time from the critical path. This session saved roughly `60 s` of managed-model time on commit messages alone — not money, but the user is sitting watching the screen during that window.

3. Privacy. The skill's "keep content on-device" framing matters for any prompt that carries secrets, internal names, or customer data. There is no price tag on that and no way to express it in a metrics file, but it is load-bearing on a repo like this one (where the audit agent surfaced real CI credentials sitting in a gitignored local file).

What the numbers **do not** support: framing the skill primarily as "save Anthropic spend". At current prices, a session of this density is a ~\$0.10 saving at most. That is not the argument. The argument is context, parallelism, and on-device content. The SKILL.md opens with "saving API tokens and keeping content on-device"; if the order were reversed — "keep content on-device, free up the main-model context, save some tokens as a side effect" — the skill would sell itself more accurately.

One more note: `estimated_tokens_avoided` is an approximation (roughly `(prompt_chars + context_chars + output_chars) / 4`). For a real cost audit, sum it into classes of call — I'd want to see "calls under 500 ms" split from "calls over 5 s", because the former are effectively free and the latter burn local power without a matching remote turn being displaced (the delegation call doesn't prevent a managed-model turn if the managed model would have just typed the paragraph itself inline — which, for a `refactor:` commit message, it would). A more pessimistic accounting would count only calls where the managed model would otherwise have made a separate round-trip. That is closer to a handful of calls per session, not twenty.

## Where to aim next (concrete follow-ups for the skill project)

Three changes that together would move the "fraction of calls that were net wins" from 5/21 (this session) closer to everything being useful:

First, **default to `run_in_background: true` when the caller does not need the output on the next line**. Right now every `delegate.sh` call blocks the main agent for whatever the local daemon takes. If the delegation pattern is "draft this and come back in a second", the main agent could be doing something else (rebasing the next branch, reading the next file, polling a pipeline) while the local model works. This is a harness-side change more than a skill-side one, but the SKILL.md could explicitly recommend "if the next managed-model action does not depend on this delegated output, run the delegation in the background".

Second, **add a hard anti-padding directive to every prose-tier prompt by default**. Every single prose-tier paragraph in this session ended with a trailing sentence that restated the point ("thereby ensuring...", "this distinction is crucial...", "effectively establishing..."). The fix is a one-line prefix in the prompt template: *"Stop after the content sentences. Do not add a closing sentence that restates the point."* The 2026-05-03 retrospective already established that directive-shaped hard rules work on small models; this is a prose-tier application of the same pattern. 30 seconds to add; improves every future call.

Third, **make `pick-model.sh` read the metrics JSONL and drop one tier when a task has been consistently easy**. The metrics file already records `prompt_chars`, `output_chars`, `duration_ms`, and `exit_status` per call. A small-input, small-output, fast-duration call that has succeeded N times in a row is a candidate for a smaller model. Today `prose` routes to `qwen3.6:35b` for every single call regardless of shape — a 40-word commit-message body resolves to the same model as a 200-word runbook paragraph. A size-aware or history-aware router would cut the local wall time (and power budget) on the smallest tasks without hurting quality on the larger ones. Out of scope for the SKILL.md itself, but worth flagging on the project's ROADMAP.md.

These are speed-and-discipline wins, not token-savings wins. The direct `$` number will stay small regardless.

## Session 2 — follow-on MRs (2026-05-05)

Continuing after the first batch merged. Running the four remaining queued MRs with the same delegate-where-it-fits pattern, noting what happened per call so the pattern-fit evidence grows.

Four MRs ran in this session:

MR-simplify-B (delete stale plans, fold WAR milestone ledger into improvements.md). Zero ollama calls — every edit was structural (delete two files, move one table across files, update four external references). This is a case where the skill was correctly not reached for, because the task shape is "move content exactly as it is, nothing to reword". Self-measured bias to record: my instinct was to delegate the commit message, but the diff was complex enough (deletes plus cross-reference updates plus a table move) that a locally-generated summary would likely have missed one of the five files touched. I wrote the commit message directly. Verdict: correct skip.

MR-simplify-D (dedupe OriginLatency caveat and workshop checklist). Zero ollama calls. Same reason as above — this was two "replace this paragraph with a pointer to the canonical home" edits where the work is decisions about which home is canonical, not prose generation. The replacement sentences are shorter than the prompt would have been.

MR-docs-C (add Managing-the-IP-allowlist section). One ollama call, `qwen3.6:35b` prose tier, 90-word paragraph, returned in ~15 s. The output had the same trailing-adverb padding observed in session 1 ("one must simply edit", "acts as a critical build-time guard") and also re-ordered the "ordering inside a category is irrelevant" clause awkwardly. I kept the bones and rewrote the final shape. Net win is probably ~30 % of the paragraph; the rest was rework. This reinforces the session-1 finding that trailing-adverb padding is pattern-like and would be addressable by a hard-rule prompt prefix in the skill. I added the same anti-padding directive to the prompt this time ("Do not add a closing sentence that restates the point") — it visibly reduced but did not eliminate the padding.

MR-docs-E (drill follow-ups into improvements.md item 7; WebACL-id precheck in legacy runbook). Zero ollama calls. The two edits are a sub-item list extension and a shell-command snippet; neither is prose generation.

## Session 2 metrics

One ollama call in four MRs. Compare to session 1's 21 calls across six MRs. The ratio shift is the lesson: once you know what the skill is for, you reach for it less often but more precisely. The call that happened produced a partially-usable paragraph — net win maybe 10 s of typing time saved against ~15 s of local-daemon wall-time plus a minute of rework. Break-even at best.

The pattern I am settling on after two sessions: delegate only when the output shape is specifically **a paragraph of flowing prose with no structural decisions embedded in it**. Commit messages, runbook first-response paragraphs, section introductions — yes. Link-index rewrites, cross-reference collapses, table moves, snippet additions — no, those are structural decisions dressed as text and delegation adds more overhead than it saves.

## Session 2 updated position on cost savings

Direct token cost for this session across 4 MRs with 1 ollama call: pennies, maybe a cent. Not a savings story. What the skill did save in this session was a tiny amount of typing on the one paragraph that genuinely fit. The context-protection argument from session 1 is weaker too, because structural edits do not consume large amounts of main-model context regardless — a 4-file delete + 1-table-move is short diff output.

Revised honest framing: the skill earns its keep when the session has a high density of **prose-generation sub-tasks**, which the IP-146 share-readiness pass specifically did in session 1 (multiple new paragraphs, a new runbook, commit messages) but did not in session 2 (structural cleanup). A realistic rule of thumb: if you would otherwise type more than ~4 paragraphs of fresh prose in a session, the skill is worth reaching for. Below that, the setup + review overhead dominates.

## One-liner summary

The skill is correct. The hard part on this host is prompt-size discipline and spotting trailing-adverb padding. Both are addressable in the SKILL.md without changing code. Cost savings are a side effect, not the headline — context protection and privacy are.
