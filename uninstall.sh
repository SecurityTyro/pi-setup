#!/usr/bin/env bash
set -euo pipefail

# Remove only changes installed/restored by this pi-setup checkout.
# Usage:
#   ./uninstall.sh              # remove pi-setup launcher/sync helper/resources
#   ./uninstall.sh --dry-run    # show what would be removed

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_HOME="${PI_HOME:-$HOME/.pi/agent}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Remove only changes installed/restored by this pi-setup checkout.

Usage:
  ./uninstall.sh              # remove pi-setup launcher/sync helper/resources
  ./uninstall.sh --dry-run    # show what would be removed
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
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

same_file_contents() {
  local a="$1" b="$2"
  [[ -f "$a" && -f "$b" ]] || return 1
  cmp -s "$a" "$b"
}

remove_if_matches_file() {
  local live="$1" repo="$2"
  [[ -e "$live" ]] || return 0
  if same_file_contents "$live" "$repo"; then
    echo "Removing $live"
    run rm -f "$live"
  else
    echo "Leaving modified file: $live"
  fi
}

remove_restored_tree_entries() {
  local repo_dir="$1" live_dir="$2"
  [[ -d "$repo_dir" && -d "$live_dir" ]] || return 0

  local entry name live_entry
  while IFS= read -r entry; do
    name="$(basename "$entry")"
    live_entry="$live_dir/$name"
    [[ -e "$live_entry" || -L "$live_entry" ]] || continue

    # install.sh --restore copies these entries from the repo. Remove the live
    # entry by name only for entries this repo owns; do not touch unrelated Pi
    # resources in the same directory.
    echo "Removing restored resource $live_entry"
    run rm -rf "$live_entry"
  done < <(find "$repo_dir" -mindepth 1 -maxdepth 1 | sort)
}

remove_self_package_reference() {
  local settings="$PI_HOME/settings.json"
  [[ -f "$settings" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would remove active package references to $ROOT from $settings"
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
except Exception:
    raise SystemExit(0)
packages = data.get("packages")
if not isinstance(packages, list):
    raise SystemExit(0)
kept = []
changed = False
for item in packages:
    source = item.get("source") if isinstance(item, dict) else item
    remove = False
    if isinstance(source, str) and not source.startswith(("npm:", "git:", "http://", "https://", "ssh://")):
        try:
            remove = (settings.parent / source).expanduser().resolve() == root
        except Exception:
            remove = False
    if remove:
        changed = True
    else:
        kept.append(item)
if changed:
    data["packages"] = kept
    settings.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Removed active package reference to {root} from {settings}")
PY
}

remove_launcher() {
  local launcher="$BIN_DIR/pi"
  [[ -f "$launcher" || -L "$launcher" ]] || return 0
  if grep -q "Personal Pi launcher" "$launcher" 2>/dev/null; then
    echo "Removing compact Pi launcher $launcher"
    run rm -f "$launcher"
  else
    echo "Leaving non-pi-setup launcher: $launcher"
  fi
}

remove_sync_helper() {
  local helper="$BIN_DIR/pi-setup-sync"
  [[ -e "$helper" || -L "$helper" ]] || return 0
  local target=""
  if [[ -L "$helper" ]]; then
    target="$(readlink "$helper")"
    [[ "$target" == /* ]] || target="$(cd "$(dirname "$helper")" && pwd)/$target"
    if [[ "$(readlink -f "$target" 2>/dev/null || true)" == "$(readlink -f "$ROOT/sync.sh" 2>/dev/null || true)" ]]; then
      echo "Removing sync helper $helper"
      run rm -f "$helper"
    else
      echo "Leaving unrelated sync helper: $helper -> $(readlink "$helper")"
    fi
  elif grep -q "Sync current ~/.pi/agent customizations into this repo" "$helper" 2>/dev/null; then
    echo "Removing copied sync helper $helper"
    run rm -f "$helper"
  else
    echo "Leaving non-pi-setup helper: $helper"
  fi
}

remove_launcher
remove_sync_helper
remove_restored_tree_entries "$ROOT/extensions" "$PI_HOME/extensions"
remove_restored_tree_entries "$ROOT/themes" "$PI_HOME/themes"
remove_restored_tree_entries "$ROOT/skills" "$PI_HOME/skills"
remove_if_matches_file "$PI_HOME/settings.json" "$ROOT/config/settings.example.json"
remove_if_matches_file "$PI_HOME/mcp.json" "$ROOT/config/mcp.example.json"
remove_self_package_reference

echo "Done. Pi's own installation is untouched. If your shell cached $BIN_DIR/pi, run: hash -r"
