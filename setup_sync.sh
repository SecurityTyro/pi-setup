#!/usr/bin/env bash
set -euo pipefail

# Install the pi-setup-sync command for this checkout.
#
# Usage:
#   ./setup_sync.sh
#   ./setup_sync.sh --bin-dir ~/.local/bin
#   ./setup_sync.sh --name pi-sync
#
# This creates a symlink:
#   <bin-dir>/<name> -> <repo>/sync.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
COMMAND_NAME="pi-setup-sync"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir)
      BIN_DIR="${2:?missing value for --bin-dir}"
      shift 2
      ;;
    --name)
      COMMAND_NAME="${2:?missing value for --name}"
      shift 2
      ;;
    -h|--help)
      sed -n '1,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$ROOT/sync.sh" ]]; then
  echo "error: sync.sh not found next to setup_sync.sh" >&2
  exit 1
fi

mkdir -p "$BIN_DIR"
chmod +x "$ROOT/sync.sh"
ln -sf "$ROOT/sync.sh" "$BIN_DIR/$COMMAND_NAME"

cat <<EOF
Installed sync command:
  $BIN_DIR/$COMMAND_NAME -> $ROOT/sync.sh

Use it from anywhere:
  $COMMAND_NAME
  $COMMAND_NAME "Update Pi setup"
  $COMMAND_NAME --dry-run
EOF

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    cat <<EOF

Note: $BIN_DIR is not currently on PATH.
Add this to your shell config if needed:
  export PATH="$BIN_DIR:\$PATH"
EOF
    ;;
esac
