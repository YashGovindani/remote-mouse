# Remote Mouse (DIY)

Control this Mac's cursor, clicks, scrolling, typing and media keys from a phone on the same Wi-Fi.
No app to install on the phone: the Mac serves a touchpad web page, the phone talks to it over a WebSocket,
and the Mac injects the events with CoreGraphics.

## The app (`~/Applications/Remote Mouse.app`)

A native menu bar app, built from `app/` with the command line tools only (no Xcode):

- **Menu bar icon** (cursor with rays): click it and the QR code + link are right there, with the connection status.
  Copy Phone Link, Open in Browser, New Link (invalidates the old one), Restart Server, Quit.
- **Desktop QR widget**: a card pinned to the desktop, above the wallpaper and icons, under every window. Drag it anywhere;
  the spot is remembered. It hides itself while a phone is connected and comes back when none is. Toggle it in the menu.
- **Start at Login**: registered automatically on first launch (menu checkmark shows the state, also visible in
  System Settings > General > Login Items & Extensions).
- **Stable link**: the token is generated once and kept, so the phone's bookmark / home-screen shortcut keeps working
  across restarts. The Mac's IP is re-checked every few seconds and the QR updates if it changes.
- **Accessibility**: macOS asks on first launch. Enable "Remote Mouse" under System Settings > Privacy & Security >
  Accessibility (the menu shows a warning item and opens the pane until it's granted).

Build / reinstall:

```sh
app/build.sh --install     # compiles, signs, copies to ~/Applications, then: open -a "Remote Mouse"
```

Note: the app is ad-hoc signed, so **each rebuild changes its identity and macOS resets the Accessibility grant**.
After a rebuild, open the Accessibility pane, remove the old "Remote Mouse" entry (−) and enable the new one.
To avoid that, create a self-signed "Code Signing" certificate in Keychain Access and build with
`RM_SIGN="<cert name>" app/build.sh --install`.

Settings live in `defaults` domain `com.yashg.remote-mouse` (`token`, `port` default 7070, `widget`).

## Phone gestures

| Gesture | Action |
|---|---|
| one finger drag | move cursor |
| tap / double tap | left click / double click |
| two-finger tap | right click |
| two-finger drag | scroll |
| hold still ~0.5s, then drag | drag (pad outline turns blue) |
| Left / Mid / Right buttons | hold to drag |
| ⛶ | fullscreen trackpad: the whole screen is the pad; tap the pill top-right to exit |
| ⌨︎ | keyboard panel: type text, esc/tab/arrows/enter, ⌘space, ⌘tab, fullscreen |
| ⚙︎ | pointer speed, scroll speed, invert scroll, rotate input |

Media row: previous / play-pause / next / mute / volume down / volume up.
Landscape: turn the phone and the controls move to a column on the right. With rotation lock on, set **Rotate input**
to the side you turned the phone. Add the page to the phone's home screen for a full-screen app feel.

## Files

- `app/Sources/*.swift` — menu bar app: `Server.swift` (HTTP + WebSocket on Network.framework), `Injector.swift`
  (CGEvent injection), `Widget.swift` (QR card + desktop panel), `AppDelegate.swift` (menu, login item, IP polling)
- `app/build.sh`, `app/Info.plist`, `app/make_icon.py` — build, bundle metadata, icon generator
- `index.html` — the touchpad page, bundled into the app at build time
- `server.py` + `run.sh` — the original Python server, still usable as a CLI alternative (`./run.sh`, needs Accessibility
  for the terminal app; `.venv` via `uv venv .venv && uv pip install --python .venv/bin/python pyobjc-framework-Quartz pyobjc-framework-ApplicationServices websockets qrcode`)

## Protocol (JSON over WebSocket at `/ws?k=TOKEN`)

`{"t":"move","dx":..,"dy":..}` · `{"t":"click","b":"left|right|middle","n":1|2}` · `{"t":"down"/"up","b":..,"n":..}` ·
`{"t":"scroll","dx":..,"dy":..,"mods":["ctrl"]}` · `{"t":"text","s":"hello"}` · `{"t":"key","code":"enter","mods":["cmd"]}` ·
`{"t":"media","name":"play|next|prev|volup|voldown|mute"}` · `{"t":"ping"}` → `{"t":"pong"}`
