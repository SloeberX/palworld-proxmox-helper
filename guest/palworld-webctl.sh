#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'web control must run as root' >&2; exit 1; }
action="${1:-}"
validate_archive() {
    python3 - "$1" <<'PY'
import sys, tarfile
archive=sys.argv[1]
try:
    with tarfile.open(archive, 'r:gz') as tf:
        members=tf.getmembers()
        good=False
        total=0
        for m in members:
            name=m.name.rstrip('/') if m.isdir() else m.name
            if name.startswith('/') or '..' in name.split('/'):
                raise ValueError('Archive contains an unsafe path.')
            allowed=(name in ('Pal', 'Pal/Saved', 'Pal/Saved/SaveGames', 'Pal/Saved/Config',
                              'Pal/Saved/Config/LinuxServer', 'Pal/Saved/Config/LinuxServer/PalWorldSettings.ini')
                     or name.startswith('Pal/Saved/SaveGames/'))
            if not allowed or not (m.isdir() or m.isfile()):
                raise ValueError('Archive contains an unexpected path or link.')
            if m.isfile():
                total += m.size
                if total > 20 * 1024**3: raise ValueError('Expanded backup exceeds 20 GiB.')
            if name.startswith('Pal/Saved/SaveGames/') or name == 'Pal/Saved/Config/LinuxServer/PalWorldSettings.ini':
                good=True
        if not good: raise ValueError('Archive contains no Palworld saves or settings.')
except (OSError, tarfile.TarError, ValueError) as exc:
    print(f'Invalid backup archive: {exc}', file=sys.stderr)
    raise SystemExit(1)
PY
}
archive_has_saves() {
    python3 - "$1" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1], 'r:gz') as tf:
    raise SystemExit(0 if any(m.name.startswith('Pal/Saved/SaveGames/') for m in tf.getmembers()) else 1)
PY
}
case "$action" in
    status)
        state="$(systemctl is-active palworld.service 2>/dev/null || true)"
        [[ -n "$state" ]] || state=unknown
        ip="$(cat /var/lib/palworld-manager/public-ip 2>/dev/null || true)"
        local_ip="$(cat /etc/palworld-web/bind-ip 2>/dev/null || true)"
        started="$(systemctl show palworld.service -p ActiveEnterTimestamp --value 2>/dev/null || true)"
        python3 -c 'import json,sys; print(json.dumps(dict(status=sys.argv[1],public_ip=sys.argv[2],local_ip=sys.argv[3],web_port=8443,started=sys.argv[4])))' "$state" "$ip" "$local_ip" "$started"
        ;;
    start|stop|restart) systemctl "$action" palworld.service ;;
    update) systemctl start --no-block palworld-update.service; echo 'Palworld and helper update queued.' ;;
    helper-update) systemctl start --no-block palworld-helper-update.service; echo 'Helper update queued.' ;;
    logs) journalctl -u palworld.service -n 120 --no-pager ;;
    save)
        key="${2:-}"
        case "$key" in ServerName|ServerDescription|ServerPlayerMaxNum|PublicPort|CrossplayPlatforms|ServerPassword|AdminPassword) ;; *) echo 'Unsupported setting.' >&2; exit 2;; esac
        /usr/local/bin/palworld-config "$key" --stdin
        ;;
    set-web-password)
        python3 3<&0 <<'PY'
import os, grp, tempfile, sys
from werkzeug.security import generate_password_hash
password=os.fdopen(3).read().rstrip('\n')
if len(password) < 12 or len(password) > 256:
    raise SystemExit('Password must be between 12 and 256 characters.')
path='/etc/palworld-web/admin.hash'
fd,tmp=tempfile.mkstemp(dir='/etc/palworld-web',prefix='.admin-')
with os.fdopen(fd,'w') as f: f.write(generate_password_hash(password))
os.chown(tmp,0,grp.getgrnam('palworld-web').gr_gid); os.chmod(tmp,0o640); os.replace(tmp,path)
try: os.unlink('/etc/palworld-web/initial-password')
except FileNotFoundError: pass
PY
        ;;
    backup)
        install -d -o root -g palworld-web -m 0750 /opt/palworld/backups
        was_active=0
        systemctl is-active --quiet palworld.service && was_active=1 || true
        restart_server() { if [[ "$was_active" == 1 ]]; then systemctl start palworld.service || true; fi; }
        trap restart_server EXIT
        if [[ "$was_active" == 1 ]]; then systemctl stop palworld.service; fi
        file="/opt/palworld/backups/palworld_$(date +%Y%m%d_%H%M%S).tar.gz"
        paths=()
        [[ ! -d /opt/palworld/server/Pal/Saved/SaveGames ]] || paths+=(Pal/Saved/SaveGames)
        [[ ! -f /opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini ]] || paths+=(Pal/Saved/Config/LinuxServer/PalWorldSettings.ini)
        ((${#paths[@]} > 0)) || { echo 'No save/config data found to back up.' >&2; exit 1; }
        tar -czf "$file" -C /opt/palworld/server "${paths[@]}"
        chown root:palworld-web "$file"; chmod 0640 "$file"
        keep="/opt/palworld/backups/${PALWORLD_KEEP_BACKUP:-}"
        find /opt/palworld/backups -maxdepth 1 -type f -name 'palworld_*.tar.gz' -printf '%T@ %p\n' | sort -rn | awk -v keep="$keep" 'NR>10 {sub(/^[^ ]+ /, ""); if ($0 != keep) print}' | xargs -r rm -f --
        echo "${file##*/}"
        ;;
    restore)
        file="${2:-}"
        [[ "$file" =~ ^palworld_[0-9]{8}_[0-9]{6}\.tar\.gz$ ]] || { echo 'Invalid backup name.' >&2; exit 2; }
        archive="/opt/palworld/backups/$file"
        [[ -f "$archive" ]] || { echo 'Backup not found.' >&2; exit 1; }
        validate_archive "$archive"
        was_active=0
        systemctl is-active --quiet palworld.service && was_active=1 || true
        restart_server() { if [[ "$was_active" == 1 ]]; then systemctl start palworld.service || true; fi; }
        trap restart_server EXIT
        if [[ "$was_active" == 1 ]]; then systemctl stop palworld.service; fi
        PALWORLD_KEEP_BACKUP="$file" /usr/local/sbin/palworld-webctl backup >/dev/null
        if archive_has_saves "$archive"; then rm -rf -- /opt/palworld/server/Pal/Saved/SaveGames; fi
        tar --no-same-owner --no-same-permissions -xzf "$archive" -C /opt/palworld/server
        [[ ! -e /opt/palworld/server/Pal/Saved/SaveGames ]] || chown -R palworld:palworld /opt/palworld/server/Pal/Saved/SaveGames
        [[ ! -e /opt/palworld/server/Pal/Saved/Config/LinuxServer ]] || chown -R palworld:palworld /opt/palworld/server/Pal/Saved/Config/LinuxServer
        echo "Restored ${file}. A safety backup was made first."
        ;;
    import-backup)
        source_file="${2:-}"
        [[ "$source_file" =~ ^/var/lib/palworld-web/imports/import-[A-Za-z0-9_-]+\.tar\.gz$ && -f "$source_file" ]] || { echo 'Invalid uploaded archive path.' >&2; exit 2; }
        validate_archive "$source_file"
        was_active=0
        systemctl is-active --quiet palworld.service && was_active=1 || true
        restart_server() { if [[ "$was_active" == 1 ]]; then systemctl start palworld.service || true; fi; }
        trap restart_server EXIT
        if [[ "$was_active" == 1 ]]; then systemctl stop palworld.service; fi
        /usr/local/sbin/palworld-webctl backup >/dev/null
        if archive_has_saves "$source_file"; then rm -rf -- /opt/palworld/server/Pal/Saved/SaveGames; fi
        tar --no-same-owner --no-same-permissions -xzf "$source_file" -C /opt/palworld/server
        [[ ! -e /opt/palworld/server/Pal/Saved/SaveGames ]] || chown -R palworld:palworld /opt/palworld/server/Pal/Saved/SaveGames
        [[ ! -e /opt/palworld/server/Pal/Saved/Config/LinuxServer ]] || chown -R palworld:palworld /opt/palworld/server/Pal/Saved/Config/LinuxServer
        echo 'Imported backup successfully. A safety backup of the previous server data was made first.'
        ;;
    list-backups)
        find /opt/palworld/backups -maxdepth 1 -type f -name 'palworld_*.tar.gz' -printf '%f\t%s\n' 2>/dev/null | sort -r
        ;;
    backup-path)
        file="${2:-}"
        [[ "$file" =~ ^palworld_[0-9]{8}_[0-9]{6}\.tar\.gz$ ]] || { echo 'Invalid backup name.' >&2; exit 2; }
        [[ -f "/opt/palworld/backups/$file" ]] || { echo 'Backup not found.' >&2; exit 1; }
        printf '%s\n' "/opt/palworld/backups/$file"
        ;;
    *) echo 'Unknown action.' >&2; exit 2 ;;
esac
