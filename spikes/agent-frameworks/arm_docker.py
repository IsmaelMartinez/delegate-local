"""docker agent arms of the spike (throwaway).

  A4a-single    one agent on the MLX endpoint, rendered recipe prompt as the message
  A4b-pipeline  drafter -> critic -> reviser chained with force_handoff

`docker agent run --exec --json <yaml> -` reads the message on stdin and emits
NDJSON events; the answer is the concatenation of `agent_choice` events for
the last agent, `agent_choice_reasoning` events are the model's thinking
(docker agent has no setting that switches it off on this endpoint).
"""
import json
import subprocess
import sys
import time
from pathlib import Path

from common import load_cases, load_results, render, save_result

HERE = Path(__file__).resolve().parent
YAML = {"A4a-single": HERE / "docker/single.yaml", "A4b-pipeline": HERE / "docker/pipeline.yaml"}


def run_case(case, yaml_path, final_agent):
    t0 = time.time()
    proc = subprocess.run(
        ["docker", "agent", "run", "--exec", "--json", str(yaml_path), "-"],
        input=render(case), capture_output=True, text=True, timeout=1800,
    )
    ms = int((time.time() - t0) * 1000)
    text, per_agent, reasoning_chunks, errors = {}, {}, 0, []
    for line in proc.stdout.splitlines():
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = ev.get("type")
        if t == "agent_choice":
            text.setdefault(ev.get("agent_name"), []).append(ev.get("content", ""))
        elif t == "agent_choice_reasoning":
            reasoning_chunks += 1
        elif t == "error":
            errors.append(str(ev)[:200])
    per_agent = {k: "".join(v).strip() for k, v in text.items()}
    out = per_agent.get(final_agent) or (list(per_agent.values())[-1] if per_agent else "")
    return out, {"ms": ms, "exit": proc.returncode, "agents": list(per_agent), "per_agent": per_agent,
                 "reasoning_chunks": reasoning_chunks, "errors": errors, "stderr": proc.stderr[-300:]}


if __name__ == "__main__":
    arm = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else None
    final_agent = "reviser" if arm == "A4b-pipeline" else "root"
    done = load_results(arm)
    for case in load_cases(limit=limit):
        if case["id"] in done:
            continue
        out, extra = run_case(case, YAML[arm], final_agent)
        save_result(arm, case, out, extra)
        print(f"{arm} {case['id']} {case['recipe'][:18]} exit={extra['exit']} {extra['ms']}ms "
              f"agents={extra['agents']} think_chunks={extra['reasoning_chunks']} {len(out)} chars", flush=True)
