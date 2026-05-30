#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# setup-ssh.sh — Set up SSH key auth from PVE host to QEMU VMs
# ═══════════════════════════════════════════════════════════════════════
# Run this once on the PVE host. It generates an SSH key (if none exists)
# and copies it to each VM so pve-updater.sh can connect without passwords.
#
# Usage:  ./setup-ssh.sh <vm-ip> [<vm-ip> ...]
# Example: ./setup-ssh.sh 192.168.1.50 192.168.1.60
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

KEY_FILE="$HOME/.ssh/id_ed25519"

if [ ! -f "$KEY_FILE" ]; then
    echo "No SSH key found at $KEY_FILE -- generating one..."
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "pve-updater@$(hostname)"
    echo "Key generated."
else
    echo "SSH key already exists at $KEY_FILE"
fi

echo ""

if [ $# -eq 0 ]; then
    echo "Usage: $0 <vm-ip> [<vm-ip> ...]"
    echo ""
    echo "Example:"
    echo "  $0 192.168.1.50 192.168.1.60"
    echo ""
    echo "This will ssh-copy-id to each IP as root."
    echo "You'll be prompted for the root password once per VM."
    exit 0
fi

for IP in "$@"; do
    echo "----------------------------------------------------"
    echo "Copying SSH key to root@$IP..."
    echo "(You'll be asked for the root password)"
    echo "----------------------------------------------------"

    ssh-copy-id -i "${KEY_FILE}.pub" -o StrictHostKeyChecking=accept-new root@"$IP"

    if ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$IP" "echo ok" &>/dev/null; then
        echo "OK: root@$IP -- key auth working"
    else
        echo "FAIL: root@$IP -- key auth failed (check the VM's sshd config)"
    fi
    echo ""
done

echo "Done. Update the IP addresses in resources.conf, then test with:"
echo "  ./pve-updater.sh --dry-run"
