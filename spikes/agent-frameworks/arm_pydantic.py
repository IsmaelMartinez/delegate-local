# /// script
# requires-python = ">=3.12"
# dependencies = ["pydantic-ai-slim[openai]>=2.43"]
# ///
"""pydantic-ai arms of the agent-framework spike (throwaway).

  A0-py       same prompt as the bash wrapper, no validator, no retry (harness sanity)
  A1-validate output_type=str + input-only validators that raise ModelRetry naming
              the offending sentences; the retry carries the whole conversation
  A2-struct   structured output (tool call) with field validators, assembled
              deterministically into the recipe's shape
  A3-critic   draft -> critic (structured violation list) -> revise, batched by
              stage so a different critic model costs one swap, not one per case
  A5-model    A0-py on another model (the model-vs-flow confound)
  A6-think    A0-py with the model's thinking switched on (the docker agent
              path cannot switch it off, so this isolates what thinking does)

Run:  uv run arm_pydantic.py <arm> [--model NAME] [--critic-model NAME] [--limit N] [--name LABEL]
"""
import argparse
import os
import re
import sys
import time

os.environ.setdefault("PYDANTIC_AI_NO_BANNER", "1")

from pydantic import BaseModel, Field, field_validator
from pydantic_ai import Agent, ModelRetry, RunContext
from pydantic_ai.models.openai import OpenAIChatModel, OpenAIChatModelSettings
from pydantic_ai.providers.openai import OpenAIProvider

from common import DEFAULT_MODEL, MLX, load_cases, load_results, render, save_result
from score import FILLER, INSTRUCTION_ECHO, PARTICIPIAL_TAIL, anchors, normalise, sentences, word_limit


def settings(think=False):
    return OpenAIChatModelSettings(
        temperature=0.0,
        max_tokens=8192 if think else 2048,
        extra_body={"chat_template_kwargs": {"enable_thinking": think}},
    )


def model(name=DEFAULT_MODEL):
    return OpenAIChatModel(name, provider=OpenAIProvider(base_url=MLX, api_key="local"))


# ---------------------------------------------------------------- validators
# Everything here is computable from the INPUTS alone (stdin + vars); the
# shipped final is never consulted, so this is what a production validator
# could legitimately know.

def input_only_violations(case, out):
    stdin, vars_ = case["stdin"], case.get("vars", {})
    ask = vars_.get("ask", "")
    problems = []
    echoed = [s for s in sentences(stdin) if s in normalise(out)]
    if len(echoed) >= 2:
        problems.append("ECHO: these input lines came back as written, carry only their anchors inside new sentences: "
                        + " | ".join(f'"{s[:80]}"' for s in echoed[:3]))
    if len(stdin) >= 400 and len(out) >= 0.8 * len(stdin):
        problems.append(f"LENGTH: the reply is {len(out)} chars against {len(stdin)} chars of facts; "
                        "curate to well under the facts' length.")
    src = anchors(stdin + "\n" + "\n".join(vars_.values()))
    invented = sorted(a for a in anchors(out) - src if re.fullmatch(r"#\d+|\d{2,}", a))
    if invented:
        problems.append("INVENTED: these values are not in the facts, remove them: " + ", ".join(invented))
    limit = word_limit(ask)
    if limit and len(out.split()) > limit:
        problems.append(f"WORDS: {len(out.split())} words, the ask allows {limit}.")
    if not ask.strip() and "?" in out:
        problems.append("ASK-INVENTED: no ask was given, so the reply must contain no question.")
    # a question whose anchors all come from the facts and none from the ask is
    # a supplied fact turned into a question (STATED-NOT-ASKED)
    ask_anchors = anchors(ask)
    for q in re.findall(r"[^.?!\n]*\?", out):
        qa = anchors(q)
        if qa and qa <= anchors(stdin) and not (qa & ask_anchors):
            problems.append(f'ASKED-NOT-STATED: "{q.strip()[:120]}" turns a supplied fact into a question; state it.')
    if FILLER.search(out):
        problems.append("FILLER: generic praise or preamble; name the specific thing or drop it.")
    if INSTRUCTION_ECHO.search(out):
        problems.append("INSTRUCTION-ECHO: the reply talks about the reader in the third person; address them directly.")
    if PARTICIPIAL_TAIL.search(out):
        problems.append("TAIL: drop the trailing participial clause.")
    return problems


# ---------------------------------------------------------------- A0 / A1 / A5 / A6

def run_text(case, model_name, validate, retries, think=False):
    agent = Agent(model(model_name), output_type=str, retries=retries, model_settings=settings(think))
    state = {"last": "", "attempts": 0}
    if validate:
        @agent.output_validator
        def check(ctx: RunContext[None], output: str) -> str:
            state["last"], state["attempts"] = output, state["attempts"] + 1
            problems = input_only_violations(case, output)
            if problems:
                raise ModelRetry("Rewrite the reply. Problems:\n" + "\n".join(problems))
            return output
    t0 = time.time()
    try:
        result = agent.run_sync(render(case))
        out, err = result.output.strip(), None
    except Exception as e:  # retries exhausted: ship the last draft, flagged, like the wrapper does
        out, err, result = state["last"].strip(), f"{type(e).__name__}: {str(e)[:160]}", None
    return out, {
        "ms": int((time.time() - t0) * 1000),
        "requests": result.usage.requests if result else state["attempts"],
        "error": err,
        "violations_final": input_only_violations(case, out),
    }


# ---------------------------------------------------------------- A2 structured

class Reply(BaseModel):
    """The maintainer's reply, in parts. The caller assembles the text."""
    statement: str = Field(description="One sentence (two at most): the specific praise or the confirmed cause, "
                                       "in your own words, carrying the facts' anchors. Never a question.")
    asks: list[str] = Field(default_factory=list,
                            description="Exactly one direct question to the reader per distinct ask in the ask "
                                        "topic; empty when the ask block is empty. Never a supplied fact as a question.")

    @field_validator("statement")
    @classmethod
    def statement_is_a_statement(cls, v):
        if "?" in v:
            raise ValueError("statement must not contain a question; questions go in asks")
        if not v.strip():
            raise ValueError("statement is required")
        return v.strip()

    @field_validator("asks")
    @classmethod
    def asks_are_questions(cls, v):
        for q in v:
            if not q.strip().endswith("?"):
                raise ValueError(f"each ask must be a direct question ending with '?': {q[:60]}")
        return [q.strip() for q in v]


class ReviewReply(BaseModel):
    """A verdict-first review reply, in parts."""
    verdict: str = Field(description="One sentence stating the given verdict plainly, no hedge, not a question.")
    evidence: str = Field(description="Flowing prose sentences of your own carrying EVERY anchor from the facts "
                                      "(paths, numbers, hashes, refs) spelled as given; well under the facts' length; "
                                      "no list, no heading, no fact line copied.")
    asks: list[str] = Field(default_factory=list,
                            description="One direct question per distinct ask in the ask topic; empty when none.")

    @field_validator("verdict")
    @classmethod
    def verdict_plain(cls, v):
        if "?" in v:
            raise ValueError("verdict must not be a question")
        return v.strip()

    @field_validator("asks")
    @classmethod
    def asks_are_questions(cls, v):
        for q in v:
            if not q.strip().endswith("?"):
                raise ValueError(f"each ask must end with '?': {q[:60]}")
        return [q.strip() for q in v]


def assemble(case, obj):
    v = case.get("vars", {})
    head = ""
    if v.get("recipient"):
        head += f"@{v['recipient']}, "
    if v.get("opener"):
        head += v["opener"].strip() + " "
    body = obj.statement if isinstance(obj, Reply) else obj.verdict + " " + obj.evidence
    if len(obj.asks) == 1:
        body += " " + obj.asks[0]
    elif len(obj.asks) > 1:
        body += "\n" + "\n".join(f"{i + 1}. {q}" for i, q in enumerate(obj.asks))
    text = head + body
    if v.get("signoff"):
        text += "\n\n" + v["signoff"].strip()
    return text.strip()


def run_struct(case, model_name, retries):
    schema = Reply if case["recipe"] == "maintainer-reply" else ReviewReply
    agent = Agent(model(model_name), output_type=schema, retries=retries, model_settings=settings(),
                  instructions="Return the reply through the tool, in parts. The user's message holds the rules and "
                               "the facts; the tool's field descriptions say what goes in each part. The handle, "
                               "opener and sign-off are added by the caller: leave them out of every field.")
    state = {"last": "", "parts": None, "attempts": 0}

    @agent.output_validator
    def check(ctx: RunContext[None], output):
        text = assemble(case, output)
        state["last"], state["parts"], state["attempts"] = text, output.model_dump(), state["attempts"] + 1
        problems = input_only_violations(case, text)
        if problems:
            raise ModelRetry("Regenerate the parts. Problems with the assembled reply:\n" + "\n".join(problems))
        return output

    t0 = time.time()
    try:
        result = agent.run_sync(render(case))
        out, err, parts = assemble(case, result.output), None, result.output.model_dump()
    except Exception as e:
        out, err, parts, result = state["last"], f"{type(e).__name__}: {str(e)[:160]}", state["parts"], None
    return out, {
        "ms": int((time.time() - t0) * 1000),
        "requests": result.usage.requests if result else state["attempts"],
        "error": err,
        "parts": parts,
        "violations_final": input_only_violations(case, out),
    }


# ---------------------------------------------------------------- A3 critic

class Violation(BaseModel):
    label: str = Field(description="One of ECHO, ASKED-NOT-STATED, INVENTED, DROPPED, MERGED, LIST, LENGTH, OPENER, "
                                   "TAIL, CLAIMED-ACTION, OTHER")
    quote: str = Field(description="The offending words from the draft, or the dropped anchor")
    fix: str = Field(description="What the reviser must do, in one sentence")


class Critique(BaseModel):
    violations: list[Violation] = Field(default_factory=list, description="Empty when the draft satisfies every rule")


CRITIC_INSTRUCTIONS = (
    "You review a draft reply against the rules and the facts in the message. You never rewrite the draft. "
    "Report only concrete violations of the stated rules, quoting the draft. Deterministic findings are also "
    "listed below the draft; include them. An empty list means the draft may ship as it is."
)


def run_critic_pipeline(cases, model_name, critic_name, arm, think_critic=False):
    done = load_results(arm)
    todo = [c for c in cases if c["id"] not in done]
    drafts, critiques, timings = {}, {}, {}
    drafter = Agent(model(model_name), output_type=str, model_settings=settings())
    for c in todo:  # stage 1
        t0 = time.time()
        drafts[c["id"]] = drafter.run_sync(render(c)).output.strip()
        timings[c["id"]] = [int((time.time() - t0) * 1000)]
        print(f"{arm} draft {c['id']} {len(drafts[c['id']])} chars", flush=True)
    critic = Agent(model(critic_name), output_type=Critique, retries=2, model_settings=settings(think_critic),
                   instructions=CRITIC_INSTRUCTIONS)
    for c in todo:  # stage 2
        det = input_only_violations(c, drafts[c["id"]])
        prompt = (render(c) + "\n\n=== DRAFT UNDER REVIEW ===\n" + drafts[c["id"]]
                  + "\n\n=== Deterministic findings ===\n" + ("\n".join(det) if det else "(none)"))
        t0 = time.time()
        try:
            critiques[c["id"]] = critic.run_sync(prompt).output
        except Exception as e:
            critiques[c["id"]] = Critique(violations=[Violation(label="OTHER", quote="", fix=f"critic failed: {e}")])
        timings[c["id"]].append(int((time.time() - t0) * 1000))
        print(f"{arm} critique {c['id']} {len(critiques[c['id']].violations)} violations", flush=True)
    reviser = Agent(model(model_name), output_type=str, model_settings=settings())
    for c in todo:  # stage 3
        v = critiques[c["id"]].violations
        t0 = time.time()
        if not v:
            out = drafts[c["id"]]
        else:
            notes = "\n".join(f"- {x.label}: \"{x.quote}\" -> {x.fix}" for x in v)
            out = reviser.run_sync(render(c) + "\n\n=== DRAFT ===\n" + drafts[c["id"]]
                                   + "\n\n=== REVIEW: fix every item, keep everything else ===\n" + notes
                                   + "\n\nOutput only the corrected reply text.").output.strip()
        timings[c["id"]].append(int((time.time() - t0) * 1000))
        save_result(arm, c, out, {"draft": drafts[c["id"]], "critique": critiques[c["id"]].model_dump(),
                                  "violations_final": input_only_violations(c, out),
                                  "critic_model": critic_name, "model": model_name,
                                  "ms": sum(timings[c["id"]]), "stage_ms": timings[c["id"]],
                                  "requests": 3 if v else 2})
        print(f"{arm} revise {c['id']} {len(out)} chars", flush=True)


# ---------------------------------------------------------------- main

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("arm")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--critic-model", default=DEFAULT_MODEL)
    ap.add_argument("--think-critic", action="store_true")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--name")
    a = ap.parse_args()
    arm = a.name or a.arm
    cases = load_cases(limit=a.limit)
    if a.arm == "A3-critic":
        run_critic_pipeline(cases, a.model, a.critic_model, arm, a.think_critic)
        sys.exit(0)
    done = load_results(arm)
    for case in cases:
        if case["id"] in done:
            continue
        if a.arm in ("A0-py", "A5-model"):
            out, extra = run_text(case, a.model, validate=False, retries=0)
        elif a.arm == "A6-think":
            out, extra = run_text(case, a.model, validate=False, retries=0, think=True)
        elif a.arm == "A1-validate":
            out, extra = run_text(case, a.model, validate=True, retries=2)
        elif a.arm == "A2-struct":
            out, extra = run_struct(case, a.model, retries=2)
        else:
            sys.exit(f"unknown arm {a.arm}")
        extra["model"] = a.model
        save_result(arm, case, out, extra)
        print(f"{arm} {case['id']} {case['recipe'][:18]} req={extra.get('requests')} {extra['ms']}ms {len(out)} chars"
              + (f" ERR {extra['error']}" if extra.get("error") else ""), flush=True)
