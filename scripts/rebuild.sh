#!/bin/bash
# Build and verify a new Claude Code Hub without disturbing the running app.
#
# This is the safe path to use while Claude conversations are live inside the
# Hub: it compiles, tests and assembles a fresh bundle, but never relaunches
# the app and never touches the helper unless asked. bundle.sh replaces the
# binaries with new files rather than writing in place, so running processes
# keep their old image until the user restarts them.
#
# Usage:
#   scripts/rebuild.sh              # build + test + bundle
#   scripts/rebuild.sh --no-test    # skip the test suite
#   scripts/rebuild.sh --helper     # also re-register and restart cch-agentd
#   CONFIG=release scripts/rebuild.sh
#
# To actually see the new build, relaunch it yourself:
#   scripts/bundle.sh --run
# That kills every Claude conversation running inside the Hub, which is why
# this script will not do it for you.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}"
RUN_TESTS=1
ENSURE_HELPER=0

for arg in "$@"; do
  case "$arg" in
    --no-test) RUN_TESTS=0 ;;
    --helper)  ENSURE_HELPER=1 ;;
    --run)
      echo "rebuild.sh does not relaunch: that would kill live Claude conversations." >&2
      echo "Run 'scripts/bundle.sh --run' yourself once you are ready." >&2
      exit 2
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: scripts/rebuild.sh [--no-test] [--helper]" >&2
      exit 2
      ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "Building ($CONFIG)"
swift build -c "$CONFIG"

if [[ $RUN_TESTS -eq 1 ]]; then
  step "Testing"
  # Surface just the verdict; the full log is noisy and swift test already
  # fails the script through set -e when anything breaks.
  swift test 2>&1 | tail -n 5
fi

step "Bundling"
CONFIG="$CONFIG" scripts/bundle.sh

if [[ $ENSURE_HELPER -eq 1 ]]; then
  step "Re-registering cch-agentd"
  # A rebuilt ad-hoc bundle cannot simply be restarted (launchd exits 78
  # EX_CONFIG); 'agentd ensure' unregisters, waits for the old job to go and
  # registers again. Subagent hosts survive this.
  build/ClaudeCodeHub.app/Contents/MacOS/cch-mcp agentd ensure
fi

cat <<EOF

Built build/ClaudeCodeHub.app ($CONFIG). The running app is untouched.
To pick up this build:  scripts/bundle.sh --run   (ends live conversations)
EOF
