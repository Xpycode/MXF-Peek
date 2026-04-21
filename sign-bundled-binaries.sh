#!/bin/bash
#
# Sign the bundled ffprobe for distribution under hardened runtime.
#
# Usage:
#   ./sign-bundled-binaries.sh                    # Uses Apple Development cert (SHA-1 hash)
#   ./sign-bundled-binaries.sh "Developer ID Application: Your Name (TEAMID)"
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/01_Project/AvidMXFPeek/Resources"
FFPROBE="$RESOURCES_DIR/ffprobe"

if [ ! -x "$FFPROBE" ]; then
    echo "Error: $FFPROBE not found. Run ./bundle-ffprobe.sh first."
    exit 1
fi

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

echo "  Signing ffprobe"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" "$FFPROBE"

rm "$ENTITLEMENTS"

echo ""
echo "=== Verification ==="
flags=$(codesign -dv "$FFPROBE" 2>&1 | grep "flags=" | sed 's/.*flags=//')
team=$(codesign -dv "$FFPROBE" 2>&1 | grep "TeamIdentifier=" | sed 's/.*TeamIdentifier=//')
echo "  ffprobe: flags=$flags team=$team"

echo ""
echo "Done. ffprobe signed with Hardened Runtime."
echo ""
echo "Next steps:"
echo "  1. In Xcode: Build Settings > Enable Hardened Runtime = YES"
echo "  2. Build the app"
echo "  3. For notarization: xcrun notarytool submit ..."
