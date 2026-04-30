# Evals

`eval-set.json` holds the trigger-correctness fixtures used by `scripts/eval-skill-triggers.sh`.

Schema: `skill` (string), `model` (string, the grader model), `thresholds.positive_recall`, `thresholds.negative_precision`, `queries[]` each with `id`, `tag` (`exact|paraphrase|adjacent|unrelated`), `expect` (`trigger|no-trigger`), `query` (string).

Rerun the runner whenever `SKILL.md` frontmatter `description` changes. Results land in `results/<run-id>.jsonl` and are not committed.

## Security

Eval queries are sent verbatim to the Anthropic API in `--api` mode. Do not put real credentials, internal hostnames, or sensitive data in `query` strings — even when you are documenting a "this kind of query should trigger" pattern, prefer placeholder tokens (`$FAKE_TOKEN`, `example.com`) over realistic-looking values. The point of the skill is to keep sensitive content on-device; do not undermine it by putting that content in a fixture file.

