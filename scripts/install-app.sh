#!/usr/bin/env bash
# Build release and install to ~/Applications/Wheredo.app with a STABLE signing identity.
# Stable signing = TCC permissions (Screen Recording, Microphone) survive rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Wheredo.app"
EXE="$APP/Contents/MacOS/Wheredo"
PLIST="$ROOT/Sources/Wheredo/Info.plist"
ENT="$ROOT/Sources/Wheredo/Entitlements.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

RUN_SETUP=0
for arg in "$@"; do
  if [[ "$arg" == "--setup" ]]; then RUN_SETUP=1; fi
done

# 1. Kill any running instance — old processes keep old code AND hold stale TCC state.
if pgrep -x Wheredo > /dev/null 2>&1; then
  echo "Stopping running Wheredo…"
  pkill -x Wheredo || true
  sleep 1
fi

echo "Building release…"
swift build -c release --package-path "$ROOT"

mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/release/Wheredo" "$EXE"
chmod +x "$EXE"
cp "$PLIST" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 2. Prefer a stable signing identity (Apple Development cert) over ad-hoc.
#    Ad-hoc signatures change CDHash on every build → macOS 26 TCC drops the grant.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -Eo '"[^"]+"' | head -1 | tr -d '"')"

if [[ -n "$IDENTITY" ]]; then
  echo "Signing with stable identity: $IDENTITY"
  codesign --force --deep --options runtime --sign "$IDENTITY" --entitlements "$ENT" "$APP" \
    || { echo "Stable signing failed, falling back to ad-hoc…"; codesign --force --deep --sign - --entitlements "$ENT" "$APP"; }
else
  echo "No signing identity found — using ad-hoc (permissions will reset on each rebuild)."
  codesign --force --deep --sign - --entitlements "$ENT" "$APP"
fi

codesign -dv "$APP" 2>&1 | grep -E "Signature|TeamIdentifier|Authority" || true

if [[ -x "$LSREGISTER" ]]; then
  echo "Registering with Launch Services…"
  "$LSREGISTER" -f "$APP"
fi

LOCAL_LINK="$ROOT/Wheredo.app"
if [[ -e "$LOCAL_LINK" && ! -L "$LOCAL_LINK" ]]; then
  rm -rf "$LOCAL_LINK"
fi
ln -sfn "$APP" "$LOCAL_LINK"

echo ""
echo "✓ Installed: $APP"

if [[ "$RUN_SETUP" -eq 1 ]]; then
  echo ""
  echo "Running full permission setup…"
  open -W -n -a "$APP" --args --setup-permissions --launched-via-open
fi

echo ""
echo "Launch: Spotlight (⌘Space → Wheredo) or open -a Wheredo"
