#!/usr/bin/env bash
# Unit tests for scripts/lib/gpu-gate.sh (#646). osascript, ioreg and sleep
# are stubs on PATH, so the tests never read this machine's real state or
# wait: the thermal state and utilisation come from files the test writes,
# and each sleep is logged rather than slept.

set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
LIB="$REPO/scripts/lib/gpu-gate.sh"

stub=$(mktemp -d)
cat > "$stub/osascript" <<EOF
#!/usr/bin/env bash
cat "$stub/thermal" 2>/dev/null
EOF
cat > "$stub/ioreg" <<EOF
#!/usr/bin/env bash
while IFS= read -r u; do printf '    | |   "PerformanceStatistics" = {"Device Utilization %%"=%s,"Renderer Utilization %%"=1}\n' "\$u"; done < "$stub/util"
EOF
cat > "$stub/sleep" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$stub/slept"
# Each sleep cools the machine by one step, so a wait can end.
t=\$(cat "$stub/thermal" 2>/dev/null); [[ -n "\$t" && "\$t" -gt 0 && -f "$stub/cools" ]] && echo \$((t - 1)) > "$stub/thermal"
exit 0
EOF
chmod +x "$stub/osascript" "$stub/ioreg" "$stub/sleep"

# run_gate <thermal> <util lines> <shell snippet> — sources the lib under the
# stubs and runs the snippet; prints its stdout and stderr, then "rc=N".
run_gate() {
  printf '%s' "$1" > "$stub/thermal"; printf '%s\n' "$2" > "$stub/util"; rm -f "$stub/slept"
  env -u DELEGATE_GPU_GATE PATH="$stub:$SAFE_PATH" bash -c ". '$LIB'; $3; echo rc=\$?" 2>&1
}

out=$(run_gate 0 "12" 'gpu_gate_wait')
assert_contains "rc=0" "$out" "nominal and idle: no wait"
assert_eq "" "$(cat "$stub/slept" 2>/dev/null)" "nominal and idle: never sleeps"

out=$(run_gate 0 "$(printf '12\n95')" 'gpu_gate_busy')
assert_contains "GPU at 95%" "$out" "busy reads the highest accelerator's utilisation"

out=$(run_gate 3 "12" 'DELEGATE_GPU_WAIT_MAX=30 DELEGATE_GPU_POLL=15 gpu_gate_wait')
assert_contains "rc=75" "$out" "critical and never cooling: gives up with 75"
assert_contains "still busy after 30s (thermal state 3); stopping" "$out" "give-up message names the wait and the reason"
assert_eq "2" "$(wc -l < "$stub/slept" | tr -d ' ')" "waited two polls of 15 s before giving up"

touch "$stub/cools"
out=$(run_gate 3 "12" 'gpu_gate_wait')
assert_contains "rc=0" "$out" "serious then cooling: proceeds once below the cap"
assert_contains "gpu-gate: waiting, thermal state 3" "$out" "waiting is announced on stderr"
assert_eq "2" "$(wc -l < "$stub/slept" | tr -d ' ')" "cools from 3 to 1 in two polls, then proceeds"
rm -f "$stub/cools"

out=$(run_gate 1 "12" 'gpu_gate_wait')
assert_contains "rc=0" "$out" "fair (1) is below the default cap of 2"

out=$(run_gate 3 "99" 'DELEGATE_GPU_GATE=0 gpu_gate_wait; DELEGATE_GPU_GATE=0 DELEGATE_GPU_COOLDOWN=5 gpu_gate_cooldown')
assert_contains "rc=0" "$out" "DELEGATE_GPU_GATE=0 turns the gate off"
assert_eq "" "$(cat "$stub/slept" 2>/dev/null)" "gate off: neither waits nor cools down"

out=$(run_gate 0 "12" 'gpu_gate_cooldown')
assert_eq "" "$(cat "$stub/slept" 2>/dev/null)" "cooldown defaults to none"
out=$(run_gate 0 "12" 'DELEGATE_GPU_COOLDOWN=5 gpu_gate_cooldown')
assert_eq "5" "$(cat "$stub/slept" 2>/dev/null)" "DELEGATE_GPU_COOLDOWN rests between items"

# No osascript or ioreg (Linux CI): nothing to read, nothing gates.
nobin=$(mktemp -d); cp "$stub/sleep" "$nobin/"
out=$(env -u DELEGATE_GPU_GATE PATH="$nobin" /bin/bash -c ". '$LIB'; gpu_gate_wait; echo rc=\$?" 2>&1)
assert_contains "rc=0" "$out" "no signal readable: the gate does not block"
rm -rf "$nobin" "$stub"

finish
