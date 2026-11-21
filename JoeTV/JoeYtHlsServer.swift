import Foundation
import Network

// MARK: - Local HLS assembly server
//
// The assembly leg of the native YouTube route: the
// resolver hands back two deciphered fMP4 URLs (video +
// audio as SEPARATE files — YouTube's adaptive shape).
// AVPlayer cannot play two bare files as one programme,
// so this server assembles them into a local HLS
// presentation:
//
//   master.m3u8 ──► video.m3u8 ──► video.bin (byte ranges
//        │                          relayed to the origin)
//        └────────► audio.m3u8 ──► audio.bin
//
// Each media playlist is a single-segment VOD: the
// format's init range becomes the EXT-X-MAP, the rest of
// the file one EXTINF segment with an EXT-X-BYTERANGE.
// The segment endpoints are transparent range relays:
// whatever Range AVPlayer asks for is forwarded to the
// deciphered origin URL and the bytes stream back
// through a bounded, back-pressured channel (8 events
// of ~256 KB in flight at most) — the whole file is
// never buffered in memory, by construction.
//
// Port discipline (FL-252 + design §4.4): a fixed port
// is a DEVICE-wide resource, so this server owns NO
// fixed port at all — it asks for the LOOPBACK
// interface with an OS-assigned ephemeral port
// (port 0), reads the real port back from the ready
// listener and builds session URLs from it. 18080
// stays DiagLog's alone (untouched) and no sibling
// app's port is used.
//
// Loopback is enforced at TWO layers, because the
// bind layer alone is not documentation-provable
// (review round 7, MAJOR): the listener is created
// with requiredLocalEndpoint = 127.0.0.1:0 — a
// different construction from DiagLogServer's proven
// NWListener(using:on:) shape, and whether NWListener
// honours requiredLocalEndpoint as a listen-address
// restriction is not something Apple's docs state
// outright — AND, independently, accept() hard-gates
// every accepted connection on its peer endpoint:
// anything that did not arrive from this device's own
// loopback is cancelled before a byte is read. The
// second layer is the guarantee; it proves itself in
// the log. The only legitimate client is this app's
// own AVPlayer on the same device, so nothing here is
// reachable from the LAN and no PIN is needed. What
// IS copied from DiagLogServer is the discipline
// around the listener (plain NWParameters.tcp,
// per-instance start guard, state surfaced verbatim)
// — the mechanism's discipline, not its bind call,
// and never its port.
//
// Swift 6: @MainActor like DiagLogServer — Network
// handlers are @Sendable closures that capture only the
// connection plus a weak self and hop straight back with
// Task { @MainActor in } before touching any state.
// Continuation resume values are Bool / Data counts —
// Sendable by construction ([CONTINUATION-SENDING]).

@MainActor
final class JoeYtHlsServer {
    static let shared = JoeYtHlsServer()

    /// The OS-assigned ephemeral port of the live
    /// listener (design §4.4: port 0 at bind time, the
    /// real value read back from the ready listener).
    /// Set BEFORE state flips to .ready, cleared when
    /// the listener dies; session URLs are built from
    /// this value, never from a constant.
    private var boundPort: UInt16?

    private enum State {
        case idle
        case starting
        case ready
    }

    /// One registered playback session: the two origin
    /// streams of one resolved episode.
    private struct StreamEntry {
        var origin: URL
        var contentLength: Int64
        var initRange: JoeYtByteRange?
        var durationSeconds: Double
        var mimeType: String
        /// The UA the origin request must carry (stored
        /// per entry — review round 1, MINOR: relay used
        /// to ignore makeSession's parameter and hardcode
        /// the spec's UA).
        var userAgent: String
    }

    private struct Session {
        var video: StreamEntry
        var audio: StreamEntry
        var videoCodec: String
        var audioCodec: String
        var width: Int
        var height: Int
        var bandwidth: Int
        var createdAt: Date
        /// Design §4.4 logging point ("segment đầu tiên
        /// được phục vụ"): flipped the first time a media
        /// segment of this session is served successfully,
        /// so that moment is logged exactly once per
        /// session; later segments stay silent.
        var firstSegmentServed = false
    }

    private let queue = DispatchQueue(label: "joetv.yt.hlsserver")
    private var listener: NWListener?
    private var state: State = .idle
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var sessions: [String: Session] = [:]
    private var sessionOrder: [String] = []

    private init() {}

    private func log(_ message: String) {
        DiagLog.write("YT-HLS", message)
    }

    // MARK: Session registration

    /// Register one resolved episode and return the
    /// master-playlist URL AVPlayer should load. Starts
    /// the listener on first use. Nil = the server could
    /// not start (logged); the caller falls back.
    func makeSession(playable: JoeYtPlayable, userAgent: String) async -> URL? {
        guard let videoURL = playable.videoURL, let audioURL = playable.audioURL else {
            return nil
        }
        guard await ensureStarted() else { return nil }
        let id = UUID().uuidString
        let video = StreamEntry(
            origin: videoURL,
            contentLength: playable.videoContentLength,
            initRange: playable.videoInitRange,
            durationSeconds: playable.durationSeconds,
            mimeType: "video/mp4",
            userAgent: userAgent)
        let audio = StreamEntry(
            origin: audioURL,
            contentLength: playable.audioContentLength,
            initRange: playable.audioInitRange,
            durationSeconds: playable.durationSeconds,
            mimeType: "audio/mp4",
            userAgent: userAgent)
        let session = Session(
            video: video, audio: audio,
            videoCodec: playable.videoCodec, audioCodec: playable.audioCodec,
            width: playable.width, height: playable.height,
            bandwidth: max(0, playable.videoBitrate) + max(0, playable.audioBitrate),
            createdAt: Date())
        sessions[id] = session
        sessionOrder.append(id)
        // Keep at most 4 sessions (current + prefetched
        // next + slack); older origins are expired signed
        // URLs anyway.
        while sessionOrder.count > 4 {
            let dropped = sessionOrder.removeFirst()
            sessions.removeValue(forKey: dropped)
        }
        log("session \(id.prefix(8)) — assembly itag \(playable.videoItag)+\(playable.audioItag), "
            + "\(playable.width)x\(playable.height), dur \(Int(playable.durationSeconds))s")
        guard let boundPort else { return nil }
        return URL(string: "http://127.0.0.1:\(boundPort)/yt/\(id)/master.m3u8")
    }

    /// Start the listener if needed and wait (bounded)
    /// until it reports ready. Returns false on failure.
    func ensureStarted() async -> Bool {
        switch state {
        case .ready: return true
        case .idle, .starting: break
        }
        if case .idle = state { startListener() }
        for _ in 0..<30 {
            switch state {
            case .ready: return true
            default: break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        log("listener chưa ready sau 3s — assembly không khả dụng lượt này")
        return false
    }

    private func startListener() {
        guard listener == nil else { return }
        state = .starting
        // Port 0 = the OS assigns an ephemeral port
        // (design §4.4); the real value is read back
        // from the listener when it reports .ready.
        guard let anyPort = NWEndpoint.Port(rawValue: 0) else {
            log("listener: không tạo được endpoint cổng ephemeral — assembly không khả dụng")
            state = .idle
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: anyPort)
        let created: NWListener
        do {
            created = try NWListener(using: parameters)
        } catch {
            // Back to .idle, not a latched .failed (review
            // round 1, MINOR): a transient failure must
            // not demote assembly for the process lifetime
            // — the next makeSession retries the start.
            state = .idle
            log("listener tạo thất bại: \(error.localizedDescription) — sẽ thử lại ở session sau")
            return
        }
        listener = created
        created.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                self?.listenerStateChanged(newState, listener: created)
            }
        }
        created.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.accept(conn)
            }
        }
        created.start(queue: queue)
        log("listener start trên 127.0.0.1 (cổng ephemeral, OS cấp)")
    }

    private func listenerStateChanged(_ newState: NWListener.State,
                                      listener: NWListener) {
        switch newState {
        case .ready:
            // Identity check FIRST (review count round
            // 1, Lens A F-1): a STALE event from a
            // replaced listener must never write the
            // live listener's state — a late .failed
            // dragging state to .idle while the current
            // listener is ready would strand every
            // makeSession (ensureStarted only starts
            // from .idle, and startListener early-returns
            // while a listener exists): assembly dead
            // for the process lifetime.
            guard self.listener === listener else { return }
            // Read the OS-assigned port back from the
            // listener itself (NWListener.port) and set
            // it BEFORE .ready so ensureStarted can only
            // observe a ready state that already has a
            // usable port. The log records only that the
            // port is ephemeral (design §4.4's logging
            // point) — never the number.
            boundPort = listener.port?.rawValue
            state = .ready
            log("listener ready trên 127.0.0.1 (ephemeral)")
        case .failed(let error):
            guard self.listener === listener else { return }
            self.listener = nil
            boundPort = nil
            // Reset to .idle so the next makeSession
            // retries (review round 1, MINOR — the .failed
            // latch made one transient bind failure
            // permanent for the process).
            state = .idle
            log("listener FAILED: \(error.localizedDescription) — lần mở session sau sẽ thử mở lại")
        case .cancelled:
            if self.listener === listener {
                self.listener = nil
                boundPort = nil
                // Back to .idle UNCONDITIONALLY (review
                // round 7, MINOR): a listener cancelled
                // while still .starting previously left
                // the state latched at .starting forever —
                // ensureStarted only starts from .idle, so
                // assembly would have been dead for the
                // process lifetime, the exact latch the
                // round-1 fix removed from the .failed
                // branch. No code cancels the listener
                // today; this is the latent path closed.
                state = .idle
            }
        default:
            break
        }
    }

    // MARK: Connection handling

    private func accept(_ conn: NWConnection) {
        // The loopback hard gate (review round 7,
        // MAJOR): whatever the bind semantics turn out
        // to be on any given OS build, a connection
        // whose peer is not this device's own loopback
        // is cancelled before a single byte is read —
        // and the refusal is logged, so the guarantee is
        // provable from the diagnostic log alone. Fail
        // closed on any endpoint shape that is not a
        // loopback hostPort.
        switch conn.endpoint {
        case .hostPort(let host, _):
            let hostText = "\(host)"
            guard hostText == "127.0.0.1" || hostText == "::1"
                    || hostText == "localhost"
                    || hostText.hasPrefix("::ffff:127.0.0.1") else {
                log("accept: TỪ CHỐI kết nối không phải loopback (peer \(hostText)) — hủy ngay")
                conn.cancel()
                return
            }
        default:
            log("accept: TỪ CHỐI kết nối có endpoint không phải hostPort — hủy ngay")
            conn.cancel()
            return
        }
        connections[ObjectIdentifier(conn)] = conn
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
            [weak self] data, _, _, _ in
            Task { @MainActor in
                self?.handle(conn, requestData: data ?? Data())
            }
        }
    }

    private func close(_ conn: NWConnection) {
        conn.cancel()
        connections.removeValue(forKey: ObjectIdentifier(conn))
    }

    /// Parse one request (request line + the Range header
    /// are all this server routes on) and dispatch.
    private func handle(_ conn: NWConnection, requestData: Data) {
        guard !requestData.isEmpty else { close(conn); return }
        let text = String(decoding: requestData, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { close(conn); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            respondText(conn, status: 400, body: "bad request",
                        headOnly: requestLine.hasPrefix("HEAD "))
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])
        // A HEAD response must carry the headers a GET
        // would, with NO body (RFC 9110) — every response
        // path below honours this flag, including the
        // error paths (review round 7, MINOR).
        let headOnly = (method == "HEAD")
        var rangeHeader: String?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("range:") {
                rangeHeader = line.dropFirst("range:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        // /yt/<session>/<file>
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count == 3, segments[0] == "yt",
              let session = sessions[segments[1]] else {
            respondText(conn, status: 404, body: "not found", headOnly: headOnly)
            return
        }
        let file = segments[2]
        switch file {
        case "master.m3u8":
            respondText(conn, status: 200, body: masterPlaylist(session),
                        contentType: "application/vnd.apple.mpegurl", headOnly: headOnly)
        case "video.m3u8":
            respondText(conn, status: 200,
                        body: mediaPlaylist(entry: session.video, file: "video.bin"),
                        contentType: "application/vnd.apple.mpegurl", headOnly: headOnly)
        case "audio.m3u8":
            respondText(conn, status: 200,
                        body: mediaPlaylist(entry: session.audio, file: "audio.bin"),
                        contentType: "application/vnd.apple.mpegurl", headOnly: headOnly)
        case "video.bin", "audio.bin":
            let entry = (file == "video.bin") ? session.video : session.audio
            Task { [weak self] in
                await self?.relay(conn, sessionID: segments[1], entry: entry,
                                  rangeHeader: rangeHeader, headOnly: headOnly)
            }
        default:
            respondText(conn, status: 404, body: "not found", headOnly: headOnly)
        }
    }

    // MARK: Playlists

    private func masterPlaylist(_ session: Session) -> String {
        let bandwidth = session.bandwidth > 0 ? session.bandwidth : 4_400_000
        let resolution = (session.width > 0 && session.height > 0)
            ? ",RESOLUTION=\(session.width)x\(session.height)" : ""
        let codecs = (session.videoCodec.isEmpty || session.audioCodec.isEmpty)
            ? "" : ",CODECS=\"\(session.videoCodec),\(session.audioCodec)\""
        return """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="AAC",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth)\(resolution)\(codecs),AUDIO="aud"
        video.m3u8
        """
    }

    private func mediaPlaylist(entry: StreamEntry, file: String) -> String {
        let duration = entry.durationSeconds > 0 ? entry.durationSeconds : 3600
        let target = Int(duration.rounded(.up)) + 1
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        var segmentStart: Int64 = 0
        if let initRange = entry.initRange {
            lines.append("#EXT-X-MAP:URI=\"\(file)\",BYTERANGE=\"\(initRange.length)@\(initRange.start)\"")
            segmentStart = initRange.end + 1
        }
        lines.append(String(format: "#EXTINF:%.3f,", duration))
        if entry.contentLength > segmentStart {
            let mediaLength = entry.contentLength - segmentStart
            lines.append("#EXT-X-BYTERANGE:\(mediaLength)@\(segmentStart)")
        }
        lines.append(file)
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Origin relay (byte ranges, streamed)

    /// One relay event from the detached origin
    /// producer. All payloads are value types — Sendable
    /// by construction ([CONTINUATION-SENDING] discipline
    /// applied to streams).
    private enum RelayEvent: Sendable {
        case head(status: Int, contentType: String,
                  contentLength: String?, contentRange: String?)
        case chunk(Data)
        case failed(String)
    }

    /// Forward the request (with AVPlayer's Range, if
    /// any) to the deciphered origin and stream the reply
    /// back in ~256 KB chunks. The origin's status and
    /// range headers are relayed verbatim — AVPlayer's
    /// byte-range bookkeeping depends on them.
    ///
    /// The fetch itself runs in a DETACHED producer task
    /// that accumulates bytes into chunks off the main
    /// actor (review round 1, MINOR: iterating
    /// URLSession.AsyncBytes byte-by-byte inside this
    /// @MainActor function resumed the actor once per
    /// byte — the known-slowest consumption pattern).
    /// Only chunk-sized events cross back here.
    private func relay(_ conn: NWConnection, sessionID: String, entry: StreamEntry,
                       rangeHeader: String?, headOnly: Bool) async {
        var request = URLRequest(url: entry.origin)
        request.timeoutInterval = 30
        // A HEAD probe is answered with a HEAD to the
        // origin too (review round 7, MINOR): issuing a
        // full GET and discarding the body after the
        // headers wasted an origin download per probe.
        if headOnly { request.httpMethod = "HEAD" }
        request.setValue(entry.userAgent, forHTTPHeaderField: "User-Agent")
        if let rangeHeader {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }
        let fallbackType = entry.mimeType
        // Bounded stream WITH back-pressure (review
        // round 7, MINOR): the buffer holds at most 8
        // events (~2 MB of chunks); when it is full the
        // producer WAITS and retries the same event —
        // bytes are never dropped, and the header's
        // "never buffered whole" claim is structural,
        // not a hope about relative speeds.
        let events = AsyncStream<RelayEvent>(bufferingPolicy: .bufferingOldest(8)) { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                // Returns false when the consumer is
                // gone (terminated / cancelled).
                func emit(_ event: RelayEvent) async -> Bool {
                    while !Task.isCancelled {
                        let result = continuation.yield(event)
                        if case .terminated = result { return false }
                        if case .dropped = result {
                            try? await Task.sleep(nanoseconds: 10_000_000)
                            continue
                        }
                        return true
                    }
                    return false
                }
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let http = response as? HTTPURLResponse
                    guard await emit(.head(
                        status: http?.statusCode ?? 200,
                        contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? fallbackType,
                        contentLength: http?.value(forHTTPHeaderField: "Content-Length"),
                        contentRange: http?.value(forHTTPHeaderField: "Content-Range"))) else {
                        continuation.finish()
                        return
                    }
                    var buffer = Data()
                    buffer.reserveCapacity(256 * 1024)
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        buffer.append(byte)
                        if buffer.count >= 256 * 1024 {
                            guard await emit(.chunk(buffer)) else { break }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        _ = await emit(.chunk(buffer))
                    }
                } catch {
                    _ = await emit(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        var headSent = false
        for await event in events {
            switch event {
            case .head(let status, let contentType, let contentLength, let contentRange):
                if status >= 400 {
                    // Design §4.4's logging point: an
                    // upstream failure is recorded with
                    // its STATUS at the layer that sees
                    // it (FL-076) — never the URL. The
                    // status still relays verbatim to
                    // AVPlayer; recovery from a dead
                    // origin is the player model's
                    // item-level re-resolve leg.
                    log("relay: upstream trả status \(status) cho một segment")
                }
                var head = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
                head += "Content-Type: \(contentType)\r\n"
                head += "Accept-Ranges: bytes\r\n"
                if let contentLength {
                    head += "Content-Length: \(contentLength)\r\n"
                }
                if let contentRange {
                    head += "Content-Range: \(contentRange)\r\n"
                }
                head += "Connection: close\r\n\r\n"
                guard await send(conn, data: Data(head.utf8)) else {
                    close(conn)
                    return
                }
                headSent = true
                if headOnly {
                    close(conn)
                    return
                }
                if (200..<300).contains(status) {
                    noteFirstSegmentServed(sessionID: sessionID)
                }
            case .chunk(let data):
                guard await send(conn, data: data) else {
                    close(conn)
                    return
                }
            case .failed(let message):
                if headSent {
                    // A cut stream after a 2xx head cannot
                    // be repaired at this layer — closing
                    // tells the player the segment is
                    // incomplete and its own retry/stall
                    // machinery takes over (the player
                    // model's re-resolve leg covers dead
                    // origins).
                    log("relay: origin đứt giữa chừng — \(message)")
                    close(conn)
                } else {
                    log("relay: origin lỗi mạng — \(message)")
                    respondText(conn, status: 502, body: "origin error", headOnly: headOnly)
                }
                return
            }
        }
        close(conn)
    }

    /// Design §4.4 logging point: the first media
    /// segment served successfully in a session,
    /// logged once (the session's flag latches). The
    /// millisecond figure is measured from
    /// Session.createdAt — the moment makeSession
    /// registered the session, the per-session start
    /// milestone this file already keeps. A HEAD probe
    /// never reaches here (it returns at the head), so
    /// only a real GET relay with a 2xx upstream head
    /// counts as "served". No URL is logged.
    private func noteFirstSegmentServed(sessionID: String) {
        guard var session = sessions[sessionID],
              !session.firstSegmentServed else { return }
        session.firstSegmentServed = true
        sessions[sessionID] = session
        let ms = Int(Date().timeIntervalSince(session.createdAt) * 1000)
        log("session \(sessionID.prefix(8)) — segment đầu tiên được phục vụ sau \(ms) ms (mốc: createdAt của session)")
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }

    // MARK: Small responses

    private func respondText(_ conn: NWConnection, status: Int, body: String,
                             contentType: String = "text/plain; charset=utf-8",
                             headOnly: Bool = false) {
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        Task { [weak self] in
            guard let self else { return }
            guard await self.send(conn, data: Data(head.utf8)) else {
                self.close(conn)
                return
            }
            if !headOnly {
                _ = await self.send(conn, data: bodyData)
            }
            self.close(conn)
        }
    }

    /// One send, awaited. The completion resumes with a
    /// Bool — Sendable by construction.
    private func send(_ conn: NWConnection, data: Data) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            conn.send(content: data, completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }
}
