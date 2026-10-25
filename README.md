# PVE Autoupdater

Unattended weekly updates for a Proxmox VE node: every LXC container, every VM, the Docker Compose stacks inside them, community-scripts apps, and the PVE host itself. One ntfy notification when it is done, and one if the run aborts.

There is **no inventory to maintain**. Guests are discovered from Proxmox on every run, so creating, cloning, renaming or deleting a container is picked up automatically. Exceptions are expressed as Proxmox tags.

## What a run does

1. **Discovers** all guests on the node. Templates are ignored, stopped guests are skipped, guests locked by a running backup are retried at the end of the run.
2. For every running guest (unless tagged otherwise):
   - takes a **snapshot** `autoupd-<timestamp>` — rolling, the newest 2 are kept, older ones are deleted
   - runs `hooks/<ID>-pre.sh` if present (a failing pre-hook stops the update of that guest)
   - updates **OS packages**: Debian/Ubuntu via `apt-get upgrade --with-new-pkgs` (plus `autoremove`), Alpine via `apk upgrade`. Guests without a supported package manager are left alone.
   - updates **Docker Compose stacks** if Docker is installed. Only stacks that are currently running are considered, and only services whose image actually changed are recreated. Stopped stacks or services are never started.
   - runs `hooks/<ID>-post.sh` if present
   - checks the guest is **still running** (and starts it again if not)
   - records whether a **reboot is pending**; reboots only if you enable it
3. Runs the community-scripts **`update-apps.sh`** for containers that updated successfully and are either tagged `community-script` or carry the community `/usr/bin/update` tool (optional). Be aware that this phase is by far the slowest part of a run: every app's own updater runs in turn, often re-running apt and downloading the application, so 20 containers can take two to three hours. If that is too long for a weekly window, set `UPDATE_APPS=false` and run `./pve-updater.sh` with apps enabled less often, or keep it and accept the runtime.
4. Updates the **PVE host** with `apt-get dist-upgrade`, which is what Proxmox recommends and what the GUI's Upgrade button runs. It refuses to continue if the upgrade would remove core Proxmox packages and waits for a running vzdump to finish. A reboot into a new kernel only happens with `AUTO_REBOOT_HOST=true` (see *Safety net*).
5. Sends the **ntfy summary**. The exit code is non-zero if anything failed.

### VMs

VMs are updated through the **QEMU guest agent** when it is installed (`qm guest exec`): no SSH, no IP addresses, nothing to configure. Inside the VM run `apt install qemu-guest-agent`, then enable *QEMU Guest Agent* under the VM's Options in the GUI.

Without an agent, or when the agent has exec disabled, the script falls back to **SSH as root**. It takes the IP from the agent or from `overrides.conf` and needs key auth, which `./setup-ssh.sh <VMID or IP>` sets up once.

VMs whose OS is not apt based (Home Assistant OS, Windows, UniFi appliances, …) are skipped automatically, with the reason in the notification. Tag them `no-update` to silence that.

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

Fill in the ntfy URL, topic and token. Everything else has sensible defaults and is documented in the example file. `settings.conf` is gitignored, so pulls never overwrite it.

### 3. Look at the plan

```bash
./pve-updater.sh --list
```

This prints every guest with what the script would do to it, including how each VM will be reached. Fix anything you don't like with tags (next section), then:

```bash
./pve-updater.sh --dry-run        # probes every guest, changes nothing, sends a test notification
./pve-updater.sh --only 103       # real run for a single guest
./pve-updater.sh                  # full run
```

### 4. Schedule via cron

```bash
crontab -e
```

```cron
# Every Sunday at 3:00 AM
0 3 * * 0 /root/pve-autoupdater/pve-updater.sh >> /root/pve-autoupdater/logs/cron.log 2>&1
```

Pick a time that does not overlap your backup job. If it does, the script copes (locked guests are retried, the host update waits), but the run takes longer.

## Controlling guests

Set these **tags** on a guest in the GUI (select the guest → Tags). Changes take effect on the next run.

| Tag           | Effect                                   |
|---------------|------------------------------------------|
| `no-update`   | never touch this guest                   |
| `no-apt`      | skip OS package updates                  |
| `no-docker`   | skip Docker stack updates                |
| `no-snapshot` | don't snapshot before updating           |
| `no-apps`     | skip the community-scripts app update    |

The same keywords can go into `overrides.conf` (`<ID>|keyword,keyword`), which is also where a VM without guest agent gets its SSH address: `124|ip=192.168.1.1`. See the comments in that file.

Stopped guests are skipped automatically, so there is no need to tag something you shut down.

## Safety net

- **Snapshots.** Every guest is snapshotted right before it is touched. To undo a bad update:
  ```bash
  pct listsnapshot 104
  pct rollback 104 autoupd-20261025-030001          # LXC
  qm  rollback 123 autoupd-20261025-030001 --start 1 # VM
  ```
  The notification includes the exact rollback command for every failed guest. Snapshots need storage that supports them (LVM-thin, ZFS, qcow2 on a directory). On storage that doesn't (raw files on NFS), the snapshot fails, a warning is reported, and the update proceeds; set `SNAPSHOT_REQUIRED=true` to make it skip such guests instead. Bind mounts are never part of a snapshot.
- **Low disk guard.** A guest with less than `MIN_FREE_MB` free on `/` is not updated and reported as failed. Same for the host with `HOST_MIN_FREE_MB`.
- **Core package guard.** The host upgrade is simulated first. If it would remove `proxmox-ve`, `pve-manager`, `qemu-server`, `pve-container` or similar (the classic broken-repo failure), nothing is installed and you get a notification.
- **Partial repo failures don't block security updates.** If `apt-get update` reports errors (an expired third-party key, the enterprise repo without a subscription), the upgrade still runs with what could be fetched and the guest is listed under *Warnings* until you fix the repo.
- **Interrupted dpkg runs heal themselves.** `dpkg --configure -a` runs before every upgrade.
- **Locking and watchdog.** Only one instance can run (kernel `flock`, so stale locks cannot happen). A run that exceeds `MAX_RUNTIME` is aborted. Every external command has a timeout.
- **Abort notification.** If the script dies for any reason before the summary, a high-priority *ABORTED* notification with the last log lines is sent, so a silent broken cron job is not possible.
- **No automatic reboots** unless you set `AUTO_REBOOT_LXC` / `AUTO_REBOOT_VM`. Pending reboots are listed in every notification until done. The host is rebooted only with `AUTO_REBOOT_HOST=true`, and even then only if every running guest has *Start at boot* enabled, no backup is running, and the run was a full one. The notification goes out first, the reboot follows one minute later and can be cancelled with `shutdown -c`. A kernel pinned with `proxmox-boot-tool` is respected.
- **Services restart automatically** after library updates when `needrestart` is installed in a guest (`apt install needrestart`); the script runs apt with `NEEDRESTART_MODE=a`.

## Hooks

Drop scripts into `hooks/` to run inside a guest before or after its update, for example to stop and start a service or run a custom updater:

```bash
# hooks/108-pre.sh
systemctl stop plexmediaserver
# hooks/108-post.sh
systemctl start plexmediaserver
```

Hooks work for containers and VMs, must be root-owned and not group/world-writable. See `hooks/README`.

## Notification example

```
⚠️ Proxmox Updates -- 2 Failed

Updated: 17 / 29 (62 pkgs)  |  Skipped: 9
Failed: isponsorblocktv (104): apt upgrade rc 100 [rollback: pct rollback 104 autoupd-20261025-030001]; pairdrop (109): low disk (120 MB free)
Warnings: debian (112): apt update errors
Reboot pending: adguard (103), webserver-deb (123), PVE host
Docker updated: komodo-docker (127): 1/3
Skipped: 4 stopped; haos (113): unsupported OS 'haos' (tag no-update to silence)
App updates: 5 OK
PVE host: 5 upgraded
Duration: 8m 42s
```

Priority is raised when anything fails. An aborted run sends a separate *ABORTED* message at the highest priority.

## CLI

```bash
./pve-updater.sh                  # normal run (what cron calls)
./pve-updater.sh --list           # discovered inventory and plan, nothing else
./pve-updater.sh --dry-run        # probe every guest, change nothing
./pve-updater.sh --only 101,123   # restrict to these guest IDs
./pve-updater.sh --no-host        # skip the PVE host update
./pve-updater.sh --no-apps        # skip the community-scripts app update phase
./pve-updater.sh --no-ntfy        # don't notify
```

Logs: `logs/latest.log` points at the current run, `logs/update-*.log` hold the per-run detail (including apt and docker output per guest), `logs/app-update-*.log` the community-scripts output. Old logs are deleted after `LOG_RETENTION_DAYS`.

## Troubleshooting

**A manual run looks stuck** — the community app-update phase prints nothing to the console; follow it with `tail -f logs/app-update-*.log`. Ctrl-C stops a run at any point, kills the running command and sends an ABORTED notification. Guest commands and the community script run detached from your terminal, so nothing inside them can grab the console or wait for a keypress.

**"another instance is running"** — a run is still going, or a leftover process from an aborted run still holds the lock. The message lists the holding PIDs and the `kill` command to end them. The lock is released the moment the last holder exits; there is no lock file to delete.

**VM: "no guest agent and no ip=…"** — install `qemu-guest-agent` in the VM and enable it in the VM options, or add `<VMID>|ip=<address>` to `overrides.conf` and run `./setup-ssh.sh <VMID>`.

**VM: "SSH key not installed"** — `./setup-ssh.sh <VMID>`. Verify with `ssh -o BatchMode=yes root@<IP> echo ok`.

**VM: "unsupported OS"** — the guest is not apt based. Tag it `no-update`.

**Docker stacks not updated** — only stacks with running containers whose compose file still exists at the path Docker recorded are handled. Containers started with plain `docker run` are not managed; use a post-hook or Watchtower for those. Look at the run log for the per-stack detail.

**Docker: "pull failed … toomanyrequests"** — Docker Hub rate-limits anonymous pulls per IP, and a guest with many stacks pulls them all in one burst. Run `docker login` once inside that container; authenticated pulls get a much higher limit.

**"would remove core packages"** — run `apt-get -s dist-upgrade` on the host and check your repositories; this is almost always a wrong or missing repo entry.

**App update "needs a manual run"** — that app's community updater stopped at a question, typically a migration confirmation. The script never answers such questions for you. Run it once by hand, `pct exec <ID> -- update`, read what it asks, and it will be unattended again afterwards. If an updater always asks, tag the container `no-apps`.

**A guest broke after an update** — roll back (see *Safety net*), then tag it `no-update` until you have looked into it.

## Updating the script

```bash
cd /root/pve-autoupdater && git pull
```

`settings.conf` is gitignored, your settings stay. New settings get defaults automatically; see `settings.conf.example` for what is available.

## Security notes

- `settings.conf` holds your ntfy token. Keep it out of git (it is in `.gitignore`).
- With `UPDATE_APPS=true`, `update-apps.sh` is downloaded from the community-scripts GitHub repository on every run and executed as root on the host. The download is checked to be a shell script and runs under a timeout, but you are trusting that repository. Set `UPDATE_APPS=false` if you don't want that, or point `APP_UPDATE_URL` at a pinned commit or your own fork.
- Hooks run as root inside guests; the script refuses hooks that are not root-owned or are writable by others.

## Testing without a PVE host

`tests/mock/` contains a fake Proxmox environment (`pct`, `qm`, `pvesh`, `ssh`, `apt-get`, `docker`, `curl` are all shell fakes with failure injections: a failing apt upgrade, a full disk, a locked guest, a VM without agent, a Docker stack whose pull fails, …). It lets you exercise the whole control flow on any machine with bash, including Git Bash on Windows:

```bash
bash tests/mock/make-harness.sh      # generate the fakes
bash tests/mock/run-test.sh --list   # then --dry-run, or a full run
```

Nothing in it touches a real system.

## File structure

```
pve-autoupdater/
├── pve-updater.sh          Main script
├── settings.conf.example   Template (committed) — copy to settings.conf
├── settings.conf           Your settings (gitignored)
├── overrides.conf          Optional per-guest exceptions (tags are usually easier)
├── setup-ssh.sh            SSH key setup for VMs without guest agent
├── hooks/                  Custom pre/post scripts per guest
├── logs/                   Auto-created, auto-cleaned (gitignored)
└── tests/mock/             Fake Proxmox environment for testing the script
```
