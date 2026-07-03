#!/usr/bin/env bash
# Rebuild Wheredo.app then trigger Screen Recording registration (does NOT reset Microphone).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Wheredo.app"

"$ROOT/scripts/install-app.sh" --no-setup

echo ""
echo "Opening Wheredo screen-capture setup (via Launch Services)…"
open -W -n -a "$APP" --args --setup-screen-capture --launched-via-open

echo ""
echo "If Wheredo is still missing from the list, add manually:"
echo "  System Settings → Screen & System Audio Recording → +"
echo "  Press ⌘⇧G and paste: $APP"
echo ""
echo "Test capture:"
echo "  open -a Wheredo --args --test-capture --launched-via-open"
