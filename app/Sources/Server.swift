import Foundation
import Network
import CryptoKit

/// Minimal HTTP + WebSocket server on Network.framework: serves index.html and takes phone events on /ws?k=TOKEN.
final class RemoteServer {
    let port: UInt16
    var token: String
    let injector: Injector
    let resource: (String) -> (data: Data, type: String)?   // path -> file contents + content type
    let queue = DispatchQueue(label: "remote-mouse.server")
    var onChange: (() -> Void)?                 // called on the main queue whenever state or clients change
    private(set) var isRunning = false
    private(set) var lastError: String?
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var keepalive: DispatchSourceTimer?

    init(port: UInt16, token: String, injector: Injector, resource: @escaping (String) -> (data: Data, type: String)?) {
        self.port = port; self.token = token; self.injector = injector; self.resource = resource
    }

    var phoneCount: Int { queue.sync { clients.values.filter { $0.isWebSocket }.count } }

    func start() {
        queue.async { self.startLocked() }
    }

    private func startLocked() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else {
            lastError = "could not listen on port \(port)"; notify(); return
        }
        l.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready: self.isRunning = true; self.lastError = nil; NSLog("server listening on port %d", Int(self.port))
            case .failed(let e): self.isRunning = false; self.lastError = "port \(self.port): \(e.localizedDescription)"; NSLog("server failed: %@", self.lastError!)
            case .cancelled: self.isRunning = false; NSLog("server stopped")
            default: break
            }
            self.notify()
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let c = Client(conn, server: self)
            self.clients[ObjectIdentifier(c)] = c
            c.start()
        }
        l.start(queue: queue)
        listener = l
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler { [weak self] in self?.clients.values.forEach { if $0.isWebSocket { $0.ping() } } }
        t.resume()
        keepalive = t
    }

    func stop() {
        queue.async {
            self.keepalive?.cancel(); self.keepalive = nil
            self.listener?.cancel(); self.listener = nil
            self.clients.values.forEach { $0.finish() }
            self.clients.removeAll()
            self.injector.releaseAll()
            self.isRunning = false
            self.notify()
        }
    }

    func restart() { stop(); start() }

    // called on `queue` by clients
    fileprivate func message(_ bytes: [UInt8], from c: Client) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { return }
        if obj["t"] as? String == "ping" { c.sendText("{\"t\":\"pong\"}"); return }
        injector.handle(obj)
    }
    fileprivate func clientOpened(_ c: Client) { NSLog("phone connected: %@", c.peer); notify() }
    fileprivate func clientClosed(_ c: Client) {
        clients.removeValue(forKey: ObjectIdentifier(c))
        if c.isWebSocket { injector.releaseAll(); NSLog("phone disconnected: %@", c.peer) }
        notify()
    }
    private func notify() { DispatchQueue.main.async { self.onChange?() } }
}

private final class Client {
    let conn: NWConnection
    unowned let server: RemoteServer
    private var buf: [UInt8] = []
    private var fragments: [UInt8] = []
    private var closed = false
    private var awaitingPong = false
    private(set) var isWebSocket = false

    init(_ conn: NWConnection, server: RemoteServer) { self.conn = conn; self.server = server }
    var peer: String {
        if case let .hostPort(host, _) = conn.endpoint { return "\(host)" }
        return "?"
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: server.queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let d = data, !d.isEmpty { self.buf.append(contentsOf: d); self.process() }
            if error != nil || complete { self.finish() } else if !self.closed { self.receive() }
        }
    }

    private func process() {
        if !isWebSocket { handleHTTP() }
        if isWebSocket { while !closed && parseFrame() {} }
    }

    // ---------------------------------------------------------------- HTTP
    private func handleHTTP() {
        guard let end = headerEnd() else { if buf.count > 16384 { finish() }; return }
        let head = String(decoding: buf[0..<end], as: UTF8.self)
        buf.removeFirst(end + 4)
        let lines = head.components(separatedBy: "\r\n")
        let req = lines[0].split(separator: " ")
        guard req.count >= 2 else { finish(); return }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let target = String(req[1]).split(separator: "?", maxSplits: 1)
        let path = String(target[0]), query = target.count > 1 ? String(target[1]) : ""
        let k = query.split(separator: "&").compactMap { kv -> String? in
            let a = kv.split(separator: "=", maxSplits: 1)
            return a.count == 2 && a[0] == "k" ? String(a[1]).removingPercentEncoding : nil
        }.first
        let tokenOK = server.token.isEmpty || k == server.token
        if path == "/ws" {
            guard tokenOK else { sendHTTP(401, Data("bad token\n".utf8)); return }
            guard headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] else {
                sendHTTP(400, Data("expected a websocket upgrade\n".utf8)); return
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
            isWebSocket = true
            server.clientOpened(self)
        } else if path == "/manifest.json", let r = server.resource(path) {
            // only a page that already has the token gets a start_url containing it (home-screen apps open there)
            var text = String(decoding: r.data, as: UTF8.self)
            if tokenOK && !server.token.isEmpty {
                text = text.replacingOccurrences(of: "\"start_url\": \"/\"", with: "\"start_url\": \"/?k=\(server.token)\"")
            }
            sendHTTP(200, Data(text.utf8), type: r.type)
        } else if let r = server.resource(path) {
            sendHTTP(200, r.data, type: r.type)
        } else {
            sendHTTP(404, Data("not found\n".utf8))
        }
    }

    private func headerEnd() -> Int? {
        guard buf.count >= 4 else { return nil }
        for i in 0...(buf.count - 4) where buf[i] == 13 && buf[i+1] == 10 && buf[i+2] == 13 && buf[i+3] == 10 { return i }
        return nil
    }

    private func sendHTTP(_ status: Int, _ body: Data, type: String = "text/plain; charset=utf-8") {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    // ---------------------------------------------------------------- WebSocket framing (RFC 6455)
    private func parseFrame() -> Bool {
        guard buf.count >= 2 else { return false }
        let b0 = buf[0], b1 = buf[1]
        let fin = b0 & 0x80 != 0, opcode = b0 & 0x0f, masked = b1 & 0x80 != 0
        var len = Int(b1 & 0x7f), idx = 2
        if len == 126 {
            guard buf.count >= 4 else { return false }
            len = Int(buf[2]) << 8 | Int(buf[3]); idx = 4
        } else if len == 127 {
            guard buf.count >= 10 else { return false }
            len = 0; for i in 2..<10 { len = len << 8 | Int(buf[i]) }; idx = 10
        }
        guard len <= 1 << 20 else { finish(); return false }
        var key: [UInt8] = []
        if masked {
            guard buf.count >= idx + 4 else { return false }
            key = Array(buf[idx..<idx + 4]); idx += 4
        }
        guard buf.count >= idx + len else { return false }
        var payload = Array(buf[idx..<idx + len])
        if masked { for i in 0..<payload.count { payload[i] ^= key[i & 3] } }
        buf.removeFirst(idx + len)
        switch opcode {
        case 0x0: fragments += payload; if fin { let m = fragments; fragments = []; server.message(m, from: self) }
        case 0x1: if fin { server.message(payload, from: self) } else { fragments = payload }
        case 0x8: sendFrame(0x8, Array(payload.prefix(2))); finish()
        case 0x9: sendFrame(0xA, payload)
        case 0xA: awaitingPong = false
        default: break
        }
        return true
    }

    private func sendFrame(_ opcode: UInt8, _ payload: [UInt8]) {
        var f: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 { f.append(UInt8(n)) }
        else if n < 65536 { f.append(126); f.append(UInt8(n >> 8)); f.append(UInt8(n & 0xff)) }
        else { f.append(127); for i in (0..<8).reversed() { f.append(UInt8((n >> (i * 8)) & 0xff)) } }
        f += payload
        conn.send(content: Data(f), completion: .contentProcessed { _ in })
    }

    func sendText(_ s: String) { sendFrame(0x1, Array(s.utf8)) }

    func ping() {
        if awaitingPong { finish() } else { awaitingPong = true; sendFrame(0x9, []) }
    }

    func finish() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        server.clientClosed(self)
    }
}
