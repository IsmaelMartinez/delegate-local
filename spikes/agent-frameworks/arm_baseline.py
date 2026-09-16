"""Arm A0: the current bash wrapper, verbatim, metrics off (throwaway)."""
import os
import subprocess
import sys
import time

from common import REPO, load_cases, load_results, save_result


def run_case(case, env_extra=None):
    cmd = ["bash", str(REPO / "scripts/delegate.sh"), "--recipe", case["recipe"]]
    for k, v in case.get("vars", {}).items():
        cmd += ["--var", f"{k}={v}"]
    env = {**os.environ, "DELEGATE_LOCAL_NO_METRICS": "1", "DELEGATE_PREFLIGHT_TIMEOUT": "120", **(env_extra or {})}
    t0 = time.time()
    proc = subprocess.run(cmd, input=case["stdin"], capture_output=True, text=True, env=env, cwd=REPO)
    ms = int((time.time() - t0) * 1000)
    checks = [l for l in proc.stderr.splitlines() if "check '" in l or "retry" in l.lower()]
    return proc.stdout.strip(), {"ms": ms, "exit": proc.returncode, "stderr_checks": checks[:6]}


if __name__ == "__main__":
    arm = sys.argv[1] if len(sys.argv) > 1 else "A0-bash"
    done = load_results(arm)
    for case in load_cases():
        if case["id"] in done:
            continue
        out, extra = run_case(case)
        save_result(arm, case, out, extra)
        print(f"{arm} {case['id']} {case['recipe'][:18]} exit={extra['exit']} {extra['ms']}ms {len(out)} chars", flush=True)
