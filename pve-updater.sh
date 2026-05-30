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

set -uo pipefail

# ── Paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES_FILE="$SCRIPT_DIR/resources.conf"
HOOKS_DIR="$SCRIPT_DIR/hooks"
LOG_DIR="$SCRIPT_DIR/logs"
LOCK_FILE="$SCRIPT_DIR/pve-updater.lock"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/update-$TIMESTAMP.log"

# ── Preflight: verify we're on a PVE host ──
for cmd in pct qm; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found. This script must run on a Proxmox VE host."
        exit 1
    fi
done

# ── Load settings ──
if [ ! -f "$SCRIPT_DIR/settings.conf" ]; then
    echo "ERROR: settings.conf not found."
    echo "  First run? Copy the example and fill in your values:"
    echo ""
    echo "  cp $SCRIPT_DIR/settings.conf.example $SCRIPT_DIR/settings.conf"
    echo "  nano $SCRIPT_DIR/settings.conf"
    echo ""
    exit 1
fi
source "$SCRIPT_DIR/settings.conf"

# ── Validate required settings ──
: "${NTFY_URL:?settings.conf: NTFY_URL is not set}"
: "${NTFY_TOKEN:?settings.conf: NTFY_TOKEN is not set}"
: "${NTFY_TOPIC:?settings.conf: NTFY_TOPIC is not set}"
: "${APT_TIMEOUT:?settings.conf: APT_TIMEOUT is not set}"
: "${DOCKER_TIMEOUT:?settings.conf: DOCKER_TIMEOUT is not set}"
: "${LOG_RETENTION_DAYS:?settings.conf: LOG_RETENTION_DAYS is not set}"

if [ "$NTFY_TOKEN" = "YOUR_NTFY_TOKEN" ] || [ "$NTFY_URL" = "http://YOUR_NTFY_IP" ]; then
    echo "ERROR: settings.conf still has placeholder values. Edit it first:"
    echo "  nano $SCRIPT_DIR/settings.conf"
    exit 1
fi

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
PVE_STATUS=""
APP_STATUS=""
START_TIME=$(date +%s)

# ── Defaults for optional settings (safe for upgrades from older configs) ──
UPDATE_APPS="${UPDATE_APPS:-false}"
APP_UPDATE_BACKUP="${APP_UPDATE_BACKUP:-no}"
APP_UPDATE_REBOOT="${APP_UPDATE_REBOOT:-no}"

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
                log "WARN: Overriding existing lock (PID $pid) due to --force"
                rm -f "$LOCK_FILE"
            else
                log "FAIL: Another instance is running (PID $pid). Use --force to override."
                exit 1
            fi
        else
            log "WARN: Removing stale lock file (PID $pid no longer running)"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

cleanup_old_logs() {
    find "$LOG_DIR" -name "update-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
    find "$LOG_DIR" -name "app-update-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
    find /usr/local/community-scripts/update_apps -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════
# Update functions
# ═══════════════════════════════════════════════════════════════════════

run_apt_lxc() {
    local ctid="$1" name="$2"

    local status
    status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
    if [ "$status" != "running" ]; then
        log "SKIP: $name ($ctid) -- not running"
        ((SKIPPED++))
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: $name ($ctid) -- would run apt upgrade"
        ((SKIPPED++))
        return 0
    fi

    log "APT: $name ($ctid) -- update & upgrade"

    local output rc
    output=$(timeout "$APT_TIMEOUT" pct exec "$ctid" -- bash -l -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>&1 && \
        apt-get upgrade -y -o Dpkg::Options::='--force-confold' -o Dpkg::Options::='--force-confdef' 2>&1
    " 2>&1)
    rc=$?

    local upgraded_count
    upgraded_count=$(echo "$output" | grep -oP '^\d+ upgraded' | grep -oP '^\d+' || echo "0")

    if [ "$rc" -eq 0 ]; then
        local reboot
        reboot=$(pct exec "$ctid" -- bash -c '[ -f /var/run/reboot-required ] && echo YES || echo NO' 2>/dev/null || echo "UNKNOWN")
        if [ "$reboot" = "YES" ]; then
            REBOOT_LIST+=("$name ($ctid)")
            log "OK: $name ($ctid) -- $upgraded_count upgraded, reboot pending"
        else
            log "OK: $name ($ctid) -- $upgraded_count upgraded"
        fi
        ((SUCCESS++))
    else
        FAIL_LIST+=("$name ($ctid)")
        log "FAIL: $name ($ctid) -- apt failed (exit $rc)"
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
        log "DRY-RUN: $name ($ctid) -- would update Docker stacks"
        return 0
    fi

    log "DOCKER: $name ($ctid) -- updating stacks"

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

            if ! pull_out=$(docker compose pull 2>&1); then
                echo "   FAIL: pull failed"
                echo "$pull_out" | tail -3
                ((errors++))
                continue
            fi

            if echo "$pull_out" | grep -q "Downloaded newer image"; then
                echo "   Pulled new images"
                if ! docker compose up -d --remove-orphans 2>&1; then
                    echo "   FAIL: restart failed"
                    ((errors++))
                else
                    ((updated++))
                fi
            else
                echo "   Already up to date"
            fi
        done

        docker image prune -f > /dev/null 2>&1 || true

        echo "DOCKER_SUMMARY: updated=$updated errors=$errors"
        exit $errors
    ' 2>&1)
    rc=$?

    local docker_errors
    docker_errors=$(echo "$output" | grep -oP 'errors=\K\d+' || echo "0")

    if [ $rc -eq 0 ]; then
        DOCKER_LIST+=("$name ($ctid)")
        log "DOCKER: $name ($ctid) -- stacks processed"
    elif [ "$docker_errors" -gt 0 ]; then
        FAIL_LIST+=("$name ($ctid) [docker: ${docker_errors} failed]")
        log "FAIL: $name ($ctid) -- docker: $docker_errors stack(s) had errors"
        echo "$output" | tail -8 | while IFS= read -r line; do
            log_detail "$line"
        done
        ((FAILED++))
    else
        FAIL_LIST+=("$name ($ctid) [docker: exit $rc]")
        log "FAIL: $name ($ctid) -- docker update failed (exit $rc)"
        echo "$output" | tail -5 | while IFS= read -r line; do
            log_detail "$line"
        done
        ((FAILED++))
    fi
}

run_apt_vm() {
    local vmid="$1" name="$2" ip="$3"

    local status
    status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    if [ "$status" != "running" ]; then
        log "SKIP: $name ($vmid) -- not running"
        ((SKIPPED++))
        return 0
    fi

    if [ -z "$ip" ] || [ "$ip" = "CHANGE_ME" ]; then
        log "WARN: $name ($vmid) -- skipped, no IP configured in resources.conf"
        ((SKIPPED++))
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: $name ($vmid) -- would run apt upgrade via SSH to $ip"
        ((SKIPPED++))
        return 0
    fi

    log "APT: $name ($vmid) -- update & upgrade via SSH ($ip)"

    if ! timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=yes \
        -o BatchMode=yes root@"$ip" "echo ok" &>/dev/null; then
        FAIL_LIST+=("$name ($vmid) [SSH unreachable]")
        log "FAIL: $name ($vmid) -- SSH connection failed to $ip"
        ((FAILED++))
        return 1
    fi

    local output rc
    output=$(timeout "$APT_TIMEOUT" ssh -o ConnectTimeout=10 -o BatchMode=yes \
        -o StrictHostKeyChecking=yes root@"$ip" "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>&1 && \
        apt-get upgrade -y -o Dpkg::Options::='--force-confold' -o Dpkg::Options::='--force-confdef' 2>&1
    " 2>&1)
    rc=$?

    if [ "$rc" -eq 0 ]; then
        local reboot
        reboot=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=yes \
            root@"$ip" '[ -f /var/run/reboot-required ] && echo YES || echo NO' 2>/dev/null || echo "UNKNOWN")
        if [ "$reboot" = "YES" ]; then
            REBOOT_LIST+=("$name ($vmid)")
            log "OK: $name ($vmid) -- upgraded, reboot pending"
        else
            log "OK: $name ($vmid) -- upgraded"
        fi
        ((SUCCESS++))
    else
        FAIL_LIST+=("$name ($vmid)")
        log "FAIL: $name ($vmid) -- apt failed (exit $rc)"
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
        log "DRY-RUN: $name ($vmid) -- would update Docker stacks via SSH"
        return 0
    fi

    log "DOCKER: $name ($vmid) -- updating stacks via SSH ($ip)"

    local output rc
    output=$(timeout "$DOCKER_TIMEOUT" ssh -o ConnectTimeout=10 -o BatchMode=yes \
        -o StrictHostKeyChecking=yes root@"$ip" '
        updated=0
        errors=0
        for f in $(find /opt /root /home /srv /data -maxdepth 5 \
            \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \
               -o -name "compose.yml" -o -name "compose.yaml" \) 2>/dev/null); do
            dir=$(dirname "$f")
            echo ">> Stack: $dir"
            cd "$dir" || continue

            if ! pull_out=$(docker compose pull 2>&1); then
                echo "   FAIL: pull failed"
                echo "$pull_out" | tail -3
                ((errors++))
                continue
            fi

            if echo "$pull_out" | grep -q "Downloaded newer image"; then
                echo "   Pulled new images"
                if ! docker compose up -d --remove-orphans 2>&1; then
                    echo "   FAIL: restart failed"
                    ((errors++))
                else
                    ((updated++))
                fi
            else
                echo "   Already up to date"
            fi
        done
        docker image prune -f > /dev/null 2>&1 || true
        echo "DOCKER_SUMMARY: updated=$updated errors=$errors"
        exit $errors
    ' 2>&1)
    rc=$?

    local docker_errors
    docker_errors=$(echo "$output" | grep -oP 'errors=\K\d+' || echo "0")

    if [ $rc -eq 0 ]; then
        DOCKER_LIST+=("$name ($vmid)")
        log "DOCKER: $name ($vmid) -- stacks processed"
    elif [ "$docker_errors" -gt 0 ]; then
        FAIL_LIST+=("$name ($vmid) [docker: ${docker_errors} failed]")
        log "FAIL: $name ($vmid) -- docker: $docker_errors stack(s) had errors"
        echo "$output" | tail -8 | while IFS= read -r line; do
            log_detail "$line"
        done
        ((FAILED++))
    else
        FAIL_LIST+=("$name ($vmid) [docker: exit $rc]")
        log "FAIL: $name ($vmid) -- docker update failed (exit $rc)"
        echo "$output" | tail -5 | while IFS= read -r line; do
            log_detail "$line"
        done
        ((FAILED++))
    fi
}

run_hooks() {
    local phase="$1" id="$2" name="$3" type="$4"

    local hook_file="$HOOKS_DIR/${id}-${phase}.sh"
    if [ -f "$hook_file" ]; then
        local hook_owner hook_perms
        hook_owner=$(stat -c '%u' "$hook_file")
        hook_perms=$(stat -c '%a' "$hook_file")

        if [ "$hook_owner" != "0" ]; then
            log "WARN: $name ($id) -- skipping $phase hook, not owned by root (uid $hook_owner)"
            return 1
        fi

        # Extract group and other digits via string slicing, then check write bit.
        # Works for both 3-digit (755) and 4-digit (4755) stat output.
        local group_digit="${hook_perms: -2:1}"
        local other_digit="${hook_perms: -1:1}"
        if (( group_digit & 2 )) || (( other_digit & 2 )); then
            log "WARN: $name ($id) -- skipping $phase hook, group/world-writable (mode $hook_perms)"
            return 1
        fi

        log "HOOK: $name ($id) -- running $phase hook"
        if [ "$type" = "lxc" ]; then
            pct exec "$id" -- bash -l < "$hook_file" >> "$LOG_FILE" 2>&1 || \
                log "WARN: $name ($id) -- $phase hook returned non-zero"
        fi
    fi
}

update_pve_host() {
    log "PVE: checking for updates"

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: PVE host -- would run apt upgrade"
        PVE_STATUS="dry-run"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive

    if ! apt-get update -qq >> "$LOG_FILE" 2>&1; then
        PVE_STATUS="apt update failed -- check log"
        log "WARN: PVE host -- apt-get update failed"
        return 1
    fi

    local upgradeable
    upgradeable=$(apt list --upgradeable 2>/dev/null | grep -v "^Listing" | wc -l)

    if [ "$upgradeable" -gt 0 ]; then
        log "PVE: $upgradeable packages to upgrade -- installing"
        if apt-get upgrade -y \
            -o Dpkg::Options::='--force-confold' \
            -o Dpkg::Options::='--force-confdef' >> "$LOG_FILE" 2>&1; then

            if [ -f /var/run/reboot-required ]; then
                PVE_STATUS="$upgradeable upgraded -- REBOOT PENDING"
                REBOOT_LIST+=("PVE host")
            else
                PVE_STATUS="$upgradeable upgraded"
            fi
        else
            PVE_STATUS="apt upgrade failed -- check log"
            FAIL_LIST+=("PVE host")
            ((FAILED++))
        fi
    else
        PVE_STATUS="already up to date"
    fi

    log "PVE: $PVE_STATUS"
}

# ═══════════════════════════════════════════════════════════════════════
# Community-scripts app updates
# ═══════════════════════════════════════════════════════════════════════

run_app_updates() {
    log "APPS: running community-scripts update-apps.sh"

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: would run update-apps.sh for all tagged containers"
        APP_STATUS="dry-run"
        return 0
    fi

    local app_log="$LOG_DIR/app-update-$TIMESTAMP.log"
    local rc

    var_backup="$APP_UPDATE_BACKUP" \
    var_container=all_running \
    var_unattended=yes \
    var_skip_confirm=yes \
    var_auto_reboot="$APP_UPDATE_REBOOT" \
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/update-apps.sh)" \
        > "$app_log" 2>&1
    rc=$?

    # Strip ANSI escape codes for clean log output
    sed -i 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\r//g' "$app_log" 2>/dev/null

    if [ $rc -eq 0 ]; then
        log "APPS: update-apps.sh finished successfully (see $app_log)"
    else
        FAIL_LIST+=("app-updates [exit $rc]")
        ((FAILED++))
        log "FAIL: update-apps.sh exited with code $rc (see $app_log)"
    fi

    # Parse the summary table from the log for the notification.
    # Lines look like: "  102       karakeep                OK          Updated successfully"
    local app_ok app_fail ok_names fail_names
    app_ok=$(grep -P '^\s+\d+\s+\S+\s+OK\b' "$app_log" 2>/dev/null | wc -l)
    app_fail=$(grep -P '^\s+\d+\s+\S+\s+FAILED\b' "$app_log" 2>/dev/null | wc -l)
    ok_names=$(grep -P '^\s+\d+\s+\S+\s+OK\b' "$app_log" 2>/dev/null | awk '{print $2}' | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
    fail_names=$(grep -P '^\s+\d+\s+\S+\s+FAILED\b' "$app_log" 2>/dev/null | awk '{print $2}' | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')

    if [ "$app_fail" -gt 0 ]; then
        APP_STATUS="${app_ok} OK, ${app_fail} FAILED (${fail_names})"
    elif [ "$app_ok" -gt 0 ]; then
        APP_STATUS="${app_ok} OK (${ok_names})"
    elif [ $rc -eq 0 ]; then
        APP_STATUS="completed (no updates needed)"
    else
        APP_STATUS="failed (exit $rc)"
    fi
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

    local priority="3"
    local tag="package,white_check_mark"
    local title="Proxmox Updates Complete"

    if [ ${#FAIL_LIST[@]} -gt 0 ]; then
        priority="4"
        tag="package,warning"
        title="Proxmox Updates -- ${#FAIL_LIST[@]} Failed"
    fi

    local msg=""
    msg+="Updated: $SUCCESS / $TOTAL"

    if [ "$SKIPPED" -gt 0 ]; then
        msg+="  |  Skipped: $SKIPPED"
    fi

    if [ ${#FAIL_LIST[@]} -gt 0 ]; then
        msg+=$'\n'"Failed: $(IFS=', '; echo "${FAIL_LIST[*]}")"
    fi

    if [ ${#REBOOT_LIST[@]} -gt 0 ]; then
        msg+=$'\n'"Reboot pending: $(IFS=', '; echo "${REBOOT_LIST[*]}")"
    fi

    if [ ${#DOCKER_LIST[@]} -gt 0 ]; then
        msg+=$'\n'"Docker updated: $(IFS=', '; echo "${DOCKER_LIST[*]}")"
    fi

    msg+=$'\n'"PVE host: $PVE_STATUS"

    if [ -n "$APP_STATUS" ]; then
        msg+=$'\n'"App updates: $APP_STATUS"
    fi

    msg+=$'\n'"Duration: ${minutes}m ${seconds}s"

    curl -s --max-time 15 \
        -H "Authorization: Bearer $NTFY_TOKEN" \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: $tag" \
        -d "$msg" \
        "${NTFY_URL}/${NTFY_TOPIC}" > /dev/null 2>&1

    local ntfy_rc=$?
    if [ $ntfy_rc -eq 0 ]; then
        log "NTFY: notification sent"
    else
        log "WARN: failed to send ntfy notification (curl exit $ntfy_rc)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

main() {
    mkdir -p "$LOG_DIR" "$HOOKS_DIR"
    acquire_lock

    [ "$DRY_RUN" = false ] && cleanup_old_logs

    log "════════════════════════════════════════════════════"
    log "  PVE Updater started  $(date '+%Y-%m-%d %H:%M:%S')"
    [ "$DRY_RUN" = true ] && log "  *** DRY RUN -- no changes will be made ***"
    log "════════════════════════════════════════════════════"

    if [ ! -f "$RESOURCES_FILE" ]; then
        log "FAIL: Resources file not found: $RESOURCES_FILE"
        exit 1
    fi

    while IFS='|' read -r id type name ip flags; do
        [[ "$id" =~ ^#.*$ ]] && continue
        [[ -z "$id" ]] && continue

        id=$(echo "$id" | xargs)
        type=$(echo "$type" | xargs)
        name=$(echo "$name" | xargs)
        ip=$(echo "$ip" | xargs)
        flags=$(echo "$flags" | xargs)

        if echo "$flags" | grep -qw "skip"; then
            log "SKIP: $name ($id) -- flagged 'skip' in config"
            ((SKIPPED++))
            ((TOTAL++))
            continue
        fi

        ((TOTAL++))

        run_hooks "pre" "$id" "$name" "$type"

        if echo "$flags" | grep -qw "apt"; then
            case "$type" in
                lxc) run_apt_lxc "$id" "$name" ;;
                vm)  run_apt_vm  "$id" "$name" "$ip" ;;
                *)   log "WARN: $name ($id) -- unknown type '$type'" ;;
            esac
        fi

        if echo "$flags" | grep -qw "docker"; then
            case "$type" in
                lxc) run_docker_lxc "$id" "$name" ;;
                vm)  run_docker_vm  "$id" "$name" "$ip" ;;
            esac
        fi

        run_hooks "post" "$id" "$name" "$type"

    done < "$RESOURCES_FILE"

    # ── Community-scripts app updates ──
    if [ "$UPDATE_APPS" = true ]; then
        run_app_updates
    else
        APP_STATUS=""
    fi

    # ── PVE host ──
    if [ "$UPDATE_PVE_HOST" = true ]; then
        update_pve_host
    else
        PVE_STATUS="skipped (disabled in settings)"
        log "PVE: update skipped (disabled in settings.conf)"
    fi

    log ""
    log "════════════════════════════════════════════════════"
    log "  SUMMARY"
    log "  Total: $TOTAL  |  OK: $SUCCESS  |  Failed: $FAILED  |  Skipped: $SKIPPED"
    [ ${#REBOOT_LIST[@]} -gt 0 ] && log "  Reboots pending: $(IFS=', '; echo "${REBOOT_LIST[*]}")"
    [ ${#FAIL_LIST[@]} -gt 0 ]   && log "  Failures: $(IFS=', '; echo "${FAIL_LIST[*]}")"
    [ -n "$APP_STATUS" ]         && log "  App updates: $APP_STATUS"
    log "  PVE host: $PVE_STATUS"
    log "  Log: $LOG_FILE"
    log "════════════════════════════════════════════════════"

    send_ntfy

    log "Done."
}

main "$@"
