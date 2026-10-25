#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# pve-updater.sh — Automated Proxmox guest + host updater with ntfy report
# ═══════════════════════════════════════════════════════════════════════
# Discovers every LXC container and QEMU VM on this node at runtime (no
# inventory file to keep in sync), then for each RUNNING guest:
#
#   1. takes a rolling snapshot (rollback safety net, pruned automatically)
#   2. runs the optional pre-hook            (hooks/<ID>-pre.sh)
#   3. updates OS packages                   (apt or apk, auto-detected)
#   4. updates running Docker Compose stacks (auto-detected, only stacks that
#      are actually running; only services whose image changed are recreated)
#   5. runs the optional post-hook           (hooks/<ID>-post.sh)
#   6. verifies the guest is still running   (restarts it if not)
#   7. optionally reboots it if a reboot is pending (off by default)
#
# Then it optionally runs the community-scripts app updater, updates the
# PVE host itself (apt dist-upgrade, as Proxmox recommends — never a reboot),
# and sends ONE ntfy summary. If the run aborts for any reason you still get
# a notification.
#
# VMs are reached through the QEMU guest agent when it is installed, and
# through SSH (key auth, see setup-ssh.sh) otherwise.
#
# Per-guest control without touching this repo — Proxmox tags:
#   no-update     skip this guest entirely
#   no-apt        skip OS package updates
#   no-docker     skip Docker stack updates
#   no-snapshot   don't snapshot before updating
# …or a line in overrides.conf (same keywords plus ip=… for VMs).
#
# Usage:
#   ./pve-updater.sh                 Normal run (what cron calls)
#   ./pve-updater.sh --dry-run       Discover + probe guests, change nothing
#   ./pve-updater.sh --list          Print the discovered inventory and plan
#   ./pve-updater.sh --only 101,123  Restrict to these guest IDs
#   ./pve-updater.sh --no-host       Skip the PVE host update
#   ./pve-updater.sh --no-ntfy       Don't send a notification
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail
umask 027

# ── Paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$SCRIPT_DIR/settings.conf"
OVERRIDES_FILE="$SCRIPT_DIR/overrides.conf"
HOOKS_DIR="$SCRIPT_DIR/hooks"
LOG_DIR="$SCRIPT_DIR/logs"
LOCK_DIR="/run/lock"
{ [ -d "$LOCK_DIR" ] && [ -w "$LOCK_DIR" ]; } || LOCK_DIR="$SCRIPT_DIR"
LOCK_FILE="$LOCK_DIR/pve-updater.lock"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/update-$TIMESTAMP.log"
SNAP_NAME="autoupd-$TIMESTAMP"
SNAP_REGEX='autoupd-[0-9]{8}-[0-9]{6}'
START_TIME=$(date +%s)
NODE="$(hostname)"

# ═══════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════

DRY_RUN=false
LIST_ONLY=false
NO_HOST=false
NO_NTFY=false
ONLY_IDS=""

usage() {
    sed -n '/^# Usage:/,/^# ═/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | grep -v '^═'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)        DRY_RUN=true ;;
        --list)           LIST_ONLY=true ;;
        --only)           shift; ONLY_IDS="${1:-}" ;;
        --only=*)         ONLY_IDS="${1#--only=}" ;;
        --no-host|--skip-host) NO_HOST=true ;;
        --no-ntfy)        NO_NTFY=true ;;
        --force)          echo "NOTE: --force is obsolete (locking uses flock, stale locks cannot happen); ignoring." ;;
        -h|--help)        usage; exit 0 ;;
        *)                echo "ERROR: unknown argument '$1'"; usage; exit 2 ;;
    esac
    shift
done
ONLY_IDS="${ONLY_IDS//,/ }"

# ═══════════════════════════════════════════════════════════════════════
# Preflight
# ═══════════════════════════════════════════════════════════════════════

die() { echo "ERROR: $*" >&2; exit 1; }

for cmd in pct qm pvesh perl flock timeout; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found. This script must run on a Proxmox VE host."
done
perl -MJSON::PP -e 1 2>/dev/null || die "perl JSON::PP module missing (it ships with perl on PVE)."

[ -f "$SETTINGS_FILE" ] || die "settings.conf not found.
  First run? Copy the example and fill in your values:
    cp $SCRIPT_DIR/settings.conf.example $SCRIPT_DIR/settings.conf
    nano $SCRIPT_DIR/settings.conf"

# shellcheck disable=SC1090
source "$SETTINGS_FILE"

# ── Defaults for every optional setting (older settings.conf files keep working) ──
NTFY_URL="${NTFY_URL:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
NTFY_TOPIC="${NTFY_TOPIC:-alerts}"
APT_TIMEOUT="${APT_TIMEOUT:-900}"
DOCKER_TIMEOUT="${DOCKER_TIMEOUT:-600}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
UPDATE_PVE_HOST="${UPDATE_PVE_HOST:-true}"
UPDATE_DOCKER="${UPDATE_DOCKER:-true}"
UPDATE_APPS="${UPDATE_APPS:-false}"
APP_UPDATE_BACKUP="${APP_UPDATE_BACKUP:-no}"
APP_UPDATE_REBOOT="${APP_UPDATE_REBOOT:-no}"
APP_UPDATE_TIMEOUT="${APP_UPDATE_TIMEOUT:-3600}"
APP_UPDATE_URL="${APP_UPDATE_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/update-apps.sh}"
SNAPSHOT_BEFORE_UPDATE="${SNAPSHOT_BEFORE_UPDATE:-true}"
SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-2}"
SNAPSHOT_REQUIRED="${SNAPSHOT_REQUIRED:-false}"
APT_AUTOREMOVE="${APT_AUTOREMOVE:-true}"
AUTO_REBOOT_LXC="${AUTO_REBOOT_LXC:-false}"
AUTO_REBOOT_VM="${AUTO_REBOOT_VM:-false}"
MIN_FREE_MB="${MIN_FREE_MB:-500}"
HOST_MIN_FREE_MB="${HOST_MIN_FREE_MB:-2048}"
MAX_RUNTIME="${MAX_RUNTIME:-14400}"
BACKUP_WAIT_MAX="${BACKUP_WAIT_MAX:-1800}"
VM_EXEC_METHOD="${VM_EXEC_METHOD:-auto}"
VM_SSH_USER="${VM_SSH_USER:-root}"
VM_IP_PREFIX="${VM_IP_PREFIX:-}"

# ── Validate ──
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
for v in APT_TIMEOUT DOCKER_TIMEOUT LOG_RETENTION_DAYS APP_UPDATE_TIMEOUT SNAPSHOT_KEEP \
         MIN_FREE_MB HOST_MIN_FREE_MB MAX_RUNTIME BACKUP_WAIT_MAX; do
    is_uint "${!v}" || die "settings.conf: $v must be a whole number (got '${!v}')"
done
case "$VM_EXEC_METHOD" in auto|agent|ssh) ;; *) die "settings.conf: VM_EXEC_METHOD must be auto, agent or ssh" ;; esac

NTFY_ENABLED=true
if [ "$NO_NTFY" = true ] || [ "$LIST_ONLY" = true ]; then
    NTFY_ENABLED=false
elif [ -z "$NTFY_URL" ]; then
    NTFY_ENABLED=false
elif [ "$NTFY_TOKEN" = "YOUR_NTFY_TOKEN" ] || [ "$NTFY_URL" = "http://YOUR_NTFY_IP" ]; then
    die "settings.conf still has placeholder ntfy values. Edit it first: nano $SETTINGS_FILE"
fi
NTFY_URL="${NTFY_URL%/}"

# ═══════════════════════════════════════════════════════════════════════
# State
# ═══════════════════════════════════════════════════════════════════════

TOTAL=0            # guests considered (non-template, after --only filter)
SUCCESS=0
FAILED=0           # guests that failed (app/host failures are only in FAIL_LIST)
SKIPPED=0
STOPPED=0          # subset of SKIPPED
PLANNED=0          # dry-run only: guests that would have been updated
PKG_TOTAL=0        # packages upgraded across all guests
declare -a FAIL_LIST=() WARN_LIST=() SKIP_LIST=() REBOOT_LIST=() REBOOTED_LIST=() DOCKER_LIST=() DEFERRED=() APP_IDS=()
PVE_STATUS=""
APP_STATUS=""
RUN_COMPLETED=false
WATCHDOG_PID=""

# Per-VM execution context, set by vm_prepare()
EXEC_METHOD=""     # agent | ssh
EXEC_IP=""

# ═══════════════════════════════════════════════════════════════════════
# Logging
# ═══════════════════════════════════════════════════════════════════════

log() {
    local msg
    msg="[$(date '+%H:%M:%S')] $1"
    echo "$msg"
    [ -d "$LOG_DIR" ] && echo "$msg" >> "$LOG_FILE"
}

# Log-file only, indented. Usage: log_block "text" [max_lines]
log_block() {
    local text="$1" max="${2:-0}"
    [ -z "$text" ] && return 0
    if [ "$max" -gt 0 ]; then
        printf '%s\n' "$text" | tail -n "$max" | sed 's/^/      /' >> "$LOG_FILE"
    else
        printf '%s\n' "$text" | sed 's/^/      /' >> "$LOG_FILE"
    fi
}

join_by() {
    local sep="$1" out="" item; shift
    for item in "$@"; do out+="${out:+$sep}$item"; done
    echo "$out"
}

# ═══════════════════════════════════════════════════════════════════════
# Lock, watchdog, abort handling
# ═══════════════════════════════════════════════════════════════════════

acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "ERROR: another pve-updater instance is running (lock: $LOCK_FILE)." >&2
        exit 1
    fi
    echo $$ >&9
}

start_watchdog() {
    [ "$MAX_RUNTIME" -eq 0 ] && return 0
    (
        exec 9>&-   # don't inherit the lock
        waited=0
        while [ "$waited" -lt "$MAX_RUNTIME" ]; do
            sleep 30
            waited=$((waited + 30))
            kill -0 $$ 2>/dev/null || exit 0
        done
        echo "WATCHDOG: run exceeded MAX_RUNTIME=${MAX_RUNTIME}s, aborting" >> "$LOG_FILE"
        command -v pkill >/dev/null 2>&1 && pkill -TERM -P $$ 2>/dev/null
        sleep 5
        kill -TERM $$ 2>/dev/null
    ) &
    WATCHDOG_PID=$!
}

on_exit() {
    local rc=$?
    [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
    if [ "$RUN_COMPLETED" = false ] && [ "$LIST_ONLY" = false ]; then
        log "FATAL: run aborted (exit $rc) before completion"
        if [ "$NTFY_ENABLED" = true ]; then
            local tail_log=""
            [ -f "$LOG_FILE" ] && tail_log=$(tail -n 8 "$LOG_FILE")
            ntfy_send "Proxmox Updater ABORTED (exit $rc)" "5" "rotating_light" \
                "The weekly update run on $NODE did not finish.${tail_log:+$'\n'$tail_log}"
        fi
    fi
    exit "$rc"
}

on_term() {
    log "FATAL: received SIGTERM/SIGINT"
    exit 143
}

# ═══════════════════════════════════════════════════════════════════════
# Guest-side scripts (POSIX sh — they run inside Debian/Ubuntu/Alpine guests)
# Each prints a single machine-readable "##…" line at the end.
# Variables prefixed UPD_ are prepended by the host before execution.
# ═══════════════════════════════════════════════════════════════════════

read -r -d '' GUEST_PROBE_SCRIPT <<'EOS' || true
pm=none
command -v apt-get >/dev/null 2>&1 && pm=apt
[ "$pm" = none ] && command -v apk >/dev/null 2>&1 && pm=apk
free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
[ -z "$free_mb" ] && free_mb=-1
docker=no; stacks=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker=yes
    stacks=$(docker ps --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | grep -v '^$' | sort -u | wc -l | tr -d ' ')
fi
echo "##PROBE pm=$pm free_mb=$free_mb docker=$docker stacks=$stacks"
EOS

read -r -d '' GUEST_PKG_SCRIPT <<'EOS' || true
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
T=""
command -v timeout >/dev/null 2>&1 && T="timeout $UPD_TIMEOUT"
pm=none
command -v apt-get >/dev/null 2>&1 && pm=apt
[ "$pm" = none ] && command -v apk >/dev/null 2>&1 && pm=apk
free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
[ -z "$free_mb" ] && free_mb=-1
if [ "$pm" = none ]; then
    echo "##RESULT pm=none free_mb=$free_mb"; exit 0
fi
if [ "$free_mb" -ge 0 ] && [ "$free_mb" -lt "$UPD_MIN_FREE_MB" ]; then
    echo "##RESULT pm=$pm free_mb=$free_mb lowdisk=1"; exit 0
fi
update_rc=0; upgrade_rc=0; upgraded=0; newinst=0; autoremove_rc=0; reboot=no
case "$pm" in
apt)
    dpkg --configure -a >/dev/null 2>&1 || true
    APTO="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef -o DPkg::Lock::Timeout=300"
    upd_out=$($T apt-get -q update 2>&1); update_rc=$?
    [ "$update_rc" -ne 0 ] && echo "$upd_out" | tail -n 15
    plan=$(apt-get -s -q --with-new-pkgs $APTO upgrade 2>/dev/null | awk '/^Inst /{print $2}')
    if [ -n "$plan" ]; then
        echo "Planned: $(echo "$plan" | tr '\n' ' ')"
        out=$($T apt-get -y -q --with-new-pkgs $APTO upgrade 2>&1); upgrade_rc=$?
        echo "$out" | tail -n 40
        upgraded=$(echo "$out" | sed -n 's/^\([0-9][0-9]*\) upgraded, \([0-9][0-9]*\) newly installed.*/\1/p' | tail -n 1)
        newinst=$(echo "$out" | sed -n 's/^\([0-9][0-9]*\) upgraded, \([0-9][0-9]*\) newly installed.*/\2/p' | tail -n 1)
        [ -z "$upgraded" ] && upgraded=0
        [ -z "$newinst" ] && newinst=0
        if [ "$upgrade_rc" -eq 0 ] && echo "$plan" | grep -Eq '^(linux-image|libc6|libssl|systemd|dbus|libpam|init-system-helpers|udev)'; then
            reboot=yes
        fi
        if [ "$UPD_AUTOREMOVE" = true ] && [ "$upgrade_rc" -eq 0 ]; then
            $T apt-get -y -q autoremove $APTO >/dev/null 2>&1 || autoremove_rc=$?
        fi
    else
        echo "Nothing to upgrade."
    fi
    ;;
apk)
    $T apk update >/dev/null 2>&1 || update_rc=$?
    out=$($T apk upgrade 2>&1); upgrade_rc=$?
    echo "$out" | tail -n 40
    upgraded=$(echo "$out" | grep -c 'Upgrading')
    ;;
esac
[ -f /var/run/reboot-required ] && reboot=yes
if [ "$UPD_IS_VM" = 1 ]; then
    newest=$(for f in /boot/vmlinuz-*; do [ -e "$f" ] && echo "${f#/boot/vmlinuz-}"; done | sort -V | tail -n 1)
    running=$(uname -r)
    if [ -n "$newest" ] && [ "$newest" != "$running" ]; then reboot=yes; fi
fi
echo "##RESULT pm=$pm free_mb=$free_mb update_rc=$update_rc upgrade_rc=$upgrade_rc upgraded=$upgraded newinst=$newinst autoremove_rc=$autoremove_rc reboot=$reboot"
EOS

read -r -d '' GUEST_DOCKER_SCRIPT <<'EOS' || true
if ! command -v docker >/dev/null 2>&1; then echo "##DOCKER present=no"; exit 0; fi
if ! docker info >/dev/null 2>&1; then echo "##DOCKER present=no reason=daemon-not-running"; exit 0; fi
if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
else echo "##DOCKER present=yes compose=no"; exit 0; fi
T=""
command -v timeout >/dev/null 2>&1 && T="timeout $UPD_TIMEOUT"
stacks=0; updated=0; errors=0; unhealthy=""
projects=$(docker ps --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.Label "com.docker.compose.project.config_files"}}' 2>/dev/null | grep -v '^|' | sort -u)
while IFS='|' read -r proj wd cfgs; do
    [ -z "$proj" ] && continue
    stacks=$((stacks + 1))
    echo ">> $proj ($wd)"
    set --
    missing=0
    oldIFS=$IFS; IFS=','
    for f in $cfgs; do
        case "$f" in /*) ;; *) f="$wd/$f" ;; esac
        [ -f "$f" ] || missing=1
        set -- "$@" -f "$f"
    done
    IFS=$oldIFS
    if [ "$missing" = 1 ] || [ ! -d "$wd" ] || [ $# -eq 0 ]; then
        echo "   SKIP: compose file(s) not found on disk ($cfgs)"
        continue
    fi
    cids=$(docker ps -q --filter "label=com.docker.compose.project=$proj")
    if ! pull_out=$(cd "$wd" && $T $DC -p "$proj" --project-directory "$wd" "$@" pull -q 2>&1); then
        echo "   FAIL: pull failed"
        echo "$pull_out" | tail -n 5 | sed 's/^/   /'
        errors=$((errors + 1))
        continue
    fi
    changed=""
    for c in $cids; do
        cur=$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null)
        ref=$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)
        svc=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$c" 2>/dev/null)
        new=$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null)
        [ -n "$new" ] && [ -n "$svc" ] && [ "$new" != "$cur" ] && changed="$changed $svc"
    done
    changed=$(echo "$changed" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
    if [ -z "$changed" ]; then echo "   up to date"; continue; fi
    echo "   new image(s) for: $changed"
    if up_out=$(cd "$wd" && $T $DC -p "$proj" --project-directory "$wd" "$@" up -d --no-deps $changed 2>&1); then
        updated=$((updated + 1))
        echo "   recreated: $changed"
        sleep 5
        bad=$(docker ps -a --filter "label=com.docker.compose.project=$proj" --format '{{.Names}} {{.Status}}' | grep -E 'Restarting|Exited \([1-9]')
        if [ -n "$bad" ]; then
            echo "   WARN: not healthy after update:"
            echo "$bad" | sed 's/^/     /'
            errors=$((errors + 1)); unhealthy="$unhealthy$proj,"
        fi
    else
        echo "   FAIL: up failed"
        echo "$up_out" | tail -n 5 | sed 's/^/   /'
        errors=$((errors + 1))
    fi
done <<EOF
$projects
EOF
docker image prune -f >/dev/null 2>&1 || true
echo "##DOCKER present=yes stacks=$stacks updated=$updated errors=$errors unhealthy=${unhealthy%,}"
EOS

# ═══════════════════════════════════════════════════════════════════════
# JSON helpers (perl JSON::PP is always present on a PVE host)
# ═══════════════════════════════════════════════════════════════════════

# stdin: /cluster/resources JSON  →  lines: vmid|type|name|status|tags|lock|template
json_inventory() {
    perl -MJSON::PP -e '
        local $/; my $node = shift; my $d = eval { decode_json(<STDIN>) }; $d = [] unless ref $d eq "ARRAY";
        for my $r (sort { $a->{vmid} <=> $b->{vmid} } @$d) {
            next unless $r->{vmid};
            next if $node ne "" && ($r->{node} // "") ne $node;
            my $t = ($r->{type} // "") eq "qemu" ? "vm" : ($r->{type} // "");
            next unless $t eq "lxc" || $t eq "vm";
            (my $tags = $r->{tags} // "") =~ s/;/,/g;
            printf "%s|%s|%s|%s|%s|%s|%s\n", $r->{vmid}, $t, $r->{name} // "", $r->{status} // "unknown",
                $tags, $r->{lock} // "", ($r->{template} ? 1 : 0);
        }' "$1"
}

# stdin: JSON object → prints value of key $1 ("" if absent)
json_field() {
    perl -MJSON::PP -e '
        local $/; my $d = eval { decode_json(<STDIN>) };
        $d = $d->{result} if ref $d eq "HASH" && ref $d->{result} eq "HASH";
        print $d->{$ARGV[0]} // "" if ref $d eq "HASH";' "$1"
}

# stdin: network-get-interfaces JSON → first usable IPv4 (prefers $1 prefix)
json_guest_ip() {
    perl -MJSON::PP -e '
        local $/; my $pref = shift // ""; my $d = eval { decode_json(<STDIN>) };
        $d = $d->{result} if ref $d eq "HASH";
        $d = [] unless ref $d eq "ARRAY";
        my @c;
        for my $if (@$d) {
            my $n = $if->{name} // "";
            next if $n =~ /^(lo|docker|br-|veth|virbr|tailscale|wg|zt|cni|flannel|podman|lxc|dummy)/;
            for my $a (@{ $if->{"ip-addresses"} // [] }) {
                next unless ($a->{"ip-address-type"} // "") eq "ipv4";
                my $ip = $a->{"ip-address"} // ""; next if $ip =~ /^(127\.|169\.254\.)/;
                push @c, $ip;
            }
        }
        my ($p) = $pref ne "" ? grep { index($_, $pref) == 0 } @c : ();
        print $p // $c[0] // "";' "$1"
}

# stdin: `qm guest exec` JSON → prints out-data + err-data, exits with the guest exit code
agent_exec_decode() {
    perl -MJSON::PP -e '
        local $/; my $raw = <STDIN>; my $d = eval { decode_json($raw) };
        if (!$d || ref $d ne "HASH") { print $raw; exit 97; }
        print $d->{"out-data"} // ""; print $d->{"err-data"} // "";
        exit 124 unless $d->{exited};
        exit($d->{exitcode} // 1);'
}

# ═══════════════════════════════════════════════════════════════════════
# Discovery & per-guest configuration
# ═══════════════════════════════════════════════════════════════════════

discover_guests() {
    local json
    json=$(timeout 60 pvesh get /cluster/resources --type vm --output-format json 2>/dev/null) || return 1
    [ -n "$json" ] || return 1
    printf '%s' "$json" | json_inventory "$NODE"
}

# Options for a guest from Proxmox tags + overrides.conf, printed as space-separated words.
# Words: skip no-apt no-docker no-snapshot ip=<addr>
guest_options() {
    local id="$1" tags="$2" opts="" t line oid oopts
    for t in ${tags//,/ }; do
        case "$t" in
            no-update|skip-update|noupdate) opts+=" skip" ;;
            no-apt|noapt)                   opts+=" no-apt" ;;
            no-docker|nodocker)             opts+=" no-docker" ;;
            no-snapshot|nosnapshot)         opts+=" no-snapshot" ;;
        esac
    done
    if [ -f "$OVERRIDES_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            line="${line//[[:space:]]/}"
            [ -z "$line" ] && continue
            oid="${line%%|*}"; oopts="${line#*|}"
            [ "$oid" = "$id" ] || continue
            for t in ${oopts//,/ }; do
                case "$t" in
                    skip|no-update) opts+=" skip" ;;
                    no-apt|no-docker|no-snapshot) opts+=" $t" ;;
                    ip=*) opts+=" $t" ;;
                    *) echo "WARN: overrides.conf: unknown option '$t' for $id (ignored)" >&2 ;;
                esac
            done
        done < "$OVERRIDES_FILE"
    fi
    echo "${opts# }"
}

has_opt() { local w; for w in $1; do [ "$w" = "$2" ] && return 0; done; return 1; }
opt_value() { local w; for w in $1; do case "$w" in "$2="*) echo "${w#*=}"; return 0 ;; esac; done; echo ""; }

guest_status() {
    local type="$1" id="$2"
    if [ "$type" = lxc ]; then
        timeout 30 pct status "$id" 2>/dev/null | awk '{print $2}'
    else
        timeout 30 qm status "$id" 2>/dev/null | awk '{print $2}'
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# Executing scripts inside guests
# ═══════════════════════════════════════════════════════════════════════

# guest_exec <type> <id> <script> <timeout>  → stdout: output, rc: script exit (124 on timeout)
guest_exec() {
    local type="$1" id="$2" script="$3" t="$4"
    # 9>&- : children must not inherit the lock file descriptor
    if [ "$type" = lxc ]; then
        timeout $((t + 30)) pct exec "$id" -- sh -c "$script" 2>&1 9>&-
        return
    fi
    case "$EXEC_METHOD" in
        agent)
            timeout $((t + 60)) qm guest exec "$id" --timeout "$t" -- sh -c "$script" 2>&1 9>&- | agent_exec_decode
            ;;
        ssh)
            printf '%s\n' "$script" | timeout $((t + 30)) ssh -o ConnectTimeout=10 -o BatchMode=yes \
                -o StrictHostKeyChecking=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=4 \
                "$VM_SSH_USER@$EXEC_IP" sh -s 2>&1 9>&-
            ;;
        *)
            echo "no execution method for VM $id"; return 96
            ;;
    esac
}

# Decide how to reach a VM. Sets EXEC_METHOD / EXEC_IP (and VM_REASON on failure).
# Returns: 0 ok, 1 skip, 2 fail.  Must NOT be called in a subshell.
VM_REASON=""
vm_prepare() {
    local id="$1" opts="$2" os_id="" ip agent_ok=false ssh_err
    EXEC_METHOD=""; EXEC_IP=""; VM_REASON=""
    ip=$(opt_value "$opts" ip)

    if timeout 20 qm guest cmd "$id" ping >/dev/null 2>&1; then
        agent_ok=true
        os_id=$(timeout 20 qm guest cmd "$id" get-osinfo 2>/dev/null | json_field id)
        case "$os_id" in
            debian|ubuntu|linuxmint|pop|raspbian|kali|devuan|alpine|"") ;;
            *)  # Non-apt OS (haos, mswindows, …) — only manage it if the user explicitly gave an IP
                if [ -z "$ip" ]; then VM_REASON="unsupported OS '$os_id' (tag no-update to silence)"; return 1; fi ;;
        esac
    fi

    if [ "$agent_ok" = true ] && [ "$VM_EXEC_METHOD" != ssh ]; then
        if timeout 60 qm guest exec "$id" --timeout 30 -- sh -c 'echo ok' 2>/dev/null | agent_exec_decode 2>/dev/null | grep -q '^ok'; then
            EXEC_METHOD=agent
            return 0
        fi
    fi
    if [ "$VM_EXEC_METHOD" = agent ]; then
        VM_REASON="guest agent unavailable and VM_EXEC_METHOD=agent"; return 1
    fi

    if [ -z "$ip" ] && [ "$agent_ok" = true ]; then
        ip=$(timeout 20 qm guest cmd "$id" network-get-interfaces 2>/dev/null | json_guest_ip "$VM_IP_PREFIX")
    fi
    if [ -z "$ip" ]; then
        if [ "$agent_ok" = true ]; then VM_REASON="guest agent has no exec support and no IP found (add ip=… in overrides.conf)"
        else VM_REASON="no guest agent and no ip=… in overrides.conf"; fi
        return 1
    fi

    ssh_err=$(timeout 20 ssh -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=yes \
        "$VM_SSH_USER@$ip" 'echo ok' 2>&1)
    if printf '%s' "$ssh_err" | grep -q '^ok'; then
        EXEC_METHOD=ssh; EXEC_IP="$ip"
        return 0
    fi
    case "$ssh_err" in
        *"Permission denied"*)
            VM_REASON="SSH key not installed on $ip (run ./setup-ssh.sh $id)"; return 1 ;;
        *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
            VM_REASON="SSH host key mismatch for $ip (run ./setup-ssh.sh $id)"; return 2 ;;
        *)
            VM_REASON="SSH unreachable at $ip ($(printf '%s' "$ssh_err" | tail -n 1))"; return 2 ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════
# Snapshots
# ═══════════════════════════════════════════════════════════════════════

# snapshot_guest <type> <id> <label> → prints snapshot name on success, "" on failure
snapshot_guest() {
    local type="$1" id="$2" label="$3" tool out rc
    tool=$([ "$type" = lxc ] && echo pct || echo qm)
    local -a extra=()
    [ "$type" = vm ] && extra=(--vmstate 0)
    out=$(timeout 300 "$tool" snapshot "$id" "$SNAP_NAME" --description "pve-updater pre-update snapshot" "${extra[@]}" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "WARN: $label -- snapshot failed: $(printf '%s' "$out" | tail -n 1)"
        return 1
    fi
    echo "$SNAP_NAME"
    # Prune: keep the newest $SNAPSHOT_KEEP autoupd-* snapshots (names sort chronologically)
    local snaps old
    snaps=$(timeout 60 "$tool" listsnapshot "$id" 2>/dev/null | grep -oE "$SNAP_REGEX" | sort -u)
    old=$(printf '%s\n' "$snaps" | head -n -"$SNAPSHOT_KEEP")
    for s in $old; do
        if timeout 300 "$tool" delsnapshot "$id" "$s" >/dev/null 2>&1; then
            log "SNAP: $label -- pruned old snapshot $s"
        else
            log "WARN: $label -- could not delete old snapshot $s"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════
# Hooks
# ═══════════════════════════════════════════════════════════════════════

run_hook() {
    local phase="$1" type="$2" id="$3" label="$4"
    local hook_file="$HOOKS_DIR/${id}-${phase}.sh"
    [ -f "$hook_file" ] || return 0

    local owner perms
    owner=$(stat -c '%u' "$hook_file")
    perms=$(stat -c '%a' "$hook_file")
    if [ "$owner" != "0" ]; then
        log "WARN: $label -- skipping $phase hook, not owned by root (uid $owner)"
        return 1
    fi
    local group_digit="${perms: -2:1}" other_digit="${perms: -1:1}"
    if (( group_digit & 2 )) || (( other_digit & 2 )); then
        log "WARN: $label -- skipping $phase hook, group/world-writable (mode $perms)"
        return 1
    fi

    log "HOOK: $label -- running $phase hook"
    local body out rc
    body=$(cat "$hook_file")
    out=$(guest_exec "$type" "$id" "$body" "$APT_TIMEOUT")
    rc=$?
    log_block "$out" 40
    if [ "$rc" -ne 0 ]; then
        if [ "$phase" = pre ]; then
            # A failed pre-hook (e.g. "stop service X") means the update must not proceed.
            log "FAIL: $label -- pre hook returned $rc, skipping update of this guest"
            FAIL_LIST+=("$label: pre hook rc $rc"); ((FAILED++))
            return 1
        fi
        log "WARN: $label -- $phase hook returned $rc"
        WARN_LIST+=("$label: $phase hook rc $rc")
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════
# Reboot handling (opt-in)
# ═══════════════════════════════════════════════════════════════════════

wait_running() {
    local type="$1" id="$2" max="$3" waited=0
    while [ "$waited" -lt "$max" ]; do
        if [ "$(guest_status "$type" "$id")" = running ]; then
            if [ "$type" = vm ] && [ "$EXEC_METHOD" = agent ]; then
                timeout 10 qm guest cmd "$id" ping >/dev/null 2>&1 && return 0
            else
                return 0
            fi
        fi
        sleep 5; waited=$((waited + 5))
    done
    return 1
}

reboot_guest() {
    local type="$1" id="$2" label="$3" tool
    tool=$([ "$type" = lxc ] && echo pct || echo qm)
    log "REBOOT: $label -- rebooting (reboot pending)"
    if ! timeout 300 "$tool" reboot "$id" --timeout 120 >> "$LOG_FILE" 2>&1; then
        log "WARN: $label -- reboot command failed"
        WARN_LIST+=("$label: reboot failed")
        return 1
    fi
    if wait_running "$type" "$id" 240; then
        log "OK: $label -- back up after reboot"
        REBOOTED_LIST+=("$label")
    else
        log "FAIL: $label -- did not come back within 240s after reboot"
        FAIL_LIST+=("$label: not back after reboot")
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# Per-guest processing
# ═══════════════════════════════════════════════════════════════════════

kv() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\([^[:space:]]*\).*/\1/p" | tail -n 1; }

in_only_filter() {
    [ -z "$ONLY_IDS" ] && return 0
    local w; for w in $ONLY_IDS; do [ "$w" = "$1" ] && return 0; done
    return 1
}

# process_guest <id> <type> <name> <status> <tags> <lock> <is_retry>
process_guest() {
    local id="$1" type="$2" name="$3" status="$4" tags="$5" lock="$6" is_retry="$7"
    local label="$name ($id)" opts
    [ -z "$name" ] && label="$type $id"

    in_only_filter "$id" || return 0
    [ "$is_retry" = 0 ] && ((TOTAL++))

    opts=$(guest_options "$id" "$tags")

    if has_opt "$opts" skip; then
        log "SKIP: $label -- disabled (tag no-update / overrides.conf)"
        SKIP_LIST+=("$label: disabled"); ((SKIPPED++)); return 0
    fi
    if [ "$status" != running ]; then
        log "SKIP: $label -- not running ($status)"
        ((STOPPED++)); ((SKIPPED++)); return 0
    fi
    if [ -n "$lock" ]; then
        if [ "$is_retry" = 0 ]; then
            log "DEFER: $label -- locked ($lock), will retry at the end"
            DEFERRED+=("$id")
        else
            log "SKIP: $label -- still locked ($lock)"
            SKIP_LIST+=("$label: locked ($lock)"); ((SKIPPED++))
        fi
        return 0
    fi

    local do_apt=true do_docker="$UPDATE_DOCKER" do_snap="$SNAPSHOT_BEFORE_UPDATE"
    has_opt "$opts" no-apt      && do_apt=false
    has_opt "$opts" no-docker   && do_docker=false
    has_opt "$opts" no-snapshot && do_snap=false
    if [ "$do_apt" = false ] && [ "$do_docker" = false ]; then
        log "SKIP: $label -- nothing to do (no-apt + no-docker)"
        SKIP_LIST+=("$label: no-apt+no-docker"); ((SKIPPED++)); return 0
    fi

    # ── VM reachability ──
    local rc
    if [ "$type" = vm ]; then
        vm_prepare "$id" "$opts"; rc=$?
        if [ "$rc" -eq 1 ]; then
            log "SKIP: $label -- $VM_REASON"
            SKIP_LIST+=("$label: $VM_REASON"); ((SKIPPED++)); return 0
        elif [ "$rc" -ne 0 ]; then
            log "FAIL: $label -- $VM_REASON"
            FAIL_LIST+=("$label: $VM_REASON"); ((FAILED++)); return 0
        fi
    fi
    local via=""
    [ "$type" = vm ] && via=" via ${EXEC_METHOD}${EXEC_IP:+ $EXEC_IP}"

    # ── Dry run: probe only ──
    if [ "$DRY_RUN" = true ]; then
        local probe
        probe=$(guest_exec "$type" "$id" "$GUEST_PROBE_SCRIPT" 60); rc=$?
        local pm docker stacks free_mb
        pm=$(kv "$probe" pm); docker=$(kv "$probe" docker); stacks=$(kv "$probe" stacks); free_mb=$(kv "$probe" free_mb)
        if [ "$rc" -ne 0 ] || [ -z "$pm" ]; then
            log "DRY-RUN: $label$via -- probe failed (rc $rc): $(printf '%s' "$probe" | tail -n 1)"
            FAIL_LIST+=("$label: probe failed"); ((FAILED++)); return 0
        fi
        local plan=""
        [ "$do_snap" = true ] && plan+="snapshot, "
        if [ "$do_apt" = true ]; then
            [ "$pm" = none ] && plan+="no apt/apk (skipped), " || plan+="$pm upgrade, "
        fi
        [ "$do_docker" = true ] && [ "$docker" = yes ] && plan+="docker ($stacks stacks), "
        [ -f "$HOOKS_DIR/$id-pre.sh" ] && plan+="pre-hook, "
        [ -f "$HOOKS_DIR/$id-post.sh" ] && plan+="post-hook, "
        local disk_note=" [free ${free_mb} MB]"
        [ "${free_mb:--1}" -ge 0 ] && [ "$free_mb" -lt "$MIN_FREE_MB" ] && disk_note=" [LOW DISK: ${free_mb} MB free < MIN_FREE_MB=$MIN_FREE_MB, would refuse]"
        log "DRY-RUN: $label$via -- would: ${plan%, }$disk_note"
        [ "$type" = lxc ] && APP_IDS+=("$id")
        ((PLANNED++)); return 0
    fi

    log "START: $label$via"
    local snap="" guest_failed=false pkgs=0 reboot=no

    # ── Snapshot ──
    if [ "$do_snap" = true ]; then
        snap=$(snapshot_guest "$type" "$id" "$label")
        if [ -n "$snap" ]; then
            log "SNAP: $label -- $snap"
        elif [ "$SNAPSHOT_REQUIRED" = true ]; then
            log "FAIL: $label -- snapshot required but failed, not updating"
            FAIL_LIST+=("$label: snapshot failed"); ((FAILED++)); return 0
        else
            WARN_LIST+=("$label: no snapshot")
        fi
    fi
    local snap_hint="${snap:+ [rollback: $([ "$type" = lxc ] && echo pct || echo qm) rollback $id $snap]}"

    run_hook pre "$type" "$id" "$label" || return 0

    # ── OS packages ──
    if [ "$do_apt" = true ]; then
        local is_vm=0; [ "$type" = vm ] && is_vm=1
        local script="UPD_TIMEOUT=$APT_TIMEOUT; UPD_IS_VM=$is_vm; UPD_AUTOREMOVE=$APT_AUTOREMOVE; UPD_MIN_FREE_MB=$MIN_FREE_MB"$'\n'"$GUEST_PKG_SCRIPT"
        local out res pm
        # APT_TIMEOUT applies per apt command inside the guest (update, upgrade, autoremove);
        # the outer budget only guards against a hung pct/qm/ssh.
        out=$(guest_exec "$type" "$id" "$script" $((APT_TIMEOUT * 3))); rc=$?
        res=$(printf '%s\n' "$out" | grep '^##RESULT' | tail -n 1)
        log_block "$(printf '%s\n' "$out" | grep -v '^##RESULT')" 60
        pm=$(kv "$res" pm)
        if [ -z "$res" ]; then
            log "FAIL: $label -- package update did not complete (rc $rc)$snap_hint"
            FAIL_LIST+=("$label: pkg update rc $rc$snap_hint"); guest_failed=true
        elif [ "$pm" = none ]; then
            log "INFO: $label -- no supported package manager (apt/apk), skipping OS packages"
            [ "$do_docker" = false ] && { SKIP_LIST+=("$label: no apt/apk"); ((SKIPPED++)); return 0; }
        elif [ "$(kv "$res" lowdisk)" = 1 ]; then
            log "FAIL: $label -- only $(kv "$res" free_mb) MB free on /, refusing to update (MIN_FREE_MB=$MIN_FREE_MB)"
            FAIL_LIST+=("$label: low disk ($(kv "$res" free_mb) MB free)"); guest_failed=true
        else
            local update_rc upgrade_rc newinst autoremove_rc
            update_rc=$(kv "$res" update_rc); upgrade_rc=$(kv "$res" upgrade_rc)
            pkgs=$(kv "$res" upgraded); newinst=$(kv "$res" newinst); autoremove_rc=$(kv "$res" autoremove_rc)
            reboot=$(kv "$res" reboot)
            if [ "${upgrade_rc:-1}" -ne 0 ]; then
                log "FAIL: $label -- $pm upgrade failed (rc $upgrade_rc)$snap_hint"
                FAIL_LIST+=("$label: $pm upgrade rc $upgrade_rc$snap_hint"); guest_failed=true
            else
                local note="$pm: ${pkgs:-0} upgraded"
                [ "${newinst:-0}" -gt 0 ] && note+=", $newinst new"
                [ "${update_rc:-0}" -ne 0 ] && { note+=", repo errors"; WARN_LIST+=("$label: apt update errors"); }
                [ "${autoremove_rc:-0}" -ne 0 ] && { note+=", autoremove failed"; }
                [ "$reboot" = yes ] && note+=", reboot pending"
                log "OK: $label -- $note"
                PKG_TOTAL=$((PKG_TOTAL + ${pkgs:-0}))
            fi
        fi
    fi

    # ── Docker stacks ──
    # Probe first: skip guests without Docker, and size the time budget by the number of running stacks.
    local stacks_n=1
    if [ "$do_docker" = true ] && [ "$guest_failed" = false ]; then
        local probe docker_present
        probe=$(guest_exec "$type" "$id" "$GUEST_PROBE_SCRIPT" 60); rc=$?
        docker_present=$(kv "$probe" docker)
        if [ -z "$docker_present" ]; then
            log "WARN: $label -- docker probe failed (rc $rc): $(printf '%s' "$probe" | tail -n 1)"
            WARN_LIST+=("$label: docker probe rc $rc")
            do_docker=false
        elif [ "$docker_present" != yes ]; then
            do_docker=false
        else
            stacks_n=$(kv "$probe" stacks); [ "${stacks_n:-0}" -ge 1 ] || stacks_n=1
        fi
    fi
    if [ "$do_docker" = true ] && [ "$guest_failed" = false ]; then
        local script out res
        script="UPD_TIMEOUT=$DOCKER_TIMEOUT"$'\n'"$GUEST_DOCKER_SCRIPT"
        out=$(guest_exec "$type" "$id" "$script" $((DOCKER_TIMEOUT * stacks_n + 60))); rc=$?
        res=$(printf '%s\n' "$out" | grep '^##DOCKER' | tail -n 1)
        if [ -z "$res" ]; then
            log_block "$out" 40
            if [ "$rc" -eq 124 ]; then
                log "FAIL: $label -- docker update timed out after ${DOCKER_TIMEOUT}s$snap_hint"
                FAIL_LIST+=("$label: docker timeout$snap_hint"); guest_failed=true
            else
                log "WARN: $label -- docker probe failed (rc $rc): $(printf '%s' "$out" | tail -n 1)"
                WARN_LIST+=("$label: docker probe rc $rc")
            fi
        elif [ "$(kv "$res" present)" = yes ] && [ "$(kv "$res" compose)" != no ]; then
            log_block "$(printf '%s\n' "$out" | grep -v '^##DOCKER')" 80
            local stacks updated errors
            stacks=$(kv "$res" stacks); updated=$(kv "$res" updated); errors=$(kv "$res" errors)
            if [ "${errors:-0}" -gt 0 ]; then
                local unhealthy; unhealthy=$(kv "$res" unhealthy)
                log "FAIL: $label -- docker: $errors of $stacks stack(s) had errors${unhealthy:+ (unhealthy: $unhealthy)}$snap_hint"
                FAIL_LIST+=("$label: docker $errors/$stacks stacks failed${unhealthy:+ ($unhealthy)}$snap_hint"); guest_failed=true
            else
                log "OK: $label -- docker: $stacks stack(s), $updated updated"
                [ "${updated:-0}" -gt 0 ] && DOCKER_LIST+=("$label: $updated/$stacks")
            fi
        elif [ "$(kv "$res" compose)" = no ]; then
            log "WARN: $label -- docker present but no compose plugin, stacks not updated"
            WARN_LIST+=("$label: no docker compose")
        fi
    fi

    run_hook post "$type" "$id" "$label"

    # ── Still alive? ──
    if [ "$(guest_status "$type" "$id")" != running ]; then
        log "WARN: $label -- not running after update, attempting start"
        if [ "$type" = lxc ]; then timeout 120 pct start "$id" >> "$LOG_FILE" 2>&1; else timeout 120 qm start "$id" >> "$LOG_FILE" 2>&1; fi
        if wait_running "$type" "$id" 90; then
            log "WARN: $label -- restarted successfully"
            WARN_LIST+=("$label: died during update, restarted")
        else
            log "FAIL: $label -- down after update and could not be started$snap_hint"
            FAIL_LIST+=("$label: DOWN after update$snap_hint"); guest_failed=true
        fi
    fi

    if [ "$guest_failed" = true ]; then
        ((FAILED++)); return 0
    fi
    ((SUCCESS++))
    [ "$type" = lxc ] && APP_IDS+=("$id")   # eligible for community-scripts app updates

    # ── Reboot if pending (opt-in) ──
    if [ "$reboot" = yes ]; then
        local allow="$AUTO_REBOOT_LXC"; [ "$type" = vm ] && allow="$AUTO_REBOOT_VM"
        if [ "$allow" = true ]; then
            reboot_guest "$type" "$id" "$label" || true
        else
            REBOOT_LIST+=("$label")
        fi
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════
# Community-scripts app updates
# ═══════════════════════════════════════════════════════════════════════

run_app_updates() {
    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: would run community-scripts update-apps.sh for: ${APP_IDS[*]:-none}"
        APP_STATUS="dry-run"; return 0
    fi
    if [ ${#APP_IDS[@]} -eq 0 ]; then
        log "APPS: no eligible containers, skipping update-apps.sh"
        APP_STATUS="skipped (no eligible containers)"; return 0
    fi

    local app_log="$LOG_DIR/app-update-$TIMESTAMP.log" tmp rc
    tmp=$(mktemp "${TMPDIR:-/tmp}/update-apps.XXXXXX")
    log "APPS: downloading update-apps.sh"
    if ! curl -fsSL --max-time 60 --retry 3 -o "$tmp" "$APP_UPDATE_URL" \
        || [ ! -s "$tmp" ] || ! head -n 1 "$tmp" | grep -q '^#!'; then
        log "FAIL: could not download a valid update-apps.sh from $APP_UPDATE_URL"
        FAIL_LIST+=("app-updates: download failed")
        APP_STATUS="download failed"; rm -f "$tmp"; return 1
    fi

    log "APPS: running update-apps.sh for $(join_by , "${APP_IDS[@]}")"
    var_backup="$APP_UPDATE_BACKUP" \
    var_container="$(join_by , "${APP_IDS[@]}")" \
    var_unattended=yes \
    var_skip_confirm=yes \
    var_continue_on_error=yes \
    var_auto_reboot="$APP_UPDATE_REBOOT" \
    timeout "$APP_UPDATE_TIMEOUT" bash "$tmp" > "$app_log" 2>&1
    rc=$?
    rm -f "$tmp"
    sed -i 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\r//g' "$app_log" 2>/dev/null

    # Summary table rows: "  <ctid>  <service>  <STATUS>  <details>"
    local ok fail restored err skipped fail_names
    ok=$(grep -cE '^\s+[0-9]+\s+\S+\s+OK\b' "$app_log")
    fail=$(grep -cE '^\s+[0-9]+\s+\S+\s+FAILED\b' "$app_log")
    restored=$(grep -cE '^\s+[0-9]+\s+\S+\s+RESTORED\b' "$app_log")
    err=$(grep -cE '^\s+[0-9]+\s+\S+\s+ERROR\b' "$app_log")
    skipped=$(grep -cE '^\s+[0-9]+\s+\S+\s+SKIPPED\b' "$app_log")
    fail_names=$(grep -E '^\s+[0-9]+\s+\S+\s+(FAILED|RESTORED|ERROR)\b' "$app_log" | awk '{print $2"("$1")"}' | paste -sd, - | sed 's/,/, /g')

    if [ "$rc" -eq 124 ]; then
        APP_STATUS="timed out after ${APP_UPDATE_TIMEOUT}s"
        FAIL_LIST+=("app-updates: timeout")
        log "FAIL: update-apps.sh timed out (see $app_log)"
    elif [ "$rc" -eq 234 ]; then
        APP_STATUS="no community-script containers"
        log "APPS: no containers matched (exit 234)"
    elif [ $((fail + restored + err)) -gt 0 ]; then
        APP_STATUS="$ok OK, $((fail + restored + err)) failed ($fail_names)"
        FAIL_LIST+=("app-updates: $fail_names")
        log "FAIL: update-apps.sh -- $APP_STATUS (see $app_log)"
    elif [ "$rc" -ne 0 ]; then
        APP_STATUS="exit $rc, $ok OK"
        FAIL_LIST+=("app-updates: exit $rc")
        log "FAIL: update-apps.sh exited $rc (see $app_log)"
    else
        APP_STATUS="$ok OK${skipped:+, $skipped skipped}"
        [ "$ok" -eq 0 ] && APP_STATUS="nothing to update"
        log "APPS: $APP_STATUS"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# PVE host
# ═══════════════════════════════════════════════════════════════════════

host_reboot_pending() {
    [ -f /var/run/reboot-required ] && return 0
    local newest running
    newest=$(for f in /boot/vmlinuz-*; do [ -e "$f" ] && echo "${f#/boot/vmlinuz-}"; done | sort -V | tail -n 1)
    running=$(uname -r)
    [ -n "$newest" ] && [ "$newest" != "$running" ]
}

backup_running() {
    # manual `vzdump` CLI runs, or scheduled backups (pvescheduler workers named "task UPID:…:vzdump:…")
    pgrep -x vzdump >/dev/null 2>&1 || pgrep -f 'UPID:[^:]*:[^:]*:[^:]*:[^:]*:vzdump:' >/dev/null 2>&1
}

wait_for_backups() {
    command -v pgrep >/dev/null 2>&1 || return 0
    local waited=0
    while backup_running; do
        if [ "$waited" -ge "$BACKUP_WAIT_MAX" ]; then return 1; fi
        [ "$waited" -eq 0 ] && log "PVE: a vzdump backup is running, waiting up to ${BACKUP_WAIT_MAX}s"
        sleep 30; waited=$((waited + 30))
    done
    return 0
}

update_pve_host() {
    log "PVE: checking host for updates"
    if [ "$DRY_RUN" = true ]; then
        local n; n=$(apt-get -s -q dist-upgrade 2>/dev/null | grep -c '^Inst ')
        PVE_STATUS="dry-run ($n upgradable per last apt update)"
        log "DRY-RUN: PVE host -- $PVE_STATUS"; return 0
    fi

    local free_mb
    free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$free_mb" ] && [ "$free_mb" -lt "$HOST_MIN_FREE_MB" ]; then
        PVE_STATUS="SKIPPED: only ${free_mb} MB free on / (HOST_MIN_FREE_MB=$HOST_MIN_FREE_MB)"
        FAIL_LIST+=("PVE host: low disk"); log "FAIL: PVE host -- $PVE_STATUS"; return 1
    fi
    if ! wait_for_backups; then
        PVE_STATUS="skipped: backup still running after ${BACKUP_WAIT_MAX}s"
        WARN_LIST+=("PVE host: $PVE_STATUS"); log "WARN: PVE host -- $PVE_STATUS"; return 1
    fi

    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    local apt_opts=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef -o DPkg::Lock::Timeout=300)
    local update_warn=""
    if ! timeout "$APT_TIMEOUT" apt-get -q update >> "$LOG_FILE" 2>&1; then
        update_warn=", repo errors"
        WARN_LIST+=("PVE host: apt update errors (enterprise repo without subscription?)")
        log "WARN: PVE host -- apt-get update reported errors, continuing"
    fi

    # Simulate first: count, and refuse if core Proxmox packages would be removed.
    local sim sim_rc n_inst removals
    sim=$(apt-get -s -q "${apt_opts[@]}" dist-upgrade 2>&1); sim_rc=$?
    if [ "$sim_rc" -ne 0 ]; then
        PVE_STATUS="FAILED: dist-upgrade simulation failed (broken dependencies?)"
        log_block "$sim" 20
        FAIL_LIST+=("PVE host: apt simulation failed"); log "FAIL: PVE host -- $PVE_STATUS"; return 1
    fi
    n_inst=$(printf '%s\n' "$sim" | grep -c '^Inst ')
    removals=$(printf '%s\n' "$sim" | awk '/^Remv /{print $2}' | grep -E '^(proxmox-ve|pve-manager|pve-cluster|qemu-server|pve-container|pve-firewall|pve-ha-manager|proxmox-default-kernel|zfsutils-linux|zfs-initramfs|libpve-|corosync|proxmox-backup-client)' | paste -sd, -)
    if [ -n "$removals" ]; then
        PVE_STATUS="REFUSED: dist-upgrade would remove core packages ($removals) -- fix repos/deps manually"
        FAIL_LIST+=("PVE host: would remove $removals"); log "FAIL: PVE host -- $PVE_STATUS"; return 1
    fi

    if [ "$n_inst" -eq 0 ]; then
        PVE_STATUS="already up to date$update_warn"
        host_reboot_pending && { PVE_STATUS+=" -- REBOOT PENDING"; REBOOT_LIST+=("PVE host"); }
        log "PVE: $PVE_STATUS"; return 0
    fi

    log "PVE: $n_inst package(s) to upgrade -- installing: $(printf '%s\n' "$sim" | awk '/^Inst /{print $2}' | paste -sd' ' -)"
    if timeout "$APT_TIMEOUT" apt-get -y -q "${apt_opts[@]}" dist-upgrade >> "$LOG_FILE" 2>&1; then
        PVE_STATUS="$n_inst upgraded$update_warn"
        if [ "$APT_AUTOREMOVE" = true ]; then
            timeout "$APT_TIMEOUT" apt-get -y -q "${apt_opts[@]}" autoremove >> "$LOG_FILE" 2>&1 || log "WARN: PVE host -- autoremove failed"
        fi
        if host_reboot_pending; then
            PVE_STATUS+=" -- REBOOT PENDING"; REBOOT_LIST+=("PVE host")
        fi
    else
        PVE_STATUS="FAILED: apt dist-upgrade exited non-zero -- check log"
        FAIL_LIST+=("PVE host: dist-upgrade failed")
    fi
    log "PVE: $PVE_STATUS"
}

# ═══════════════════════════════════════════════════════════════════════
# Notification
# ═══════════════════════════════════════════════════════════════════════

ntfy_send() {
    local title="$1" priority="$2" tags="$3" body="${4:0:3900}"   # ntfy default message limit is 4096 bytes
    [ "$NTFY_ENABLED" = true ] || return 0
    local -a auth=()
    [ -n "$NTFY_TOKEN" ] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
    if curl -s --max-time 20 --retry 3 --retry-delay 10 --retry-connrefused "${auth[@]}" \
        -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
        --data-binary "$body" "$NTFY_URL/$NTFY_TOPIC" > /dev/null 2>&1; then
        log "NTFY: notification sent"
    else
        log "WARN: failed to send ntfy notification (curl exit $?)"
    fi
}

send_summary() {
    local duration=$(( $(date +%s) - START_TIME ))
    local priority=3 tags="package,white_check_mark" title="Proxmox Updates Complete"
    local n_fail=${#FAIL_LIST[@]}
    if [ "$n_fail" -gt 0 ]; then
        priority=4; tags="package,warning"; title="Proxmox Updates -- $n_fail Failed"
    elif [ "$DRY_RUN" = true ]; then
        title="Proxmox Updates (dry run)"
    fi

    local msg="Updated: $SUCCESS / $TOTAL"
    [ "$DRY_RUN" = true ] && msg="Would update: $PLANNED / $TOTAL"
    [ "$PKG_TOTAL" -gt 0 ] && msg+=" ($PKG_TOTAL pkgs)"
    [ "$SKIPPED" -gt 0 ] && msg+="  |  Skipped: $SKIPPED"
    [ "$n_fail" -gt 0 ]            && msg+=$'\n'"Failed: $(join_by '; ' "${FAIL_LIST[@]}")"
    [ ${#WARN_LIST[@]} -gt 0 ]     && msg+=$'\n'"Warnings: $(join_by '; ' "${WARN_LIST[@]}")"
    [ ${#REBOOT_LIST[@]} -gt 0 ]   && msg+=$'\n'"Reboot pending: $(join_by ', ' "${REBOOT_LIST[@]}")"
    [ ${#REBOOTED_LIST[@]} -gt 0 ] && msg+=$'\n'"Rebooted: $(join_by ', ' "${REBOOTED_LIST[@]}")"
    [ ${#DOCKER_LIST[@]} -gt 0 ]   && msg+=$'\n'"Docker updated: $(join_by ', ' "${DOCKER_LIST[@]}")"
    if [ ${#SKIP_LIST[@]} -gt 0 ] || [ "$STOPPED" -gt 0 ]; then
        local sk=""
        [ "$STOPPED" -gt 0 ] && sk="$STOPPED stopped"
        [ ${#SKIP_LIST[@]} -gt 0 ] && sk+="${sk:+; }$(join_by '; ' "${SKIP_LIST[@]}")"
        msg+=$'\n'"Skipped: $sk"
    fi
    [ -n "$APP_STATUS" ] && msg+=$'\n'"App updates: $APP_STATUS"
    msg+=$'\n'"PVE host: $PVE_STATUS"
    msg+=$'\n'"Duration: $((duration / 60))m $((duration % 60))s"

    ntfy_send "$title" "$priority" "$tags" "$msg"
}

# ═══════════════════════════════════════════════════════════════════════
# Housekeeping
# ═══════════════════════════════════════════════════════════════════════

cleanup_old_logs() {
    find "$LOG_DIR" -name "update-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
    find "$LOG_DIR" -name "app-update-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
    find /usr/local/community-scripts/update_apps -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
    local cron_log="$LOG_DIR/cron.log"
    if [ -f "$cron_log" ] && [ "$(stat -c '%s' "$cron_log" 2>/dev/null || echo 0)" -gt 2000000 ]; then
        tail -n 2000 "$cron_log" > "$cron_log.tmp" && mv "$cron_log.tmp" "$cron_log"
    fi
}

print_inventory() {
    local inventory="$1"
    printf '%-6s %-4s %-24s %-8s %-28s %s\n' ID TYPE NAME STATUS TAGS PLAN
    while IFS='|' read -r id type name status tags lock template; do
        [ -z "$id" ] && continue
        in_only_filter "$id" || continue
        local plan="" opts
        opts=$(guest_options "$id" "$tags")
        if [ "$template" = 1 ]; then plan="template (ignored)"
        elif has_opt "$opts" skip; then plan="skip (disabled)"
        elif [ "$status" != running ]; then plan="skip (not running)"
        elif [ -n "$lock" ]; then plan="locked ($lock)"
        else
            EXEC_METHOD=""
            if [ "$type" = vm ]; then
                if vm_prepare "$id" "$opts"; then plan="via $EXEC_METHOD${EXEC_IP:+ $EXEC_IP}: "; else plan="$VM_REASON"; fi
            fi
            if [ "$type" = lxc ] || [ -n "$EXEC_METHOD" ]; then
                local probe pm docker stacks
                probe=$(guest_exec "$type" "$id" "$GUEST_PROBE_SCRIPT" 60)
                pm=$(kv "$probe" pm); docker=$(kv "$probe" docker); stacks=$(kv "$probe" stacks)
                [ "$pm" = none ] && pm="no-apt/apk"
                has_opt "$opts" no-apt || plan+="${pm:-probe-failed} "
                if [ "$docker" = yes ] && [ "$UPDATE_DOCKER" = true ] && ! has_opt "$opts" no-docker; then plan+="docker($stacks) "; fi
                has_opt "$opts" no-snapshot || [ "$SNAPSHOT_BEFORE_UPDATE" != true ] || plan+="snapshot"
            fi
        fi
        printf '%-6s %-4s %-24s %-8s %-28s %s\n' "$id" "$type" "${name:0:24}" "$status" "${tags:0:28}" "${plan% }"
    done <<< "$inventory"
}

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

main() {
    local inventory
    if [ "$LIST_ONLY" = true ]; then
        inventory=$(discover_guests) || die "could not discover guests via pvesh (is this a PVE host?)"
        print_inventory "$inventory"
        RUN_COMPLETED=true
        return 0
    fi

    mkdir -p "$LOG_DIR" "$HOOKS_DIR"
    acquire_lock
    trap on_exit EXIT
    trap on_term TERM INT
    start_watchdog
    [ "$DRY_RUN" = false ] && cleanup_old_logs
    ln -sfn "$LOG_FILE" "$LOG_DIR/latest.log" 2>/dev/null || true

    log "════════════════════════════════════════════════════"
    log "  PVE Updater started  $(date '+%Y-%m-%d %H:%M:%S')  node: $NODE"
    [ "$DRY_RUN" = true ] && log "  *** DRY RUN -- no changes will be made ***"
    [ -n "$ONLY_IDS" ] && log "  only: $ONLY_IDS"
    [ "$NTFY_ENABLED" = false ] && log "  (ntfy notifications disabled)"
    log "════════════════════════════════════════════════════"

    inventory=$(discover_guests) || { log "FAIL: could not discover guests via pvesh"; exit 1; }
    log "Discovered $(printf '%s\n' "$inventory" | grep -c .) guest(s) on $NODE"

    while IFS='|' read -r id type name status tags lock template; do
        [ -z "$id" ] && continue
        [ "$template" = 1 ] && continue
        process_guest "$id" "$type" "$name" "$status" "$tags" "$lock" 0
    done <<< "$inventory"

    if [ ${#DEFERRED[@]} -gt 0 ]; then
        log "Retrying ${#DEFERRED[@]} locked guest(s)"
        inventory=$(discover_guests) || inventory=""
        local did
        for did in "${DEFERRED[@]}"; do
            local line
            line=$(printf '%s\n' "$inventory" | grep "^$did|" | head -n 1)
            if [ -z "$line" ]; then
                log "SKIP: $did -- disappeared from inventory"; SKIP_LIST+=("$did: gone"); ((SKIPPED++)); continue
            fi
            IFS='|' read -r id type name status tags lock template <<< "$line"
            process_guest "$id" "$type" "$name" "$status" "$tags" "$lock" 1
        done
    fi

    if [ "$UPDATE_APPS" = true ]; then
        run_app_updates
    fi

    if [ "$NO_HOST" = true ]; then
        PVE_STATUS="skipped (--no-host)"
        log "PVE: host update skipped (--no-host)"
    elif [ "$UPDATE_PVE_HOST" = true ]; then
        update_pve_host
    else
        PVE_STATUS="skipped (disabled in settings)"
        log "PVE: host update skipped (disabled in settings.conf)"
    fi

    log ""
    log "════════════════════════════════════════════════════"
    log "  SUMMARY"
    if [ "$DRY_RUN" = true ]; then
        log "  Guests: $TOTAL  |  Would update: $PLANNED  |  Failed: $FAILED  |  Skipped: $SKIPPED ($STOPPED stopped)"
    else
        log "  Guests: $TOTAL  |  OK: $SUCCESS  |  Failed: $FAILED  |  Skipped: $SKIPPED ($STOPPED stopped)  |  Packages: $PKG_TOTAL"
    fi
    [ ${#FAIL_LIST[@]} -gt 0 ]     && log "  Failures: $(join_by '; ' "${FAIL_LIST[@]}")"
    [ ${#WARN_LIST[@]} -gt 0 ]     && log "  Warnings: $(join_by '; ' "${WARN_LIST[@]}")"
    [ ${#SKIP_LIST[@]} -gt 0 ]     && log "  Skipped: $(join_by '; ' "${SKIP_LIST[@]}")"
    [ ${#REBOOT_LIST[@]} -gt 0 ]   && log "  Reboot pending: $(join_by ', ' "${REBOOT_LIST[@]}")"
    [ ${#REBOOTED_LIST[@]} -gt 0 ] && log "  Rebooted: $(join_by ', ' "${REBOOTED_LIST[@]}")"
    [ ${#DOCKER_LIST[@]} -gt 0 ]   && log "  Docker updated: $(join_by ', ' "${DOCKER_LIST[@]}")"
    [ -n "$APP_STATUS" ]           && log "  App updates: $APP_STATUS"
    log "  PVE host: $PVE_STATUS"
    log "  Log: $LOG_FILE"
    log "════════════════════════════════════════════════════"

    send_summary
    RUN_COMPLETED=true
    log "Done."
    [ ${#FAIL_LIST[@]} -eq 0 ]
}

main
