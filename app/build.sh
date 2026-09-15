#!/bin/sh
# Build Remote Mouse.app with the Xcode Command Line Tools (no Xcode needed), sign it, and with --install copy it to ~/Applications.
# Usage: ./build.sh [--install]      (optional: RM_SIGN="Cert Name" to sign with your own certificate)
set -e
cd "$(dirname "$0")"
APP="build/Remote Mouse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f AppIcon.icns ] || "$(cd .. && pwd)/.venv/bin/python" make_icon.py AppIcon.icns
# WebRTC (UDP-like data channel for move/scroll events): prebuilt framework from github.com/stasel/WebRTC, cached in build/
WEBRTC_VERSION="153.0.0"
WEBRTC_FW="build/webrtc/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework"
if [ ! -d "$WEBRTC_FW" ]; then
  echo "downloading WebRTC M153 framework (~45 MB, once)"
  mkdir -p build/webrtc
  curl -fL -o build/webrtc/webrtc.zip "https://github.com/stasel/WebRTC/releases/download/$WEBRTC_VERSION/WebRTC-M153.xcframework.zip"
  unzip -q -o build/webrtc/webrtc.zip -d build/webrtc
fi
WEBRTC_DIR="$(cd "$(dirname "$WEBRTC_FW")" && pwd)"
# universal binary: Apple Silicon + Intel
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -framework Cocoa -framework Network -framework ServiceManagement -framework CoreImage \
    -F "$WEBRTC_DIR" -framework WebRTC -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/*.swift -o "build/RemoteMouse-$arch"
done
lipo -create build/RemoteMouse-arm64 build/RemoteMouse-x86_64 -output "$APP/Contents/MacOS/RemoteMouse"
rm -f build/RemoteMouse-arm64 build/RemoteMouse-x86_64
mkdir -p "$APP/Contents/Frameworks"
cp -R "$WEBRTC_FW" "$APP/Contents/Frameworks/"
cp Info.plist "$APP/Contents/"
cp ../index.html ../manifest.json ../icons/icon-*.png AppIcon.icns "$APP/Contents/Resources/"
# Signing identity: RM_SIGN if set, else a "Remote Mouse Dev" certificate if one exists in the keychain (see README,
# "Local development"), else ad hoc ("-"). Ad-hoc signing changes the app identity on every build, which makes macOS
# forget the Accessibility grant; a certificate keeps the identity stable across rebuilds.
SIGN_ID="${RM_SIGN:-}"
if [ -z "$SIGN_ID" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Remote Mouse Dev"'; then
  SIGN_ID="Remote Mouse Dev"
fi
SIGN_ID="${SIGN_ID:--}"
echo "signing with: $SIGN_ID"
codesign --force --deep --sign "$SIGN_ID" "$APP"
if [ "$1" = "--install" ]; then
  pkill -x RemoteMouse 2>/dev/null || true
  rm -rf "$HOME/Applications/Remote Mouse.app"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/"
  echo "installed to ~/Applications/Remote Mouse.app"
fi
echo "built $APP"
