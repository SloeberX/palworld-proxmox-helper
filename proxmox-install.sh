#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)"
exec "$SCRIPT_DIR/ct/palworld-server.sh" "$@"
