#!/usr/bin/env bash
# linux_probe.sh — runs INSIDE ubuntu:24.04 with /src mounted read-only.
# Installs deps, copies src/ into /work (writable, ext4/overlay), runs
# install.sh, session_start/end smoke, concurrent_smoke.sh, and the full
# bats unit suite. Captures concise status lines per phase.
#
# Phase 7 / T7.07 (F-019 RESOLVED): driver relocated from
# .coord/experiments/linux-parity/linux_probe.sh (gitignored via .coord/
# blanket) to src/tests/manual/linux_probe.sh (committed). Phase
# additions now propagate via standard commit flow; fresh checkouts
# include the full probe suite without manual sync.
#
# Canonical invocation (host macOS):
#   bash .coord/experiments/linux-parity/run.sh
# (the host-side wrapper is gitignored but its INNER path now points
# at this file). Operators may also invoke directly inside a Docker
# ubuntu:24.04 container with /src mounted read-only.
set -euo pipefail

banner() { printf '\n=== %s ===\n' "$*"; }

banner 'environment'
uname -a
cat /etc/os-release | head -5
bash --version | head -1
id

banner 'apt: install deps (non-interactive)'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -qq -y --no-install-recommends \
  bash jq util-linux coreutils git bats perl ca-certificates \
  inotify-tools \
  >/dev/null
command -v bash
command -v jq
command -v flock
command -v sha256sum
command -v shasum || echo "shasum: absent (linux has sha256sum; hash.sh falls back)"
command -v git
command -v bats
bats --version
jq --version
flock --version | head -1
sha256sum --version | head -1
perl --version | head -2

banner 'init a fresh git repo inside container (so install.sh finds a toplevel)'
# install.sh resolves repo root via git rev-parse --show-toplevel;
# our target is /work, which we initialise as a fresh repo.
mkdir -p /work
cp -r /src /work/src
cd /work
git init -q
git config user.email linux-parity@test
git config user.name 'linux parity'
git add -A
# On a brand-new repo without any commits, session_start.sh will see
# `git rev-parse --verify HEAD` fail and store git_head="" — same as the
# original macOS first run. Make a seed commit to match a post-commit host.
git commit -q -m 'seed' >/dev/null || true

banner 'install.sh --yes'
bash /work/src/install.sh --yes

banner 'coord health'
/work/.coord/bin/coord health; echo "exit=$?"

banner 'coord status'
/work/.coord/bin/coord status

banner 'session_start → session_end smoke (direct, idempotent)'
# Run the session_start + session_end pair outside the installer's own smoke
# to ensure they work when invoked directly too.
SID="linux-smoke-$RANDOM"
export COORD_DIR=/work/.coord CLAUDE_COORD=1
printf '%s\n' "{\"session_id\":\"$SID\",\"cwd\":\"/work\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}" \
  | /work/.coord/hooks/session_start.sh >/tmp/start.out
echo 'start stdout:'; cat /tmp/start.out; echo
echo 'active markers after start:'; ls /work/.coord/sessions/
printf '%s\n' "{\"session_id\":\"$SID\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"linux-smoke\"}" \
  | /work/.coord/hooks/session_end.sh >/dev/null
echo 'active markers after end (expect gone for this sid):'
ls /work/.coord/sessions/ || echo '(none)'
echo 'events.jsonl tail:'
tail -5 /work/.coord/events.jsonl

banner '5-session concurrent smoke (T0.22 port)'
bash /work/src/tests/concurrent_smoke.sh

# Clear env that the earlier "direct smoke" section exported — otherwise
# bats inherits CLAUDE_COORD=1 and the "unset" tests fail for the wrong
# reason.
unset CLAUDE_COORD
unset COORD_DIR
unset SESSION_ID

banner 'bats unit suite'
bats /work/src/tests/unit
echo "bats exit=$?"

banner 'two_session_warn manual smoke (Phase 1 done-when + Phase 2 02_lock_deny)'
bash /work/src/tests/manual/two_session_warn.sh
echo "two_session_warn exit=$?"

banner 'phase3_ship_gate manual smoke (Phase 3 done-when 4 scenarios)'
bash /work/src/tests/manual/phase3_ship_gate.sh
echo "phase3_ship_gate exit=$?"

banner 'phase4_ship_gate manual smoke (Phase 4 done-when 4 scenarios)'
bash /work/src/tests/manual/phase4_ship_gate.sh
echo "phase4_ship_gate exit=$?"

banner 'phase5_ship_gate manual smoke (Phase 5 done-when 4 scenarios)'
bash /work/src/tests/manual/phase5_ship_gate.sh
echo "phase5_ship_gate exit=$?"

banner 'phase6_ship_gate manual smoke (Phase 6 done-when 5 scenarios)'
bash /work/src/tests/manual/phase6_ship_gate.sh
echo "phase6_ship_gate exit=$?"

banner 'phase7_ship_gate manual smoke (Phase 7 done-when 5 scenarios)'
bash /work/src/tests/manual/phase7_ship_gate.sh
echo "phase7_ship_gate exit=$?"

banner 'watchdog ps lstart format compatibility (BSD vs GNU)'
# Per PR-PHASE3-02 disposition #4: verify GNU `ps -p <pid> -o lstart=`
# produces a parseable, trim-able string identical in shape to the BSD
# (macOS) form. The watchdog code uses a single trim pipeline for both;
# any divergence would surface here as a non-empty non-trivial diff.
LX_LSTART_PID="$$"
LX_LSTART_RAW=$(ps -p "$LX_LSTART_PID" -o lstart= 2>/dev/null)
LX_LSTART_TRIMMED=$(printf '%s' "$LX_LSTART_RAW" | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
echo "GNU ps lstart raw:     [${LX_LSTART_RAW}]"
echo "GNU ps lstart trimmed: [${LX_LSTART_TRIMMED}]"
# Sanity: trimmed value must contain a 4-digit year and not be empty.
case "$LX_LSTART_TRIMMED" in
  *2026*|*2025*|*2027*) echo "lstart format check: OK (contains expected year)" ;;
  *)                    echo "lstart format check: WARN — unexpected format [$LX_LSTART_TRIMMED]" ;;
esac

banner 'Phase 2 lock event sanity (LOCK_*, NOTIFICATION_PRODUCED, MEDIATOR_PENDING_DELIVERED)'
# Drive a minimal acquire→deny→release sequence directly to confirm the
# Phase 2 events surface on Linux's overlay/ext4 fs. Reuses the same
# fixture init pattern.
LX_TMP=$(mktemp -d -t lx-phase2-XXXX)
mkdir -p "$LX_TMP/.coord/sessions" "$LX_TMP/.coord/mediator" "$LX_TMP/.coord/validation" "$LX_TMP/.coord/hooks" "$LX_TMP/.coord/lib"
printf '%s' '{"schema_version":"1.0","sessions":{},"locks":{},"wait_queue":{},"read_sets":{},"notifications":{},"self_tasks":{},"anomaly_votes":{},"task_graph":{}}' >"$LX_TMP/.coord/sessions.json"
touch "$LX_TMP/.coord/sessions.lock" "$LX_TMP/.coord/sessions.json.lock" "$LX_TMP/.coord/events.lock"
A_SID="lx-a-001"; B_SID="lx-b-001"
touch "$LX_TMP/.coord/sessions/${A_SID}.active" "$LX_TMP/.coord/sessions/${B_SID}.active"
jq --arg a "$A_SID" --arg b "$B_SID" '.sessions[$a]={state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"} | .sessions[$b]={state:"ACTIVE",pid:2,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}' "$LX_TMP/.coord/sessions.json" > "$LX_TMP/.coord/sessions.json.new"
mv "$LX_TMP/.coord/sessions.json.new" "$LX_TMP/.coord/sessions.json"
LX_F="$LX_TMP/foo.ts"; printf 'foo\n' >"$LX_F"
export COORD_DIR="$LX_TMP/.coord" CLAUDE_COORD=1
printf '%s' '{"session_id":"'"$A_SID"'","cwd":"'"$LX_TMP"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$LX_F"'"}}' \
  | /work/src/adapters/claude-code/hooks/pre_tool_use_write.sh >/dev/null
sleep 1
DENY_OUT=$(printf '%s' '{"session_id":"'"$B_SID"'","cwd":"'"$LX_TMP"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$LX_F"'"}}' \
  | /work/src/adapters/claude-code/hooks/pre_tool_use_write.sh 2>/dev/null)
echo "deny stdout (truncated):"; echo "$DENY_OUT" | head -c 200; echo "..."
printf '%s' '{"session_id":"'"$A_SID"'","cwd":"'"$LX_TMP"'","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$LX_F"'"}}' \
  | /work/src/adapters/claude-code/hooks/post_tool_use_write.sh >/dev/null
sleep 0.4
echo "Phase 2 events (kind counts):"
jq -rs '
  reduce .[] as $e ({}; .[$e.kind] = (.[$e.kind] // 0) + 1)
  | to_entries
  | map(select(.key | IN("LOCK_ACQUIRED","LOCK_DENIED","LOCK_RELEASED","NOTIFICATION_PRODUCED","WAIT_RELEASED","WAIT_TIMEOUT","WAIT_CLAMPED","MEDIATOR_PENDING_DELIVERED")))
  | map(.key + "=" + (.value | tostring))
  | join(", ")
' "$LX_TMP/.coord/events.jsonl"
unset COORD_DIR CLAUDE_COORD

banner 'coord wait polling latency on Linux (release-detection time)'
# Single-waiter scenario: B waits, A releases at t=1s, measure detection latency.
LXW=$(mktemp -d -t lx-cw-XXXX)
mkdir -p "$LXW/.coord/sessions" "$LXW/.coord/mediator"
printf '%s' '{"schema_version":"1.0","sessions":{"holder":{"state":"ACTIVE","pid":1,"pid_lstart":"x","registered_at":"y","last_activity_at":"z","git_head":"","prompt_id":null,"script_version":"1.0"}},"locks":{},"wait_queues":{},"read_sets":{},"notifications":{},"self_tasks":{},"anomaly_votes":{},"task_graph":{}}' >"$LXW/.coord/sessions.json"
mkdir -p "$LXW/.coord/wait_queues" "$LXW/.coord/wakers"
touch "$LXW/.coord/sessions.lock" "$LXW/.coord/events.lock" "$LXW/.coord/sessions/holder.active"
# Phase 5: detect installed wait_backend so the latency reflects the
# event-driven path (inotifywait on Linux); record both detection and
# resolved values for the audit trail.
printf '{"schema_version":"1.0","wait_backend":"auto"}' >"$LXW/.coord/config.json"
echo "wait_backend detect: $(. /work/src/core/lib/wait_backend.sh; coord_wait_backend_detect)"
LXF=$LXW/foo.ts; printf 'foo\n' >"$LXF"
jq --arg f "$LXF" '.locks[$f] = {session:"holder", acquired_at:"2026-01-01T00:00:00Z", last_refresh_at:"t", tasks:[]}' "$LXW/.coord/sessions.json" > "$LXW/.coord/sessions.json.new"
mv "$LXW/.coord/sessions.json.new" "$LXW/.coord/sessions.json"
# Phase 5 release-side: parallel subshell removes the lock AND writes
# a stub diff_summary to every queued waiter's wake_file (mirroring
# notify_waiters.sh stub producer that T5.04 will replace with real
# verdict-file diff_summary lookup).
( sleep 1 \
  && jq --arg f "$LXF" 'del(.locks[$f])' "$LXW/.coord/sessions.json" > "$LXW/.coord/sessions.json.new" \
  && mv "$LXW/.coord/sessions.json.new" "$LXW/.coord/sessions.json" \
  && for w in "$LXW/.coord/wakers"/waiter-*.wake; do
       [ -e "$w" ] && printf 'modified by holder\n' > "$w"
     done ) &
T0=$(date -u +%s%N)
COORD_DIR="$LXW/.coord" SESSION_ID=waiter /work/src/core/bin/coord wait "$LXF" --timeout 30 >/dev/null
T1=$(date -u +%s%N)
wait
echo "Linux coord wait detection latency: $(( (T1 - T0) / 1000000 )) ms (release at t=1000ms; expect ~1000-1100ms with inotifywait, ~1000-1300ms with polling)"

banner 'coord health (post)'
/work/.coord/bin/coord health; echo "exit=$?"

banner 'summary marker'
echo 'LINUX_PARITY_COMPLETE'
