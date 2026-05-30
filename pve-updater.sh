#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# pve-updater.sh — Automated Proxmox LXC/VM updater with ntfy reporting
# ═══════════════════════════════════════════════════════════════════════
# Runs apt update/upgrade on all configured LXC containers (via pct exec)
# and QEMU VMs (via SSH). Optionally updates Docker Compose stacks.
# Sends a summary notification via ntfy when done.
#
# Usage:
#   ./pve-updater.sh              # Normal run
#   ./pve-updater.sh --dry-run    # Show what would be done, skip actual updates
#   ./pve-updater.sh --force      # Run even if lock file exists
#
# Designed to run via cron on the Proxmox VE host.
# ═══════════════════════════════════════════════════════════════════════

# ── Strict mode (no set -e: we handle errors per-resource) ──
set -uo pipefail

# ── Paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES_FILE="$SCRIPT_DIR/resources.conf"
HOOKS_DIR="$SCRIPT_DIR/hooks"
LOG_DIR="$SCRIPT_DIR/logs"
LOCK_FILE="/tmp/pve-updater.lock"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/update-$TIMESTAMP.log"

# ── Load settings ──
if [ ! -f "$SCRIPT_DIR/settings.conf" ]; then
    echo "❌ settings.conf not found."
    echo "   First run? Copy the example and fill in your values:"
    echo ""
    echo "   cp $SCRIPT_DIR/settings.conf.example $SCRIPT_DIR/settings.conf"
    echo "   nano $SCRIPT_DIR/settings.conf"
    echo ""
    exit 1
fi
source "$SCRIPT_DIR/settings.conf"

# ── CLI flags ──
DRY_RUN=false
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --force)   FORCE=true ;;
    esac
done

# ── Counters & collectors ──
TOTAL=0
SUCCESS=0
FAILED=0
SKIPPED=0
declare -a REBOOT_LIST=()
declare -a DOCKER_LIST=()
declare -a FAIL_LIST=()
declare -a SUCCESS_LIST=()
PVE_STATUS=""
START_TIME=$(date +%s)

# ═══════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════

log() {
    local msg="[$(date '+%H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_detail() {
    echo "  $1" >> "$LOG_FILE"
}

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            if [ "$FORCE" = true ]; then
                log "⚠️  Overriding existing lock (PID $pid) due to --force"
                rm -f "$LOCK_FILE"
            else
                log "❌ Another instance is running (PID $pid). Use --force to override."
                exit 1
            fi
        else
            log "⚠️  Removing stale lock file (PID $pid no longer running)"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

cleanup_old_logs() {
    find "$LOG_DIR" -name "update-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════
# Update functions
# ═══════════════════════════════════════════════════════════════════════

run_apt_lxc() {
    local ctid="$1" name="$2"

    local status
    status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
    if [ "$status" != "running" ]; then
        log "⏭️  $name ($ctid): skipped — not running"
        ((SKIPPED++))
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log "🔍 $name ($ctid): would run apt upgrade [dry-run]"
        ((SKIPPED++))
        return 0
    fi

    log "📦 $name ($ctid): apt update & upgrade …"

    local output rc
    output=$(timeout "$APT_TIMEOUT" pct exec "$ctid" -- bash -l -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>&1
        apt-get upgrade -y -o Dpkg::Options::='--force-confold' -o Dpkg::Options::='--force-confdef' 2>&1
    " 2>&1) || true
    rc=${PIPESTATUS[0]:-$?}

    # Count upgraded packages from output
    local upgraded_count
    upgraded_count=$(echo "$output" | grep -c "^Inst " 2>/dev/null || echo "0")

    if echo "$output" | grep -qiE "(E: |Err:|dpkg error|FATAL)"; then
        rc=1
    fi

    if [ "$rc" -eq 0 ]; then
        # Check reboot required
        local reboot
        reboot=$(pct exec "$ctid" -- bash -c '[ -f /var/run/reboot-required ] && echo YES || echo NO' 2>/dev/null || echo "UNKNOWN")
        if [ "$reboot" = "YES" ]; then
            REBOOT_LIST+=("$name ($ctid)")
            log "✅ $name ($ctid): $upgraded_count upgraded — reboot pending"
        else
            log "✅ $name ($ctid): $upgraded_count upgraded"
        fi
        SUCCESS_LIST+=("$name")
        ((SUCCESS++))
    else
        FAIL_LIST+=("$name ($ctid)")
        log "❌ $name ($ctid): apt failed (exit $rc)"
        # Log last 10 lines for debugging
        echo "$output" | tail -10 | while IFS= read -r line; do
            log_detail "$line"
        done
        ((FAILED++))
    fi
}

run_docker_lxc() {
    local ctid="$1" name="$2"

    local status
    status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
    if [ "$status" != "running" ]; then
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log "🔍 $name ($ctid): would update Docker stacks [dry-run]"
        return 0
    fi

    log "🐳 $name ($ctid): updating Docker stacks …"

    local output rc
    output=$(timeout "$DOCKER_TIMEOUT" pct exec "$ctid" -- bash -l -c '
        updated=0
        errors=0
        for f in $(find /opt /root /home /srv /data -maxdepth 5 \
            \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \
               -o -name "compose.yml" -o -name "compose.yaml" \) 2>/dev/null); do

            dir=$(dirname "$f")
            echo ">> Stack: $dir"
            cd "$dir" || continue

            pull_out=$(docker compose pull 2>&1)
            if echo "$pull_out" | grep -q "Downloaded newer image"; then
                echo "   Pulled new images"
                docker compose up -d --remove-orphans 2>&1
                ((updated++))
            else
                echo "   Already up to date"
            fi
        done

        # Prune dangling images to free space
        docker image prune -f > /dev/null 2>&1 || true

        echo "DOCKER_SUMMARY: updated=$updated"
    ' 2>&1) || true
    rc=$?

    if [ $rc -eq 0 ]; then
        DOCKER_LIST+=("$name ($ctid)")
        log "🐳 $name ($ctid): Docker stacks processed"
    else
        log "⚠️  $name ($ctid): Docker update had issues (exit $rc)"
        echo "$output" | tail -5 | while IFS= read -r line; do
            log_detail "$line"
        done
    fi
}

run_apt_vm() {
    local vmid="$1" name="$2" ip="$3"

    local status
    status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    if [ "$status" != "running" ]; then
        log "⏭️  $name ($vmid): skipped — not running"
        ((SKIPPED++))
        return 0
    fi

    if [ -z "$ip" ] || [ "$ip" = "CHANGE_ME" ]; then
        log "⚠️  $name ($vmid): skipped — no IP configured in resources.conf"
        ((SKIPPED++))
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log "🔍 $name ($vmid): would run apt upgrade via SSH to $ip [dry-run]"
        ((SKIPPED++))
        return 0
    fi

    log "📦 $name ($vmid): apt update & upgrade via SSH ($ip) …"

    # Test SSH connectivity first
    if ! timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes root@"$ip" "echo ok" &>/dev/null; then
        FAIL_LIST+=("$name ($vmid) [SSH unreachable]")
        log "❌ $name ($vmid): SSH connection failed to $ip"
        ((FAILED++))
        return 1
    fi

    local output rc
    output=$(timeout "$APT_TIMEOUT" ssh -o ConnectTimeout=10 -o BatchMode=yes \
        root@"$ip" "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>&1
        apt-get upgrade -y -o Dpkg::Options::='--force-confold' -o Dpkg::Options::='--force-confdef' 2>&1
    " 2>&1) || true
    rc=$?

    if [ "$rc" -eq 0 ]; then
        local reboot
        reboot=$(ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$ip" \
            '[ -f /var/run/reboot-required ] && echo YES || echo NO' 2>/dev/null || echo "UNKNOWN")
        if [ "$reboot" = "YES" ]; then
            REBOOT_LIST+=("$name ($vmid)")
            log "✅ $name ($vmid): upgraded — reboot pending"
        else
            log "✅ $name ($vmid): upgraded"
        fi
        SUCCESS_LIST+=("$name")
        ((SUCCESS++))
    else
        FAIL_LIST+=("$name ($vmid)")
        log "❌ $name ($vmid): apt failed (exit $rc)"
        echo "$output" | tail -10 | while IFS= read -r line; do
            log_detail "$line"
        done
        ((FAILED++))
    fi
}

run_docker_vm() {
    local vmid="$1" name="$2" ip="$3"

    local status
    status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    if [ "$status" != "running" ]; then
        return 0
    fi

    if [ -z "$ip" ] || [ "$ip" = "CHANGE_ME" ]; then
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log "🔍 $name ($vmid): would update Docker stacks via SSH [dry-run]"
        return 0
    fi

    log "🐳 $name ($vmid): updating Docker stacks via SSH ($ip) …"

    local output rc
    output=$(timeout "$DOCKER_TIMEOUT" ssh -o ConnectTimeout=10 -o BatchMode=yes \
        root@"$ip" '
        for f in $(find /opt /root /home /srv /data -maxdepth 5 \
            \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \
               -o -name "compose.yml" -o -name "compose.yaml" \) 2>/dev/null); do
            dir=$(dirname "$f")
            echo ">> Stack: $dir"
            cd "$dir" || continue
            docker compose pull 2>&1
            docker compose up -d --remove-orphans 2>&1
        done
        docker image prune -f > /dev/null 2>&1 || true
    ' 2>&1) || true
    rc=$?

    if [ $rc -eq 0 ]; then
        DOCKER_LIST+=("$name ($vmid)")
        log "🐳 $name ($vmid): Docker stacks processed"
    else
        log "⚠️  $name ($vmid): Docker update had issues (exit $rc)"
    fi
}

run_hooks() {
    local phase="$1" id="$2" name="$3" type="$4"

    local hook_file="$HOOKS_DIR/${id}-${phase}.sh"
    if [ -f "$hook_file" ]; then
        log "🪝 $name ($id): running $phase hook …"
        if [ "$type" = "lxc" ]; then
            pct exec "$id" -- bash -l < "$hook_file" >> "$LOG_FILE" 2>&1 || \
                log "⚠️  $name ($id): $phase hook returned non-zero"
        fi
        # VM hooks would need SSH, but for simplicity we skip those for now
    fi
}

update_pve_host() {
    log "🖥️  PVE host: checking for updates …"

    if [ "$DRY_RUN" = true ]; then
        log "🔍 PVE host: would run apt upgrade [dry-run]"
        PVE_STATUS="dry-run"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >> "$LOG_FILE" 2>&1

    local upgradeable
    upgradeable=$(apt list --upgradeable 2>/dev/null | grep -v "^Listing" | wc -l)

    if [ "$upgradeable" -gt 0 ]; then
        log "🖥️  PVE host: $upgradeable packages to upgrade — installing …"
        apt-get upgrade -y \
            -o Dpkg::Options::='--force-confold' \
            -o Dpkg::Options::='--force-confdef' >> "$LOG_FILE" 2>&1 || true

        if [ -f /var/run/reboot-required ]; then
            PVE_STATUS="$upgradeable upgraded — ⚠️ REBOOT PENDING"
            REBOOT_LIST+=("PVE host")
        else
            PVE_STATUS="$upgradeable upgraded"
        fi
    else
        PVE_STATUS="already up to date"
    fi

    log "🖥️  PVE host: $PVE_STATUS"
}

# ═══════════════════════════════════════════════════════════════════════
# Notification
# ═══════════════════════════════════════════════════════════════════════

send_ntfy() {
    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - START_TIME ))
    local minutes=$(( duration / 60 ))
    local seconds=$(( duration % 60 ))

    # Determine priority & emoji based on results
    local priority="3"
    local tag="package,white_check_mark"
    local title="✅ Proxmox Updates Complete"

    if [ ${#FAIL_LIST[@]} -gt 0 ]; then
        priority="4"
        tag="package,warning"
        title="⚠️ Proxmox Updates — ${#FAIL_LIST[@]} Failed"
    fi

    # Build message body
    local msg=""
    msg+="Updated: $SUCCESS / $TOTAL"

    if [ "$SKIPPED" -gt 0 ]; then
        msg+="  •  Skipped: $SKIPPED"
    fi

    if [ ${#FAIL_LIST[@]} -gt 0 ]; then
        msg+=$'\n'"❌ Failed: $(IFS=', '; echo "${FAIL_LIST[*]}")"
    fi

    if [ ${#REBOOT_LIST[@]} -gt 0 ]; then
        msg+=$'\n'"🔄 Reboot pending: $(IFS=', '; echo "${REBOOT_LIST[*]}")"
    fi

    if [ ${#DOCKER_LIST[@]} -gt 0 ]; then
        msg+=$'\n'"🐳 Docker updated: $(IFS=', '; echo "${DOCKER_LIST[*]}")"
    fi

    msg+=$'\n'"🖥️ PVE host: $PVE_STATUS"
    msg+=$'\n'"⏱️ Duration: ${minutes}m ${seconds}s"

    # Send via ntfy
    curl -s \
        -H "Authorization: Bearer $NTFY_TOKEN" \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: $tag" \
        -d "$msg" \
        "${NTFY_URL}/${NTFY_TOPIC}" > /dev/null 2>&1

    local ntfy_rc=$?
    if [ $ntfy_rc -eq 0 ]; then
        log "📨 Notification sent to ntfy"
    else
        log "⚠️  Failed to send ntfy notification (curl exit $ntfy_rc)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

main() {
    mkdir -p "$LOG_DIR" "$HOOKS_DIR"
    acquire_lock
    cleanup_old_logs

    log "════════════════════════════════════════════════════"
    log "  PVE Updater started  $(date '+%Y-%m-%d %H:%M:%S')"
    [ "$DRY_RUN" = true ] && log "  *** DRY RUN — no changes will be made ***"
    log "════════════════════════════════════════════════════"

    # ── Read resources.conf and process each entry ──
    if [ ! -f "$RESOURCES_FILE" ]; then
        log "❌ Resources file not found: $RESOURCES_FILE"
        exit 1
    fi

    while IFS='|' read -r id type name ip flags; do
        # Skip comments and blank lines
        [[ "$id" =~ ^#.*$ ]] && continue
        [[ -z "$id" ]] && continue

        # Trim whitespace
        id=$(echo "$id" | xargs)
        type=$(echo "$type" | xargs)
        name=$(echo "$name" | xargs)
        ip=$(echo "$ip" | xargs)
        flags=$(echo "$flags" | xargs)

        # Check for skip flag
        if echo "$flags" | grep -qw "skip"; then
            log "⏭️  $name ($id): skipped (flagged 'skip' in config)"
            ((SKIPPED++))
            ((TOTAL++))
            continue
        fi

        ((TOTAL++))

        # ── Pre-hook ──
        run_hooks "pre" "$id" "$name" "$type"

        # ── apt update ──
        if echo "$flags" | grep -qw "apt"; then
            case "$type" in
                lxc) run_apt_lxc "$id" "$name" ;;
                vm)  run_apt_vm  "$id" "$name" "$ip" ;;
                *)   log "⚠️  $name ($id): unknown type '$type'" ;;
            esac
        fi

        # ── Docker update ──
        if echo "$flags" | grep -qw "docker"; then
            case "$type" in
                lxc) run_docker_lxc "$id" "$name" ;;
                vm)  run_docker_vm  "$id" "$name" "$ip" ;;
            esac
        fi

        # ── Post-hook ──
        run_hooks "post" "$id" "$name" "$type"

    done < "$RESOURCES_FILE"

    # ── PVE host ──
    if [ "$UPDATE_PVE_HOST" = true ]; then
        update_pve_host
    else
        PVE_STATUS="skipped (disabled in settings)"
        log "🖥️  PVE host: update skipped (disabled in settings.conf)"
    fi

    # ── Summary ──
    log ""
    log "════════════════════════════════════════════════════"
    log "  SUMMARY"
    log "  Total: $TOTAL  |  ✅ $SUCCESS  |  ❌ $FAILED  |  ⏭️ $SKIPPED"
    [ ${#REBOOT_LIST[@]} -gt 0 ] && log "  Reboots pending: $(IFS=', '; echo "${REBOOT_LIST[*]}")"
    [ ${#FAIL_LIST[@]} -gt 0 ]   && log "  Failures: $(IFS=', '; echo "${FAIL_LIST[*]}")"
    log "  PVE host: $PVE_STATUS"
    log "  Log: $LOG_FILE"
    log "════════════════════════════════════════════════════"

    # ── Send notification ──
    send_ntfy

    log "Done."
}

main "$@"
