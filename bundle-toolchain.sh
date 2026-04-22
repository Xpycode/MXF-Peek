#!/bin/bash
# Bundle static Avid MXF Peek toolchain binaries into the app Resources.
#
# Usage:
#   ./bundle-toolchain.sh ffprobe=/path/to/ffprobe ffmpeg=/path/to/ffmpeg
#   ./bundle-toolchain.sh ffprobe=/path/to/ffprobe                          # ffprobe only
#   ./bundle-toolchain.sh ffmpeg=/path/to/ffmpeg                            # ffmpeg only
#
# Source for both binaries: https://www.martin-riedl.de/ — arm64 static builds.
# Do NOT use Homebrew's ffprobe / ffmpeg: they are dynamically linked to
# ~30 dylibs and will not run from the app bundle under hardened runtime.
#
# History: originally bundle-ffprobe.sh (2026-04-20-C pivot). Generalised to
# bundle-toolchain.sh (2026-04-22) when ffmpeg was added for the HLS player
# preview pipeline (see docs/plans/2026-04-22-player-hls.md).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/01_Project/AvidMXFPeek/Resources"

if [ $# -eq 0 ]; then
    cat <<'EOF'
Error: at least one binary path required.

Usage:
  ./bundle-toolchain.sh ffprobe=/path/to/ffprobe ffmpeg=/path/to/ffmpeg
  ./bundle-toolchain.sh ffprobe=/path/to/ffprobe
  ./bundle-toolchain.sh ffmpeg=/path/to/ffmpeg

Download static arm64 builds from https://www.martin-riedl.de/
EOF
    exit 1
fi

# Parse name=path arguments into parallel arrays.
declare -a NAMES
declare -a PATHS
for arg in "$@"; do
    name="${arg%%=*}"
    path="${arg#*=}"
    if [ -z "$name" ] || [ -z "$path" ] || [ "$name" = "$arg" ]; then
        echo "Error: argument '$arg' must be of form name=path (e.g. ffmpeg=/usr/local/bin/ffmpeg)"
        exit 1
    fi
    NAMES+=("$name")
    PATHS+=("$path")
done

echo "Validating binaries..."
for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    path="${PATHS[$i]}"

    if [ ! -x "$path" ]; then
        echo "  ✗ $name at $path is not executable."
        exit 1
    fi

    # Reject non-static builds: anything outside /usr/lib or /System/Library is a dylib dep.
    NON_SYSTEM_DEPS=$(otool -L "$path" | tail -n +2 | awk '{print $1}' \
        | grep -vE '^(/usr/lib/|/System/)' || true)
    if [ -n "$NON_SYSTEM_DEPS" ]; then
        echo "  ✗ $name at $path has non-system dynamic dependencies:"
        echo "$NON_SYSTEM_DEPS" | sed 's/^/      /'
        echo ""
        echo "This won't run from the app bundle under hardened runtime."
        echo "Use a static arm64 build from https://www.martin-riedl.de/ instead."
        exit 1
    fi

    echo "  ✓ $name: $path"
    echo "      version: $("$path" -version | head -1)"
done

echo ""
mkdir -p "$RESOURCES_DIR"

for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    src="${PATHS[$i]}"
    dest="$RESOURCES_DIR/$name"

    src_abs="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
    dest_abs="$(cd "$(dirname "$dest")" 2>/dev/null && pwd 2>/dev/null)/$(basename "$dest")"
    if [ "$src_abs" = "$dest_abs" ]; then
        echo "  = $name: source is already the bundled copy — skipping"
    else
        cp "$src" "$dest"
        chmod +x "$dest"
        echo "  → $name: copied to $dest"
    fi
done

echo ""
echo "Next: run ./sign-bundled-binaries.sh to codesign for hardened runtime."
