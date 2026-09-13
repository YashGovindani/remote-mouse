import Cocoa

/// Turns JSON messages from the phone into CoreGraphics input events.
/// Needs Accessibility permission for this app, otherwise macOS silently drops the events.
final class Injector {
    private var held: [String] = []          // buttons currently pressed, in press order
    private var remX = 0.0, remY = 0.0       // sub-pixel remainders so slow moves still add up

    private struct Btn { let button: CGMouseButton; let down: CGEventType; let up: CGEventType; let drag: CGEventType }
    private static let buttons: [String: Btn] = [
        "left": Btn(button: .left, down: .leftMouseDown, up: .leftMouseUp, drag: .leftMouseDragged),
        "right": Btn(button: .right, down: .rightMouseDown, up: .rightMouseUp, drag: .rightMouseDragged),
        "middle": Btn(button: .center, down: .otherMouseDown, up: .otherMouseUp, drag: .otherMouseDragged),
    ]
    private static let keycodes: [String: CGKeyCode] = [
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
    ]
    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "shift": .maskShift, "alt": .maskAlternate, "opt": .maskAlternate,
        "ctrl": .maskControl, "fn": .maskSecondaryFn,
    ]
    // NX_KEYTYPE_* values used by the system-defined media key events
    private static let mediaKeys: [String: Int] = [
        "volup": 0, "voldown": 1, "mute": 7, "play": 16, "next": 17, "prev": 18, "brightup": 2, "brightdown": 3,
    ]

    private func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func bounds() -> CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        var r = CGRect.null
        for i in 0..<Int(n) { r = r.union(CGDisplayBounds(ids[i])) }
        return r.isNull ? CGRect(x: 0, y: 0, width: 1920, height: 1080) : r
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: clicks)
        ev.post(tap: .cghidEventTap)
    }

    private func flags(_ mods: [String]) -> CGEventFlags {
        var f = CGEventFlags()
        for m in mods { if let x = Injector.modifiers[m] { f.insert(x) } }
        return f
    }

    func move(dx: Double, dy: Double) {
        let c = cursor()
        remX += dx; remY += dy
        let ix = remX.rounded(.towardZero), iy = remY.rounded(.towardZero)
        remX -= ix; remY -= iy
        let b = bounds()
        let p = CGPoint(x: min(max(c.x + ix, b.minX), b.maxX - 1), y: min(max(c.y + iy, b.minY), b.maxY - 1))
        if let name = held.last, let btn = Injector.buttons[name] { post(btn.drag, at: p, button: btn.button) }
        else { post(.mouseMoved, at: p) }
    }

    func button(_ name: String, down: Bool, clicks: Int64 = 1) {
        guard let btn = Injector.buttons[name] else { return }
        post(down ? btn.down : btn.up, at: cursor(), button: btn.button, clicks: clicks)
        if down { if !held.contains(name) { held.append(name) } } else { held.removeAll { $0 == name } }
    }

    func click(_ name: String, clicks: Int64) {
        button(name, down: true, clicks: clicks)
        button(name, down: false, clicks: clicks)
    }

    func releaseAll() { for n in held { button(n, down: false) } }

    func scroll(dx: Double, dy: Double, mods: [String]) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        let f = flags(mods)
        if !f.isEmpty { ev.flags = f }
        ev.post(tap: .cghidEventTap)
    }

    func text(_ s: String) {
        for ch in s {
            var u = Array(ch.utf16)
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
                ev.post(tap: .cghidEventTap)
            }
        }
    }

    func key(_ code: String, mods: [String]) {
        guard let vk = Injector.keycodes[code.lowercased()] else { return }
        let f = flags(mods)
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: down) else { continue }
            if !f.isEmpty { ev.flags = f }
            ev.post(tap: .cghidEventTap)
        }
    }

    func media(_ name: String) {
        guard let key = Injector.mediaKeys[name] else { return }
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                        data1: (key << 16) | (state << 8), data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    func handle(_ m: [String: Any]) {
        func num(_ k: String) -> Double { (m[k] as? NSNumber)?.doubleValue ?? 0 }
        func str(_ k: String, _ d: String) -> String { m[k] as? String ?? d }
        let mods = m["mods"] as? [String] ?? []
        let n = Int64(max(1, num("n")))
        switch m["t"] as? String {
        case "move": move(dx: num("dx"), dy: num("dy"))
        case "click": click(str("b", "left"), clicks: n)
        case "down": button(str("b", "left"), down: true, clicks: n)
        case "up": button(str("b", "left"), down: false, clicks: n)
        case "scroll": scroll(dx: num("dx"), dy: num("dy"), mods: mods)
        case "text": text(str("s", ""))
        case "key": key(str("code", ""), mods: mods)
        case "media": media(str("name", ""))
        default: break
        }
    }
}
