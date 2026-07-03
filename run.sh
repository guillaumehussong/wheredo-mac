#!/usr/bin/env bash
# Launch Wheredo WITHOUT rebuilding (rebuild only with ./scripts/install-app.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Wheredo.app/Contents/MacOS/Wheredo"

if [[ ! -x "$APP" ]]; then
  echo "Wheredo not installed. Run: ./scripts/install-app.sh --no-setup"
  exit 1
fi

exec "$APP" "$@"
