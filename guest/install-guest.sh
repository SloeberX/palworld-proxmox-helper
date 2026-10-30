#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run as root inside the LXC.' >&2; exit 1; }
GAME_PORT="${GAME_PORT:-8211}"
MAX_PLAYERS="${MAX_PLAYERS:-32}"
SERVER_NAME="${SERVER_NAME:-Palworld Community Server}"
GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
HELPER_VERSION="${HELPER_VERSION:-0.1.0}"
HELPER_UPDATE_ONLY="${HELPER_UPDATE_ONLY:-0}"

if [[ "$HELPER_UPDATE_ONLY" != 1 ]]; then
    export DEBIAN_FRONTEND=noninteractive
    dpkg --add-architecture i386
    apt-get update
    apt-get install -y ca-certificates curl wget tar xz-utils python3 whiptail lib32gcc-s1 lib32stdc++6 libcurl4t64:i386 libatomic1 libssl3t64 python3-flask python3-werkzeug gunicorn sudo openssl
else
    [[ -x /opt/steamcmd/steamcmd.sh && -x /opt/palworld/server/Pal/Binaries/Linux/PalServer-Linux-Shipping ]] || { echo 'Existing Palworld installation not found.' >&2; exit 1; }
    [[ -f /opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini ]] || { echo 'Existing Palworld settings file not found.' >&2; exit 1; }
fi

if [[ "$HELPER_UPDATE_ONLY" != 1 ]]; then
    id palworld >/dev/null 2>&1 || useradd --system --create-home --home-dir /opt/palworld --shell /usr/sbin/nologin palworld
    id palworld-web >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/palworld-web --shell /usr/sbin/nologin --groups palworld palworld-web
else
    id palworld >/dev/null 2>&1 || { echo 'Palworld service user does not exist.' >&2; exit 1; }
    id palworld-web >/dev/null 2>&1 || { echo 'Web service user does not exist.' >&2; exit 1; }
fi
install -d -o palworld -g palworld /opt/palworld/server /opt/steamcmd /etc/palworld-manager /var/lib/palworld-manager /var/log/palworld
install -d -o root -g root -m 0755 /usr/local/lib/palworld-web
install -d -o root -g palworld-web -m 0750 /etc/palworld-web /var/lib/palworld-web
install -d -o palworld-web -g palworld-web -m 0700 /var/lib/palworld-web/imports
install -d -o root -g palworld-web -m 0750 /opt/palworld/backups

mkdir -p /etc/systemd/system/console-getty.service.d /etc/systemd/system/getty@.service.d /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/console-getty.service.d/override.conf <<'CONSOLE_GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear console $TERM
CONSOLE_GETTY
cat > /etc/systemd/system/getty@.service.d/20-palworld-autologin.conf <<'TTY_GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
TTY_GETTY
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'TTY1_GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear tty1 $TERM
TTY1_GETTY
systemctl daemon-reload
systemctl enable getty@tty1.service >/dev/null 2>&1 || true
cat > /etc/profile.d/palworld-server-banner.sh <<'BANNER'
if [ "$(id -u)" -eq 0 ] && [ -t 1 ] && [ "${PALWORLD_BANNER_SHOWN:-0}" != 1 ]; then
    _pw_ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n1 || true)"
    _pw_port="$(awk -F= '$1=="GAME_PORT"{print $2}' /etc/palworld-manager/server.env 2>/dev/null)"
    _pw_name="$(hostname)"
    _pw_os="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Debian GNU/Linux}")"
    printf '\n\033[1;36mPalworld Server LXC\033[0m\n'
    printf '\033[1;33m  Provided by:  SloeberX | GitHub: https://github.com/SloeberX/palworld-proxmox-helper\033[0m\n'
    printf '\033[1;32m  OS:           %s\033[0m\n' "$_pw_os"
    printf '\033[1;32m  Hostname:     %s\033[0m\n' "$_pw_name"
    printf '\033[1;32m  Local IP:     %s\033[0m\n' "${_pw_ip:-unavailable}"
    printf '\033[1;32m  Game server:  %s:%s/udp\033[0m\n' "${_pw_ip:-unavailable}" "${_pw_port:-8211}"
    printf '\033[1;32m  Web manager:  https://%s:8443\033[0m\n\n' "${_pw_ip:-unavailable}"
    export PALWORLD_BANNER_SHOWN=1
    unset _pw_ip _pw_port _pw_name _pw_os
fi
BANNER
chmod 0644 /etc/profile.d/palworld-server-banner.sh
if ! grep -Fq '# Palworld LXC login banner' /etc/bash.bashrc; then
    cat >> /etc/bash.bashrc <<'BASHRC'

# Palworld LXC login banner
if [ -n "${PS1:-}" ] && [ -r /etc/profile.d/palworld-server-banner.sh ]; then
    . /etc/profile.d/palworld-server-banner.sh
fi
BASHRC
fi
systemctl restart getty@tty1.service >/dev/null 2>&1 || true

if [[ "$HELPER_UPDATE_ONLY" != 1 && ! -x /opt/steamcmd/steamcmd.sh ]]; then
    curl -fL --retry 3 https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz -o /tmp/steamcmd_linux.tar.gz
    tar -xzf /tmp/steamcmd_linux.tar.gz -C /opt/steamcmd
    chown -R palworld:palworld /opt/steamcmd
fi

if [[ "$HELPER_UPDATE_ONLY" != 1 ]]; then
    runuser -u palworld -- /opt/steamcmd/steamcmd.sh +force_install_dir /opt/palworld/server +login anonymous +app_update 2394010 validate +quit
fi

mkdir -p /opt/palworld/server/Pal/Saved/Config/LinuxServer
CONFIG=/opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
if [[ ! -f "$CONFIG" ]]; then
    [[ "$HELPER_UPDATE_ONLY" != 1 ]] || { echo 'Refusing to create/reset config during a helper-only update.' >&2; exit 1; }
    if [[ -f /opt/palworld/server/DefaultPalWorldSettings.ini ]]; then cp /opt/palworld/server/DefaultPalWorldSettings.ini "$CONFIG"; else printf '[/Script/Pal.PalGameWorldSettings]\nOptionSettings=()\n' > "$CONFIG"; fi
fi
if [[ "$HELPER_UPDATE_ONLY" != 1 ]]; then chown -R palworld:palworld /opt/palworld; fi

ensure_settings_access() {
    local dir
    for dir in /opt/palworld /opt/palworld/server /opt/palworld/server/Pal \
        /opt/palworld/server/Pal/Saved /opt/palworld/server/Pal/Saved/Config \
        /opt/palworld/server/Pal/Saved/Config/LinuxServer; do
        [[ ! -d "$dir" ]] || { chgrp palworld "$dir"; chmod g+rx "$dir"; }
    done
    if [[ -f "$CONFIG" ]]; then chown palworld:palworld "$CONFIG"; chmod 0640 "$CONFIG"; fi
}
ensure_settings_access

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
printf '%s\n' "$GITHUB_BRANCH" > /etc/palworld-manager/github-branch
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
ExecStartPre=-/opt/steamcmd/steamcmd.sh +force_install_dir /opt/palworld/server +login anonymous +app_update 2394010 +quit
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
if [[ -x /usr/local/bin/palworld-helper-update ]]; then
    if ! /usr/local/bin/palworld-helper-update; then echo 'Warning: helper update failed; continuing with the game update.' >&2; fi
fi
was_active=0
systemctl is-active --quiet palworld.service && was_active=1 || true
systemctl stop palworld.service
if ! /usr/local/sbin/palworld-webctl backup; then echo 'Warning: pre-update backup failed; proceeding with SteamCMD update.' >&2; fi
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

[[ -f /root/palworld-web.py && -f /root/palworld-webctl.sh && -f /root/palworld-helper-update.sh ]] || { echo 'Missing one or more web/helper source files.' >&2; exit 1; }
install -o root -g root -m 0644 /root/palworld-web.py /usr/local/lib/palworld-web/palworld_web.py
install -o root -g root -m 0755 /root/palworld-webctl.sh /usr/local/sbin/palworld-webctl
install -o root -g root -m 0755 /root/palworld-helper-update.sh /usr/local/bin/palworld-helper-update

cat > /etc/sudoers.d/palworld-web <<'SUDO'
palworld-web ALL=(root) NOPASSWD: /usr/local/sbin/palworld-webctl *
SUDO
chmod 0440 /etc/sudoers.d/palworld-web
visudo -cf /etc/sudoers.d/palworld-web

if [[ ! -s /etc/palworld-web/bind-ip ]]; then
    WEB_BIND_IP="$(hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n1)"
    [[ -n "$WEB_BIND_IP" ]] || { echo 'Could not detect the LXC LAN IPv4 for the web panel.' >&2; exit 1; }
    printf '%s\n' "$WEB_BIND_IP" > /etc/palworld-web/bind-ip
fi
if [[ ! -s /etc/palworld-web/session.key ]]; then openssl rand -hex 32 > /etc/palworld-web/session.key; fi
chown root:palworld-web /etc/palworld-web/bind-ip /etc/palworld-web/session.key
chmod 0640 /etc/palworld-web/bind-ip /etc/palworld-web/session.key

cat > /usr/local/sbin/palworld-web-cert-refresh <<'CERT'
#!/usr/bin/env bash
set -Eeuo pipefail
ip="$(hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n1)"
[[ -n "$ip" ]] || { echo 'No LXC LAN IPv4 is available for the web panel.' >&2; exit 1; }
old="$(cat /etc/palworld-web/bind-ip 2>/dev/null || true)"
cert_valid=0
if [[ -s /etc/palworld-web/server.crt ]] && openssl x509 -in /etc/palworld-web/server.crt -checkend 2592000 -noout >/dev/null 2>&1; then cert_valid=1; fi
if [[ "$ip" != "$old" || "$cert_valid" != 1 || ! -s /etc/palworld-web/server.key ]]; then
    printf '%s\n' "$ip" > /etc/palworld-web/bind-ip
    openssl req -x509 -nodes -newkey rsa:3072 -days 825 \
        -keyout /etc/palworld-web/server.key -out /etc/palworld-web/server.crt \
        -subj "/CN=$ip" -addext "subjectAltName=IP:$ip"
    chown root:palworld-web /etc/palworld-web/server.key /etc/palworld-web/server.crt /etc/palworld-web/bind-ip
    chmod 0640 /etc/palworld-web/server.key /etc/palworld-web/bind-ip
    chmod 0644 /etc/palworld-web/server.crt
fi
CERT
chmod 0755 /usr/local/sbin/palworld-web-cert-refresh
/usr/local/sbin/palworld-web-cert-refresh

cat > /usr/local/bin/palworld-web-start <<'WEBSTART'
#!/usr/bin/env bash
set -Eeuo pipefail
bind_ip="$(cat /etc/palworld-web/bind-ip)"
exec /usr/bin/gunicorn --workers 1 --timeout 240 --bind "$bind_ip:8443" \
    --certfile /etc/palworld-web/server.crt --keyfile /etc/palworld-web/server.key palworld_web:app
WEBSTART
chmod 0755 /usr/local/bin/palworld-web-start

cat > /etc/systemd/system/palworld-web.service <<'UNIT'
[Unit]
Description=Palworld LAN Web Management Panel
After=network-online.target palworld.service
Wants=network-online.target

[Service]
Type=simple
User=palworld-web
Group=palworld-web
SupplementaryGroups=palworld
WorkingDirectory=/usr/local/lib/palworld-web
Environment=PYTHONUNBUFFERED=1
ExecStartPre=+/usr/local/sbin/palworld-web-cert-refresh
ExecStart=/usr/local/bin/palworld-web-start
Restart=on-failure
RestartSec=5
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/palworld-helper-update.service <<'UNIT'
[Unit]
Description=Refresh Palworld helper scripts from GitHub

[Service]
Type=oneshot
ExecStart=/usr/local/bin/palworld-helper-update
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
printf '%s\n' "$GITHUB_BRANCH" > /etc/palworld-manager/github-branch
/usr/local/bin/palworld-config ServerName "$SERVER_NAME"
/usr/local/bin/palworld-config ServerPlayerMaxNum "$MAX_PLAYERS"
/usr/local/bin/palworld-config PublicPort "$GAME_PORT"
/usr/local/bin/palworld-config CrossplayPlatforms Steam,Xbox,PS5,Mac
ensure_settings_access
systemctl daemon-reload
if [[ -f /root/palworld-helper-update.sh ]]; then install -o root -g root -m 0755 /root/palworld-helper-update.sh /usr/local/bin/palworld-helper-update; fi
if [[ "$HELPER_UPDATE_ONLY" == 1 ]]; then
    echo "Palworld helper files refreshed. Existing save and config data were preserved."
    exit 0
fi
WEB_PASSWORD=""
if [[ ! -s /etc/palworld-web/admin.hash ]]; then
    WEB_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
    printf '%s' "$WEB_PASSWORD" | /usr/local/sbin/palworld-webctl set-web-password
    printf '%s' "$WEB_PASSWORD" > /etc/palworld-web/initial-password
    chmod 0600 /etc/palworld-web/initial-password
else
    WEB_PASSWORD="$(cat /etc/palworld-web/initial-password 2>/dev/null || true)"
fi
systemctl enable --now palworld.service palworld-public-ip.timer palworld-update.timer palworld-web.service
if [[ -n "$WEB_PASSWORD" ]]; then
    echo "WEB_PANEL_URL=https://$(cat /etc/palworld-web/bind-ip):8443"
    echo "WEB_PANEL_USERNAME=admin"
    echo "WEB_PANEL_PASSWORD=$WEB_PASSWORD"
    echo 'Save this generated password now; it is not shown again.'
fi
echo "Palworld LXC install complete. Open the manager with: palworld-manager"
