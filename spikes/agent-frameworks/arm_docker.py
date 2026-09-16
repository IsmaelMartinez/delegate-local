"""docker agent arms of the spike (throwaway).

  A4a-single    one agent on the MLX endpoint, rendered recipe prompt as the message
  A4b-pipeline  drafter -> critic -> reviser chained with force_handoff
  A4c-loop      drafter with the critic as a sub-agent, told to iterate (model-driven loop)

`docker agent run --exec --json <yaml> -` reads the message on stdin and emits
NDJSON events; the answer is the concatenation of `agent_choice` events for
the final agent (after its last tool call, when it made any),
`agent_choice_reasoning` events are the model's thinking, `tool_call` events
are sub-agent transfers.

Usage: python3 arm_docker.py <arm> [limit] [--name LABEL]
"""
import json
import subprocess
import sys
import time
from pathlib import Path

from common import load_cases, load_results, render, save_result

HERE = Path(__file__).resolve().parent
YAML = {
    "A4a-single": (HERE / "docker/single.yaml", "root"),
    "A4b-pipeline": (HERE / "docker/pipeline.yaml", "reviser"),
    "A4c-loop": (HERE / "docker/loop.yaml", "root"),
}


def run_case(case, yaml_path, final_agent):
    t0 = time.time()
    proc = subprocess.run(
        ["docker", "agent", "run", "--exec", "--json", str(yaml_path), "-"],
        input=render(case), capture_output=True, text=True, timeout=3600,
    )
    ms = int((time.time() - t0) * 1000)
    text, reasoning_chunks, errors, tool_calls, order = {}, 0, [], [], []
    for line in proc.stdout.splitlines():
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        t, agent = ev.get("type"), ev.get("agent_name")
        if t == "agent_choice":
            text.setdefault(agent, []).append(ev.get("content", ""))
            if not order or order[-1] != agent:
                order.append(agent)
        elif t == "agent_choice_reasoning":
            reasoning_chunks += 1
        elif t == "tool_call":
            tool_calls.append(ev.get("tool_name") or ev.get("name") or str(ev)[:80])
            # the final agent's answer is what it says after its last tool call
            if agent == final_agent:
                text[final_agent] = []
        elif t == "error":
            errors.append(str(ev)[:200])
    per_agent = {k: "".join(v).strip() for k, v in text.items()}
    out = per_agent.get(final_agent) or (list(per_agent.values())[-1] if per_agent else "")
    return out, {"ms": ms, "exit": proc.returncode, "agents": order, "per_agent": per_agent,
                 "reasoning_chunks": reasoning_chunks, "tool_calls": tool_calls, "errors": errors,
                 "stderr": proc.stderr[-300:]}


if __name__ == "__main__":
    argv = sys.argv[1:]
    name = None
    if "--name" in argv:
        i = argv.index("--name")
        name = argv[i + 1]
        del argv[i:i + 2]
    arm = argv[0]
    limit = int(argv[1]) if len(argv) > 1 else None
    name = name or arm
    yaml_path, final_agent = YAML[arm]
    done = load_results(name)
    for case in load_cases(limit=limit):
        if case["id"] in done:
            continue
        out, extra = run_case(case, yaml_path, final_agent)
        save_result(name, case, out, extra)
        print(f"{name} {case['id']} {case['recipe'][:18]} exit={extra['exit']} {extra['ms']}ms "
              f"agents={extra['agents']} tool_calls={len(extra['tool_calls'])} think_chunks={extra['reasoning_chunks']} "
              f"{len(out)} chars", flush=True)
