#!/bin/bash
# Bundle a static ffprobe into AvidMXFPeek.
#
# Usage:
#   ./bundle-ffprobe.sh <path-to-ffprobe>
#
# Source: https://www.martin-riedl.de/ — download the static arm64 build.
# Do NOT use Homebrew's ffprobe: it's dynamically linked to ~30 dylibs and
# will not run from the app bundle under hardened runtime.

set -e

RESOURCES_DIR="01_Project/AvidMXFPeek/Resources"

if [ -z "$1" ]; then
    echo "Error: path to ffprobe required."
    echo ""
    echo "Usage: ./bundle-ffprobe.sh /path/to/ffprobe"
    echo ""
    echo "Download a static arm64 build from https://www.martin-riedl.de/"
    exit 1
fi

FFPROBE_PATH="$1"

if [ ! -x "$FFPROBE_PATH" ]; then
    echo "Error: $FFPROBE_PATH is not executable."
    exit 1
fi

# Reject non-static builds: anything outside /usr/lib or /System/Library is a dylib dep.
NON_SYSTEM_DEPS=$(otool -L "$FFPROBE_PATH" | tail -n +2 | awk '{print $1}' \
    | grep -vE '^(/usr/lib/|/System/)' || true)
if [ -n "$NON_SYSTEM_DEPS" ]; then
    echo "Error: $FFPROBE_PATH has non-system dynamic dependencies:"
    echo "$NON_SYSTEM_DEPS" | sed 's/^/  /'
    echo ""
    echo "This won't run from the app bundle under hardened runtime."
    echo "Use a static arm64 build from https://www.martin-riedl.de/ instead."
    exit 1
fi

echo "Found ffprobe at: $FFPROBE_PATH"
echo "Version: $("$FFPROBE_PATH" -version | head -1)"
echo ""

mkdir -p "$RESOURCES_DIR"
DEST="$RESOURCES_DIR/ffprobe"
if [ "$(cd "$(dirname "$FFPROBE_PATH")" && pwd)/$(basename "$FFPROBE_PATH")" \
   = "$(cd "$(dirname "$DEST")" && pwd)/$(basename "$DEST")" ]; then
    echo "Source is already the bundled copy — nothing to do."
else
    cp "$FFPROBE_PATH" "$DEST"
    chmod +x "$DEST"
    echo "Copied to $DEST"
fi

echo ""
echo "Next: run ./sign-bundled-binaries.sh to codesign for hardened runtime."
