#!/usr/bin/env bash
# interrupt-test.sh — verifies that a running update can be stopped with SIGTERM/Ctrl-C:
# the guest command is killed at once, an ABORTED notification goes out, no child lingers.
set -u
cd "$(dirname "$0")"
M="$PWD"
bash "$M/run-test.sh" --list >/dev/null 2>&1 || { echo "harness not ready"; exit 1; }
# make guest 103's apt hang
sed -i '2i [ "${MOCK_CT:-}" = 103 ] && sleep 120' "$M/guest-deb/apt-get"
: > "$M/state/ntfy.log"
export PATH="$M/bin:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8
bash "$M/sandbox/pve-updater.sh" --only 103 --no-host > "$M/state/interrupt.out" 2>&1 &
PID=$!
sleep 8
echo "--- console before the signal:"; tail -n 2 "$M/state/interrupt.out"
T0=$(date +%s)
kill -TERM "$PID"
wait "$PID"; RC=$?
echo "--- updater exit=$RC after $(( $(date +%s) - T0 ))s; console after the signal:"
tail -n 3 "$M/state/interrupt.out"
echo "--- notification:"; grep -E 'Title|BODY' -A1 "$M/state/ntfy.log" | cut -c1-100
sleep 2
echo "--- lingering mock apt sleeps: $(ps -ef | grep -c '[s]leep 120')"
sed -i '2d' "$M/guest-deb/apt-get"
