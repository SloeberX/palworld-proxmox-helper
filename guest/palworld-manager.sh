#!/usr/bin/env bash
set -Eeuo pipefail

repo_file=/etc/palworld-manager/github-repo
config=/opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini

ask() {
    local title="$1" prompt="$2" default="${3:-}" result
    if command -v whiptail >/dev/null 2>&1; then result="$(whiptail --title "$title" --inputbox "$prompt" 10 72 "$default" 3>&1 1>&2 2>&3)" || return 1
    else read -r -p "$prompt [$default]: " result; result="${result:-$default}"; fi
    printf '%s' "$result"
}
ask_secret() {
    local title="$1" prompt="$2" result
    if command -v whiptail >/dev/null 2>&1; then result="$(whiptail --title "$title" --passwordbox "$prompt" 10 72 3>&1 1>&2 2>&3)" || return 1
    else read -r -s -p "$prompt: " result; printf '\n' >&2; fi
    printf '%s' "$result"
}
msg() { if command -v whiptail >/dev/null 2>&1; then whiptail --title 'Palworld Manager' --msgbox "$1" 12 74; else printf '%s\n' "$1"; fi; }
choose() {
    if command -v whiptail >/dev/null 2>&1; then whiptail --title 'Palworld Manager' --menu "$1" 18 74 8 "${@:2}" 3>&1 1>&2 2>&3
    else
        local title="$1" choice index=0; shift; local -a keys=()
        printf '%s\n' "$title" >&2
        while (($# >= 2)); do index=$((index + 1)); printf '%s) %s\n' "$index" "$2" >&2; keys+=("$1"); shift 2; done
        read -r -p 'Choose: ' choice
        [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= index)) || return 1
        printf '%s' "${keys[$((choice - 1))]}"
    fi
}
restart_after() { systemctl restart palworld.service; msg 'Saved settings and restarted Palworld.'; }
settings_menu() {
    while true; do
        local action
        action="$(choose 'Configure the server. Changes take effect after restart.' name 'Set server name' players 'Set maximum players' port 'Set UDP game port' serverpass 'Set/clear server password' adminpass 'Set admin password' crossplay 'Set crossplay platforms' description 'Set description' back 'Back')" || return
        case "$action" in
            name) local v; v="$(ask 'Server name' 'Name (1-64 characters)' 'Palworld Community Server')" || continue; /usr/local/bin/palworld-config ServerName "$v" && restart_after ;;
            players) local v; v="$(ask 'Maximum players' 'Enter 1-32' '32')" || continue; /usr/local/bin/palworld-config ServerPlayerMaxNum "$v" && restart_after ;;
            port) local v; v="$(ask 'Game port' 'UDP port 1-65535; update Proxmox allocation and router forward too' '8211')" || continue; /usr/local/bin/palworld-config PublicPort "$v" && restart_after ;;
            serverpass) local v; v="$(ask_secret 'Server password' 'Leave blank to remove password')" || continue; printf '%s' "$v" | /usr/local/bin/palworld-config ServerPassword --stdin && restart_after ;;
            adminpass) local v; v="$(ask_secret 'Admin password' 'Enter new admin password')" || continue; [[ -n "$v" ]] && printf '%s' "$v" | /usr/local/bin/palworld-config AdminPassword --stdin && restart_after ;;
            crossplay) local v; v="$(ask 'Crossplay platforms' 'Comma-separated: Steam,Xbox,PS5,Mac' 'Steam,Xbox,PS5,Mac')" || continue; /usr/local/bin/palworld-config CrossplayPlatforms "$v" && restart_after ;;
            description) local v; v="$(ask 'Description' 'Server description (up to 128 characters)' '')" || continue; /usr/local/bin/palworld-config ServerDescription "$v" && restart_after ;;
            *) return;;
        esac
    done
}
self_update() {
    local was_active=0
    systemctl is-active --quiet palworld.service && was_active=1 || true
    if /usr/local/bin/palworld-helper-update; then
        if [[ "$was_active" == 1 ]]; then systemctl restart palworld.service; fi
        msg 'Helper scripts and web manager updated from GitHub.'
    else
        msg 'Helper update failed. Check the GitHub repository and network, then see journalctl for details.'
    fi
}

[[ $EUID -eq 0 ]] || { echo 'Run this manager through pct enter as root.' >&2; exit 1; }
while true; do
    action="$(choose 'Palworld management console' status 'Server status and recent log' start 'Start server' stop 'Stop server' restart 'Restart server' update 'Update game and helper from GitHub' settings 'Server settings' ip 'Show current public IP' selfupdate 'Update helper scripts only' exit 'Exit')" || exit 0
    case "$action" in
        status) systemctl --no-pager --full status palworld.service || true; journalctl -u palworld.service -n 35 --no-pager || true; read -r -p 'Press Enter to continue...' _ || true;;
        start) systemctl start palworld.service; msg 'Palworld started.';;
        stop) systemctl stop palworld.service; msg 'Palworld stopped.';;
        restart) systemctl restart palworld.service; msg 'Palworld restarted.';;
        update) if systemctl start palworld-update.service; then msg 'SteamCMD update finished.'; else msg 'SteamCMD update failed. Check the Palworld update service log with: journalctl -u palworld-update.service'; fi;;
        settings) settings_menu;;
        ip) msg "Detected public IPv4: $(cat /var/lib/palworld-manager/public-ip 2>/dev/null || echo 'not detected yet')\n\nThe value is refreshed every 5 minutes. DDNS is not configured or modified by this helper.";;
        selfupdate) self_update;;
        *) exit 0;;
    esac
done

