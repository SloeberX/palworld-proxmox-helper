#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run the helper updater as root.' >&2; exit 1; }
REPO_FILE=/etc/palworld-manager/github-repo
ENV_FILE=/etc/palworld-manager/server.env
[[ -s "$REPO_FILE" ]] || { echo 'GitHub repository is not configured.' >&2; exit 1; }
[[ -r "$ENV_FILE" ]] || { echo 'Server settings file is missing.' >&2; exit 1; }

GITHUB_REPO="$(cat "$REPO_FILE")"
GITHUB_BRANCH="$(cat /etc/palworld-manager/github-branch 2>/dev/null || echo main)"
[[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid GitHub repository setting.' >&2; exit 1; }
[[ "$GITHUB_BRANCH" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid GitHub branch setting.' >&2; exit 1; }
BASE_URL="https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/guest"
TMP_DIR="$(mktemp -d -t palworld-update.XXXXXX)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

for asset in install-guest.sh palworld-manager.sh palworld-helper-update.sh palworld-web.py palworld-webctl.sh; do
    curl -fLsS --retry 3 "$BASE_URL/$asset" -o "$TMP_DIR/$asset"
    sed -i 's/\r$//' "$TMP_DIR/$asset"
done
HELPER_VERSION="$(curl -fLsS --retry 2 "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/VERSION" || cat /etc/palworld-manager/version 2>/dev/null || echo 0.1.0)"

# server.env contains only validated service settings; source it to preserve them during a helper refresh.
source "$ENV_FILE"
install -o root -g root -m 0644 "$TMP_DIR/palworld-manager.sh" /root/palworld-manager.sh
install -o root -g root -m 0644 "$TMP_DIR/palworld-helper-update.sh" /root/palworld-helper-update.sh
install -o root -g root -m 0644 "$TMP_DIR/palworld-web.py" /root/palworld-web.py
install -o root -g root -m 0644 "$TMP_DIR/palworld-webctl.sh" /root/palworld-webctl.sh
env GAME_PORT="$GAME_PORT" MAX_PLAYERS="$MAX_PLAYERS" SERVER_NAME="$SERVER_NAME" \
    GITHUB_REPO="$GITHUB_REPO" GITHUB_BRANCH="$GITHUB_BRANCH" HELPER_VERSION="$HELPER_VERSION" HELPER_UPDATE_ONLY=1 \
    bash "$TMP_DIR/install-guest.sh"

echo "Palworld helper files updated from $GITHUB_REPO/$GITHUB_BRANCH."
if systemctl is-active --quiet palworld-web.service; then systemctl restart palworld-web.service; fi
