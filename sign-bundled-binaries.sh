#!/bin/bash
#
# Sign the bundled toolchain for distribution under hardened runtime.
#
# Usage:
#   ./sign-bundled-binaries.sh                    # Uses Apple Development cert (SHA-1 hash)
#   ./sign-bundled-binaries.sh "Developer ID Application: Your Name (TEAMID)"
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/01_Project/AvidMXFPeek/Resources"

# Binaries that require hardened-runtime signing. Add new tools here.
BINARIES=(ffprobe ffmpeg)

if [ -n "$1" ]; then
    IDENTITY="$1"
else
    # SHA-1 hash of Apple Development cert — avoids ambiguity with revoked certs.
    IDENTITY="2D26CB1211F32FD4E3C6EF413EC1EDD6F30631AA"
fi

echo "Signing with identity: $IDENTITY"
echo ""

ENTITLEMENTS=$(mktemp)
cat > "$ENTITLEMENTS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

missing=0
for name in "${BINARIES[@]}"; do
    binary="$RESOURCES_DIR/$name"
    if [ ! -x "$binary" ]; then
        echo "  ✗ $name not found at $binary — run ./bundle-toolchain.sh first."
        missing=1
        continue
    fi
    echo "  Signing $name"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" \
        --entitlements "$ENTITLEMENTS" "$binary"
done

rm "$ENTITLEMENTS"

if [ "$missing" -ne 0 ]; then
    echo ""
    echo "Error: one or more binaries missing. Run ./bundle-toolchain.sh and retry."
    exit 1
fi

echo ""
echo "=== Verification ==="
for name in "${BINARIES[@]}"; do
    binary="$RESOURCES_DIR/$name"
    flags=$(codesign -dv "$binary" 2>&1 | grep "flags=" | sed 's/.*flags=//')
    team=$(codesign -dv "$binary" 2>&1 | grep "TeamIdentifier=" | sed 's/.*TeamIdentifier=//')
    echo "  $name: flags=$flags team=$team"
done

echo ""
echo "Done. Bundled toolchain signed with Hardened Runtime."
echo ""
echo "Next steps:"
echo "  1. In Xcode: Build Settings > Enable Hardened Runtime = YES"
echo "  2. Build the app"
echo "  3. For notarization: xcrun notarytool submit ..."
