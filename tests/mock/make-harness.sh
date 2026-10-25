#!/usr/bin/env bash
# Generates a mock Proxmox environment to exercise pve-updater.sh on a non-PVE machine.
set -e
cd "$(dirname "$0")"
M="$PWD"
mkdir -p bin guest-deb guest-deb-docker guest-alpine guest-none state

cat > state/inventory.json <<'EOF'
[
 {"vmid":101,"type":"lxc","name":"audiomuse-ai","status":"running","node":"NODE","tags":"community-script"},
 {"vmid":102,"type":"lxc","name":"radio","status":"running","node":"NODE","tags":"community-script"},
 {"vmid":103,"type":"lxc","name":"adguard","status":"running","node":"NODE","tags":"community-script"},
 {"vmid":104,"type":"lxc","name":"isponsorblocktv","status":"running","node":"NODE","tags":"community-script"},
 {"vmid":105,"type":"lxc","name":"navidrome","status":"running","node":"NODE","tags":"community-script"},
 {"vmid":106,"type":"lxc","name":"stirling-pdf","status":"running","node":"NODE","tags":"community-script"},
 {"vmid":107,"type":"lxc","name":"proxmox-backup-server","status":"stopped","node":"NODE","tags":""},
 {"vmid":108,"type":"lxc","name":"sonarqube","status":"running","node":"NODE","tags":"no-update"},
 {"vmid":109,"type":"lxc","name":"pairdrop","status":"running","node":"NODE","tags":"community-script"},
 {"vmid":110,"type":"lxc","name":"ntfy","status":"running","node":"NODE","tags":"community-script;no-docker"},
 {"vmid":111,"type":"lxc","name":"pocketid","status":"running","node":"NODE","tags":""},
 {"vmid":112,"type":"lxc","name":"debian","status":"running","node":"NODE","tags":""},
 {"vmid":114,"type":"lxc","name":"ollama","status":"running","node":"NODE","tags":""},
 {"vmid":115,"type":"lxc","name":"jellyfin","status":"running","node":"NODE","tags":"community-script"},
 {"vmid":116,"type":"lxc","name":"dockge","status":"stopped","node":"NODE","tags":""},
 {"vmid":117,"type":"lxc","name":"paperless","status":"running","node":"NODE","tags":""},
 {"vmid":118,"type":"lxc","name":"karakeep-app","status":"running","node":"NODE","tags":"community-script","lock":"backup"},
 {"vmid":119,"type":"lxc","name":"n8n","status":"running","node":"NODE","tags":""},
 {"vmid":120,"type":"lxc","name":"databasus","status":"running","node":"NODE","tags":""},
 {"vmid":121,"type":"lxc","name":"audiobookshelf","status":"running","node":"NODE","tags":""},
 {"vmid":125,"type":"lxc","name":"apache-guacamole","status":"stopped","node":"NODE","tags":""},
 {"vmid":126,"type":"lxc","name":"python-ct","status":"running","node":"NODE","tags":""},
 {"vmid":127,"type":"lxc","name":"komodo-docker","status":"running","node":"NODE","tags":""},
 {"vmid":9000,"type":"lxc","name":"debian-template","status":"stopped","node":"NODE","tags":"","template":1},
 {"vmid":100,"type":"qemu","name":"VM 100","status":"stopped","node":"NODE","tags":""},
 {"vmid":113,"type":"qemu","name":"haos","status":"running","node":"NODE","tags":""},
 {"vmid":123,"type":"qemu","name":"webserver-deb","status":"running","node":"NODE","tags":""},
 {"vmid":124,"type":"qemu","name":"unifios","status":"running","node":"NODE","tags":""},
 {"vmid":130,"type":"qemu","name":"win11","status":"running","node":"NODE","tags":""},
 {"vmid":131,"type":"qemu","name":"noagent","status":"running","node":"NODE","tags":""},
 {"vmid":200,"type":"lxc","name":"other-node-ct","status":"running","node":"othernode","tags":""}
]
EOF

cat > state/profiles <<'EOF'
101 deb
102 deb
103 deb
104 deb
105 deb
106 deb
109 deb
110 deb-docker
111 deb
112 deb-docker
114 deb
115 deb
117 deb-docker
118 deb
119 deb
120 none
121 deb
126 alpine
127 deb-docker
123 deb
124 deb
131 deb
EOF
echo "104" > state/fail-apt
echo "105" > state/fail-snap
echo "109" > state/lowdisk
echo "112" > state/fail-update
: > state/calls.log
: > state/ntfy.log
rm -f state/snaps-* state/pvesh.count state/status-*

# ---------------- host-side mocks ----------------
cat > bin/flock <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > bin/stat <<'EOF'
#!/usr/bin/env bash
case "$2" in
  '%u') echo 0 ;;
  '%a') echo 700 ;;
  *) exec /usr/bin/stat "$@" ;;
esac
EOF

cat > bin/pvesh <<'EOF'
#!/usr/bin/env bash
M="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${MOCK_PVESH_FAIL:-}" ] && { echo "pvesh: connection refused" >&2; exit 2; }
echo "pvesh $*" >> "$M/state/calls.log"
n=$(cat "$M/state/pvesh.count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$M/state/pvesh.count"
json=$(sed "s/\"NODE\"/\"$(hostname)\"/g" "$M/state/inventory.json")
if [ "$n" -ge 2 ]; then json=$(printf '%s' "$json" | sed 's/,"lock":"backup"//'); fi
printf '%s\n' "$json"
EOF

cat > bin/guest-run <<'EOF'
#!/usr/bin/env bash
M="$(cd "$(dirname "$0")/.." && pwd)"
id="$1"; shift
prof=$(awk -v id="$id" '$1==id{print $2}' "$M/state/profiles"); prof="${prof:-none}"
export MOCK_CT="$id" MOCK_ROOT="$M"
export PATH="$M/guest-$prof:/usr/bin:/bin"
exec "$@"
EOF

cat > bin/pct <<'EOF'
#!/usr/bin/env bash
M="$(cd "$(dirname "$0")/.." && pwd)"
echo "pct $*" >> "$M/state/calls.log"
cmd="$1"; id="$2"; shift 2
inv() { perl -MJSON::PP -e 'local $/; my $d=decode_json(<STDIN>); for (@$d){ if ($_->{vmid}==$ARGV[0]) { print $_->{$ARGV[1]}//"", "\n"; exit } }' "$id" "$1" < "$M/state/inventory.json"; }
case "$cmd" in
  status)
    st=$(cat "$M/state/status-$id" 2>/dev/null || inv status); echo "status: $st" ;;
  config)
    echo "ostype: debian"; echo "tags: $(inv tags)" ;;
  exec)
    [ "$1" = "--" ] && shift
    exec "$M/bin/guest-run" "$id" "$@" ;;
  snapshot)
    name="$1"
    if grep -qx "$id" "$M/state/fail-snap" 2>/dev/null; then echo "snapshot feature is not available"; exit 1; fi
    echo "$name" >> "$M/state/snaps-$id"; exit 0 ;;
  listsnapshot)
    if [ -f "$M/state/snaps-$id" ]; then while read -r s; do echo "\`-> $s  2026-10-25 03:00:00  pve-updater pre-update snapshot"; done < "$M/state/snaps-$id"; fi
    echo "    \`-> current  You are here!" ;;
  delsnapshot)
    grep -vx "$1" "$M/state/snaps-$id" > "$M/state/snaps-$id.tmp" || true; mv "$M/state/snaps-$id.tmp" "$M/state/snaps-$id"; exit 0 ;;
  reboot|start)
    rm -f "$M/state/status-$id"; exit 0 ;;
  *) echo "mock pct: unhandled $cmd" >&2; exit 2 ;;
esac
EOF

cat > bin/qm <<'EOF'
#!/usr/bin/env bash
M="$(cd "$(dirname "$0")/.." && pwd)"
echo "qm $*" >> "$M/state/calls.log"
cmd="$1"; shift
inv() { perl -MJSON::PP -e 'local $/; my $d=decode_json(<STDIN>); for (@$d){ if ($_->{vmid}==$ARGV[0]) { print $_->{$ARGV[1]}//"", "\n"; exit } }' "$1" "$2" < "$M/state/inventory.json"; }
case "$cmd" in
  status) id="$1"; echo "status: $(inv "$id" status)" ;;
  guest)
    sub="$1"; id="$2"; shift 2
    case "$id" in 131) echo "QEMU guest agent is not running" >&2; exit 2 ;; esac
    case "$sub" in
      cmd)
        case "$1" in
          ping) exit 0 ;;
          get-osinfo)
            case "$id" in
              113) echo '{"id":"haos","name":"Home Assistant OS","version-id":"13.1"}' ;;
              130) echo '{"id":"mswindows","name":"Microsoft Windows"}' ;;
              *)   echo '{"id":"debian","name":"Debian GNU/Linux","version-id":"12"}' ;;
            esac ;;
          network-get-interfaces)
            echo "[{\"name\":\"lo\",\"ip-addresses\":[{\"ip-address\":\"127.0.0.1\",\"ip-address-type\":\"ipv4\"}]},{\"name\":\"docker0\",\"ip-addresses\":[{\"ip-address\":\"172.17.0.1\",\"ip-address-type\":\"ipv4\"}]},{\"name\":\"ens18\",\"ip-addresses\":[{\"ip-address\":\"fe80::1\",\"ip-address-type\":\"ipv6\"},{\"ip-address\":\"192.168.1.$id\",\"ip-address-type\":\"ipv4\"}]}]" ;;
        esac ;;
      exec)
        while [ $# -gt 0 ]; do case "$1" in --timeout) shift 2 ;; --) shift; break ;; *) shift ;; esac; done
        case "$id" in 124|113) echo "QEMU guest agent command 'guest-exec' has been disabled" >&2; exit 255 ;; esac
        out=$("$M/bin/guest-run" "$id" "$@" 2>&1); rc=$?
        OUT="$out" perl -MJSON::PP -e 'print encode_json({"exitcode"=>int($ARGV[0]),"exited"=>1,"out-data"=>$ENV{OUT}."\n"}),"\n"' "$rc" ;;
    esac ;;
  snapshot) id="$1"; echo "$2" >> "$M/state/snaps-$id"; exit 0 ;;
  listsnapshot)
    id="$1"; if [ -f "$M/state/snaps-$id" ]; then while read -r s; do echo "\`-> $s  2026-10-25 03:00:00  pve-updater"; done < "$M/state/snaps-$id"; fi; echo "    \`-> current  You are here!" ;;
  delsnapshot) id="$1"; grep -vx "$2" "$M/state/snaps-$id" > "$M/state/snaps-$id.tmp" || true; mv "$M/state/snaps-$id.tmp" "$M/state/snaps-$id"; exit 0 ;;
  reboot|start) exit 0 ;;
  *) echo "mock qm: unhandled $cmd" >&2; exit 2 ;;
esac
EOF

cat > bin/ssh <<'EOF'
#!/usr/bin/env bash
M="$(cd "$(dirname "$0")/.." && pwd)"
echo "ssh $*" >> "$M/state/calls.log"
target=""; while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; *@*) target="$1"; shift; break ;; *) shift ;; esac; done
ip="${target#*@}"; id="${ip##*.}"
case "$ip" in
  192.168.1.124) echo "root@$ip: Permission denied (publickey)." >&2; exit 255 ;;
  192.168.1.99)  echo "ssh: connect to host $ip port 22: Connection timed out" >&2; exit 255 ;;
esac
case "$1" in echo|"echo ok") echo ok; exit 0 ;; esac
exec "$M/bin/guest-run" "$id" "$@"
EOF

cat > bin/curl <<'EOF'
#!/usr/bin/env bash
M="$(cd "$(dirname "$0")/.." && pwd)"
echo "curl $*" >> "$M/state/calls.log"
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data-binary) printf '%s\n' "--- NTFY BODY ---" "$2" "--- END ---" >> "$M/state/ntfy.log"; shift 2 ;;
    -H) echo "H: $2" >> "$M/state/ntfy.log"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$out" ]; then
  cp "$M/fake-update-apps.sh" "$out"
fi
exit 0
EOF

cat > fake-update-apps.sh <<'EOF'
#!/usr/bin/env bash
echo "mock update-apps.sh: containers=$var_container backup=$var_backup unattended=$var_unattended continue=$var_continue_on_error reboot=$var_auto_reboot"
echo "[INFO] Updating container 115"
echo "[ERROR] in line 120: exit code 1: while executing command npm install"
echo "Update failed for container 115 (exit code: 1)"
echo "[INFO] Updating container 117"
echo "[WARN] Before continuing make sure that you do not use encryption or have decrypted all documents."
echo "[ERROR] in line 66: exit code 1 (The command failed; its output says why): while executing command read -rp 'Do you want to continue with the update? (y/N): ' MIGRATE"
echo "Update failed for container 117 (exit code: 1)"
echo "  CTID      Service                 Status      Details"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  %-8s  %-22s  %-10s  %s\n" 101 audiomuse-ai OK "Updated successfully"
printf "  %-8s  %-22s  %-10s  %s\n" 102 radio OK "Updated successfully"
printf "  %-8s  %-22s  %-10s  %s\n" 102 "(unknown)" ERROR "Invalid or missing service name in /usr/bin/update"
printf "  %-8s  %-22s  %-10s  %s\n" 103 adguard SKIPPED "Storage critically low on /boot (>80%)"
printf "  %-8s  %-22s  %-10s  %s\n" 115 jellyfin FAILED "Exit code 1"
printf "  %-8s  %-22s  %-10s  %s\n" 117 paperless FAILED "Exit code 1"
printf "  %-8s  %-22s  %-10s  %s\n" 119 n8n SKIPPED "no update script"
exit 0
EOF

cat > bin/apt-get <<'EOF'
#!/usr/bin/env bash
M="${MOCK_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
id="${MOCK_CT:-host}"
echo "[$id] apt-get $*" >> "$M/state/calls.log"
sim=0; action=""
for a in "$@"; do case "$a" in -s) sim=1 ;; update|upgrade|dist-upgrade|autoremove) action="$a" ;; esac; done
case "$action" in
  update)
    if grep -qx "$id" "$M/state/fail-update" 2>/dev/null; then echo "Err:1 http://repo bookworm InRelease  401 Unauthorized"; echo "E: Some index files failed to download."; exit 100; fi
    echo "Hit:1 http://deb.debian.org/debian bookworm InRelease"; exit 0 ;;
  upgrade|dist-upgrade)
    n=3; [ "$id" = 103 ] && n=0; [ "$id" = host ] && n=5
    core=0; [ "$id" = 103 ] || [ "$id" = host ] || core=1
    if [ "$sim" = 1 ]; then
      for i in $(seq 1 $n); do echo "Inst pkg$i [1.0] (1.1 Debian:12/stable [amd64])"; done
      [ "$core" = 1 ] && echo "Inst libc6 [2.36-9] (2.36-9+deb12u10 Debian:12/stable [amd64])"
      [ "$id" = host ] && [ -n "${MOCK_HOST_REMOVE:-}" ] && echo "Remv proxmox-ve [8.2.0]"
      exit 0
    fi
    if grep -qx "$id" "$M/state/fail-apt" 2>/dev/null; then echo "E: Unable to correct problems, you have held broken packages."; exit 100; fi
    n=$((n+core))
    echo "Reading package lists..."; echo "Setting up pkg1 (1.1) ..."
    echo "$n upgraded, 1 newly installed, 0 to remove and 0 not upgraded."; exit 0 ;;
  autoremove) echo "0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded."; exit 0 ;;
  *) exit 0 ;;
esac
EOF

cat > bin/dpkg <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > bin/apk <<'EOF'
#!/usr/bin/env bash
case "$1" in
  update) echo "OK: 12 distinct packages available"; exit 0 ;;
  upgrade) echo "(1/2) Upgrading musl (1.2.4-r1 -> 1.2.4-r2)"; echo "(2/2) Upgrading busybox (1.36.1-r1 -> 1.36.1-r2)"; echo "OK: 8 MiB in 20 packages"; exit 0 ;;
esac
EOF

cat > bin/df <<'EOF'
#!/usr/bin/env bash
M="${MOCK_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
free=20000
grep -qx "${MOCK_CT:-x}" "$M/state/lowdisk" 2>/dev/null && free=120
echo "Filesystem 1M-blocks Used Available Use% Mounted on"
echo "/dev/root 40000 20000 $free 50% /"
EOF

cat > bin/docker <<'EOF'
#!/usr/bin/env bash
M="${MOCK_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
id="${MOCK_CT:-host}"
echo "[$id] docker $*" >> "$M/state/calls.log"
S="$M/state/stacks/$id"
# stacks per container: "<project> <comma-separated services with a NEW image, or ->"
stacks() { case "$id" in
  110) echo "ntfy -" ;;
  112) echo "mystack web" ;;
  117) echo "paperless webserver" ;;
  127) echo "komodo -"; echo "immich server,ml"; echo "gone -" ;;
esac; }
case "$1" in
  info) exit 0 ;;
  compose)
    shift
    if [ "$1" = version ]; then echo "Docker Compose version v2.29.1"; exit 0; fi
    proj=""; act=""
    while [ $# -gt 0 ]; do case "$1" in -p) proj="$2"; shift 2 ;; -f|--project-directory) shift 2 ;; pull|up) act="$1"; shift; break ;; *) shift ;; esac; done
    case "$act" in
      pull) if [ "$proj" = komodo ]; then echo "Error response from daemon: pull access denied for ghcr.io/x"; exit 1; fi; exit 0 ;;
      up) echo "Container ${proj}-$* Recreated"; exit 0 ;;
    esac ;;
  ps)
    args="$*"
    if printf '%s' "$args" | grep -q -- '-q --filter'; then
      proj=$(printf '%s' "$args" | sed 's/.*project=//')
      stacks | awk -v p="$proj" '$1==p{ if ($2!="-") {n=split($2,a,","); for(i=1;i<=n;i++) print p"_"a[i]}; print p"_db"}'
    elif printf '%s' "$args" | grep -q 'Status'; then
      proj=$(printf '%s' "$args" | sed 's/.*project=\([^ ]*\).*/\1/')
      echo "${proj}-db-1 Up 3 days"
      if [ "$proj" = paperless ]; then echo "paperless-webserver-1 Restarting (1) 2 seconds ago"; else echo "${proj}-web-1 Up 5 seconds"; fi
    elif printf '%s' "$args" | grep -q 'working_dir'; then
      stacks | awk -v s="$S" '{print $1"|"s"/"$1"|"s"/"$1"/compose.yml"}'
      echo "||"
    else
      stacks | awk '{print $1}'; echo ""
    fi ;;
  inspect)
    tmpl="$3"; cid="$4"; p="${cid%%_*}"; svc="${cid#*_}"
    case "$tmpl" in
      '{{.Image}}') echo "sha256:old-$cid" ;;
      '{{.Config.Image}}') echo "img/$p/$svc:latest" ;;
      *service*) echo "$svc" ;;
    esac ;;
  image)
    case "$2" in
      inspect) ref="$5"; p=$(echo "$ref" | cut -d/ -f2); svc=$(echo "$ref" | cut -d/ -f3 | cut -d: -f1)
        if stacks | awk -v p="$p" '$1==p{print $2}' | tr ',' '\n' | grep -qx "$svc"; then echo "sha256:new-${p}_$svc"; else echo "sha256:old-${p}_$svc"; fi ;;
      prune) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF

for id in 110 112 117 127; do
  for s in ntfy mystack paperless komodo immich; do
    mkdir -p "state/stacks/$id/$s"; echo "services: {}" > "state/stacks/$id/$s/compose.yml"
  done
done
cp bin/apt-get bin/dpkg bin/df guest-deb/
cp bin/apt-get bin/dpkg bin/df bin/docker guest-deb-docker/
cp bin/apk bin/df guest-alpine/
cp bin/df guest-none/
chmod +x bin/* guest-*/* fake-update-apps.sh

cat > settings.conf <<'EOF'
NTFY_URL="http://192.168.1.169"
NTFY_TOPIC="alerts"
NTFY_TOKEN="tk_test"
APT_TIMEOUT=60
DOCKER_TIMEOUT=60
UPDATE_PVE_HOST=true
LOG_RETENTION_DAYS=30
UPDATE_APPS=true
MAX_RUNTIME=600
EOF


cat > overrides.conf <<'EOO'
131|ip=192.168.1.131
124|skip
112|no-snapshot
EOO
echo "harness ready in $M  (next: bash run-test.sh --list)"

# setsid is not available in Git Bash: drop -w and run the command directly
cat > bin/setsid <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-w" ] && shift
exec "$@"
EOF
chmod +x bin/setsid
