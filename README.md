# PVE Updater

Automated update script for Proxmox LXC containers and QEMU VMs. Updates system packages via `apt`, Docker Compose stacks, and the PVE host itself. Sends a summary notification via ntfy.

## How It Works

- **LXC containers** are updated via `pct exec` — no SSH, no keys, direct host-level access
- **QEMU VMs** are updated via SSH (key-based auth)
- **Docker stacks** are auto-discovered by searching for `compose.yml` / `docker-compose.yml` files
- **Stopped resources** are automatically skipped at runtime
- **PVE host** is updated last (reboot is never automatic)
- A single **ntfy notification** summarizes everything when done

## Quick Setup (5 minutes)

### 1. Copy files to PVE host

From your local machine (or any machine with the files):

```bash
scp -r pve-updater/ root@<PVE-IP>:/root/pve-updater/
```

### 2. Make scripts executable

```bash
ssh root@<PVE-IP>
cd /root/pve-updater
chmod +x pve-updater.sh setup-ssh.sh
```

### 3. Edit settings.conf

Open `settings.conf` and verify the ntfy URL, topic, and token are correct.

### 4. Set up SSH for QEMU VMs

```bash
./setup-ssh.sh 192.168.1.XX 192.168.1.YY
```

Replace with the actual IPs of your VMs (webserver-deb and unifios). You'll be prompted for each VM's root password once.

### 5. Update resources.conf

Open `resources.conf` and replace `CHANGE_ME` with the actual IP addresses of your VMs:

```
123|vm|webserver-deb|192.168.1.50|apt
124|vm|unifios|192.168.1.60|apt
```

### 6. Test with a dry run

```bash
./pve-updater.sh --dry-run
```

This shows what the script *would* do without making any changes.

### 7. Run it for real

```bash
./pve-updater.sh
```

### 8. Set up the cron job

```bash
crontab -e
```

Add one of these (pick your preferred schedule):

```cron
# Every Sunday at 3:00 AM
0 3 * * 0 /root/pve-updater/pve-updater.sh >> /root/pve-updater/logs/cron.log 2>&1

# Every Saturday at 4:00 AM
0 4 * * 6 /root/pve-updater/pve-updater.sh >> /root/pve-updater/logs/cron.log 2>&1
```

## File Structure

```
/root/pve-updater/
├── pve-updater.sh      Main script (run this)
├── settings.conf       ntfy credentials, timeouts, toggles
├── resources.conf      List of resources to update
├── setup-ssh.sh        One-time SSH key setup for VMs
├── hooks/              Custom pre/post scripts per resource
│   └── README          Explains the hook naming convention
└── logs/               Auto-created, auto-cleaned
    └── update-*.log    One log file per run
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

**Temporarily disable a resource:**
```
130|lxc|my-new-service||skip
```

**Add a new VM:**
1. Run `./setup-ssh.sh <VM-IP>` to copy the SSH key
2. Add to resources.conf: `130|vm|my-vm|192.168.1.70|apt`

## Custom Hooks

For resources that need special handling (restart a service, run a specific update command), create hook scripts in the `hooks/` directory:

```bash
# Example: hooks/108-post.sh (runs after Plex is updated)
systemctl restart plexmediaserver
```

See `hooks/README` for details.

## Notification Format

You'll get an ntfy notification like this after each run:

```
✅ Proxmox Updates Complete

Updated: 18 / 20  •  Skipped: 2
❌ Failed: karakeep (102)
🔄 Reboot pending: adguard (103), debian (112), PVE host
🐳 Docker updated: dockge (116), komodo-docker (127)
🖥️ PVE host: 5 upgraded — ⚠️ REBOOT PENDING
⏱️ Duration: 8m 42s
```

If any resource fails, the notification priority is raised to high so it stands out.

## Logs

Each run creates a timestamped log in `logs/`. Logs older than 30 days are auto-deleted (configurable in `settings.conf`).

View the latest log:
```bash
ls -t /root/pve-updater/logs/ | head -1 | xargs -I{} cat /root/pve-updater/logs/{}
```

## Troubleshooting

**"Another instance is running"** — A previous run didn't finish cleanly. Use `--force`:
```bash
./pve-updater.sh --force
```

**VM shows "SSH connection failed"** — Verify key auth works:
```bash
ssh -o BatchMode=yes root@<VM-IP> "echo ok"
```

**A container fails with apt errors** — Check the log file for details. Common causes: broken packages, full disk, expired repo keys. Fix manually, then the next run will succeed.

**Docker stacks not found** — The script searches `/opt`, `/root`, `/home`, `/srv`, and `/data` (up to 5 levels deep). If your compose files are elsewhere, create a post-hook that handles it.
