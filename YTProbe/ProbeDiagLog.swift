import Foundation
import Network

/// YT PROBE — rolling diagnostic log + LAN export.
///
/// Copied from JoeTV's JoeDiagLog.swift implementation
/// pattern (v2.0.33/v2.0.48): a small rolling log in the
/// app sandbox, served over the home LAN by a one-time-PIN
/// HTTP server (DiagLogServer, bottom of this file) — tvOS
/// has no share sheet, so the LAN download + QR is the
/// only export route. Adaptations for the probe, all
/// deliberate:
///  • the file is ytprobe-diag.log and the download is
///    named ytprobe-diag.txt;
///  • the scrubber's credential-value pass erases the
///    probe's own secrets (the YouTube OAuth access /
///    refresh tokens and the scraped client id/secret)
///    instead of JoeTV's debrid set;
///  • JoeTV's stall/focus instrumentation is NOT carried
///    over — the probe has no focus surfaces to measure;
///  • logLaunchPresence() records the OAuth tokens'
///    presence + length only, same rule as JoeTV's.
enum DiagLog {

    // MARK: - Storage

    private static let storageDirectory: URL = {
        let fm = FileManager.default
        if let base = try? fm.url(for: .applicationSupportDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: true) {
            try? fm.createDirectory(at: base,
                                    withIntermediateDirectories: true)
            return base
        }
        if let base = try? fm.url(for: .cachesDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: true) {
            try? fm.createDirectory(at: base,
                                    withIntermediateDirectories: true)
            return base
        }
        return fm.temporaryDirectory
    }()

    static var fileURL: URL {
        storageDirectory.appendingPathComponent("ytprobe-diag.log")
    }

    // MARK: - Serialisation state
    //
    // Same lock discipline as JoeTV's: every mutable value
    // below is touched ONLY while `lock` is held, so the
    // enum is safe to call from any thread or actor.

    private static let lock = NSLock()
    private nonisolated(unsafe) static var writeCounter = 0
    private nonisolated(unsafe) static var didLogLaunchPresence = false

    private static let sizeCap = 1_000_000
    private static let rotationKeepBytes = 700_000

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:https?|stremio)://[^\s"']+"#)

    // MARK: - Writing

    /// Append ONE line: `[yyyy-MM-dd HH:mm:ss.SSS]
    /// [category] message`. The message is URL-scrubbed
    /// first and flattened to a single line.
    static func write(_ category: String, _ message: String) {
        let clean = scrubbed(message)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let line = "[\(timestamp())] [\(category)] \(clean)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        appendLocked(data)
        writeCounter += 1
        if writeCounter % 64 == 0 {
            rotateIfNeededLocked()
        }
    }

    /// The file's full current contents ("" when absent or
    /// unreadable) — the export server's body source.
    static func currentText() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func appendLocked(_ data: Data) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    private static func rotateIfNeededLocked() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > sizeCap,
              let data = try? Data(contentsOf: fileURL),
              data.count > rotationKeepBytes
        else { return }
        let threshold = data.count - rotationKeepBytes
        var start = data.count
        if let newline = data[threshold...].firstIndex(of: 0x0A) {
            start = newline + 1
        }
        let marker = "[\(timestamp())] [diag] log rotated — older lines dropped\n"
        var rotated = Data(marker.utf8)
        if start < data.count {
            rotated.append(data[start...])
        }
        try? rotated.write(to: fileURL)
    }

    // MARK: - Formatting + redaction

    private static let timestampLock = NSLock()
    private nonisolated(unsafe) static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone.autoupdatingCurrent
        return f
    }()

    private static func timestamp() -> String {
        let now = Date()
        return timestampLock.withLock {
            timestampFormatter.string(from: now)
        }
    }

    /// Two passes (JoeTV's passes 1 and 3; its pass 2 was
    /// Torrentio-specific and does not apply here):
    /// 1. Every URL reduces to scheme://host — googlevideo
    ///    paths/queries carry the solved sig/n and the
    ///    account-bound ip, so they never reach disk.
    /// 2. Value pass: the probe's credential values are
    ///    erased wherever they appear, in any shape.
    private static func scrubbed(_ message: String) -> String {
        var result = message
        let full = NSRange(location: 0,
                           length: (result as NSString).length)
        for match in urlRegex.matches(in: result, range: full).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let raw = String(result[range])
            if let comps = URLComponents(string: raw),
               let scheme = comps.scheme, let host = comps.host {
                result.replaceSubrange(range, with: "\(scheme)://\(host)")
            } else {
                result.replaceSubrange(range, with: "[url]")
            }
        }
        for secret in secretValues() {
            result = result.replacingOccurrences(of: secret,
                                                 with: "[redacted]")
        }
        return result
    }

    /// The probe's credential values in force (the OAuth
    /// store), longest first. Values under 8 characters
    /// are skipped — too short to be a credential, too
    /// likely to be an innocent substring.
    private static func secretValues() -> [String] {
        let raw: [String?] = [
            JoeYtOAuthStore.accessToken,
            JoeYtOAuthStore.refreshToken,
            JoeYtOAuthStore.clientSecret,
            JoeYtOAuthStore.clientID,
        ]
        var seen = Set<String>()
        var out: [String] = []
        for value in raw {
            let v = (value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard v.count >= 8, seen.insert(v).inserted else { continue }
            out.append(v)
        }
        return out.sorted { $0.count > $1.count }
    }

    // MARK: - Launch presence

    /// ONE settings line per process: session header +
    /// the OAuth tokens' PRESENCE + LENGTH ONLY.
    static func logLaunchPresence() {
        lock.lock()
        if didLogLaunchPresence {
            lock.unlock()
            return
        }
        didLogLaunchPresence = true
        lock.unlock()

        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        write("diag", "session start app=\(short)/\(build) "
              + "system=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")

        func presence(_ label: String, _ value: String?) -> String {
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return "\(label)=absent" }
            return "\(label)=present len=\(value.count)"
        }

        let parts: [String] = [
            presence("ytAccess", JoeYtOAuthStore.accessToken),
            presence("ytRefresh", JoeYtOAuthStore.refreshToken),
            presence("ytClientId", JoeYtOAuthStore.clientID),
            presence("ytClientSecret", JoeYtOAuthStore.clientSecret),
        ]
        write("settings", "launch presence: " + parts.joined(separator: " "))
    }
}

// MARK: - LAN export server
//
// JoeTV's DiagLogServer, carried over with only names
// and the download filename changed: ONE app-lifetime
// instance on port 18080, a one-time 4-digit PIN minted
// per listener, 3 wrong PINs stop it for 60 seconds.
// The class is @MainActor; Network.framework handlers
// are @Sendable closures that hop straight back to the
// main actor before touching state (see JoeTV's file
// for the full FL-378 rationale).
@MainActor
final class DiagLogServer {

    static let shared = DiagLogServer()

    enum State {
        case starting
        case serving(url: String)
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "ytprobe.diaglog.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var servingURL: String?

    private(set) var pin = ""
    private var failedAttempts = 0
    private static var lockoutUntil: Date?

    func start() {
        if let until = Self.lockoutUntil, until > Date() {
            emit(.failed("Kênh gửi log đang tạm dừng sau 3 lần nhập sai mã PIN — chờ khoảng 1 phút rồi mở lại màn hình này."))
            return
        }
        guard listener == nil else {
            if let listener, listener.state == .ready,
               let port = listener.port {
                if let ip = Self.lanIPAddress() {
                    let url = "http://\(ip):\(port.rawValue)/log?pin=\(pin)"
                    servingURL = url
                    emit(.serving(url: url))
                } else if let servingURL {
                    emit(.serving(url: servingURL))
                } else {
                    emit(.failed("Không tìm thấy địa chỉ mạng nội bộ"))
                }
            } else if let servingURL {
                emit(.serving(url: servingURL))
            } else {
                emit(.starting)
            }
            return
        }
        servingURL = nil
        pin = String(format: "%04d", Int.random(in: 0...9999))
        failedAttempts = 0
        emit(.starting)
        guard let port = NWEndpoint.Port(rawValue: 18080) else {
            emit(.failed("Không mở được kênh gửi log (cổng không hợp lệ)."))
            return
        }
        let created: NWListener
        do {
            created = try NWListener(using: NWParameters.tcp, on: port)
        } catch {
            emit(.failed("Không mở được kênh gửi log: \(error.localizedDescription)"))
            return
        }
        listener = created
        created.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.listenerStateChanged(state, listener: created)
            }
        }
        created.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.accept(conn)
            }
        }
        created.start(queue: queue)
    }

    func stop() {
        servingURL = nil
        listener?.cancel()
        listener = nil
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
    }

    // MARK: - Listener / connection handling (main actor)

    private func listenerStateChanged(_ state: NWListener.State,
                                      listener: NWListener) {
        switch state {
        case .ready:
            guard let ip = Self.lanIPAddress(), let port = listener.port else {
                emit(.failed("Không tìm thấy địa chỉ mạng nội bộ"))
                return
            }
            let url = "http://\(ip):\(port.rawValue)/log?pin=\(pin)"
            servingURL = url
            emit(.serving(url: url))
        case .failed(let error):
            if self.listener === listener { self.listener = nil; servingURL = nil }
            emit(.failed("Kênh gửi log lỗi: \(error.localizedDescription)"))
        case .cancelled:
            if self.listener === listener { self.listener = nil; servingURL = nil }
        default:
            break
        }
    }

    private func accept(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = conn
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, _ in
            Task { @MainActor in
                self?.handle(conn, requestData: data ?? Data())
            }
        }
    }

    private func handle(_ conn: NWConnection, requestData: Data) {
        guard !requestData.isEmpty else {
            conn.cancel()
            connections.removeValue(forKey: ObjectIdentifier(conn))
            return
        }
        if !pin.isEmpty, Self.requestPIN(in: requestData) == pin {
            failedAttempts = 0
            respond(to: conn)
            return
        }
        failedAttempts += 1
        let locking = failedAttempts >= 3
        if locking {
            Self.lockoutUntil = Date().addingTimeInterval(60)
        }
        respondForbidden(to: conn) { [weak self] in
            guard let self, locking else { return }
            self.listener?.cancel()
            self.listener = nil
            self.servingURL = nil
            for other in self.connections.values { other.cancel() }
            self.connections.removeAll()
            self.emit(.failed("Quá 3 lần nhập sai mã PIN — kênh gửi log đã tạm dừng 60 giây. Đóng màn hình này, chờ một chút rồi mở lại."))
        }
    }

    nonisolated private static func requestPIN(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("x-diag-pin:") {
                return lower.dropFirst("x-diag-pin:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
            if lower.hasPrefix("get ") || lower.hasPrefix("head "),
               let r = lower.range(of: "pin=") {
                let tail = lower[r.upperBound...]
                let digits = tail.prefix { $0.isNumber }
                let next = tail.dropFirst(digits.count).first
                if !digits.isEmpty,
                   next == nil || next == " " || next == "&" || next == "#" {
                    return String(digits)
                }
            }
        }
        return nil
    }

    private func respond(to conn: NWConnection) {
        let text = DiagLog.currentText()
        let bodyText = text.isEmpty
            ? "YT Probe diagnostic log is empty.\n" : text
        let body = Data(bodyText.utf8)
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Disposition: attachment; filename=\"ytprobe-diag.txt\"\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        sendAndClose(conn, payload: payload)
    }

    private func respondForbidden(to conn: NWConnection,
                                  after: @escaping @MainActor () -> Void) {
        let body = Data("403 — wrong or missing PIN.\n".utf8)
        let header = "HTTP/1.1 403 Forbidden\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        sendAndClose(conn, payload: payload, after: after)
    }

    private func sendAndClose(_ conn: NWConnection, payload: Data,
                              after: (@MainActor () -> Void)? = nil) {
        conn.send(content: payload, completion: .contentProcessed {
            [weak self] _ in
            conn.cancel()
            Task { @MainActor in
                self?.connections.removeValue(
                    forKey: ObjectIdentifier(conn))
                after?()
            }
        })
    }

    private func emit(_ state: State) {
        let callback = onStateChange
        Task { @MainActor in
            callback?(state)
        }
    }

    // MARK: - LAN address

    nonisolated static func lanIPAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let ptr = cursor {
            cursor = ptr.pointee.ifa_next
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" || name == "en2"
            else { continue }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr,
                              socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("127.") { return ip }
        }
        return nil
    }
}
