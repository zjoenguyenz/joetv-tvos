import Foundation
import JavaScriptCore

// MARK: - YouTube native resolver (tv_samsung + EJS solver)
//
// The resolve leg of the native YouTube route (owner's
// single-route ruling, 2026-11-20), ported from YT Probe
// 16 (ProbeEjs.swift), which proved this exact chain on
// the owner's Apple TV (verdict ĐẠT, 2026-11-20):
//
//   device-code OAuth token (JoeYtIdentity)
//   → POST /player as the downgraded TVHTML5 client
//     (yt-dlp's `tv_samsung`: TVHTML5 5.20260707, Tizen)
//   → playability + format census
//   → player JS fetched AT RUNTIME (tv-player-ias from
//     the /tv page; embed base.js as fallback), accepted
//     only if it carries the decipher marker
//     "signatureCipher" (FL-335's gate — Probe 15 died
//     solving the wrong file)
//   → the vendored EJS solver (yt-dlp-ejs 0.8.0) runs in
//     a bare JavaScriptCore context and identifies the
//     sig/n functions BY BEHAVIOUR on the current player
//     generation (the regex families are dead upstream)
//   → deciphered adaptive AVC + AAC URLs for the local
//     HLS assembly, muxed 18 as the fallback playable.
//
// Every result is a Sendable value BY CONSTRUCTION — the
// response dictionaries are mapped to structs inside
// this actor and never cross a continuation
// ([CONTINUATION-SENDING]). Stream URLs and token values
// are NEVER logged: statuses, reasons (YouTube's public
// text), counts, hashes and milliseconds only (FL-073 /
// FL-076).

// MARK: Client spec

/// The downgraded TV client as data (yt-dlp master,
/// INNERTUBE_CLIENTS['tv_samsung'] — the spec Probe 14
/// captured and Probe 16 proved). The API key is the TV
/// client's PUBLIC InnerTube key, the same value the
/// probe's bundled ladder carries for TVHTML5 — it is
/// shipped in every YouTube TV client and is not an
/// account credential.
struct JoeYtClientSpec: Sendable {
    var clientName: String
    var clientVersion: String
    var clientNumber: String
    var userAgent: String
    var apiKey: String
    var deviceMake: String
    var deviceModel: String
    var osName: String
    var osVersion: String

    static let tvSamsung = JoeYtClientSpec(
        clientName: "TVHTML5",
        clientVersion: "5.20260707",
        clientNumber: "7",
        userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
        apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
        deviceMake: "Samsung",
        deviceModel: "UKS9800",
        osName: "Tizen",
        osVersion: "2.4.0")
}

// MARK: Format model (Sendable by construction)

struct JoeYtByteRange: Sendable {
    var start: Int64
    var end: Int64  // inclusive, per the /player payload
    var length: Int64 { end - start + 1 }
}

struct JoeYtFormat: Sendable {
    var itag: Int
    var mimeType: String
    var bitrate: Int
    var width: Int
    var height: Int
    var directURL: String?
    var cipher: String?
    var contentLength: Int64
    var approxDurationMs: Double
    var initRange: JoeYtByteRange?
    var indexRange: JoeYtByteRange?

    var isVideo: Bool { mimeType.hasPrefix("video/") }
    var isAudio: Bool { mimeType.hasPrefix("audio/") }
    var isAvc: Bool { mimeType.lowercased().contains("avc1") }
    var isAac: Bool { mimeType.lowercased().contains("mp4a") }
}

// MARK: Resolve outcome

/// What the assembly/player layer receives on success.
/// URLs live ONLY in this value (memory) — never in the
/// log, never on disk.
struct JoeYtPlayable: Sendable {
    enum Kind: Sendable {
        /// Deciphered adaptive pair → local HLS assembly.
        case assembly
        /// One deciphered muxed file → AVPlayer directly.
        case muxed
        /// The response carried an HLS manifest after all.
        case hlsManifest
    }
    var kind: Kind
    /// Assembly inputs (kind == .assembly).
    var videoURL: URL?
    var audioURL: URL?
    var videoInitRange: JoeYtByteRange?
    var audioInitRange: JoeYtByteRange?
    var videoContentLength: Int64 = 0
    var audioContentLength: Int64 = 0
    /// Direct input (kind == .muxed / .hlsManifest).
    var directURL: URL?
    /// When the assembly server cannot start, the player
    /// falls back to this deciphered muxed URL instead
    /// (kind == .assembly only; nil when no muxed format
    /// was solvable).
    var fallbackDirectURL: URL?
    /// Codec strings for the master playlist's CODECS
    /// attribute, lifted from the formats' mimeTypes.
    var videoCodec: String = ""
    var audioCodec: String = ""
    var videoItag: Int = 0
    var audioItag: Int = 0
    var width: Int = 0
    var height: Int = 0
    var videoBitrate: Int = 0
    var audioBitrate: Int = 0
    var durationSeconds: Double = 0
}

struct JoeYtResolveMetrics: Sendable {
    var playerMs: Int = 0
    var solverMs: Int = 0
    var playerHash: String = ""
    var formatCount: Int = 0
}

enum JoeYtResolveResult: Sendable {
    case playable(JoeYtPlayable, JoeYtResolveMetrics)
    /// No usable token — the router presents the
    /// device-code sign-in surface.
    case needsIdentity
    /// The live signal outranks the catalogue label: this
    /// episode is member-locked above the account's tier
    /// (reason is YouTube's own public text).
    case membersRequired(reason: String)
    case unplayable(status: String, reason: String)
    case httpFailure(status: Int)
    case transportFailure(message: String)
    /// The solver leg failed; `step` names the exact
    /// stage (the router's door+page fallback keys off
    /// this, and the log carries the step verbatim).
    case solverFailed(step: String, message: String)
}

// MARK: Resolver

actor JoeYtResolver {
    static let shared = JoeYtResolver()

    private let spec = JoeYtClientSpec.tvSamsung

    /// Session cache of the fetched player JS (the file
    /// is ~2.5 MB and its hash rotates rarely; the FETCH
    /// is cached, the solve still runs per resolve —
    /// challenges differ per video).
    private var cachedPlayerJS: PlayerJS?
    /// Session solve cache: player hash → nothing
    /// reusable across videos exists in the solver
    /// protocol (results are per-challenge), so the cache
    /// holds only WHICH hash has already solved cleanly —
    /// a diagnostic, logged when a later solve on the
    /// same hash fails (a same-hash failure after a
    /// success points at the network, not the solver).
    private var solvedHashes: Set<String> = []

    private func log(_ message: String) {
        DiagLog.write("YT-RES", message)
    }

    // MARK: Entry point

    func resolve(videoId: String) async -> JoeYtResolveResult {
        let identity = JoeYtIdentity.shared
        guard let initial = await identity.validAccessToken() else {
            log("resolve vid=\(videoId): không có access token dùng được → needsIdentity")
            return .needsIdentity
        }
        var token = initial
        var call = await callPlayer(token: token, videoId: videoId)
        if call.http == 401 {
            log("resolve vid=\(videoId): /player HTTP 401 — thử refresh 1 lần")
            var retried = false
            if let refreshed = await identity.refreshAccessToken() {
                token = refreshed
                call = await callPlayer(token: token, videoId: videoId)
                retried = true
            }
            if retried, call.http == 401 {
                log("resolve vid=\(videoId): vẫn 401 sau refresh — token chết, về needsIdentity")
                JoeYtOAuthStore.clearTokens()
                await identity.noteTokensCleared()
                return .needsIdentity
            }
            if !retried {
                // The refresh itself failed (network): the
                // stored tokens were never proven dead —
                // destroying them here would force a full
                // device-code re-approval over a transient
                // failure (review round 2, MINOR). Report
                // needsIdentity WITHOUT clearing.
                log("resolve vid=\(videoId): refresh thất bại — giữ token đã lưu, về needsIdentity không xoá")
                return .needsIdentity
            }
        }
        guard call.http == 200, let json = call.json else {
            if call.http == 0 {
                log("resolve vid=\(videoId): /player lỗi mạng (không có HTTP response)")
                return .transportFailure(message: "Không gọi được YouTube (mạng).")
            }
            log("resolve vid=\(videoId): /player HTTP \(call.http)")
            return .httpFailure(status: call.http)
        }

        let playability = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "?"
        let reason = (json["playabilityStatus"] as? [String: Any])?["reason"] as? String ?? ""
        var metrics = JoeYtResolveMetrics(playerMs: call.ms)

        guard playability == "OK" else {
            log("resolve vid=\(videoId): /player \(call.ms)ms playability=\(playability) reason=\(reason.isEmpty ? "-" : reason)")
            if playability == "LOGIN_REQUIRED" {
                return .needsIdentity
            }
            if playability == "UNPLAYABLE", Self.reasonNamesMemberTier(reason) {
                return .membersRequired(reason: reason)
            }
            return .unplayable(status: playability, reason: reason)
        }

        // Census — mapped to Sendable structs HERE; the
        // dictionaries never leave this function.
        let streaming = json["streamingData"] as? [String: Any]
        let muxedRaw = streaming?["formats"] as? [[String: Any]] ?? []
        let adaptiveRaw = streaming?["adaptiveFormats"] as? [[String: Any]] ?? []
        let muxed = muxedRaw.map(Self.mapFormat)
        let adaptive = adaptiveRaw.map(Self.mapFormat)
        let all = muxed + adaptive
        metrics.formatCount = all.count
        let cipheredCount = all.filter { $0.cipher != nil }.count
        log("resolve vid=\(videoId): /player \(call.ms)ms playability=OK formats=\(all.count) ciphered=\(cipheredCount)")

        if let hls = streaming?["hlsManifestUrl"] as? String, let hlsURL = URL(string: hls) {
            log("resolve vid=\(videoId): response có HLS manifest — dùng thẳng")
            var playable = JoeYtPlayable(kind: .hlsManifest)
            playable.directURL = hlsURL
            return .playable(playable, metrics)
        }

        // Selection — the CLOSED ladder of design §4.4,
        // no fail-soft extras (review round 7, MINOR:
        // three by-bitrate fallbacks beyond the spec's
        // closed form were removed — a response without
        // a ladder AVC rung, without itag 140, or
        // without muxed 18 is NO_FORMATS / muxed-less by
        // the spec's own failure table, not an invitation
        // to improvise a format the design never chose).
        let videoLadder = [137, 136, 135, 134, 133, 160]
        let video = videoLadder.compactMap { tag in
            adaptive.first { $0.itag == tag && $0.isVideo && $0.isAvc }
        }.first
        let audio = adaptive.first { $0.itag == 140 && $0.isAudio }
        let muxedFallback = muxed.first { $0.itag == 18 }

        var targets: [JoeYtFormat] = []
        if let video { targets.append(video) }
        if let audio { targets.append(audio) }
        if let muxedFallback { targets.append(muxedFallback) }
        // A playable needs a COMPLETE format set
        // (review rounds 3+4, MINOR): an adaptive pair
        // (video AND audio) or a muxed file. Anything
        // less — audio-only, or video with no audio and
        // no muxed — would otherwise "solve" fine and
        // fall out the bottom mislabelled as a solver
        // failure at step "apply"; the response simply
        // has nothing playable, which is NO_FORMATS.
        guard (video != nil && audio != nil) || muxedFallback != nil else {
            log("resolve vid=\(videoId): census không đủ bộ format (video=\(video != nil) audio=\(audio != nil) muxed=\(muxedFallback != nil))")
            return .unplayable(status: "NO_FORMATS", reason: "")
        }

        // What does this response need from the solver?
        var needsSig = false
        var needsN = false
        for format in targets {
            if let plain = format.directURL {
                if nParameter(in: plain) != nil { needsN = true }
            } else if let cipher = format.cipher {
                needsSig = true
                if let parts = parseCipher(cipher),
                   nParameter(in: parts.url) != nil { needsN = true }
            }
        }

        var sigResults: [String: String]?
        var nResults: [String: String]?
        if needsSig || needsN {
            var sigChallenges: [String] = []
            var nChallenges: [String] = []
            for format in targets {
                if let cipher = format.cipher, let parts = parseCipher(cipher) {
                    if needsSig, !sigChallenges.contains(parts.s) {
                        sigChallenges.append(parts.s)
                    }
                    if let nParam = nParameter(in: parts.url),
                       !nChallenges.contains(nParam.value) {
                        nChallenges.append(nParam.value)
                    }
                } else if let plain = format.directURL,
                          let nParam = nParameter(in: plain),
                          !nChallenges.contains(nParam.value) {
                    nChallenges.append(nParam.value)
                }
            }
            let solve = await solve(videoId: videoId,
                                    sigChallenges: sigChallenges,
                                    nChallenges: nChallenges,
                                    needsSig: needsSig, needsN: needsN)
            switch solve {
            case .failed(let step, let message):
                return .solverFailed(step: step, message: message)
            case .solved(let sig, let n, let ms, let hash):
                sigResults = sig
                nResults = n
                metrics.solverMs = ms
                metrics.playerHash = hash
            }
        }

        // Apply the solver's results PER CONSTRUCTION
        // (review round 5, MINOR): one format's failed
        // apply must not discard a complete playable
        // built from the others — a failed muxed apply
        // leaves the assembly pair intact (it merely
        // loses its fallback URL), and a failed adaptive
        // leg leaves a solved muxed file playable. The
        // fall-out at the bottom is now genuinely "no
        // construction survived".
        var solvedURLs: [Int: URL] = [:]
        for format in targets {
            let outcome = applySolved(format: format,
                                      sigResults: sigResults, nResults: nResults)
            switch outcome {
            case .solved(let url):
                solvedURLs[format.itag] = url
            case .failed(let why):
                log("resolve vid=\(videoId): apply itag \(format.itag) thất bại — \(why) (kiểm tra các construction còn lại)")
            }
        }

        // The assembly branch additionally requires a
        // usable initialization section on BOTH legs
        // (review round 7, MINOR): an fMP4 media
        // playlist without EXT-X-MAP is not valid HLS
        // (RFC 8216), so a format whose response carries
        // no initRange cannot enter the assembly — the
        // muxed construction below is the designed
        // fallback for that shape.
        //
        // It also requires at least one MEDIA byte
        // after the init section on BOTH legs (Lens B
        // F-B2): initRange.end is INCLUSIVE and
        // contentLength counts the whole file, so the
        // media segment starts at end + 1 and holds
        // contentLength - (end + 1) bytes — positive
        // only when contentLength > end + 1, the exact
        // test the assembly server applies before it
        // emits EXT-X-BYTERANGE. mapFormat stores 0
        // when the payload omits contentLength, so a
        // missing length fails this gate as well;
        // without it the server would emit MAP + EXTINF
        // with no BYTERANGE line and the init bytes
        // would be fetched twice.
        if let video, let audio, (video.initRange == nil || audio.initRange == nil) {
            log("resolve vid=\(videoId): cặp adaptive thiếu initRange (video=\(video.initRange != nil) audio=\(audio.initRange != nil)) — bỏ qua assembly, xét muxed")
        }
        if let video, let audio,
           let videoInit = video.initRange, let audioInit = audio.initRange,
           video.contentLength <= videoInit.end + 1
               || audio.contentLength <= audioInit.end + 1 {
            log("resolve vid=\(videoId): cặp adaptive không còn byte media sau init (video contentLength=\(video.contentLength) initEnd=\(videoInit.end) · audio contentLength=\(audio.contentLength) initEnd=\(audioInit.end)) — bỏ qua assembly, xét muxed")
        }
        // The init ranges themselves must also be
        // valid (Lens B F-B3): range() parses start/end
        // as raw Int64 and accepts end < start (length
        // ≤ 0) or a negative start, but the EXT-X-MAP
        // the server emits carries
        // BYTERANGE="<length>@<start>" — RFC 8216
        // requires a positive length and a non-negative
        // offset, and AVPlayer rejects the item
        // otherwise. The gate is the single decision
        // point, so the pair is rejected here like the
        // F-B2 shape above; range() itself stays a
        // plain parser.
        if let video, let audio,
           let videoInit = video.initRange, let audioInit = audio.initRange,
           videoInit.length <= 0 || videoInit.start < 0
               || audioInit.length <= 0 || audioInit.start < 0 {
            log("resolve vid=\(videoId): cặp adaptive có initRange không hợp lệ (video length=\(videoInit.length) start=\(videoInit.start) · audio length=\(audioInit.length) start=\(audioInit.start)) — bỏ qua assembly, xét muxed")
        }
        if let video, let audio,
           let videoInit = video.initRange, let audioInit = audio.initRange,
           video.contentLength > videoInit.end + 1,
           audio.contentLength > audioInit.end + 1,
           videoInit.length > 0, videoInit.start >= 0,
           audioInit.length > 0, audioInit.start >= 0,
           let videoURL = solvedURLs[video.itag],
           let audioURL = solvedURLs[audio.itag] {
            var playable = JoeYtPlayable(kind: .assembly)
            playable.videoURL = videoURL
            playable.audioURL = audioURL
            playable.videoInitRange = videoInit
            playable.audioInitRange = audioInit
            playable.videoContentLength = video.contentLength
            playable.audioContentLength = audio.contentLength
            playable.videoItag = video.itag
            playable.audioItag = audio.itag
            playable.width = video.width
            playable.height = video.height
            playable.videoBitrate = video.bitrate
            playable.audioBitrate = audio.bitrate
            playable.videoCodec = Self.codecString(from: video.mimeType)
            playable.audioCodec = Self.codecString(from: audio.mimeType)
            if let muxedFallback, let muxedURL = solvedURLs[muxedFallback.itag] {
                playable.fallbackDirectURL = muxedURL
            }
            playable.durationSeconds = max(video.approxDurationMs, audio.approxDurationMs) / 1000.0
            log("resolve vid=\(videoId): OK — cặp adaptive itag \(video.itag)+\(audio.itag) "
                + "(\(video.width)x\(video.height)) cho assembly, solver \(metrics.solverMs)ms")
            return .playable(playable, metrics)
        }
        if let muxedFallback, let url = solvedURLs[muxedFallback.itag] {
            var playable = JoeYtPlayable(kind: .muxed)
            playable.directURL = url
            playable.videoItag = muxedFallback.itag
            playable.width = muxedFallback.width
            playable.height = muxedFallback.height
            playable.videoBitrate = muxedFallback.bitrate
            playable.durationSeconds = muxedFallback.approxDurationMs / 1000.0
            log("resolve vid=\(videoId): OK — bản muxed itag \(muxedFallback.itag) (không đủ cặp adaptive)")
            return .playable(playable, metrics)
        }
        log("resolve vid=\(videoId): không dựng được playable nào từ các target đã giải")
        return .solverFailed(step: "apply",
                             message: "Không dựng được URL phát từ các format đã giải mã.")
    }

    /// `video/mp4; codecs="avc1.640028"` → `avc1.640028`
    /// (the first codec when several are listed).
    private static func codecString(from mimeType: String) -> String {
        guard let start = mimeType.range(of: "codecs=\"") else { return "" }
        let rest = mimeType[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return "" }
        let list = rest[..<end]
        return list.split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private static func reasonNamesMemberTier(_ reason: String) -> Bool {
        let lower = reason.lowercased()
        return lower.contains("member")
            || lower.contains("thành viên")
            || lower.contains("level:")
    }

    // MARK: /player call (Probe 16's shape, verbatim)

    private func callPlayer(token: String,
                            videoId: String) async -> (http: Int, json: [String: Any]?, ms: Int) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false&key=\(spec.apiKey)") else {
            return (0, nil, 0)
        }
        let clientContext: [String: Any] = [
            "clientName": spec.clientName,
            "clientVersion": spec.clientVersion,
            "hl": "en",
            "gl": "US",
            "userAgent": spec.userAgent,
            "deviceMake": spec.deviceMake,
            "deviceModel": spec.deviceModel,
            "osName": spec.osName,
            "osVersion": spec.osVersion,
        ]
        let body: [String: Any] = [
            "videoId": videoId,
            "context": ["client": clientContext],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(spec.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(spec.clientNumber, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(spec.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let t0 = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (http, json, ms)
        } catch {
            return (0, nil, Int(Date().timeIntervalSince(t0) * 1000))
        }
    }

    private static func mapFormat(_ raw: [String: Any]) -> JoeYtFormat {
        func range(_ key: String) -> JoeYtByteRange? {
            guard let dict = raw[key] as? [String: Any],
                  let startText = dict["start"] as? String,
                  let endText = dict["end"] as? String,
                  let start = Int64(startText), let end = Int64(endText) else { return nil }
            return JoeYtByteRange(start: start, end: end)
        }
        let durationText = raw["approxDurationMs"] as? String
        let durationNumber = raw["approxDurationMs"] as? NSNumber
        return JoeYtFormat(
            itag: (raw["itag"] as? NSNumber)?.intValue ?? 0,
            mimeType: raw["mimeType"] as? String ?? "",
            bitrate: (raw["bitrate"] as? NSNumber)?.intValue ?? 0,
            width: (raw["width"] as? NSNumber)?.intValue ?? 0,
            height: (raw["height"] as? NSNumber)?.intValue ?? 0,
            directURL: raw["url"] as? String,
            cipher: raw["signatureCipher"] as? String,
            contentLength: Int64(raw["contentLength"] as? String ?? "") ?? 0,
            approxDurationMs: durationNumber?.doubleValue
                ?? Double(durationText ?? "") ?? 0,
            initRange: range("initRange"),
            indexRange: range("indexRange"))
    }

    // MARK: Solver orchestration

    private enum SolveOutcome {
        case solved(sig: [String: String]?, n: [String: String]?, ms: Int, hash: String)
        case failed(step: String, message: String)
    }

    /// Fetch (or reuse) the player JS, run the solver,
    /// retry once against the embed player file when the
    /// failure is retryable — Probe 16's exact policy.
    private func solve(videoId: String, sigChallenges: [String], nChallenges: [String],
                       needsSig: Bool, needsN: Bool) async -> SolveOutcome {
        guard let playerJS = await acquirePlayerJS(videoId: videoId) else {
            return .failed(step: "player-js",
                           message: "Không lấy được file player JS (cả nguồn tv-player-ias lẫn embed).")
        }
        // The hash names the file that ACTUALLY solved
        // (review round 2, MINOR): when the embed retry
        // wins, the TV file's hash must not be recorded —
        // the same-hash diagnostic is the cache's point.
        var winnerPath = playerJS.path
        var attempt = await runSolverAttempt(playerJS: playerJS,
                                             sigChallenges: sigChallenges,
                                             nChallenges: nChallenges)
        if let failure = solverFailure(attempt, needsSig: needsSig, needsN: needsN) {
            var finalFailure = failure
            // A cancelled caller must not spend a second
            // fetch + full solve (review count round 1,
            // Lens A F-4): the A-1 orphan bound covers
            // ONE attempt; without this check a
            // retryable first failure would run the
            // whole embed leg for a caller that has
            // already walked away.
            if Task.isCancelled {
                return .failed(step: failure.step, message: failure.verdict)
            }
            if failure.retryable, playerJS.source == "tv-player-ias" {
                log("solver: lần thử tv-player-ias chưa xong (\(failure.verdict)) — thử lại với player của trang embed")
                if let embedJS = await fetchEmbedPlayerJS(videoId: videoId) {
                    let second = await runSolverAttempt(playerJS: embedJS,
                                                         sigChallenges: sigChallenges,
                                                         nChallenges: nChallenges)
                    if let secondFailure = solverFailure(second, needsSig: needsSig, needsN: needsN) {
                        finalFailure = secondFailure
                    } else {
                        attempt = second
                        winnerPath = embedJS.path
                        finalFailure = (verdict: "", step: "", retryable: false)
                    }
                }
            }
            if !finalFailure.verdict.isEmpty {
                let step = finalFailure.step
                return .failed(step: step, message: finalFailure.verdict)
            }
        }
        let hash = Self.playerHash(fromPath: winnerPath)
        solvedHashes.insert(hash)
        DiagLog.write("YT-SOLVER", "hash \(hash) — giải xong sig=\(attempt.sigResults?.count ?? 0) n=\(attempt.nResults?.count ?? 0) trong \(attempt.elapsedMs)ms")
        return .solved(sig: attempt.sigResults, n: attempt.nResults,
                       ms: attempt.elapsedMs, hash: hash)
    }

    private static func playerHash(fromPath path: String) -> String {
        // /s/player/<hash>/… — the hash is the segment
        // right after "player".
        let parts = path.split(separator: "/")
        if let index = parts.firstIndex(of: "player"), index + 1 < parts.count {
            return String(parts[index + 1])
        }
        return "unknown"
    }

    private func runSolverAttempt(playerJS: PlayerJS, sigChallenges: [String],
                                  nChallenges: [String]) async -> EjsSolveOutcome {
        let playerText = playerJS.text
        // The solve runs detached because JSC evaluation
        // is synchronous (~2.4 s measured) and must not
        // block this actor. Cancellation honesty (review
        // round 7, MINOR): a synchronous JSC eval cannot
        // be interrupted mid-flight, so a cancelled
        // caller leaves a BOUNDED orphan — the detached
        // task finishes its one solve (≤ ~2.4 s + the
        // 2.5 MB player parse) and its outcome is then
        // discarded by the callers' attempt guards. The
        // handler exists so the cancellation is at least
        // on the record, and the post-await check logs
        // the discard instead of pretending the solve
        // never ran.
        let outcome = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> EjsSolveOutcome in
                JoeYtEjsSolver.solve(player: playerText, sigChallenges: sigChallenges,
                                     nChallenges: nChallenges)
            }.value
        } onCancel: {
            DiagLog.write("YT-SOLVER", "caller đã hủy trong lúc solver chạy — eval đồng bộ không ngắt được, kết quả sẽ bị bỏ qua khi về đích (mồ côi có biên)")
        }
        if Task.isCancelled {
            log("solver: resolve đã bị hủy — outcome của lần solve này bị bỏ qua theo attempt guard của caller")
        }
        for note in outcome.notes { DiagLog.write("YT-SOLVER", note) }
        return outcome
    }

    /// nil = the outcome satisfies this run's needs.
    /// Otherwise the verdict + the failing step + whether
    /// swapping the player file could change it (load
    /// failures are artifact-level — the same for every
    /// player file — so they never retry).
    private func solverFailure(_ outcome: EjsSolveOutcome,
                               needsSig: Bool, needsN: Bool)
        -> (verdict: String, step: String, retryable: Bool)? {
        if let step = outcome.loadErrorStep {
            return ("SOLVER KHÔNG NẠP ĐƯỢC — \(step): \(outcome.loadErrorMessage ?? "")",
                    step, false)
        }
        if let step = outcome.runErrorStep {
            return ("SOLVER CHẠY LỖI — \(step): \(outcome.runErrorMessage ?? "")",
                    step, true)
        }
        if needsSig, let sigError = outcome.sigError {
            return ("SOLVER KHÔNG NHẬN DIỆN ĐƯỢC — sig: \(sigError)",
                    "solver identify sig", true)
        }
        if needsN, let nError = outcome.nError {
            return ("SOLVER KHÔNG NHẬN DIỆN ĐƯỢC — n: \(nError)",
                    "solver identify n", true)
        }
        if needsSig, outcome.sigResults == nil {
            return ("KHÔNG KẾT ÁN ĐƯỢC — solver không trả kết quả sig mà cũng không báo lỗi",
                    "solver run", false)
        }
        if needsN, outcome.nResults == nil {
            return ("KHÔNG KẾT ÁN ĐƯỢC — solver không trả kết quả n mà cũng không báo lỗi",
                    "solver run", false)
        }
        return nil
    }

    // MARK: Player JS acquisition (runtime, marker-gated)
    //
    // FL-335's gate as code: a JS file is only accepted
    // as THE player if it carries the decipher
    // machinery's marker ("signatureCipher"). The kabuki
    // bundle of the TV web app carries it ZERO times and
    // is rejected by construction.

    private struct PlayerJS: Sendable {
        var text: String
        var source: String
        var host: String
        var path: String
        var markerCount: Int
    }

    private static let tvScrapeUA = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/5.0 Chrome/85.0.4183.120 TV Safari/537.36"
    private static let embedUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private func markerCount(in js: String) -> Int {
        var count = 0
        var searchFrom = js.startIndex
        while let found = js.range(of: "signatureCipher", range: searchFrom..<js.endIndex) {
            count += 1
            searchFrom = found.upperBound
        }
        return count
    }

    private func fetchPlayerFile(urlString: String, source: String,
                                 userAgent: String) async -> PlayerJS? {
        guard let js = await fetchText(urlString, userAgent: userAgent) else {
            log("player-js: tải file cho nguồn \(source) THẤT BẠI")
            return nil
        }
        let markers = markerCount(in: js)
        let url = URL(string: urlString)
        let host = url?.host ?? "?"
        let path = url?.path ?? "?"
        guard js.utf8.count > 100_000 else {
            log("player-js: nguồn \(source) trả file quá ngắn (\(js.utf8.count) bytes) — không dùng")
            return nil
        }
        guard markers > 0 else {
            log("player-js: nguồn \(source) — file \(js.utf8.count) bytes nhưng marker signatureCipher ×0 — SAI FILE, loại")
            return nil
        }
        log("player-js: nguồn \(source) OK — host \(host), path \(path), \(js.utf8.count) bytes, marker signatureCipher ×\(markers)")
        return PlayerJS(text: js, source: source, host: host, path: path, markerCount: markers)
    }

    private func fetchTVPlayerJS() async -> PlayerJS? {
        guard let rawHTML = await fetchText("https://www.youtube.com/tv", userAgent: Self.tvScrapeUA) else {
            log("player-js: tải trang /tv THẤT BẠI")
            return nil
        }
        let html = rawHTML.replacingOccurrences(of: "\\/", with: "/")
        let patterns: [(label: String, pattern: String)] = [
            ("jsUrl tv-player-ias", #""jsUrl"\s*:\s*"([^"]*tv-player-ias[^"]*\.js)""#),
            ("player_url tv-player-ias", #""player_url"\s*:\s*"([^"]*tv-player-ias[^"]*\.js)""#),
            ("/s/player/*.js đầu tiên", #""(/s/player/[^"]*\.js)""#),
        ]
        for entry in patterns {
            if let src = regexCapture(in: html, pattern: entry.pattern, group: 1) {
                let full = src.hasPrefix("http") ? src : "https://www.youtube.com" + src
                log("player-js: trang /tv trỏ player bằng pattern '\(entry.label)' → path \(URL(string: full)?.path ?? src)")
                return await fetchPlayerFile(urlString: full, source: "tv-player-ias",
                                             userAgent: Self.tvScrapeUA)
            }
        }
        log("player-js: trang /tv không thấy tham chiếu player JS nào (cả 3 pattern đều miss)")
        return nil
    }

    private func fetchEmbedPlayerJS(videoId: String) async -> PlayerJS? {
        guard let rawHTML = await fetchText("https://www.youtube.com/embed/\(videoId)",
                                            userAgent: Self.embedUA) else {
            log("player-js: tải trang embed THẤT BẠI")
            return nil
        }
        let html = rawHTML.replacingOccurrences(of: "\\/", with: "/")
        guard let src = regexCapture(in: html, pattern: #""jsUrl"\s*:\s*"([^"]+)""#, group: 1) else {
            log("player-js: trang embed không có jsUrl")
            return nil
        }
        let full = src.hasPrefix("http") ? src : "https://www.youtube.com" + src
        log("player-js: trang embed trỏ jsUrl → path \(URL(string: full)?.path ?? src)")
        return await fetchPlayerFile(urlString: full, source: "embed",
                                     userAgent: Self.embedUA)
    }

    private func acquirePlayerJS(videoId: String) async -> PlayerJS? {
        if let cached = cachedPlayerJS {
            log("player-js: dùng bản cache trong phiên (nguồn \(cached.source), \(cached.text.utf8.count) bytes)")
            return cached
        }
        let fetched: PlayerJS?
        if let tv = await fetchTVPlayerJS() {
            fetched = tv
        } else {
            log("player-js: nguồn tv-player-ias không dùng được — rơi xuống nguồn embed")
            fetched = await fetchEmbedPlayerJS(videoId: videoId)
        }
        if let fetched { cachedPlayerJS = fetched }
        return fetched
    }

    // MARK: Cipher handling (probe shapes, verbatim)

    private struct CipherParts {
        var s: String
        var sp: String
        var url: String
    }

    private func parseCipher(_ cipher: String) -> CipherParts? {
        var fields: [String: String] = [:]
        for pair in cipher.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            fields[key] = value
        }
        guard let s = fields["s"], let url = fields["url"] else { return nil }
        return CipherParts(s: s, sp: fields["sp"] ?? "signature", url: url)
    }

    private func percentEncodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func nParameter(in url: String) -> (value: String, range: Range<String.Index>)? {
        let question = url.range(of: "?n=")
        let amp = url.range(of: "&n=")
        let marker: Range<String.Index>?
        switch (question, amp) {
        case let (q?, a?): marker = q.lowerBound < a.lowerBound ? q : a
        case let (q?, nil): marker = q
        case let (nil, a?): marker = a
        case (nil, nil): marker = nil
        }
        guard let marker else { return nil }
        let valueStart = marker.upperBound
        let valueEnd = url.range(of: "&", range: valueStart..<url.endIndex)?.lowerBound ?? url.endIndex
        let raw = String(url[valueStart..<valueEnd])
        return (raw.removingPercentEncoding ?? raw, valueStart..<valueEnd)
    }

    private enum ApplyOutcome {
        case solved(url: URL)
        case failed(why: String)
    }

    /// One format → a playable URL: plain URL as-is, else
    /// append the solver's deciphered `s` under the
    /// cipher's `sp` name, then replace the URL's `n`
    /// value with the solver's transformed one, in place.
    private func applySolved(format: JoeYtFormat,
                             sigResults: [String: String]?,
                             nResults: [String: String]?) -> ApplyOutcome {
        var urlString: String
        if let rawURL = format.directURL {
            urlString = rawURL
        } else if let cipher = format.cipher {
            guard let parts = parseCipher(cipher) else {
                return .failed(why: "apply: itag \(format.itag) signatureCipher không parse được (thiếu s hoặc url)")
            }
            guard let solvedSig = sigResults?[parts.s], !solvedSig.isEmpty else {
                return .failed(why: "apply: solver không có kết quả sig cho itag \(format.itag)")
            }
            urlString = parts.url + "&" + parts.sp + "=" + percentEncodeQueryValue(solvedSig)
        } else {
            return .failed(why: "apply: itag \(format.itag) không có url cũng không có signatureCipher")
        }
        if let nParam = nParameter(in: urlString) {
            if let solvedN = nResults?[nParam.value], !solvedN.isEmpty {
                urlString.replaceSubrange(nParam.range, with: percentEncodeQueryValue(solvedN))
            } else if nResults != nil {
                return .failed(why: "apply: solver không có kết quả n cho itag \(format.itag)")
            }
        }
        guard let url = URL(string: urlString) else {
            return .failed(why: "apply: itag \(format.itag) URL sau giải mã không hợp lệ")
        }
        return .solved(url: url)
    }

    // MARK: HTTP helpers

    private func regexCapture(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let capture = Range(match.range(at: group), in: text) else { return nil }
        return String(text[capture])
    }

    private func fetchText(_ urlString: String, userAgent: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }
}

// MARK: - EJS solver (vendored yt-dlp-ejs 0.8.0)
//
// Bundled resources (pinned; recorded in the build
// report):
//   yt.solver.lib.min.js  — 151,561 B, md5
//     7fbcfdf209230f48e7a5ce656ba9bfda (meriyah 6.1.4 +
//     astring 1.9.0, upstream minified build)
//   yt.solver.core.min.js — 6,945 B, md5
//     72eb80c74322cb0f4f10f69e64ff9352 (the solver)
// Upstream: yt-dlp-ejs 0.8.0 (PyPI wheel yt_dlp_ejs-0.8.0).
//
// The harness mirrors upstream's driver (yt-dlp master,
// jsc/_builtin/ejs.py `_construct_stdin`) line for line:
//   {lib}  →  Object.assign(globalThis, lib);
//   {core} →  jsc({type:"player", player, requests,
//                  output_preprocessed:false})
// Only the transport differs: the input crosses as
// JSValues and the JSON string comes back as the
// driver's value. Ported verbatim from Probe 16's
// EjsSolver (device-proven 2026-11-20).
//
// Everything runs inside ONE detached task: the
// JSContext is created, used and released there, so the
// context never crosses an actor boundary.

struct EjsSolveOutcome: Sendable {
    var notes: [String] = []
    var loadErrorStep: String?
    var loadErrorMessage: String?
    var runErrorStep: String?
    var runErrorMessage: String?
    var sigResults: [String: String]?
    var sigError: String?
    var nResults: [String: String]?
    var nError: String?
    var elapsedMs: Int = 0
}

enum JoeYtEjsSolver {

    static func solve(player: String, sigChallenges: [String],
                      nChallenges: [String]) -> EjsSolveOutcome {
        var outcome = EjsSolveOutcome()
        let t0 = Date()
        defer { outcome.elapsedMs = Int(Date().timeIntervalSince(t0) * 1000) }

        let createdContext: JSContext? = JSContext()
        guard let context = createdContext else {
            outcome.loadErrorStep = "solver load (JSContext)"
            outcome.loadErrorMessage = "không tạo được JSContext"
            return outcome
        }

        // lib: meriyah + astring.
        guard let libSource = bundledText("yt.solver.lib.min", "js") else {
            outcome.loadErrorStep = "solver load (lib resource)"
            outcome.loadErrorMessage = "không tìm thấy yt.solver.lib.min.js trong bundle"
            return outcome
        }
        _ = context.evaluateScript(libSource)
        if let message = takeException(from: context) {
            outcome.loadErrorStep = "solver load (lib eval)"
            outcome.loadErrorMessage = message
            return outcome
        }
        _ = context.evaluateScript("Object.assign(globalThis, lib);")
        if let message = takeException(from: context) {
            outcome.loadErrorStep = "solver load (Object.assign(globalThis, lib))"
            outcome.loadErrorMessage = message
            return outcome
        }
        let parseType = context.evaluateScript("typeof lib.meriyah.parse")?.toString() ?? "?"
        let generateType = context.evaluateScript("typeof lib.astring.generate")?.toString() ?? "?"
        outcome.notes.append("solver: lib nạp OK (\(libSource.utf8.count) bytes) — lib.meriyah.parse=\(parseType), lib.astring.generate=\(generateType)")
        guard parseType == "function", generateType == "function" else {
            outcome.loadErrorStep = "solver load (lib shape)"
            outcome.loadErrorMessage = "thiếu API — lib.meriyah.parse=\(parseType), lib.astring.generate=\(generateType)"
            return outcome
        }

        // core: defines `jsc` = the solver main.
        guard let coreSource = bundledText("yt.solver.core.min", "js") else {
            outcome.loadErrorStep = "solver load (core resource)"
            outcome.loadErrorMessage = "không tìm thấy yt.solver.core.min.js trong bundle"
            return outcome
        }
        _ = context.evaluateScript(coreSource)
        if let message = takeException(from: context) {
            outcome.loadErrorStep = "solver load (core eval)"
            outcome.loadErrorMessage = message
            return outcome
        }
        let jscType = context.evaluateScript("typeof jsc")?.toString() ?? "?"
        outcome.notes.append("solver: core nạp OK (\(coreSource.utf8.count) bytes) — typeof jsc=\(jscType)")
        guard jscType == "function" else {
            outcome.loadErrorStep = "solver load (jsc)"
            outcome.loadErrorMessage = "jsc không phải function (typeof=\(jscType))"
            return outcome
        }

        // Run: the input crosses as JSValues; the driver
        // builds the upstream input object and returns
        // JSON.stringify(jsc(input)).
        context.setObject(player, forKeyedSubscript: "__ejsPlayer" as NSString)
        context.setObject(sigChallenges, forKeyedSubscript: "__ejsSigChallenges" as NSString)
        context.setObject(nChallenges, forKeyedSubscript: "__ejsNChallenges" as NSString)
        let driver = """
        (function () {
          var requests = [];
          if (__ejsSigChallenges.length > 0) { requests.push({type: "sig", challenges: __ejsSigChallenges}); }
          if (__ejsNChallenges.length > 0) { requests.push({type: "n", challenges: __ejsNChallenges}); }
          var output = jsc({type: "player", player: __ejsPlayer, requests: requests, output_preprocessed: false});
          return JSON.stringify(output);
        })()
        """
        let result = context.evaluateScript(driver)
        if let message = takeException(from: context) {
            outcome.runErrorStep = "solver run (jsc)"
            outcome.runErrorMessage = message
            return outcome
        }
        guard let jsonText = result?.toString(),
              !jsonText.isEmpty, jsonText != "undefined" else {
            outcome.runErrorStep = "solver run (output)"
            outcome.runErrorMessage = "jsc không trả về chuỗi JSON"
            return outcome
        }
        guard let parsed = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))) as? [String: Any] else {
            outcome.runErrorStep = "solver run (output parse)"
            outcome.runErrorMessage = "JSON từ jsc không parse được (\(jsonText.utf8.count) bytes)"
            return outcome
        }
        if (parsed["type"] as? String) == "error" {
            outcome.runErrorStep = "solver run (jsc output)"
            outcome.runErrorMessage = (parsed["error"] as? String) ?? "output type=error, không có text"
            return outcome
        }
        let responses = parsed["responses"] as? [[String: Any]] ?? []
        var index = 0
        if !sigChallenges.isEmpty {
            readResponse(responses, at: index, kind: "sig", into: &outcome)
            index += 1
        }
        if !nChallenges.isEmpty {
            readResponse(responses, at: index, kind: "n", into: &outcome)
            index += 1
        }
        return outcome
    }

    /// One request's response → results or a named
    /// identify failure. Only counts and result LENGTHS
    /// are noted — never values.
    private static func readResponse(_ responses: [[String: Any]], at index: Int,
                                     kind: String, into outcome: inout EjsSolveOutcome) {
        guard index < responses.count else {
            setError(&outcome, kind: kind,
                     message: "solver không trả response cho \(kind)")
            outcome.notes.append("solver: \(kind) — KHÔNG có response")
            return
        }
        let response = responses[index]
        if (response["type"] as? String) == "error" {
            let raw = (response["error"] as? String) ?? "error không có text"
            let trimmed = raw.count > 300 ? String(raw.prefix(300)) + "…" : raw
            setError(&outcome, kind: kind, message: trimmed)
            outcome.notes.append("solver: \(kind) — KHÔNG NHẬN DIỆN ĐƯỢC: \(trimmed)")
            return
        }
        let data = response["data"] as? [String: String] ?? [:]
        let lengths = data.values.map { $0.count }.sorted()
        if kind == "sig" { outcome.sigResults = data } else { outcome.nResults = data }
        outcome.notes.append("solver: \(kind) — NHẬN DIỆN ĐƯỢC, giải \(data.count) challenge, độ dài kết quả \(lengths)")
    }

    private static func setError(_ outcome: inout EjsSolveOutcome,
                                 kind: String, message: String) {
        if kind == "sig" { outcome.sigError = message } else { outcome.nError = message }
    }

    private static func bundledText(_ name: String, _ ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func takeException(from context: JSContext) -> String? {
        guard let exception = context.exception, !exception.isUndefined else { return nil }
        context.exception = nil
        return exception.toString() ?? "JS exception (không có text)"
    }
}
