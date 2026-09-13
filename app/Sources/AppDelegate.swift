import Cocoa
import ServiceManagement
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let injector = Injector()
    private var server: RemoteServer!
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let menuCard = QRCard(style: .menu)
    private var widget: WidgetWindow?
    private var timer: Timer?
    private var currentIP = ""
    private var trusted = false

    /// Files served to the phone (bundled into Resources by build.sh).
    private static let webFiles: [String: (file: String, type: String)] = [
        "/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
        "/manifest.json": ("manifest.json", "application/manifest+json"),
        "/icon-180.png": ("icon-180.png", "image/png"), "/icon-192.png": ("icon-192.png", "image/png"),
        "/icon-512.png": ("icon-512.png", "image/png"),
    ]

    private var token: String {
        get { defaults.string(forKey: "token") ?? "" }
        set { defaults.set(newValue, forKey: "token") }
    }
    private var port: UInt16 { let p = defaults.integer(forKey: "port"); return p > 0 ? UInt16(p) : 7070 }
    private var url: String { "http://\(currentIP.isEmpty ? "<no-wifi>" : currentIP):\(port)/?k=\(token)" }
    private var isInstalled: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Remote Mouse launching from %@", Bundle.main.bundlePath)
        NSApp.setActivationPolicy(.accessory)
        if token.isEmpty { token = Self.randomToken() }
        currentIP = Self.localIPs().first ?? ""
        trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)

        server = RemoteServer(port: port, token: token, injector: injector) { path in
            guard let f = Self.webFiles[path], let url = Bundle.main.url(forResource: f.file, withExtension: nil),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (data, f.type)
        }
        server.onChange = { [weak self] in self?.refresh() }
        server.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Remote Mouse")
            b.image?.isTemplate = true
        }
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()

        if defaults.object(forKey: "widget") == nil { defaults.set(true, forKey: "widget") }

        if !defaults.bool(forKey: "didFirstRun") {
            defaults.set(true, forKey: "didFirstRun")
            if isInstalled { try? SMAppService.mainApp.register() }     // start at login by default
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) { server.stop() }

    // ------------------------------------------------------------------ periodic checks
    private func poll() {
        let ip = Self.localIPs().first ?? ""
        let t = AXIsProcessTrusted()
        if ip != currentIP || t != trusted {
            NSLog("network/permission change: ip=%@ accessibility=%d", ip, t ? 1 : 0)
            currentIP = ip; trusted = t; refresh()
        }
    }

    private var statusText: String {
        if !server.isRunning { return server.lastError ?? "server stopped" }
        if currentIP.isEmpty { return "no Wi-Fi / network connection" }
        if !trusted { return "needs Accessibility permission" }
        let n = server.phoneCount
        return n == 0 ? "waiting for a phone" : "\(n) phone\(n == 1 ? "" : "s") connected"
    }
    private var ok: Bool { server.isRunning && !currentIP.isEmpty && trusted }

    private func refresh() {
        menuCard.update(url: url, statusText: statusText, ok: ok)
        statusItem.button?.toolTip = "Remote Mouse — \(statusText)"
        statusItem.button?.appearsDisabled = !ok
        updateWidget()
    }

    /// The desktop widget is only useful while no phone is connected: show it when the user has it enabled
    /// and nothing is connected, hide it as soon as a phone connects, bring it back when the phone leaves.
    private func updateWidget() {
        let shouldShow = defaults.bool(forKey: "widget") && server.isRunning && server.phoneCount == 0
        if shouldShow {
            if widget == nil { widget = WidgetWindow() }
            widget?.card.update(url: url, statusText: statusText, ok: ok)
            if !(widget?.isVisible ?? false) { widget?.orderFrontRegardless() }
        } else {
            widget?.orderOut(nil)
        }
    }

    // ------------------------------------------------------------------ menu
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let card = NSMenuItem()
        card.view = menuCard
        menu.addItem(card)
        menu.addItem(.separator())
        menu.addItem(item("Copy Phone Link", #selector(copyLink)))
        menu.addItem(item("Open in Browser", #selector(openInBrowser)))
        menu.addItem(item("New Link (invalidate old one)", #selector(resetToken)))
        menu.addItem(.separator())
        let w = item("Show QR Widget", #selector(toggleWidget))
        w.state = defaults.bool(forKey: "widget") ? .on : .off
        menu.addItem(w)
        let l = item("Start at Login", #selector(toggleLogin)); l.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(l)
        menu.addItem(.separator())
        if !trusted { menu.addItem(item("⚠︎ Grant Accessibility Access…", #selector(openAccessibility))) }
        menu.addItem(item("Restart Server", #selector(restartServer)))
        menu.addItem(item("Quit Remote Mouse", #selector(quit), key: "q"))
        refresh()
    }

    @objc private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    @objc private func openInBrowser() { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
    @objc private func resetToken() {
        token = Self.randomToken()
        server.token = token
        server.restart()
        refresh()
    }
    @objc private func toggleWidget() {
        defaults.set(!defaults.bool(forKey: "widget"), forKey: "widget")
        updateWidget()
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Could not change the login item"
            a.informativeText = "\(error.localizedDescription)\n\nYou can also add Remote Mouse under System Settings > General > Login Items."
            a.runModal()
        }
    }
    @objc private func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }
    @objc private func restartServer() { server.restart() }
    @objc private func quit() { NSApp.terminate(nil) }

    // ------------------------------------------------------------------ helpers
    private static func randomToken() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    /// IPv4 addresses of Wi-Fi/Ethernet interfaces (en*), en0 first, link-local skipped.
    static func localIPs() -> [String] {
        var out: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") || ip.hasPrefix("127.") { continue }
            out.append((name, ip))
        }
        return out.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}
