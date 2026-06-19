# Install verification findings (WS1 of the lean-core reset)

Date: 2026-06-19
Backend on the test host: Ollama and MLX both running; `DELEGATE_BACKEND=auto`
resolves to MLX (Apple Silicon, `mlx_lm.server` up on :8080).

## Method

Exported the git-tracked tree with `git archive HEAD` into a clean temp
directory — exactly the file set a fresh `git clone` / `npx skills add` would
copy — and ran the install-path scripts from there with metrics disabled
(`DELEGATE_LOCAL_NO_METRICS=1`), so the test reflects what a brand-new user
gets, not the developer's symlinked checkout.

## The headline finding: the install was never actually exercised

`~/.claude/skills/delegate-local` is a symlink to the dev repo
(`/Users/ismael.martinez/projects/github/delegate-local`), not a real install.
Every "install" the maintainer has run has resolved straight back to the working
checkout. The copy-based path that real users get — `npx skills add` (which
clones the repo) or the documented `cp -r` fallback — had never been run. This
is the concrete source of the "I'm fairly sure it is not actually correct"
doubt: not that it was broken, but that nobody had ever looked.

## What actually works (verified from a clean copied tree)

The runtime is functional standalone. `pick-model.sh` resolves every tier,
`audit-models.sh` prints installed models + tier routing + llmfit suggestions, a
bare prose call (`delegate.sh prose`) routed to MLX and returned a clean summary
in 711ms, and the preflight canary correctly caught a cold/unloaded `code`-tier
MLX model within its 10s budget and printed actionable advice. So the install is
not broken — it is bloated and untested, which is a different and more tractable
problem.

## Defects and observations

1. Install bloat. The clean tree is 5.9MB / 534 files. Of that, `experiments/`
   alone is 3.0MB the user never touches, plus a 196KB CHANGELOG, a 144KB
   ROADMAP, the 80KB `mcp/` Python server, `dashboards/`, and `observability/`.
   There is no `.npmignore` / `.skillsignore`, so the installer ships
   everything. WS2's deletions remove the biggest offenders (experiments, mcp,
   observability, dashboards) directly. Residual shipped-but-arguably-unneeded
   material after WS2 — `tests/` (740KB), the full `docs/`, CHANGELOG, ROADMAP —
   is noted for the maintainer to decide on later via packaging excludes; it is
   harmless bytes, not a blocker, so not touched here.

2. The 62KB commit-message recipe produces output that fails its own quality
   check. On the warm prose tier it returned a structurally-correct
   conventional-commit subject ("fix: guard against empty tier argument in
   pick-model.sh") but a body ending in a textbook padding tail ("This prevents
   unexpected behavior when the argument is missing"), tripping
   `no_padding_tail` (checks_failed=1), at 1272 tokens / 14.2s. This is direct
   evidence for the WS3 hypothesis that the oversized recipe is not delivering
   clean output and a leaner template should do at least as well.

3. Recipe input friction. `commit-message` requires three mandatory `--var`
   inputs (`recent_commits`, `diff_stat`, `why`) plus the diff on stdin. The
   caller must gather all of that before invoking. Worth weighing in the WS3
   rewrite: rich context can help, but mandatory friction on the single
   most-used recipe is a cost.

4. Cold-model UX on multi-tier MLX hosts. Because only one model is resident in
   `mlx_lm.server` at a time, the first call to a non-resident tier hits the
   preflight timeout until that model loads. The behaviour is correct and the
   message is actionable; noting it because a first-run user on MLX may meet it
   and read it as a failure. The README/onboarding could pre-warm or call it out
   (follow-up, not in scope here).

## Verdict

No install fix is required to make the skill function — it already works from a
clean copy. The reset's value to the install story is (a) shrinking what ships
(WS2), (b) making the shipped recipe produce clean output (WS3), and (c)
re-running this exact exercise against the lean tree in WS6 to confirm the
under-five-minutes goal end to end. No code changes were made in WS1; this is a
facts-capture step.
