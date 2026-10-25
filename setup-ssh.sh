#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# setup-ssh.sh — Set up SSH key auth from the PVE host to QEMU VMs
# ═══════════════════════════════════════════════════════════════════════
# Only needed for VMs WITHOUT the QEMU guest agent: VMs that have the agent
# installed are updated through it and need no SSH setup at all.
#
# Run once on the PVE host. Generates an SSH key (if none exists) and copies
# it to each VM so pve-updater.sh can connect without a password.
#
# Usage:   ./setup-ssh.sh <vmid-or-ip> [<vmid-or-ip> ...]
# Example: ./setup-ssh.sh 123 192.168.1.60
#          (a VMID is resolved to its IP through the guest agent, if present)
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

KEY_FILE="$HOME/.ssh/id_ed25519"
SSH_USER="${VM_SSH_USER:-root}"

if [ ! -f "$KEY_FILE" ]; then
    echo "No SSH key found at $KEY_FILE -- generating one..."
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "pve-updater@$(hostname)"
    echo "Key generated."
else
    echo "SSH key already exists at $KEY_FILE"
fi
echo ""

if [ $# -eq 0 ]; then
    sed -n '/^# Usage:/,/^# ═/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^═'
    exit 0
fi

resolve_ip() {
    local id="$1"
    command -v qm >/dev/null 2>&1 || return 1
    timeout 20 qm guest cmd "$id" network-get-interfaces 2>/dev/null | perl -MJSON::PP -e '
        local $/; my $d = eval { decode_json(<STDIN>) }; $d = $d->{result} if ref $d eq "HASH"; $d = [] unless ref $d eq "ARRAY";
        for my $if (@$d) {
            next if ($if->{name} // "") =~ /^(lo|docker|br-|veth|virbr|tailscale|wg|zt)/;
            for my $a (@{ $if->{"ip-addresses"} // [] }) {
                next unless ($a->{"ip-address-type"} // "") eq "ipv4";
                my $ip = $a->{"ip-address"} // ""; next if $ip =~ /^(127\.|169\.254\.)/;
                print $ip; exit 0;
            }
        }
        exit 1;'
}

for target in "$@"; do
    ip="$target"
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        if ! ip=$(resolve_ip "$target") || [ -z "$ip" ]; then
            echo "FAIL: could not resolve VM $target to an IP (no guest agent?). Pass the IP instead,"
            echo "      and add '$target|ip=<address>' to overrides.conf."
            echo ""
            continue
        fi
        echo "VM $target -> $ip"
    fi

    echo "----------------------------------------------------"
    echo "Copying SSH key to $SSH_USER@$ip..."
    echo "(You'll be asked for the password)"
    echo "----------------------------------------------------"
    ssh-copy-id -i "${KEY_FILE}.pub" -o StrictHostKeyChecking=accept-new "$SSH_USER@$ip" || true

    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$ip" "echo ok" &>/dev/null; then
        echo "OK: $SSH_USER@$ip -- key auth working"
    else
        echo "FAIL: $SSH_USER@$ip -- key auth failed (check the VM's sshd config: PermitRootLogin / PubkeyAuthentication)"
    fi
    echo ""
done

echo "Done. If a VM has no guest agent, add its IP to overrides.conf:  <VMID>|ip=<address>"
echo "Then check the plan with:  ./pve-updater.sh --list"
