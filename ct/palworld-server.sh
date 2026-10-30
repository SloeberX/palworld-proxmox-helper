#!/usr/bin/env bash
set -Eeuo pipefail

HELPER_VERSION="${HELPER_VERSION:-0.1.0}"
GITHUB_REPO="${PALWORLD_HELPER_REPO:-SloeberX/palworld-proxmox-helper}"
GITHUB_BRANCH="${PALWORLD_HELPER_BRANCH:-main}"
ASSET_DIR="$(mktemp -d -t palworld-helper.XXXXXX)"
BASE_URL="https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH"
GUEST_INSTALLER="$ASSET_DIR/install-guest.sh"
MANAGER_SOURCE="$ASSET_DIR/palworld-manager.sh"
HELPER_UPDATER_SOURCE="$ASSET_DIR/palworld-helper-update.sh"
WEB_APP_SOURCE="$ASSET_DIR/palworld-web.py"
WEB_CTL_SOURCE="$ASSET_DIR/palworld-webctl.sh"
cleanup() { rm -rf -- "$ASSET_DIR"; }
trap cleanup EXIT

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

header_info() {
    printf '\n\033[1;36mPalworld Dedicated Server\033[0m\n'
    printf '\033[1;34mProxmox LXC Helper\033[0m  |  Debian 13  |  Crossplay enabled\n\n'
}

ui_input() {
    local title="$1" prompt="$2" default="$3" answer
    if command -v whiptail >/dev/null 2>&1; then
        answer="$(whiptail --title "$title" --inputbox "$prompt" 10 74 "$default" 3>&1 1>&2 2>&3)" || return 1
    else
        read -r -p "$prompt [$default]: " answer
        answer="${answer:-$default}"
    fi
    printf '%s' "$answer"
}

ui_msg() {
    if command -v whiptail >/dev/null 2>&1; then whiptail --title "Palworld LXC Helper" --msgbox "$1" 12 76; else printf '%s\n' "$1"; fi
}

ui_status() {
    if command -v whiptail >/dev/null 2>&1; then whiptail --title 'Palworld LXC Helper' --infobox "$1" 10 76; else printf '%s\n' "$1"; fi
}

ui_menu() {
    local title="$1" prompt="$2"; shift 2
    if command -v whiptail >/dev/null 2>&1; then whiptail --title "$title" --menu "$prompt" 16 78 6 "$@" 3>&1 1>&2 2>&3
    else
        local i=1 choice; local -a values=() labels=()
        while (($#)); do values+=("$1"); labels+=("$2"); shift 2; done
        for i in "${!values[@]}"; do printf '%s) %s\n' "$((i+1))" "${labels[$i]}" >&2; done
        read -r -p 'Choose [1]: ' choice; choice="${choice:-1}"
        [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#values[@]})) || return 1
        printf '%s' "${values[$((choice-1))]}"
    fi
}

select_storage() {
    local wanted_content="$1" title="$2" preferred="$3"
    local name type state total used avail percent free content
    local -a ids=() labels=() options=()
    while read -r name type state total used avail percent; do
        [[ -n "$name" && "$name" != Name && "$state" == active ]] || continue
        if awk -v id="$name" -v wanted="$wanted_content" '
            /^[^[:space:]]/ { current=$2; sub(/:$/, "", current); active=(current==id) }
            active && /^[[:space:]]+content[[:space:]]/ { for (i=2;i<=NF;i++) { n=split($i,a,","); for (j=1;j<=n;j++) if (a[j]==wanted) found=1 } }
            END { exit !found }
        ' /etc/pve/storage.cfg; then
            # pvesm status reports Total/Used/Available in KiB (1024-byte units).
            free="$(awk -v kib="$avail" 'BEGIN { gib=kib/1048576; if (gib >= 1024) printf "%.2f TiB free", gib/1024; else printf "%.1f GiB free", gib }')"
            ids+=("$name")
            labels+=("$type | $free")
        fi
    done < <(pvesm status | tail -n +2)
    ((${#ids[@]} > 0)) || die "No active Proxmox storage supports $wanted_content."
    local default_index=0 i selected
    for i in "${!ids[@]}"; do
        if [[ "${ids[$i]}" == "$preferred" ]]; then default_index=$i; fi
    done
    if command -v whiptail >/dev/null 2>&1; then
        for i in "${!ids[@]}"; do
            local marker=OFF
            [[ "$i" == "$default_index" ]] && marker=ON
            options+=("${ids[$i]}" "${labels[$i]}" "$marker")
        done
        selected="$(whiptail --title 'Choose Proxmox storage' --radiolist "$title" 18 84 8 "${options[@]}" 3>&1 1>&2 2>&3)" || return 1
    else
        printf '%s\n' "$title" >&2
        for i in "${!ids[@]}"; do printf '%s) %s\n' "$((i+1))" "${labels[$i]}" >&2; done
        read -r -p "Choose storage [$((default_index+1))]: " selected
        selected="${selected:-$((default_index+1))}"
        [[ "$selected" =~ ^[0-9]+$ ]] && ((selected >= 1 && selected <= ${#ids[@]})) || return 1
        selected="${ids[$((selected-1))]}"
    fi
    printf '%s' "$selected"
}

[[ $EUID -eq 0 ]] || die "Run this on the Proxmox VE host as root."
header_info
need_cmd pct
need_cmd pvesh
need_cmd pvesm
need_cmd pveam
need_cmd curl
curl -fLsS --retry 3 "$BASE_URL/guest/install-guest.sh" -o "$GUEST_INSTALLER" || die "Could not download the guest installer from $BASE_URL. Check the repository and branch."
curl -fLsS --retry 3 "$BASE_URL/guest/palworld-manager.sh" -o "$MANAGER_SOURCE" || die "Could not download the manager UI from $BASE_URL. Check the repository and branch."
curl -fLsS --retry 3 "$BASE_URL/guest/palworld-helper-update.sh" -o "$HELPER_UPDATER_SOURCE" || die "Could not download the helper updater from $BASE_URL. Check the repository and branch."
curl -fLsS --retry 3 "$BASE_URL/guest/palworld-web.py" -o "$WEB_APP_SOURCE" || die "Could not download the web app from $BASE_URL. Check the repository and branch."
curl -fLsS --retry 3 "$BASE_URL/guest/palworld-webctl.sh" -o "$WEB_CTL_SOURCE" || die "Could not download the web control wrapper from $BASE_URL. Check the repository and branch."
# GitHub uploads from Windows can preserve CRLF. Normalize guest assets before
# pushing them so Bash doesn't parse `set -euo pipefail` as an invalid option.
for asset in "$GUEST_INSTALLER" "$MANAGER_SOURCE" "$HELPER_UPDATER_SOURCE" "$WEB_APP_SOURCE" "$WEB_CTL_SOURCE"; do
    sed -i 's/\r$//' "$asset"
done

NODE="$(hostname)"
NEXT_ID="$(pvesh get /cluster/nextid)"
CTID="$(ui_input 'Container ID' 'LXC ID' "$NEXT_ID")" || exit 0
[[ "$CTID" =~ ^[0-9]{3,6}$ ]] || die "Container ID must be 3 to 6 digits."
RESUME_EXISTING=0
if [[ -e "/etc/pve/lxc/$CTID.conf" ]]; then
    choice="$(ui_menu 'Existing container found' "Container $CTID already exists. Resume setup only if this is the Palworld LXC from a previous failed run. It will be restarted; its disk and save files are kept." resume 'Resume Palworld setup in this LXC' cancel 'Cancel')" || exit 0
    [[ "$choice" == resume ]] || exit 0
    RESUME_EXISTING=1
    HOSTNAME="$(pct config "$CTID" | sed -n 's/^hostname: //p' | head -n1)"
    [[ -n "$HOSTNAME" ]] || HOSTNAME="$(ui_input 'Container hostname' 'Hostname' 'palworld')" || exit 0
    BRIDGE="$(pct config "$CTID" | sed -n 's/^net0:.*bridge=\([^,]*\).*/\1/p' | head -n1)"
    BRIDGE="${BRIDGE:-existing bridge}"
    ROOT_STORAGE='existing LXC disk'
    TEMPLATE_STORAGE='Debian 13 already installed'
    DISK='existing'
    CORES='existing'
    MEMORY='existing'
    SWAP='existing'
    EXISTING_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    IP_CIDR="${EXISTING_IP:-existing network}"
else
    HOSTNAME="$(ui_input 'Container hostname' 'Hostname' 'palworld')" || exit 0
    BRIDGE="$(ui_input 'Network bridge' 'Proxmox bridge' 'vmbr0')" || exit 0
    ROOT_STORAGE="$(select_storage rootdir 'Select where the LXC disk should live. Free space is shown.' 'local-lvm')" || exit 0
    TEMPLATE_STORAGE="$(select_storage vztmpl 'Select storage for the Debian 13 container template.' 'local')" || exit 0
    DISK="$(ui_input 'Disk size' 'Root disk size in GiB' '40')" || exit 0
    CORES="$(ui_input 'CPU cores' 'CPU cores' '4')" || exit 0
    MEMORY="$(ui_input 'Memory' 'RAM in MiB (Palworld recommends 16 GiB or more)' '16384')" || exit 0
    SWAP="$(ui_input 'Swap' 'Swap in MiB' '2048')" || exit 0
fi
[[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || die "Use letters, numbers, dots, or hyphens for the hostname."
if [[ "$RESUME_EXISTING" != 1 ]]; then [[ "$BRIDGE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Invalid bridge name."; fi
GAME_PORT_DEFAULT=8211
MAX_PLAYERS_DEFAULT=32
SERVER_NAME_DEFAULT='Palworld Community Server'
if [[ "$RESUME_EXISTING" == 1 ]]; then
    EXISTING_ENV="$(pct exec "$CTID" -- bash -c 'if [[ -r /etc/palworld-manager/server.env ]]; then source /etc/palworld-manager/server.env; printf "%s\n%s\n%s\n" "${GAME_PORT:-}" "${MAX_PLAYERS:-}" "${SERVER_NAME:-}"; fi' 2>/dev/null || true)"
    mapfile -t EXISTING_VALUES <<< "$EXISTING_ENV"
    GAME_PORT_DEFAULT="${EXISTING_VALUES[0]:-8211}"
    MAX_PLAYERS_DEFAULT="${EXISTING_VALUES[1]:-32}"
    SERVER_NAME_DEFAULT="${EXISTING_VALUES[2]:-Palworld Community Server}"
fi
GAME_PORT="$(ui_input 'Game port' 'Palworld UDP game port' "$GAME_PORT_DEFAULT")" || exit 0
MAX_PLAYERS="$(ui_input 'Player limit' 'Maximum player count' "$MAX_PLAYERS_DEFAULT")" || exit 0
SERVER_NAME="$(ui_input 'Server name' 'Name shown in Palworld' "$SERVER_NAME_DEFAULT")" || exit 0
[[ "$GAME_PORT" =~ ^[0-9]+$ && "$MAX_PLAYERS" =~ ^[0-9]+$ ]] || die "Game port and player limit must be numeric."
(( GAME_PORT >= 1 && GAME_PORT <= 65535 && MAX_PLAYERS >= 1 && MAX_PLAYERS <= 32 )) || die "Game port or player limit is outside supported limits."
if [[ "$RESUME_EXISTING" != 1 ]]; then
    for n in "$DISK" "$CORES" "$MEMORY" "$SWAP"; do [[ "$n" =~ ^[0-9]+$ ]] || die "Numeric option has an invalid value: $n"; done
    (( DISK >= 20 && CORES >= 2 && MEMORY >= 8192 )) || die "Disk, CPU, or memory values are outside supported limits."
fi
[[ -z "$GITHUB_REPO" || "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "GitHub repo must look like owner/repository."

if [[ "$RESUME_EXISTING" != 1 ]]; then
    ui_status "PREPARING TEMPLATE\n\nRefreshing the Proxmox template index and selecting the newest available Debian 13 image..."
    pveam update
    TEMPLATE="$(pveam available | awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.zst$/ {print $2}' | sort -V | tail -n1)"
    [[ -n "$TEMPLATE" ]] || die "No Debian 13 amd64 template is available from the Proxmox template index."
    if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -Fq "$TEMPLATE"; then
        pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
    fi

    IP_CIDR="$(ui_input 'Container IP' 'Use dhcp or enter a static IPv4/CIDR (example 192.168.50.111/24). Reserve a stable LAN IP for router forwarding.' 'dhcp')" || exit 0
    if [[ "$IP_CIDR" == dhcp ]]; then
        NET_SPEC="name=eth0,bridge=$BRIDGE,ip=dhcp,ip6=auto"
    else
        [[ "$IP_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$ ]] || die "Static IP must be IPv4/CIDR, such as 192.168.50.111/24."
        GATEWAY="$(ui_input 'Default gateway' 'LAN router address (example 192.168.50.1)' '192.168.50.1')" || exit 0
        [[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Gateway must be an IPv4 address."
        NET_SPEC="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY,ip6=auto"
    fi
fi
[[ "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.\ -]{0,63}$ ]] || die "Server name may contain letters, numbers, spaces, dots, underscores, and hyphens (up to 64 characters)."
INSTALL_MODE="$(ui_menu 'Installation display' 'Choose how installation progress should be shown.' clean 'Progress screens' verbose 'Verbose console output')" || exit 0

if [[ "$RESUME_EXISTING" == 1 ]]; then
    ui_msg "Ready to resume Palworld setup in LXC $CTID. Existing storage and network settings will be kept; the container will restart to apply nesting."
    ui_status "RESUMING PALWORLD LXC\n\nContainer: $CTID\nKeeping its existing disk and network configuration..."
    pct exec "$CTID" -- systemctl stop palworld.service >/dev/null 2>&1 || true
    if pct status "$CTID" | grep -q running; then pct shutdown "$CTID" --timeout 120 || die "Could not gracefully stop LXC $CTID. It was left unchanged; inspect it with pct status $CTID."; fi
    FEATURES="$(pct config "$CTID" | sed -n 's/^features: //p' | head -n1)"
    if [[ ",$FEATURES," != *,nesting=1,* ]]; then
        if [[ ",$FEATURES," == *,nesting=0,* ]]; then FEATURES="${FEATURES/nesting=0/nesting=1}"
        else FEATURES="${FEATURES:+$FEATURES,}nesting=1"; fi
        pct set "$CTID" --features "$FEATURES" --cmode shell || die "Could not configure LXC $CTID for resume."
    else
        pct set "$CTID" --cmode shell || die "Could not set the LXC console shell mode."
    fi
    pct status "$CTID" | grep -q running || pct start "$CTID" || die "Could not start LXC $CTID."
else
    ui_msg "Ready to create Debian 13 LXC $CTID on $NODE. It will use $CORES cores and ${MEMORY} MiB RAM, with $DISK GiB disk and game port UDP $GAME_PORT."
    ui_status "CREATING LXC\n\nContainer: $CTID\nStorage: $ROOT_STORAGE\nNetwork: $IP_CIDR"
    pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
        --hostname "$HOSTNAME" --ostype debian --unprivileged 1 \
        --features nesting=1 --cmode shell \
        --cores "$CORES" --memory "$MEMORY" --swap "$SWAP" \
        --rootfs "$ROOT_STORAGE:$DISK" --net0 "$NET_SPEC" --onboot 1 --start 1 || die "Proxmox failed to create LXC $CTID. Check the task log above."
fi

ui_status "STARTING LXC\n\nWaiting for Debian 13 to boot before setup..."
for _ in {1..30}; do pct status "$CTID" | grep -q running && break; sleep 2; done
pct status "$CTID" | grep -q running || die "LXC $CTID did not start. Inspect its Proxmox task log."
if [[ "$RESUME_EXISTING" == 1 ]]; then pct exec "$CTID" -- systemctl stop palworld.service >/dev/null 2>&1 || true; fi

ui_status "PREPARING SERVER\n\nCopying the Palworld manager and installer into LXC $CTID..."
pct push "$CTID" "$GUEST_INSTALLER" /root/palworld-install-guest.sh
pct push "$CTID" "$MANAGER_SOURCE" /root/palworld-manager.sh
pct push "$CTID" "$HELPER_UPDATER_SOURCE" /root/palworld-helper-update.sh
pct push "$CTID" "$WEB_APP_SOURCE" /root/palworld-web.py
pct push "$CTID" "$WEB_CTL_SOURCE" /root/palworld-webctl.sh
INSTALL_LOG="/tmp/palworld-install-${CTID}.log"
(umask 077; : > "$INSTALL_LOG")
while true; do
    ui_status "INSTALLING PALWORLD\n\nContainer: $CTID ($HOSTNAME)\nStage: Installing Debian packages and downloading the dedicated server\n\nThis can take several minutes."
    if [[ "$INSTALL_MODE" == verbose ]]; then
        if pct exec "$CTID" -- env GAME_PORT="$GAME_PORT" MAX_PLAYERS="$MAX_PLAYERS" SERVER_NAME="$SERVER_NAME" GITHUB_REPO="$GITHUB_REPO" GITHUB_BRANCH="$GITHUB_BRANCH" HELPER_VERSION="$HELPER_VERSION" bash /root/palworld-install-guest.sh 2>&1 | tee "$INSTALL_LOG"; then break; fi
    else
        printf 'Installing Palworld in LXC %s. Output is being recorded at %s.\n' "$CTID" "$INSTALL_LOG"
        pct exec "$CTID" -- env GAME_PORT="$GAME_PORT" MAX_PLAYERS="$MAX_PLAYERS" SERVER_NAME="$SERVER_NAME" GITHUB_REPO="$GITHUB_REPO" GITHUB_BRANCH="$GITHUB_BRANCH" HELPER_VERSION="$HELPER_VERSION" bash /root/palworld-install-guest.sh >"$INSTALL_LOG" 2>&1 &
        install_pid=$!
        while kill -0 "$install_pid" 2>/dev/null; do
            sleep 15
            if kill -0 "$install_pid" 2>/dev/null; then
                printf 'Still installing Palworld in LXC %s; see %s for detailed progress.\n' "$CTID" "$INSTALL_LOG"
            fi
        done
        if wait "$install_pid"; then break; fi
    fi
    choice="$(ui_menu 'Installation needs attention' "Guest installation failed. Log: $INSTALL_LOG" retry 'Retry in verbose console mode' console 'Open LXC shell for debugging' exit 'Stop here and leave the LXC for debugging')" || choice=exit
    case "$choice" in
        retry) INSTALL_MODE=verbose ;;
        console) pct enter "$CTID"; INSTALL_MODE=verbose ;;
        *) ui_msg "The LXC was left in place for debugging.\n\nOpen it with: pct enter $CTID\nInstall log: $INSTALL_LOG"; exit 1 ;;
    esac
done

IP_ADDR="$(pct exec "$CTID" -- hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n1 || true)"
[[ -n "$IP_ADDR" ]] || IP_ADDR='not yet assigned (check LXC network)'
WEB_PASSWORD="$(sed -n 's/^WEB_PANEL_PASSWORD=//p' "$INSTALL_LOG" | tail -n1)"
WEB_URL="https://${IP_ADDR}:8443"
ui_msg "PALWORLD SERVER READY\n\nContainer: $CTID  |  Hostname: $HOSTNAME\nLocal IP: $IP_ADDR\nGame server: $IP_ADDR:$GAME_PORT (UDP)\nWeb manager: $WEB_URL\nUsername: admin\nInitial password: ${WEB_PASSWORD:-check install output}\n\nForward UDP $GAME_PORT to $IP_ADDR:$GAME_PORT on your router. Keep TCP 8443 LAN-only. Proxmox Console opens a root shell without a login prompt."
printf '\nPalworld Server Manager is ready\n  LXC:          %s (%s)\n  Local IP:     %s\n  Game server:  %s:%s/udp\n  Web manager:  %s\n  Username:     admin\n  Password:     %s\n\n' "$CTID" "$HOSTNAME" "$IP_ADDR" "$IP_ADDR" "$GAME_PORT" "$WEB_URL" "${WEB_PASSWORD:-check $INSTALL_LOG}"
