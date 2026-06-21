## What

A short description of the change. Reference any roadmap item or issue this closes.

## Why

The motivation. If this is a routing change, link to the ADR or evidence that supports the new preference order.

## Validation

Confirm the gates that apply:

- [ ] `bash tests/run-tests.sh` and per-script `tests/test-*.sh` pass
- [ ] `bash scripts/validate-frontmatter.sh SKILL.md` passes
- [ ] `bash scripts/validate-skill-content.sh SKILL.md` passes
- [ ] `bash scripts/eval-skill-triggers.sh` passes (shape mode)
- [ ] If `SKILL.md` frontmatter `description` changed: `bash scripts/eval-skill-triggers.sh --ollama` passes recall ≥ 0.9 and negative-precision ≥ 0.9
- [ ] If `pick-model.sh` preferences changed: corresponding test in `tests/run-tests.sh` updated

## Notes for the reviewer

Anything non-obvious — tradeoffs, deferred follow-ups, edge cases the tests do not cover. Cross-platform (macOS bash 3.2 + GNU bash) compatibility called out if the change touches shell scripts.
