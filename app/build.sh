#!/bin/sh
# Build Remote Mouse.app with the command line tools (no Xcode needed), sign it ad hoc, install to ~/Applications.
set -e
cd "$(dirname "$0")"
APP="build/Remote Mouse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f AppIcon.icns ] || "$(cd .. && pwd)/.venv/bin/python" make_icon.py AppIcon.icns
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -framework Cocoa -framework Network -framework ServiceManagement -framework CoreImage \
  Sources/*.swift -o "$APP/Contents/MacOS/RemoteMouse"
cp Info.plist "$APP/Contents/"
cp ../index.html AppIcon.icns "$APP/Contents/Resources/"
# Ad-hoc signing ("-") changes the app identity on every build, which resets its Accessibility grant.
# To keep it stable, create a self-signed "Code Signing" certificate in Keychain Access and run: RM_SIGN="Cert Name" ./build.sh --install
codesign --force --deep --sign "${RM_SIGN:--}" "$APP"
if [ "$1" = "--install" ]; then
  pkill -x RemoteMouse 2>/dev/null || true
  rm -rf "$HOME/Applications/Remote Mouse.app"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/"
  echo "installed to ~/Applications/Remote Mouse.app"
fi
echo "built $APP"
