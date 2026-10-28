#!/usr/bin/env bash
set -Eeuo pipefail

HELPER_VERSION="${HELPER_VERSION:-0.1.0}"
GITHUB_REPO="${PALWORLD_HELPER_REPO:-SloeberX/palworld-proxmox-helper}"
GITHUB_BRANCH="${PALWORLD_HELPER_BRANCH:-main}"
ASSET_DIR="$(mktemp -d -t palworld-helper.XXXXXX)"
BASE_URL="https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH"
GUEST_INSTALLER="$ASSET_DIR/install-guest.sh"
MANAGER_SOURCE="$ASSET_DIR/palworld-manager.sh"
cleanup() { rm -rf -- "$ASSET_DIR"; }
trap cleanup EXIT

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

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

[[ $EUID -eq 0 ]] || die "Run this on the Proxmox VE host as root."
need_cmd pct
need_cmd pvesh
need_cmd pvesm
need_cmd pveam
need_cmd curl
curl -fLsS --retry 3 "$BASE_URL/guest/install-guest.sh" -o "$GUEST_INSTALLER" || die "Could not download the guest installer from $BASE_URL. Check the repository and branch."
curl -fLsS --retry 3 "$BASE_URL/guest/palworld-manager.sh" -o "$MANAGER_SOURCE" || die "Could not download the manager UI from $BASE_URL. Check the repository and branch."

NODE="$(hostname)"
NEXT_ID="$(pvesh get /cluster/nextid)"
CTID="$(ui_input 'Container ID' 'LXC ID' "$NEXT_ID")" || exit 0
[[ "$CTID" =~ ^[0-9]{3,6}$ ]] || die "Container ID must be 3 to 6 digits."
[[ ! -e "/etc/pve/lxc/$CTID.conf" ]] || die "Container ID $CTID is already in use."

HOSTNAME="$(ui_input 'Container hostname' 'Hostname' 'palworld')" || exit 0
[[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || die "Use letters, numbers, dots, or hyphens for the hostname."
BRIDGE="$(ui_input 'Network bridge' 'Proxmox bridge' 'vmbr0')" || exit 0
[[ "$BRIDGE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Invalid bridge name."
ROOT_STORAGE="$(ui_input 'Root disk storage' 'Storage for the container root disk' 'local-lvm')" || exit 0
TEMPLATE_STORAGE="$(ui_input 'Template storage' 'Storage containing the Debian 12 LXC template' 'local')" || exit 0
DISK="$(ui_input 'Disk size' 'Root disk size in GiB' '40')" || exit 0
CORES="$(ui_input 'CPU cores' 'CPU cores' '4')" || exit 0
MEMORY="$(ui_input 'Memory' 'RAM in MiB (Palworld recommends 16 GiB or more)' '16384')" || exit 0
SWAP="$(ui_input 'Swap' 'Swap in MiB' '2048')" || exit 0
GAME_PORT="$(ui_input 'Game port' 'Palworld UDP game port' '8211')" || exit 0
MAX_PLAYERS="$(ui_input 'Player limit' 'Maximum player count' '32')" || exit 0
SERVER_NAME="$(ui_input 'Server name' 'Name shown in Palworld' 'Palworld Community Server')" || exit 0
for n in "$DISK" "$CORES" "$MEMORY" "$SWAP" "$GAME_PORT" "$MAX_PLAYERS"; do [[ "$n" =~ ^[0-9]+$ ]] || die "Numeric option has an invalid value: $n"; done
(( DISK >= 20 && CORES >= 2 && MEMORY >= 8192 && GAME_PORT >= 1 && GAME_PORT <= 65535 && MAX_PLAYERS >= 1 && MAX_PLAYERS <= 32 )) || die "One or more values are outside supported limits."
[[ -z "$GITHUB_REPO" || "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "GitHub repo must look like owner/repository."

TEMPLATE="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '$1 ~ /debian-12-standard.*amd64/ {print $1}' | sort -V | tail -n1 | cut -d/ -f2)"
if [[ -z "$TEMPLATE" ]]; then
    echo "No Debian 12 template installed on $TEMPLATE_STORAGE; refreshing template index..."
    pveam update
    AVAILABLE="$(pveam available | awk '$2 ~ /^debian-12-standard_.*_amd64\.tar\.zst$/ {print $2}' | sort -V | tail -n1)"
    [[ -n "$AVAILABLE" ]] || die "No Debian 12 amd64 template is available from the Proxmox template index."
    pveam download "$TEMPLATE_STORAGE" "$AVAILABLE"
    TEMPLATE="$AVAILABLE"
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
[[ "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.\ -]{0,63}$ ]] || die "Server name may contain letters, numbers, spaces, dots, underscores, and hyphens (up to 64 characters)."

ui_msg "Ready to create Debian LXC $CTID on $NODE. It will use $CORES cores, ${MEMORY} MiB RAM, ${DISK} GiB disk, and game port UDP $GAME_PORT. Ensure the LAN address is stable for port forwarding."

echo "Creating LXC $CTID..."
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
    --hostname "$HOSTNAME" --ostype debian --unprivileged 1 \
    --cores "$CORES" --memory "$MEMORY" --swap "$SWAP" \
    --rootfs "$ROOT_STORAGE:$DISK" --net0 "$NET_SPEC" --onboot 1 --start 1

echo "Waiting for the container..."
for _ in {1..30}; do pct status "$CTID" | grep -q running && break; sleep 2; done
pct status "$CTID" | grep -q running || die "LXC $CTID did not start. Inspect its Proxmox task log."

echo "Copying installer and installing Palworld..."
pct push "$CTID" "$GUEST_INSTALLER" /root/palworld-install-guest.sh
pct push "$CTID" "$MANAGER_SOURCE" /root/palworld-manager.sh
pct exec "$CTID" -- env GAME_PORT="$GAME_PORT" MAX_PLAYERS="$MAX_PLAYERS" SERVER_NAME="$SERVER_NAME" GITHUB_REPO="$GITHUB_REPO" HELPER_VERSION="$HELPER_VERSION" bash /root/palworld-install-guest.sh

IP_ADDR="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
ui_msg "Palworld LXC is ready.\n\nContainer: $CTID ($HOSTNAME)\nLAN address: $IP_ADDR\nGame port: UDP $GAME_PORT\n\nForward UDP $GAME_PORT on your router to $IP_ADDR:$GAME_PORT. Use pct enter $CTID to open the manager console."
printf '\nCreated Palworld LXC %s at %s (UDP %s).\n' "$CTID" "$IP_ADDR" "$GAME_PORT"
