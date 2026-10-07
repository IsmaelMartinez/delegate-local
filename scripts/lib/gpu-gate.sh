#!/usr/bin/env bash
# Heat gate for local batch inference (#646). Batch callers (replay-recipe.sh)
# call gpu_gate_wait before each item and gpu_gate_cooldown after it, so a
# long run backs off while the machine is hot or another session holds the
# GPU, instead of stacking more load on it. Interactive delegate.sh calls are
# not gated: one call is short, and a lock on the runtime path would add
# latency to every delegation and could go stale.
#
# Two signals, both readable without sudo and measured on 2026-10-06/07:
#   thermal  macOS's own thermal state (0 nominal, 1 fair, 2 serious,
#            3 critical) from NSProcessInfo via osascript. `pmset -g therm`
#            reports nothing on this hardware, and GPU utilisation alone does
#            not track heat.
#   util     the highest `Device Utilization %` ioreg reports for an
#            IOAccelerator; above the cap means another session is
#            generating.
# A signal that cannot be read (Linux, a missing binary) does not gate.
#
# Env:  DELEGATE_GPU_GATE=0          turn the gate off
#       DELEGATE_GPU_MAX_THERMAL     wait at or above this state (default 2)
#       DELEGATE_GPU_MAX_UTIL        wait above this percentage (default 90)
#       DELEGATE_GPU_POLL            seconds between checks while waiting (15)
#       DELEGATE_GPU_WAIT_MAX        give up after this many seconds (600)
#       DELEGATE_GPU_COOLDOWN        seconds to rest after each item (0)
# Sourcing has no side effects. bash 3.2 portable.

# The exit code a batch caller uses when the gate gives up (EX_TEMPFAIL), so
# a scheduler can tell "too hot, rerun later" from a failure.
GPU_GATE_BUSY=75

gpu_gate_thermal() {
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSProcessInfo.processInfo.thermalState' </dev/null 2>/dev/null \
    | tr -cd '0-9'
}

gpu_gate_util() {
  command -v ioreg >/dev/null 2>&1 || return 0
  ioreg -r -d 1 -c IOAccelerator </dev/null 2>/dev/null \
    | grep -oE '"Device Utilization %"=[0-9]+' | sed 's/.*=//' | sort -n | tail -1
}

# gpu_gate_int NAME DEFAULT — the whole-number value of env var NAME, or
# DEFAULT with a warning when it is set to anything else (a fraction, a word),
# so a typo cannot reach (( )) and silently gate on 0 or break the loop; a
# leading zero is read as base 10, not octal.
gpu_gate_int() {
  local v="${!1:-}"
  case "$v" in
    '') echo "$2" ;;
    *[!0-9]*) echo "gpu-gate: $1='$v' is not a whole number; using $2" >&2; echo "$2" ;;
    *) echo "$((10#$v))" ;;
  esac
}

# gpu_gate_busy — prints why and returns 0 while the machine should not take
# more local inference; returns 1 when it is clear.
gpu_gate_busy() {
  local t u
  t=$(gpu_gate_thermal)
  if [[ -n "$t" ]] && (( t >= $(gpu_gate_int DELEGATE_GPU_MAX_THERMAL 2) )); then
    echo "thermal state $t"; return 0
  fi
  u=$(gpu_gate_util)
  if [[ -n "$u" ]] && (( u > $(gpu_gate_int DELEGATE_GPU_MAX_UTIL 90) )); then
    echo "GPU at ${u}%"; return 0
  fi
  return 1
}

# gpu_gate_wait — returns 0 once the machine is clear, or GPU_GATE_BUSY after
# DELEGATE_GPU_WAIT_MAX seconds of waiting. Progress goes to stderr. A poll
# under one second is taken as one, so the probes never spin.
gpu_gate_wait() {
  [[ "${DELEGATE_GPU_GATE:-1}" == "0" ]] && return 0
  local step max waited=0 why s
  step=$(gpu_gate_int DELEGATE_GPU_POLL 15); (( step < 1 )) && step=1
  max=$(gpu_gate_int DELEGATE_GPU_WAIT_MAX 600)
  while why=$(gpu_gate_busy); do
    if (( waited >= max )); then
      echo "gpu-gate: still busy after ${waited}s ($why); stopping, rerun to resume" >&2
      return "$GPU_GATE_BUSY"
    fi
    echo "gpu-gate: waiting, $why" >&2
    # The last sleep is cut to what is left, so WAIT_MAX is a real cap.
    s="$step"; (( max - waited < s )) && s=$((max - waited))
    sleep "$s"
    waited=$((waited + s))
  done
  return 0
}

gpu_gate_cooldown() {
  [[ "${DELEGATE_GPU_GATE:-1}" == "0" ]] && return 0
  local c
  c=$(gpu_gate_int DELEGATE_GPU_COOLDOWN 0)
  (( c > 0 )) && sleep "$c"
  return 0
}
