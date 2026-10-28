#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run as root inside the LXC.' >&2; exit 1; }
GAME_PORT="${GAME_PORT:-8211}"
MAX_PLAYERS="${MAX_PLAYERS:-32}"
SERVER_NAME="${SERVER_NAME:-Palworld Community Server}"
GITHUB_REPO="${GITHUB_REPO:-}"
HELPER_VERSION="${HELPER_VERSION:-0.1.0}"

export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture i386
apt-get update
apt-get install -y ca-certificates curl wget tar xz-utils python3 whiptail lib32gcc-s1 lib32stdc++6 libcurl4:i386 libatomic1 libssl3

id palworld >/dev/null 2>&1 || useradd --system --create-home --home-dir /opt/palworld --shell /usr/sbin/nologin palworld
install -d -o palworld -g palworld /opt/palworld/server /opt/steamcmd /etc/palworld-manager /var/lib/palworld-manager /var/log/palworld

if [[ ! -x /opt/steamcmd/steamcmd.sh ]]; then
    curl -fL --retry 3 https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz -o /tmp/steamcmd_linux.tar.gz
    tar -xzf /tmp/steamcmd_linux.tar.gz -C /opt/steamcmd
    chown -R palworld:palworld /opt/steamcmd
fi

runuser -u palworld -- /opt/steamcmd/steamcmd.sh +force_install_dir /opt/palworld/server +login anonymous +app_update 2394010 validate +quit

mkdir -p /opt/palworld/server/Pal/Saved/Config/LinuxServer
CONFIG=/opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
if [[ ! -f "$CONFIG" ]]; then
    if [[ -f /opt/palworld/server/DefaultPalWorldSettings.ini ]]; then cp /opt/palworld/server/DefaultPalWorldSettings.ini "$CONFIG"; else printf '[/Script/Pal.PalGameWorldSettings]\nOptionSettings=()\n' > "$CONFIG"; fi
fi
chown -R palworld:palworld /opt/palworld

cat > /usr/local/bin/palworld-config <<'PY'
#!/usr/bin/env python3
import os, re, shlex, sys, tempfile

CONFIG = '/opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini'
ENVFILE = '/etc/palworld-manager/server.env'

def quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

def replace_key(text, key, value):
    match = re.search(r'(?m)^[ \t]*OptionSettings=\(', text)
    if not match: raise SystemExit('Active OptionSettings=( was not found in the config.')
    open_at = match.end() - 1
    depth, in_string, escaped, close_at = 0, False, False, None
    for i in range(open_at, len(text)):
        c = text[i]
        if in_string:
            if escaped: escaped = False
            elif c == '\\': escaped = True
            elif c == '"': in_string = False
            continue
        if c == '"': in_string = True
        elif c == '(': depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0: close_at = i; break
    if close_at is None: raise SystemExit('OptionSettings parentheses are unbalanced.')
    body = text[open_at + 1:close_at]
    pat = re.compile(r'(?<![A-Za-z0-9_])' + re.escape(key) + r'=(?:"(?:\\.|[^"\\])*"|\([^)]*(?:\([^)]*\)[^)]*)*\)|[^,)]*)')
    val = f'{key}={value}'
    if pat.search(body): body = pat.sub(lambda _: val, body, count=1)
    else: body = body + (',' if body and not body.endswith(',') else '') + val
    return text[:open_at + 1] + body + text[close_at:]

def atomic_write(path, content):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.palworld-')
    with os.fdopen(fd, 'w') as f: f.write(content)
    os.chmod(tmp, 0o640)
    if path == CONFIG and os.geteuid() == 0:
        import pwd, grp
        os.chown(tmp, pwd.getpwnam('palworld').pw_uid, grp.getgrnam('palworld').gr_gid)
    elif path == ENVFILE and os.geteuid() == 0:
        import pwd, grp
        os.chown(tmp, pwd.getpwnam('palworld').pw_uid, grp.getgrnam('palworld').gr_gid)
    os.replace(tmp, path)

def set_value(key, value):
    if key == 'ServerName':
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_. -]{0,63}', value): raise SystemExit('Server name may contain letters, numbers, spaces, dots, underscores, and hyphens (up to 64 characters).')
        q = quote(value)
        env = read_env(); env['SERVER_NAME'] = value; write_env(env)
    elif key in ('ServerPassword', 'AdminPassword', 'ServerDescription'):
        if key in ('ServerPassword', 'AdminPassword') and value and (len(value) > 30 or not re.fullmatch(r'[A-Za-z0-9_-]+', value)):
            raise SystemExit('Password must use only letters, numbers, underscores, and hyphens (up to 30 characters).')
        if key == 'ServerDescription' and len(value) > 128: raise SystemExit('Description must be at most 128 characters.')
        if key == 'ServerDescription' and any(ord(ch) < 32 for ch in value): raise SystemExit('Description cannot contain control characters.')
        q = quote(value)
    elif key == 'ServerPlayerMaxNum':
        if not value.isdigit() or not 1 <= int(value) <= 32: raise SystemExit('Player count must be 1–32.')
        q = value
        env = read_env(); env['MAX_PLAYERS'] = value; write_env(env)
    elif key == 'PublicIP':
        if not re.fullmatch(r'(?:[0-9]{1,3}\.){3}[0-9]{1,3}', value): raise SystemExit('Public IP must be an IPv4 address.')
        q = quote(value)
    elif key in ('PublicPort',):
        if not value.isdigit() or not 1 <= int(value) <= 65535: raise SystemExit('Port must be 1–65535.')
        q = value
        env = read_env(); env['GAME_PORT'] = value; write_env(env)
    elif key == 'CrossplayPlatforms':
        allowed = {'Steam','Xbox','PS5','Mac'}
        values = [v for v in value.split(',') if v]
        if not values or any(v not in allowed for v in values) or len(set(values)) != len(values): raise SystemExit('Use a comma-separated selection of Steam,Xbox,PS5,Mac.')
        q = '(' + ','.join(values) + ')'
    else: raise SystemExit('Unsupported setting.')
    with open(CONFIG, encoding='utf-8') as f: text = f.read()
    atomic_write(CONFIG, replace_key(text, key, q))

def read_env():
    data = {'GAME_PORT':'8211', 'MAX_PLAYERS':'32', 'SERVER_NAME':'Palworld Community Server'}
    try:
        with open(ENVFILE) as f:
            for line in f:
                if '=' in line:
                    k,v=line.rstrip('\n').split('=',1); parts=shlex.split(v); data[k]=parts[0] if parts else ''
    except FileNotFoundError: pass
    return data

def write_env(data):
    atomic_write(ENVFILE, ''.join(f'{k}={shlex.quote(v)}\n' for k,v in data.items()))

if __name__ == '__main__':
    if len(sys.argv) != 3: raise SystemExit('Usage: palworld-config SETTING VALUE|--stdin')
    value = sys.stdin.read().rstrip('\n') if sys.argv[2] == '--stdin' else sys.argv[2]
    set_value(sys.argv[1], value)
PY
chmod 0755 /usr/local/bin/palworld-config

cat > /etc/palworld-manager/server.env <<EOF
GAME_PORT=$GAME_PORT
MAX_PLAYERS=$MAX_PLAYERS
SERVER_NAME=$(printf '%q' "$SERVER_NAME")
EOF
chmod 0640 /etc/palworld-manager/server.env
if [[ -n "$GITHUB_REPO" ]]; then printf '%s\n' "$GITHUB_REPO" > /etc/palworld-manager/github-repo; fi
printf '%s\n' "$HELPER_VERSION" > /etc/palworld-manager/version

cat > /usr/local/bin/palworld-public-ip-sync <<'IPSH'
#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG=/opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
STATE=/var/lib/palworld-manager/public-ip
NEW_IP="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
[[ "$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo 'Public IPv4 lookup failed; leaving current config unchanged.'; exit 0; }
OLD_IP="$(cat "$STATE" 2>/dev/null || true)"
if [[ "$NEW_IP" == "$OLD_IP" ]]; then exit 0; fi
/usr/local/bin/palworld-config PublicIP "$NEW_IP"
printf '%s\n' "$NEW_IP" > "$STATE"
echo "Public IP changed: ${OLD_IP:-not recorded} -> $NEW_IP"
if [[ "${1:-}" != --no-restart ]] && systemctl is-active --quiet palworld.service; then systemctl restart palworld.service; fi
IPSH
chmod 0755 /usr/local/bin/palworld-public-ip-sync

cat > /usr/local/bin/palworld-start <<'START'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/palworld-manager/server.env
/usr/local/bin/palworld-public-ip-sync --no-restart || true
cd /opt/palworld/server
exec ./Pal/Binaries/Linux/PalServer-Linux-Shipping Pal -publiclobby -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS -port="$GAME_PORT" -publicport="$GAME_PORT" -servername="$SERVER_NAME" -players="$MAX_PLAYERS"
START
chmod 0755 /usr/local/bin/palworld-start

cat > /etc/systemd/system/palworld.service <<'UNIT'
[Unit]
Description=Palworld Dedicated Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=palworld
Group=palworld
WorkingDirectory=/opt/palworld/server
ExecStartPre=-/usr/sbin/runuser -u palworld -- /opt/steamcmd/steamcmd.sh +force_install_dir /opt/palworld/server +login anonymous +app_update 2394010 +quit
ExecStart=/usr/local/bin/palworld-start
KillSignal=SIGINT
TimeoutStopSec=90
Restart=on-failure
RestartSec=15
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
UNIT

cat > /usr/local/bin/palworld-update <<'UPD'
#!/usr/bin/env bash
set -Eeuo pipefail
was_active=0
systemctl is-active --quiet palworld.service && was_active=1 || true
systemctl stop palworld.service
if runuser -u palworld -- /opt/steamcmd/steamcmd.sh +force_install_dir /opt/palworld/server +login anonymous +app_update 2394010 validate +quit; then
    systemctl start palworld.service
else
    if [[ "$was_active" == 1 ]]; then systemctl start palworld.service || true; fi
    exit 1
fi
UPD
chmod 0755 /usr/local/bin/palworld-update

cat > /etc/systemd/system/palworld-update.service <<'UNIT'
[Unit]
Description=Update Palworld dedicated server via SteamCMD

[Service]
Type=oneshot
ExecStart=/usr/local/bin/palworld-update
UNIT
cat > /etc/systemd/system/palworld-update.timer <<'UNIT'
[Unit]
Description=Daily Palworld update check

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
UNIT

cat > /etc/systemd/system/palworld-public-ip.service <<'UNIT'
[Unit]
Description=Check public IP and refresh Palworld advertisement

[Service]
Type=oneshot
ExecStart=/usr/local/bin/palworld-public-ip-sync
UNIT
cat > /etc/systemd/system/palworld-public-ip.timer <<'UNIT'
[Unit]
Description=Check Palworld public IPv4 for changes

[Timer]
OnBootSec=90s
OnUnitActiveSec=5min
AccuracySec=30s
Unit=palworld-public-ip.service

[Install]
WantedBy=timers.target
UNIT

[[ -f /root/palworld-manager.sh ]] || { echo "Missing manager UI source file." >&2; exit 1; }
install -o root -g root -m 0755 /root/palworld-manager.sh /usr/local/bin/palworld-manager

cat > /usr/local/bin/palworld-console <<'CONSOLE'
#!/usr/bin/env bash
exec /usr/local/bin/palworld-manager "$@"
CONSOLE
chmod 0755 /usr/local/bin/palworld-console

chown -R palworld:palworld /opt/palworld /var/log/palworld /var/lib/palworld-manager
chown palworld:palworld /etc/palworld-manager/server.env
chmod 0640 /etc/palworld-manager/server.env
if [[ -n "$GITHUB_REPO" ]]; then printf '%s\n' "$GITHUB_REPO" > /etc/palworld-manager/github-repo; fi
/usr/local/bin/palworld-config ServerName "$SERVER_NAME"
/usr/local/bin/palworld-config ServerPlayerMaxNum "$MAX_PLAYERS"
/usr/local/bin/palworld-config PublicPort "$GAME_PORT"
/usr/local/bin/palworld-config CrossplayPlatforms Steam,Xbox,PS5,Mac
systemctl daemon-reload
systemctl enable --now palworld.service palworld-public-ip.timer palworld-update.timer
echo "Palworld LXC install complete. Open the manager with: palworld-manager"
