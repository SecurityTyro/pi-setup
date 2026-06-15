#!/usr/bin/env bash
set -euo pipefail

# Install helper commands for this pi-setup repo.
#
# ~/.pi/agent is the live Pi setup. This repo is the versioned pi-setup copy
# used to back up that live setup to GitHub and recreate it on any machine.
#
# Usage:
#   ./install.sh                         # install sync helper + compact launcher only
#   ./install.sh --copy-config           # also overwrite ~/.pi/agent/settings.json and mcp.json
#   ./install.sh --restore               # also restore extensions/themes/skills from this repo
#   ./install.sh --restore --dry-run     # preview changes without writing files
#   ./install.sh --restore --backup      # save current live files before replacing them
#   ./install.sh --revert <backup-dir>   # restore a backup created by --backup

REPO_URL="${PI_SETUP_REPO_URL:-https://github.com/abhinand5/pi-setup.git}"
DEFAULT_CHECKOUT="${PI_SETUP_CHECKOUT:-$HOME/dev/ai-agents/pi-setup}"

# One-line installer mode: when this script is run from curl/bash instead of a
# checkout, clone/update the repo and re-exec the real script from there.
if [[ -z "${PI_SETUP_BOOTSTRAPPED:-}" ]]; then
  SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd || pwd)"
  if [[ ! -f "$SCRIPT_DIR/sync.sh" || ! -d "$SCRIPT_DIR/extensions" || ! -d "$SCRIPT_DIR/themes" ]]; then
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
      : # fall through to local usage when possible
    else
      if [[ -d "$DEFAULT_CHECKOUT/.git" ]]; then
        echo "Using existing pi-setup checkout: $DEFAULT_CHECKOUT"
        git -C "$DEFAULT_CHECKOUT" pull --ff-only
      else
        echo "Cloning pi-setup into: $DEFAULT_CHECKOUT"
        mkdir -p "$(dirname "$DEFAULT_CHECKOUT")"
        git clone "$REPO_URL" "$DEFAULT_CHECKOUT"
      fi
      export PI_SETUP_BOOTSTRAPPED=1
      exec "$DEFAULT_CHECKOUT/install.sh" "$@"
    fi
  fi
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_HOME="${PI_HOME:-$HOME/.pi/agent}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
COPY_CONFIG=0
RESTORE=0
DRY_RUN=0
BACKUP=0
BACKUP_DIR=""
REVERT_DIR=""

usage() {
  cat <<'EOF'
Install helper commands for this pi-setup repo.

~/.pi/agent is the live Pi setup. This repo is the versioned pi-setup copy
used to back up that live setup to GitHub and recreate it on any machine.

Usage:
  ./install.sh                         # install sync helper + compact launcher only
  ./install.sh --copy-config           # also overwrite ~/.pi/agent/settings.json and mcp.json
  ./install.sh --restore               # also restore extensions/themes/skills into ~/.pi/agent
  ./install.sh --restore --dry-run     # preview changes without writing files
  ./install.sh --restore --backup      # save current live files before replacing them
  ./install.sh --revert <backup-dir>   # restore a backup created by --backup

One-line install from GitHub:
  curl -fsSL https://raw.githubusercontent.com/abhinand5/pi-setup/main/install.sh | bash -s -- --restore --backup

Options:
  --dry-run       Print what would change without writing files.
  --backup        Back up current live Pi files before restore/config overwrite.
  --no-backup     Explicitly skip backup prompts/policy; useful in scripts.
  --revert DIR    Restore extensions/themes/skills/settings/mcp from a backup dir.

Recommended: install the Pi CLI first. The compact launcher wraps an existing
Pi binary and will look in /usr/local/bin/pi, /usr/bin/pi, /opt/homebrew/bin/pi,
or PI_REAL_BIN.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy-config)
      COPY_CONFIG=1
      shift
      ;;
    --restore)
      RESTORE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --backup)
      BACKUP=1
      shift
      ;;
    --no-backup)
      BACKUP=0
      shift
      ;;
    --revert)
      REVERT_DIR="${2:?missing backup directory for --revert}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'would run: '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

copy_path() {
  local src="$1" dst="$2"
  if [[ -d "$src" ]]; then
    run mkdir -p "$dst"
    run cp -R "$src"/. "$dst"/
  elif [[ -f "$src" ]]; then
    run mkdir -p "$(dirname "$dst")"
    run cp "$src" "$dst"
  fi
}

copy_dir_contents() {
  local src="$1"
  local dst="$2"
  [[ -d "$src" ]] || return 0
  run mkdir -p "$dst"
  run find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf '{}' +
  run cp -R "$src"/. "$dst"/
}

make_backup() {
  if [[ "$BACKUP" != "1" || "$DRY_RUN" == "1" ]]; then
    [[ "$BACKUP" == "1" && "$DRY_RUN" == "1" ]] && echo "would create backup under $PI_HOME/backups/"
    return 0
  fi

  BACKUP_DIR="$PI_HOME/backups/pi-setup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"

  for name in extensions themes skills; do
    if [[ -d "$PI_HOME/$name" ]]; then
      mkdir -p "$BACKUP_DIR/$name"
      cp -R "$PI_HOME/$name"/. "$BACKUP_DIR/$name"/
    else
      touch "$BACKUP_DIR/.absent-$name"
    fi
  done
  for name in settings.json mcp.json; do
    if [[ -f "$PI_HOME/$name" ]]; then
      cp "$PI_HOME/$name" "$BACKUP_DIR/$name"
    else
      touch "$BACKUP_DIR/.absent-$name"
    fi
  done

  cat >"$BACKUP_DIR/MANIFEST.txt" <<EOF
pi-setup backup
created: $(date -Is)
source: $PI_HOME
repo: $ROOT
revert: $ROOT/install.sh --revert "$BACKUP_DIR"
EOF
  echo "Created backup: $BACKUP_DIR"
}

revert_backup() {
  local backup="$1"
  if [[ ! -d "$backup" ]]; then
    echo "error: backup directory not found: $backup" >&2
    exit 1
  fi

  echo "Reverting live Pi setup from backup: $backup"
  for name in extensions themes skills; do
    if [[ -d "$backup/$name" ]]; then
      copy_dir_contents "$backup/$name" "$PI_HOME/$name"
    elif [[ -f "$backup/.absent-$name" ]]; then
      echo "Removing $PI_HOME/$name because it was absent when the backup was created."
      run rm -rf "$PI_HOME/$name"
    else
      echo "Backup has no $name/ state; leaving $PI_HOME/$name unchanged."
    fi
  done
  for name in settings.json mcp.json; do
    if [[ -f "$backup/$name" ]]; then
      copy_path "$backup/$name" "$PI_HOME/$name"
    elif [[ -f "$backup/.absent-$name" ]]; then
      echo "Removing $PI_HOME/$name because it was absent when the backup was created."
      run rm -f "$PI_HOME/$name"
    else
      echo "Backup has no $name state; leaving $PI_HOME/$name unchanged."
    fi
  done
  echo "Revert complete. Restart Pi or run /reload in an existing session."
}

remove_legacy_package_reference() {
  local settings="$PI_HOME/settings.json"
  [[ -f "$settings" ]] || return 0

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Skipping legacy package-reference cleanup: python3 not found."
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would remove legacy active package references to $ROOT from $settings"
    return 0
  fi

  python3 - <<'PY' "$settings" "$ROOT"
import json
import sys
from pathlib import Path

settings = Path(sys.argv[1])
root = Path(sys.argv[2]).resolve()
try:
    data = json.loads(settings.read_text())
except Exception as exc:
    raise SystemExit(f"error: failed to parse {settings}: {exc}")

packages = data.get("packages")
if not isinstance(packages, list):
    raise SystemExit(0)

changed = False
kept = []
for item in packages:
    source = item.get("source") if isinstance(item, dict) else item
    remove = False
    if isinstance(source, str) and not source.startswith(("npm:", "git:", "http://", "https://", "ssh://")):
        try:
            candidate = (settings.parent / source).expanduser().resolve()
        except Exception:
            candidate = None
        remove = candidate == root
    if remove:
        changed = True
    else:
        kept.append(item)

if changed:
    data["packages"] = kept
    settings.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Removed legacy active package reference to {root} from {settings}")
PY
}

if [[ -n "$REVERT_DIR" ]]; then
  revert_backup "$REVERT_DIR"
  exit 0
fi

run mkdir -p "$PI_HOME"
make_backup
remove_legacy_package_reference

if [[ "$RESTORE" == "1" ]]; then
  echo "Restoring repo resources into live Pi home: $PI_HOME"
  copy_dir_contents "$ROOT/extensions" "$PI_HOME/extensions"
  copy_dir_contents "$ROOT/themes" "$PI_HOME/themes"
  copy_dir_contents "$ROOT/skills" "$PI_HOME/skills"
else
  echo "Skipping resource restore. To copy repo resources into $PI_HOME, run: ./install.sh --restore"
fi

if [[ "$COPY_CONFIG" == "1" ]]; then
  echo "Copying example config into $PI_HOME/"
  copy_path "$ROOT/config/settings.example.json" "$PI_HOME/settings.json"
  if [[ -f "$ROOT/config/mcp.example.json" ]]; then
    copy_path "$ROOT/config/mcp.example.json" "$PI_HOME/mcp.json"
  fi
  remove_legacy_package_reference
else
  echo "Skipping config copy. To copy settings/mcp examples, run: ./install.sh --copy-config"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "would run: $ROOT/setup_sync.sh"
else
  "$ROOT/setup_sync.sh"
fi

if [[ -f "$ROOT/bin/pi" ]]; then
  run mkdir -p "$BIN_DIR"
  run cp "$ROOT/bin/pi" "$BIN_DIR/pi"
  run chmod +x "$BIN_DIR/pi"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would install compact Pi launcher: $BIN_DIR/pi"
  else
    echo "Installed compact Pi launcher: $BIN_DIR/pi"
  fi
  if [[ -z "${PI_REAL_BIN:-}" && ! -x /usr/local/bin/pi && ! -x /usr/bin/pi && ! -x /opt/homebrew/bin/pi ]]; then
    echo "Warning: no existing Pi binary found. Install Pi first, or set PI_REAL_BIN before running the launcher."
  fi
fi

if [[ -n "$BACKUP_DIR" ]]; then
  echo "To revert this install: $ROOT/install.sh --revert '$BACKUP_DIR'"
fi

echo "Done. Restart Pi or run /reload in an existing session."
echo "Sync live Pi tweaks back here with: pi-setup-sync"
