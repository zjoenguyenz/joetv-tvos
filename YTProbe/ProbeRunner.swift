import Combine
import Foundation

// MARK: - YT PROBE matrix runner
//
// One tap runs the PROBE-SPEC v1 matrix (variants 1, 2,
// 3, 3b on both videos; variant 5 on the public control
// only) and writes one results table at the end of the
// DiagLog. The fetches are DIRECT test GETs on the
// resolved post-solve URLs — no AVPlayer, no HLS relay:
//   per itag (140 and 18): GET bytes=0-1023 and
//   GET bytes=65536-131071, at t=0 and again at t+8s;
//   a variant passing every t+8 check earns the 75 s
//   continuous sequential-range fetch on itag 140.
// Logged per spec: /player status, playability, format
// count, sts sent; per GET — status, bytes, the URL's
// ip= family and the connection's remote-address family
// (from URLSession task metrics). NO URLs, NO tokens,
// NO cookie values are ever written.

// MARK: One test GET, with task metrics

struct ProbeGETResult: Sendable {
    var status: Int          // HTTP status; 0 = transport failure
    var bytes: Int
    var remoteFamily: String // ipv4 / ipv6 / ?
}

/// A URLSession whose delegate keeps each task's
/// URLSessionTaskMetrics beside its data/response, so a
/// fetch returns the remote address family together
/// with the body. URLSession itself never exposes the
/// connected address; the transaction metrics are the
/// supported route. All mutable state sits behind one
/// lock (the house discipline); a 1.5 s grace after the
/// data lands resumes any fetch whose metrics never
/// arrive, with family "?".
final class ProbeMetricsFetcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ProbeMetricsFetcher()

    private final class Box {
        var data: Data?
        var response: URLResponse?
        var metrics: URLSessionTaskMetrics?
        var dataDone = false
        var metricsDone = false
        var resumed = false
        var continuation: CheckedContinuation<(Data?, URLResponse?, URLSessionTaskMetrics?), Never>?
    }

    private let lock = NSLock()
    private var boxes: [Int: Box] = [:]
    private lazy var session: URLSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil)

    func fetch(_ request: URLRequest) async -> (Data?, URLResponse?, URLSessionTaskMetrics?) {
        await withCheckedContinuation { continuation in
            var task: URLSessionDataTask!
            task = session.dataTask(with: request) { [weak self] data, response, _ in
                guard let self else {
                    continuation.resume(returning: (data, response, nil))
                    return
                }
                let id = task.taskIdentifier
                self.lock.lock()
                if let box = self.boxes[id] {
                    box.data = data
                    box.response = response
                    box.dataDone = true
                }
                self.lock.unlock()
                self.resumeIfReady(id: id, force: false)
                // Metrics normally land BEFORE this
                // completion handler runs; if they still
                // have not arrived 1.5 s after the data,
                // complete without them (family "?")
                // instead of hanging the fetch forever.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.resumeIfReady(id: id, force: true)
                }
            }
            let box = Box()
            box.continuation = continuation
            lock.lock()
            boxes[task.taskIdentifier] = box
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        let id = task.taskIdentifier
        lock.lock()
        if let box = boxes[id] {
            box.metrics = metrics
            box.metricsDone = true
        }
        lock.unlock()
        resumeIfReady(id: id, force: false)
    }

    /// Resume exactly once: when both halves have
    /// landed, or — only ever after the data has landed —
    /// when the metrics grace window expires (force).
    private func resumeIfReady(id: Int, force: Bool) {
        lock.lock()
        guard let box = boxes[id], !box.resumed else {
            lock.unlock()
            return
        }
        let ready = box.dataDone && (box.metricsDone || force)
        if ready {
            box.resumed = true
            boxes.removeValue(forKey: id)
        }
        lock.unlock()
        if ready {
            box.continuation?.resume(returning: (box.data, box.response, box.metrics))
        }
    }
}

/// One ranged GET on a resolved URL, as the winning
/// client (googlevideo binds URLs to the client UA).
func probeGET(url: URL, userAgent: String, rangeHeader: String) async -> ProbeGETResult {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(rangeHeader, forHTTPHeaderField: "Range")
    let (data, response, metrics) = await ProbeMetricsFetcher.shared.fetch(request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    var family = "?"
    if let address = metrics?.transactionMetrics.last?.remoteAddress {
        family = address.contains(":") ? "ipv6" : (address.contains(".") ? "ipv4" : "?")
    }
    return ProbeGETResult(status: status, bytes: data?.count ?? 0,
                          remoteFamily: family)
}

/// The family of the URL's own `ip=` parameter (the
/// address the /player call was made from, embedded by
/// YouTube) — the VALUE itself is never logged, only
/// its family (Claude ROUND4's IP-family-split lead).
func ipParamFamily(of url: URL) -> String {
    guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let raw = comps.queryItems?.first(where: { $0.name == "ip" })?.value,
          !raw.isEmpty else { return "absent" }
    return raw.contains(":") ? "ipv6" : "ipv4"
}

// MARK: Matrix view model

@MainActor
final class ProbeRunViewModel: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false

    /// V-pub: aqz-KE-bpKQ — the established public
    /// control. No video ID in the incident DiagLogs is
    /// clearly a PUBLIC TVB trailer (the logged IDs are
    /// episode resolves), so the spec's fallback applies.
    static let publicVideo = (tag: "V-pub", id: "aqz-KE-bpKQ")
    /// V-mem: a members-only TVB episode from the
    /// incident logs (DiagLog 2026-11-23 21:41).
    static let membersVideo = (tag: "V-mem", id: "-fvytGF7toA")

    func startMatrix() {
        guard !running else { return }
        running = true
        Task { [weak self] in
            await self?.runMatrix()
            self?.running = false
        }
    }

    private func say(_ message: String) {
        DiagLog.write("PROBE", message)
        lines.append(message)
        if lines.count > 500 {
            lines.removeFirst(lines.count - 500)
        }
    }

    private func runMatrix() async {
        let videos = [Self.publicVideo, Self.membersVideo]
        say("=== PROBE MATRIX RUN \(Self.stamp()) ===")
        say("V-pub = \(Self.publicVideo.id) (public control — no clearly-public TVB trailer ID in the incident logs)")
        say("V-mem = \(Self.membersVideo.id) (members-only episode, incident logs)")
        var rows: [String] = []
        for video in videos {
            var variants: [ProbeVariant] = [.v1, .v2, .v3, .v3b]
            if video.tag == "V-pub" { variants.append(.v5) }
            for variant in variants {
                rows.append(await runVariant(variant, video: video))
            }
        }
        say("=== RESULTS TABLE ===")
        say("variant | video | /player | playability | fmts | sts | 140 t0 z/m | 140 t8 z/m | 18 t0 z/m | 18 t8 z/m | 75s | verdict")
        for row in rows { say(row) }
        say("=== END OF RUN — verdict PASS* = passes every gate in THIS run; promotion needs a second run ≥10 min later with fresh resolves (PROBE-SPEC) ===")
    }

    private func runVariant(_ variant: ProbeVariant,
                            video: (tag: String, id: String)) async -> String {
        say("--- variant \(variant.id) (\(variant.label)) × \(video.tag) vid=\(video.id)")
        let outcome = await ProbeResolver.shared.resolve(videoId: video.id, variant: variant)
        let playerCell = outcome.httpStatus == 0 ? "-" : String(outcome.httpStatus)
        let stsCell = outcome.stsSent.map(String.init) ?? "-"
        if outcome.playability != "OK" {
            say("variant \(variant.id) × \(video.tag): playability=\(outcome.playability) reason=\(outcome.reason.isEmpty ? "-" : outcome.reason)")
        }
        if let step = outcome.solverStep {
            say("variant \(variant.id) × \(video.tag): solver FAILED step=\(step)")
        }

        var cell140t0 = "-", cell140t8 = "-", cell18t0 = "-", cell18t8 = "-"
        var passFetch = false
        var fetch75 = "-"
        if outcome.audioURL != nil || outcome.muxedURL != nil {
            let ua = variant.spec.userAgent
            let t0Start = Date()
            cell140t0 = await fetchPair(url: outcome.audioURL, ua: ua, itag: "140",
                                        variant: variant, videoTag: video.tag, when: "t0")
            cell18t0 = await fetchPair(url: outcome.muxedURL, ua: ua, itag: "18",
                                       variant: variant, videoTag: video.tag, when: "t0")
            let elapsed = Date().timeIntervalSince(t0Start)
            if elapsed < 8 {
                try? await Task.sleep(nanoseconds: UInt64((8 - elapsed) * 1_000_000_000))
            }
            cell140t8 = await fetchPair(url: outcome.audioURL, ua: ua, itag: "140",
                                        variant: variant, videoTag: video.tag, when: "t8")
            cell18t8 = await fetchPair(url: outcome.muxedURL, ua: ua, itag: "18",
                                       variant: variant, videoTag: video.tag, when: "t8")
            // The fetch gate: itag 140 present and every
            // GET on every PRESENT itag answered 206, at
            // t0 and at t+8s (PROBE-SPEC promotion rule,
            // single-run half).
            passFetch = outcome.audioURL != nil
                && cell140t0 == "206/206" && cell140t8 == "206/206"
                && (outcome.muxedURL == nil
                    || (cell18t0 == "206/206" && cell18t8 == "206/206"))
            if passFetch, let audioURL = outcome.audioURL {
                fetch75 = await continuousFetch(url: audioURL, ua: ua,
                                                variant: variant, videoTag: video.tag)
            }
        }

        let verdict: String
        if outcome.playability != "OK" {
            verdict = "FAIL(resolve)"
        } else if outcome.audioURL == nil && outcome.muxedURL == nil {
            verdict = "FAIL(no-url)"
        } else if !passFetch {
            verdict = "FAIL(fetch)"
        } else if fetch75 == "OK" || fetch75.hasPrefix("COMPLETE") {
            verdict = "PASS*"
        } else {
            verdict = "FAIL(75s)"
        }
        say("variant \(variant.id) × \(video.tag): verdict \(verdict)")
        return "\(variant.id) | \(video.tag) | \(playerCell) | \(outcome.playability) | \(outcome.formatCount) | \(stsCell) | \(cell140t0) | \(cell140t8) | \(cell18t0) | \(cell18t8) | \(fetch75) | \(verdict)"
    }

    /// The two spec GETs for one itag at one time point;
    /// returns the "byteZero/firstMedia" status cell.
    private func fetchPair(url: URL?, ua: String, itag: String,
                           variant: ProbeVariant, videoTag: String,
                           when: String) async -> String {
        guard let url else { return "absent" }
        let family = ipParamFamily(of: url)
        let zero = await probeGET(url: url, userAgent: ua, rangeHeader: "bytes=0-1023")
        say("GET v\(variant.id) \(videoTag) itag \(itag) \(when) bytes=0-1023 → \(zero.status) (\(zero.bytes)B) ip=\(family) remote=\(zero.remoteFamily)")
        let media = await probeGET(url: url, userAgent: ua, rangeHeader: "bytes=65536-131071")
        say("GET v\(variant.id) \(videoTag) itag \(itag) \(when) bytes=65536-131071 → \(media.status) (\(media.bytes)B) ip=\(family) remote=\(media.remoteFamily)")
        return "\(zero.status)/\(media.status)"
    }

    /// The winners-only gate: 75 s of sequential media
    /// ranges on itag 140 (256 KiB ranges, ~0.5 s pacing
    /// so the fetch actually spans the window — an
    /// unpaced loop would drain the file in seconds and
    /// never test the ~60 s boundary). A 416 or a short
    /// read means the file ended first: that is a
    /// COMPLETE, not a failure. Any other non-206 stops
    /// the fetch and is the result.
    private func continuousFetch(url: URL, ua: String,
                                 variant: ProbeVariant,
                                 videoTag: String) async -> String {
        say("75s fetch v\(variant.id) \(videoTag) itag 140: bắt đầu (ranges 256KiB, nhịp ~0.5s)")
        let chunk = 262_144
        var offset = 0
        var total = 0
        var ranges = 0
        let start = Date()
        while Date().timeIntervalSince(start) < 75 {
            let r = await probeGET(url: url, userAgent: ua,
                                   rangeHeader: "bytes=\(offset)-\(offset + chunk - 1)")
            let elapsed = Int(Date().timeIntervalSince(start))
            if r.status == 416 {
                say("75s fetch: file hết ở \(elapsed)s (\(ranges) ranges, \(total)B) — COMPLETE")
                return "COMPLETE@\(elapsed)s"
            }
            guard r.status == 206 else {
                say("75s fetch: FAIL status \(r.status) ở \(elapsed)s offset \(offset)")
                return "FAIL \(r.status)@\(elapsed)s"
            }
            ranges += 1
            total += r.bytes
            if r.bytes < chunk {
                say("75s fetch: file hết (short read) ở \(elapsed)s (\(ranges) ranges, \(total)B) — COMPLETE")
                return "COMPLETE@\(elapsed)s"
            }
            offset += r.bytes
            if ranges % 30 == 0 {
                say("75s fetch: \(elapsed)s — \(ranges) ranges OK, tiếp tục")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        say("75s fetch: OK — \(ranges) ranges, \(total)B, zero 403 trong 75s")
        return "OK"
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
