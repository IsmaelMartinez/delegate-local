# /// script
# requires-python = ">=3.12"
# dependencies = ["pydantic-evals>=2.43"]
# ///
"""What pydantic-evals adds over report.py: the same deterministic scorers as
Evaluators over the same cases, with the library's report table (throwaway).

Usage: uv run evals_demo.py [arm]   (default: the stored draft the wrapper produced)
"""
import sys
from dataclasses import dataclass

from pydantic_evals import Case, Dataset
from pydantic_evals.evaluators import Evaluator, EvaluatorContext

from common import load_cases, load_results
from score import score


@dataclass
class Rule(Evaluator[dict, str]):
    """One recipe rule as a pass/fail evaluator; `name` is the scorer's fail label."""
    rule: str

    def evaluate(self, ctx: EvaluatorContext[dict, str]) -> bool:
        return self.rule not in score(ctx.inputs, ctx.output)["fails"]


@dataclass
class AnchorsKept(Evaluator[dict, str]):
    def evaluate(self, ctx: EvaluatorContext[dict, str]) -> float:
        return score(ctx.inputs, ctx.output)["anchors_kept"] or 0.0


@dataclass
class ShipCore(Evaluator[dict, str]):
    def evaluate(self, ctx: EvaluatorContext[dict, str]) -> bool:
        return score(ctx.inputs, ctx.output)["ship_core"]


if __name__ == "__main__":
    arm = sys.argv[1] if len(sys.argv) > 1 else "stored-draft"
    cases = [c for c in load_cases() if c.get("final")]
    outputs = {c["id"]: c["draft"] for c in cases} if arm == "stored-draft" else \
        {k: v["output"] for k, v in load_results(arm).items()}
    dataset = Dataset(
        name=f"reply-recipes/{arm}",
        cases=[Case(name=c["id"][:8], inputs=c, expected_output=c["final"]) for c in cases if c["id"] in outputs],
        evaluators=[Rule(rule="echo"), Rule(rule="questions"), Rule(rule="invented"), Rule(rule="shape"),
                    AnchorsKept(), ShipCore()],
    )

    def task(case: dict) -> str:  # the "system under test" is a stored output, not a live call
        return outputs[case["id"]]

    report = dataset.evaluate_sync(task)
    report.print(include_input=False, include_output=False, include_durations=False)
