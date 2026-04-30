# Evals

`eval-set.json` holds the trigger-correctness fixtures used by `scripts/eval-skill-triggers.sh`.

Schema: `skill` (string), `model` (string, the grader model), `thresholds.positive_recall`, `thresholds.negative_precision`, `queries[]` each with `id`, `tag` (`exact|paraphrase|adjacent|unrelated`), `expect` (`trigger|no-trigger`), `query` (string).

Rerun the runner whenever `SKILL.md` frontmatter `description` changes. Results land in `results/<run-id>.jsonl` and are not committed.
