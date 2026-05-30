# PVE Autoupdater

Automated update script for Proxmox LXC containers and QEMU VMs. Updates system packages via `apt`, Docker Compose stacks, and the PVE host itself. Sends a summary notification via ntfy.

## How It Works

- **LXC containers** are updated via `pct exec` — no SSH needed, direct host-level access
- **QEMU VMs** are updated via SSH (key-based auth)
- **Docker stacks** are auto-discovered by searching for `compose.yml` / `docker-compose.yml`
- **Stopped resources** are automatically skipped at runtime
- **PVE host** gets `apt upgrade` but never an automatic reboot
- A single **ntfy notification** summarizes everything when done

## Setup

### 1. Clone onto the PVE host

```bash
ssh root@<PVE-IP>
cd /root
git clone git@github.com:mwckr/pve-autoupdater.git
cd pve-autoupdater
chmod +x pve-updater.sh setup-ssh.sh
```

### 2. Create your settings file

```bash
cp settings.conf.example settings.conf
nano settings.conf
```

Fill in your ntfy URL, topic, and bearer token. This file is gitignored — your secrets stay local.

### 3. Set up SSH for QEMU VMs

```bash
./setup-ssh.sh 192.168.1.XX 192.168.1.YY
```

Replace with the actual IPs of webserver-deb and unifios. You'll be prompted for the root password once per VM.

### 4. Update resources.conf

Replace the `CHANGE_ME` entries with your VM IPs. Review the full list — if any container also runs Docker stacks that aren't marked, add `,docker` to their flags.

### 5. Test

```bash
./pve-updater.sh --dry-run   # Preview what would happen
./pve-updater.sh              # Run for real
```

### 6. Schedule via cron

```bash
crontab -e
```

```cron
# Every Sunday at 3:00 AM
0 3 * * 0 /root/pve-autoupdater/pve-updater.sh >> /root/pve-autoupdater/logs/cron.log 2>&1
```

### Updating the script

When you push changes to GitHub:

```bash
cd /root/pve-autoupdater && git pull
```

Your `settings.conf` is gitignored, so pulls never overwrite your secrets.

## File Structure

```
pve-autoupdater/
├── pve-updater.sh          Main script
├── settings.conf.example   Template (committed) — copy to settings.conf
├── settings.conf           Your secrets (gitignored, local only)
├── resources.conf          List of resources to update
├── setup-ssh.sh            One-time SSH key setup for VMs
├── hooks/                  Custom pre/post scripts per resource
│   └── README
├── logs/                   Auto-created, auto-cleaned (gitignored)
└── .gitignore
```

## Managing Resources

**Add a new LXC container:**
```
130|lxc|my-new-service||apt
```

**Add one with Docker:**
```
131|lxc|my-docker-app||apt,docker
```

**Temporarily disable:**
```
130|lxc|my-new-service||skip
```

**Add a new VM:**
1. Run `./setup-ssh.sh <VM-IP>`
2. Add: `130|vm|my-vm|192.168.1.70|apt`

## Custom Hooks

For resources needing special handling, drop scripts into `hooks/`:

```bash
# hooks/108-post.sh — restart Plex after upgrade
systemctl restart plexmediaserver
```

```bash
# hooks/119-post.sh — update n8n after apt
cd /opt/n8n && npm update -g n8n
```

See `hooks/README` for naming conventions.

## Notification Example

```
✅ Proxmox Updates Complete

Updated: 18 / 20  •  Skipped: 2
❌ Failed: karakeep (102)
🔄 Reboot pending: adguard (103), debian (112), PVE host
🐳 Docker updated: dockge (116), komodo-docker (127)
🖥️ PVE host: 5 upgraded — ⚠️ REBOOT PENDING
⏱️ Duration: 8m 42s
```

Priority is raised to high if anything fails.

## CLI Options

```bash
./pve-updater.sh              # Normal run
./pve-updater.sh --dry-run    # Preview only, no changes
./pve-updater.sh --force      # Run even if a previous run left a stale lock
```

## Troubleshooting

**"settings.conf not found"** — Run `cp settings.conf.example settings.conf` and fill in your values.

**"Another instance is running"** — A previous run didn't finish cleanly. Use `--force`.

**VM shows "SSH connection failed"** — Verify: `ssh -o BatchMode=yes root@<VM-IP> "echo ok"`

**Docker stacks not found** — The script searches `/opt /root /home /srv /data` up to 5 levels deep. For other paths, use a post-hook.
