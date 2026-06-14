#!/usr/bin/env bash
set -euo pipefail

# End-to-end pi-setup smoke test, intentionally outside CI.
#
# This tests the real user flow in a fresh Ubuntu container:
#   git clone <remote> -> ./install.sh --restore --copy-config -> ~/.pi/agent
# and then verifies the backup flow:
#   ~/.pi/agent change -> pi-setup-sync --no-push -> repo commit

IMAGE="ubuntu:24.04"
REMOTE=""
BRANCH=""
RUN_SYNC=1

usage() {
  cat <<'EOF'
Usage: tests/docker-e2e.sh [options]

Options:
  --remote URL      Git remote to clone inside the container.
                    Defaults to this checkout's origin, converting GitHub SSH
                    remotes to HTTPS when possible.
  --branch NAME     Branch to clone. Defaults to this checkout's current branch.
  --image IMAGE     Docker image. Default: ubuntu:24.04
  --restore-only    Test clone + restore only; skip the pi-setup-sync backup smoke.
  -h, --help        Show this help.

Examples:
  tests/docker-e2e.sh
  tests/docker-e2e.sh --remote https://github.com/abhinand5/pi-setup.git --branch main
  tests/docker-e2e.sh --restore-only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      REMOTE="${2:?missing value for --remote}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:?missing value for --branch}"
      shift 2
      ;;
    --image)
      IMAGE="${2:?missing value for --image}"
      shift 2
      ;;
    --restore-only)
      RUN_SYNC=0
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required" >&2
  exit 1
fi

if [[ -z "$REMOTE" ]]; then
  REMOTE="$(git -C "$ROOT" config --get remote.origin.url || true)"
  if [[ -z "$REMOTE" ]]; then
    echo "error: could not infer remote.origin.url; pass --remote" >&2
    exit 1
  fi
fi

# A fresh container usually has no SSH credentials. For public GitHub repos,
# convert common SSH remotes to HTTPS so the test behaves like a fresh user clone.
if [[ "$REMOTE" =~ ^git@github.com:(.+)$ ]]; then
  REMOTE="https://github.com/${BASH_REMATCH[1]}"
elif [[ "$REMOTE" =~ ^ssh://git@github.com/(.+)$ ]]; then
  REMOTE="https://github.com/${BASH_REMATCH[1]}"
fi

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  if [[ "$BRANCH" == "HEAD" ]]; then
    BRANCH=""
  fi
fi

CONTAINER="pi-setup-e2e-$(date +%s)"

echo "Docker image: $IMAGE"
echo "Remote:       $REMOTE"
[[ -n "$BRANCH" ]] && echo "Branch:       $BRANCH" || echo "Branch:       remote default"
echo "Container:    $CONTAINER"

docker run --rm \
  --name "$CONTAINER" \
  -e PI_SETUP_REMOTE="$REMOTE" \
  -e PI_SETUP_BRANCH="$BRANCH" \
  -e PI_SETUP_RUN_SYNC="$RUN_SYNC" \
  "$IMAGE" \
  bash -lc '
set -euo pipefail

. /etc/os-release
echo "ubuntu=$PRETTY_NAME"

apt-get update >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates >/dev/null

if command -v python3 >/dev/null 2>&1; then
  echo "python3_before_restore=present"
else
  echo "python3_before_restore=absent"
fi

mkdir -p /root/dev/ai-agents
cd /root/dev/ai-agents

if [[ -n "${PI_SETUP_BRANCH:-}" ]]; then
  git clone --branch "$PI_SETUP_BRANCH" "$PI_SETUP_REMOTE" pi-setup >/dev/null 2>&1
else
  git clone "$PI_SETUP_REMOTE" pi-setup >/dev/null 2>&1
fi

cd pi-setup
echo "commit=$(git rev-parse --short HEAD)"

./install.sh --restore --copy-config

cat > /usr/local/bin/pi <<PI_FAKE
#!/usr/bin/env bash
echo 0.0.0-container
PI_FAKE
chmod +x /usr/local/bin/pi
/root/.local/bin/pi --version | grep -q "0.0.0-container"

printf "\nVERIFY RESTORE\n"
test -d /root/.pi/agent/extensions
test -d /root/.pi/agent/themes
test -d /root/.pi/agent/skills
test -f /root/.pi/agent/settings.json
test -f /root/.pi/agent/mcp.json
test -x /root/.local/bin/pi
test -L /root/.local/bin/pi-setup-sync

ext_count=$(find /root/.pi/agent/extensions -type f | wc -l)
theme_count=$(find /root/.pi/agent/themes -type f -name "*.json" | wc -l)
skill_count=$(find /root/.pi/agent/skills -type f -name "SKILL.md" | wc -l)
echo "extensions=$ext_count themes=$theme_count skills=$skill_count"
test "$ext_count" -gt 0
test "$theme_count" -gt 0
test "$skill_count" -gt 0

if grep -q "pi-setup" /root/.pi/agent/settings.json; then
  echo "error: settings contains a pi-setup self-reference" >&2
  cat /root/.pi/agent/settings.json >&2
  exit 1
fi
if grep -Eq '"(defaultProvider|defaultModel|enabledModels)"' /root/.pi/agent/settings.json; then
  echo "error: example settings should not contain personal model/provider selections" >&2
  cat /root/.pi/agent/settings.json >&2
  exit 1
fi

grep -q "\"extensions\": \[\]" package.json
grep -q "\"skills\": \[\]" package.json
grep -q "\"themes\": \[\]" package.json

printf "\nVERIFY SYNC HELPER TARGET\n"
/root/.local/bin/pi-setup-sync --dry-run | tee /tmp/dry-run.txt
grep -q "into /root/dev/ai-agents/pi-setup" /tmp/dry-run.txt
if grep -q "into /root/.local/bin" /tmp/dry-run.txt; then
  echo "error: pi-setup-sync resolved ROOT to ~/.local/bin" >&2
  exit 1
fi

if [[ "$PI_SETUP_RUN_SYNC" == "1" ]]; then
  printf "\nVERIFY BACKUP/SYNC PATH\n"
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3 >/dev/null
  git config user.email container@example.invalid
  git config user.name "Container Test"
  printf "\n// container-sync-smoke\n" >> /root/.pi/agent/extensions/flow-title.ts
  /root/.local/bin/pi-setup-sync --all-skills --no-push "Container sync smoke"
  git log --oneline -1 | grep -q "Container sync smoke"
  grep -q "container-sync-smoke" extensions/flow-title.ts
fi

printf "\nVERIFY UNINSTALL\n"
./uninstall.sh
test -x /usr/local/bin/pi
test ! -e /root/.local/bin/pi
test ! -e /root/.local/bin/pi-setup-sync
test ! -e /root/.pi/agent/themes/nebula-pulse.json

echo "remote clone pi-setup e2e passed"
'
