#!/usr/bin/env python3
"""Remote Mouse — control this Mac's cursor and keyboard from a phone on the same Wi-Fi.

Serves a touchpad web page over HTTP and receives events over a WebSocket.
Events are injected with Quartz (CoreGraphics), which needs Accessibility permission
for the app that runs this script (Terminal / iTerm / VS Code ...).
"""
import argparse
import asyncio
import json
import os
import secrets
import socket
import sys
from http import HTTPStatus
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import Quartz
from AppKit import NSEvent
from ApplicationServices import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
from websockets.asyncio.server import serve
from websockets.datastructures import Headers
from websockets.http11 import Response

HERE = Path(__file__).resolve().parent
WEB_FILES = {  # path -> (file, content type)
    "/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/manifest.json": ("manifest.json", "application/manifest+json"),
    "/icon-180.png": ("icons/icon-180.png", "image/png"), "/icon-192.png": ("icons/icon-192.png", "image/png"),
    "/icon-512.png": ("icons/icon-512.png", "image/png"),
}
DEBUG = os.environ.get("RM_DEBUG") == "1"   # print every event received from the phone

# --------------------------------------------------------------------------- input injection

KEYCODES = {
    "enter": 36, "return": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "esc": 53,
    "delete": 117, "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
    "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
}
MODIFIERS = {
    "cmd": Quartz.kCGEventFlagMaskCommand, "shift": Quartz.kCGEventFlagMaskShift,
    "alt": Quartz.kCGEventFlagMaskAlternate, "opt": Quartz.kCGEventFlagMaskAlternate,
    "ctrl": Quartz.kCGEventFlagMaskControl, "fn": Quartz.kCGEventFlagMaskSecondaryFn,
}
# NX_KEYTYPE_* values used by the system-defined media key events
MEDIA_KEYS = {"volup": 0, "voldown": 1, "mute": 7, "play": 16, "next": 17, "prev": 18,
              "brightup": 2, "brightdown": 3}
BUTTONS = {
    "left": (Quartz.kCGMouseButtonLeft, Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp,
             Quartz.kCGEventLeftMouseDragged),
    "right": (Quartz.kCGMouseButtonRight, Quartz.kCGEventRightMouseDown, Quartz.kCGEventRightMouseUp,
              Quartz.kCGEventRightMouseDragged),
    "middle": (Quartz.kCGMouseButtonCenter, Quartz.kCGEventOtherMouseDown, Quartz.kCGEventOtherMouseUp,
               Quartz.kCGEventOtherMouseDragged),
}


class Injector:
    """Turns JSON messages from the phone into CoreGraphics events."""

    def __init__(self):
        self.held = []          # buttons currently pressed, in press order
        self.rem_x = 0.0        # sub-pixel remainder so slow moves still add up
        self.rem_y = 0.0

    @staticmethod
    def cursor():
        p = Quartz.CGEventGetLocation(Quartz.CGEventCreate(None))
        return p.x, p.y

    @staticmethod
    def bounds():
        _, ids, n = Quartz.CGGetActiveDisplayList(16, None, None)
        rects = [Quartz.CGDisplayBounds(d) for d in ids[:n]]
        x0 = min(r.origin.x for r in rects)
        y0 = min(r.origin.y for r in rects)
        x1 = max(r.origin.x + r.size.width for r in rects)
        y1 = max(r.origin.y + r.size.height for r in rects)
        return x0, y0, x1 - 1, y1 - 1

    def _post_mouse(self, etype, x, y, button=Quartz.kCGMouseButtonLeft, clicks=1):
        ev = Quartz.CGEventCreateMouseEvent(None, etype, (x, y), button)
        Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGMouseEventClickState, clicks)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)

    def move(self, dx, dy):
        x, y = self.cursor()
        self.rem_x += dx
        self.rem_y += dy
        ix, iy = int(self.rem_x), int(self.rem_y)
        self.rem_x -= ix
        self.rem_y -= iy
        x0, y0, x1, y1 = self.bounds()
        nx = min(max(x + ix, x0), x1)
        ny = min(max(y + iy, y0), y1)
        if self.held:
            btn, _, _, dragged = BUTTONS[self.held[-1]]
            self._post_mouse(dragged, nx, ny, btn)
        else:
            self._post_mouse(Quartz.kCGEventMouseMoved, nx, ny)

    def button(self, name, down, clicks=1):
        btn, down_t, up_t, _ = BUTTONS[name]
        x, y = self.cursor()
        self._post_mouse(down_t if down else up_t, x, y, btn, clicks)
        if down and name not in self.held:
            self.held.append(name)
        elif not down and name in self.held:
            self.held.remove(name)

    def click(self, name="left", clicks=1):
        self.button(name, True, clicks)
        self.button(name, False, clicks)

    def release_all(self):
        for name in list(self.held):
            self.button(name, False)

    def scroll(self, dx, dy, mods=()):
        ev = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitPixel, 2, int(dy), int(dx))
        flags = 0
        for m in mods:
            flags |= MODIFIERS.get(m, 0)
        if flags:
            Quartz.CGEventSetFlags(ev, flags)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


    def text(self, s):
        for ch in s:
            for down in (True, False):
                ev = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
                Quartz.CGEventKeyboardSetUnicodeString(ev, len(ch), ch)
                Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)

    # modifier keys are pressed for real around the key: system hotkeys (Mission Control, Spotlight) watch the
    # modifier state, not just the flags on the key event
    MODIFIER_KEYS = [("cmd", 55), ("shift", 56), ("alt", 58), ("opt", 58), ("ctrl", 59), ("fn", 63)]

    def _post_key(self, vk, down, flags):
        ev = Quartz.CGEventCreateKeyboardEvent(None, vk, down)
        Quartz.CGEventSetFlags(ev, Quartz.CGEventGetFlags(ev) | flags)   # keep the fn/numpad flags arrow keys carry
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)

    def key(self, code, mods=()):
        vk = KEYCODES.get(code.lower())
        if vk is None:
            return
        held = []
        for name, mvk in self.MODIFIER_KEYS:
            if name in mods and mvk not in [h[0] for h in held]:
                held.append((mvk, MODIFIERS[name]))
        flags = 0
        for mvk, flag in held:
            flags |= flag
            self._post_key(mvk, True, flags)
        self._post_key(vk, True, flags)
        self._post_key(vk, False, flags)
        for mvk, flag in reversed(held):
            flags &= ~flag
            self._post_key(mvk, False, flags)

    def media(self, name):
        key = MEDIA_KEYS.get(name)
        if key is None:
            return
        for down in (True, False):
            state = 0xA if down else 0xB
            ev = NSEvent.otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2_(
                14, (0, 0), state << 8, 0, 0, None, 8, (key << 16) | (state << 8), -1)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev.CGEvent())

    def handle(self, m):
        t = m.get("t")
        if t == "move":
            self.move(float(m.get("dx", 0)), float(m.get("dy", 0)))
        elif t == "click":
            self.click(m.get("b", "left"), int(m.get("n", 1)))
        elif t == "down":
            self.button(m.get("b", "left"), True, int(m.get("n", 1)))
        elif t == "up":
            self.button(m.get("b", "left"), False, int(m.get("n", 1)))
        elif t == "scroll":
            self.scroll(float(m.get("dx", 0)), float(m.get("dy", 0)), m.get("mods", ()))
        elif t == "text":
            self.text(str(m.get("s", "")))
        elif t == "key":
            self.key(str(m.get("code", "")), m.get("mods", ()))
        elif t == "media":
            self.media(str(m.get("name", "")))


# --------------------------------------------------------------------------- server

def local_ips():
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    for iface in ("en0", "en1"):
        ip = os.popen(f"ipconfig getifaddr {iface} 2>/dev/null").read().strip()
        if ip and ip not in ips:
            ips.append(ip)
    return ips


def print_qr(url):
    try:
        import qrcode
        qr = qrcode.QRCode(border=1)
        qr.add_data(url)
        qr.print_ascii(invert=True)
    except Exception:
        pass


def main():
    sys.stdout.reconfigure(line_buffering=True)
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=int(os.environ.get("RM_PORT", 7070)))
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--token", default=os.environ.get("RM_TOKEN") or secrets.token_urlsafe(6),
                    help="shared secret the phone must present (default: random per run)")
    ap.add_argument("--no-token", action="store_true", help="disable the token check (open to your whole LAN)")
    args = ap.parse_args()
    token = None if args.no_token else args.token

    trusted = AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: True})
    if not trusted:
        print("!! Accessibility permission is NOT granted to this terminal app.")
        print("   Events will be silently dropped until you allow it:")
        print("   System Settings > Privacy & Security > Accessibility > enable your terminal app,")
        print("   then restart this server.\n")

    inj = Injector()
    clients = set()

    def process_request(conn, request):
        u = urlparse(request.path)
        if u.path == "/ws":
            if token and parse_qs(u.query).get("k", [None])[0] != token:
                return conn.respond(HTTPStatus.UNAUTHORIZED, "bad token\n")
            return None  # proceed with the WebSocket handshake
        if u.path in WEB_FILES:
            file, ctype = WEB_FILES[u.path]
            body = (HERE / file).read_bytes()
            return Response(HTTPStatus.OK, "OK", Headers([("Content-Type", ctype), ("Content-Length", str(len(body))),
                                                          ("Cache-Control", "no-store"), ("Connection", "close")]), body)
        return conn.respond(HTTPStatus.NOT_FOUND, "not found\n")

    async def handler(ws):
        peer = ws.remote_address[0] if ws.remote_address else "?"
        clients.add(ws)
        print(f"+ phone connected from {peer}")
        try:
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except ValueError:
                    continue
                if DEBUG and msg.get("t") != "ping":
                    print("  <-", raw)
                if msg.get("t") == "ping":
                    await ws.send('{"t":"pong"}')
                    continue
                try:
                    inj.handle(msg)
                except Exception as e:  # never let one bad event kill the connection
                    print("event error:", e, msg)
        finally:
            clients.discard(ws)
            inj.release_all()
            print(f"- phone disconnected ({peer})")

    async def run():
        async with serve(handler, args.host, args.port, process_request=process_request,
                         max_size=64 * 1024, ping_interval=20, ping_timeout=20):
            ips = local_ips() or ["<your-mac-ip>"]
            q = f"?k={token}" if token else ""
            url = f"http://{ips[0]}:{args.port}/{q}"
            print(f"Remote Mouse running on port {args.port}. Open this on your phone (same Wi-Fi):\n")
            for ip in ips:
                print(f"   http://{ip}:{args.port}/{q}")
            print()
            print_qr(url)
            print("\nCtrl+C to stop.")
            await asyncio.Future()

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        inj.release_all()
        print("\nbye")


if __name__ == "__main__":
    main()
