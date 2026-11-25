import CryptoKit
import Foundation
import JavaScriptCore

// MARK: - YT PROBE — parameterized resolver copy
//
// A PROBE COPY of JoeTV's JoeYtResolver.swift (the run60
// shape: player JS first, signatureTimestamp in
// playbackContext, Origin header, TV-family specs),
// reworked for the YT-403 variant matrix (PROBE-SPEC
// 2026-11-24): the /player call is parameterized per
// variant (client spec, key on/off, bearer-or-none,
// visitorData for 3b) and the resolve returns the solved
// itag 140 / itag 18 URLs plus n-solve diagnostics
// instead of building a playable. The production
// resolver is NOT touched by this file. Everything below
// the probe entry point (player-JS acquisition, cipher
// handling, the vendored EJS solver) is the production
// code verbatim.
//
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

    /// YT-403 round 3 (2026-11-23): yt-dlp's other
    /// TV-family client — clientName TVHTML5 with the
    /// Cobalt UA and version 7.20260707.07.00
    /// (INNERTUBE_CLIENTS['tv'], SUPPORTS_COOKIES).
    /// Device fields are empty: yt-dlp sends none for
    /// this client and the context builder omits
    /// empty fields. Same public TV key as tvSamsung.
    static let tv = JoeYtClientSpec(
        clientName: "TVHTML5",
        clientVersion: "7.20260707.07.00",
        clientNumber: "7",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)",
        apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
        deviceMake: "",
        deviceModel: "",
        osName: "",
        osVersion: "")
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

// MARK: Probe outcome types

/// One matrix variant: the knobs the production
/// resolver holds fixed, made per-run data.
struct ProbeVariant: Sendable {
    var id: String
    var label: String
    var spec: JoeYtClientSpec
    var sendKey: Bool
    var useAuth: Bool
    var useVisitorData: Bool
    /// PO-token probe (SPEC §8): when true the resolve
    /// mints (or reuses) the session PO token and attaches
    /// it at every SPEC §5 point. When false the resolve
    /// is EXACTLY today's probe behaviour — variants
    /// 1/2/3/3b/5 are the negative control (SPEC §9.5).
    var usePoToken: Bool

    /// PROBE-SPEC v1 variants (1, 2, 3, 3b, 5).
    static let v1 = ProbeVariant(
        id: "1", label: "tv_samsung run60 (sts+key, bearer)",
        spec: .tvSamsung, sendKey: true, useAuth: true, useVisitorData: false,
        usePoToken: false)
    static let v2 = ProbeVariant(
        id: "2", label: "tv_samsung run60 NO key, bearer",
        spec: .tvSamsung, sendKey: false, useAuth: true, useVisitorData: false,
        usePoToken: false)
    static let v3 = ProbeVariant(
        id: "3", label: "tv Cobalt parity (sts, no key, bearer)",
        spec: .tv, sendKey: false, useAuth: true, useVisitorData: false,
        usePoToken: false)
    static let v3b = ProbeVariant(
        id: "3b", label: "tv Cobalt parity + visitorData",
        spec: .tv, sendKey: false, useAuth: true, useVisitorData: true,
        usePoToken: false)
    static let v5 = ProbeVariant(
        id: "5", label: "tv_samsung parity, NO auth (V-pub only)",
        spec: .tvSamsung, sendKey: false, useAuth: false, useVisitorData: false,
        usePoToken: false)

    /// PO-token variant (2026-11-25): v1's exact shape
    /// with the PO token FORCED ON (SPEC §8 probe mode).
    static let v6 = ProbeVariant(
        id: "6", label: "tv_samsung run60 + PO token (FORCED ON)",
        spec: .tvSamsung, sendKey: true, useAuth: true, useVisitorData: false,
        usePoToken: true)
}

/// Per-n-challenge solve diagnostics: lengths and a
/// short hash ONLY — the values themselves never leave
/// the resolver (Team D's on-device conviction data:
/// on the current player a correct solve maps the
/// ≈18-char challenge to an 11-char output).
struct ProbeNDiagnostic: Sendable {
    var inputLength: Int
    var outputLength: Int  // -1 = the solver produced no output for this challenge
    var outputHash8: String
}

/// What one variant resolve hands the matrix runner.
struct ProbeResolveOutcome: Sendable {
    var httpStatus: Int = 0
    var playability: String = "NOT_CALLED"
    var reason: String = ""
    var formatCount: Int = 0
    var stsSent: Int? = nil
    var audioURL: URL? = nil   // solved itag 140
    var muxedURL: URL? = nil   // solved itag 18
    var nDiagnostics: [ProbeNDiagnostic] = []
    var solverStep: String? = nil
}

// MARK: Resolver

actor ProbeResolver {
    static let shared = ProbeResolver()

    /// Session cache of the fetched player JS (the file
    /// is ~2.5 MB and its hash rotates rarely; the FETCH
    /// is cached, the solve still runs per resolve —
    /// challenges differ per video).
    private var cachedPlayerJS: PlayerJS?
    /// Session cache of the /tv page's visitorData
    /// (variant 3b only; fetched once per process).
    private var cachedVisitorData: String?
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

    // MARK: Probe entry point

    /// One variant against one video. Unlike the
    /// production resolver this returns the SOLVED URLs
    /// for itag 140 and itag 18 (when the response offers
    /// them) plus the diagnostic surface the matrix logs
    /// — it never builds a playable and never touches
    /// the HLS server.
    func resolve(videoId: String, variant: ProbeVariant) async -> ProbeResolveOutcome {
        var outcome = ProbeResolveOutcome()
        let spec = variant.spec
        var token: String? = nil
        if variant.useAuth {
            let identity = await JoeYtIdentity.shared
            guard let initial = await identity.validAccessToken() else {
                log("probe v\(variant.id) vid=\(videoId): không có access token dùng được → needsIdentity")
                outcome.playability = "NEEDS_IDENTITY"
                return outcome
            }
            token = initial
        }
        var visitorData: String? = nil
        if variant.useVisitorData {
            visitorData = await fetchVisitorData()
            if let visitorData {
                log("probe v\(variant.id): visitorData OK (len \(visitorData.count), giá trị không ghi)")
            } else {
                log("probe v\(variant.id): KHÔNG lấy được visitorData từ trang /tv — chạy tiếp không có nó")
            }
        }
        // Player JS first (session-cached) so /player can
        // declare its signatureTimestamp — run60's shape.
        let sts = await currentSignatureTimestamp(videoId: videoId)
        outcome.stsSent = sts
        // PO-token wiring (SPEC §5, variant 6 only): mint
        // or reuse the session token BEFORE the /player
        // call. A nil token (the mint failed at any step)
        // degrades to EXACTLY the no-token call — the §0
        // law. Only the token's LENGTH is ever logged.
        var poToken: JoeYtPoToken? = nil
        if variant.usePoToken {
            poToken = await JoeYtPoMinter.shared.sessionToken()
            if let poToken {
                log("probe v\(variant.id) vid=\(videoId): TOKEN MODE ON (forced) — PO token attached at all SPEC §5 points (len \(poToken.token.count), giá trị không ghi)")
            } else {
                log("probe v\(variant.id) vid=\(videoId): TOKEN MODE ON (forced) — mint FAILED, resolve tiếp KHÔNG token (hành vi hôm nay)")
            }
        } else {
            log("probe v\(variant.id) vid=\(videoId): TOKEN MODE OFF (negative control — hành vi hôm nay, SPEC §9.5)")
        }
        var call = await callPlayer(token: token, videoId: videoId, spec: spec,
                                    sts: sts, sendKey: variant.sendKey,
                                    visitorData: visitorData, poToken: poToken)
        if call.http == 401, variant.useAuth {
            log("probe v\(variant.id) vid=\(videoId): /player HTTP 401 — thử refresh 1 lần")
            let identity = await JoeYtIdentity.shared
            if let refreshed = await identity.refreshAccessToken() {
                token = refreshed
                call = await callPlayer(token: token, videoId: videoId, spec: spec,
                                        sts: sts, sendKey: variant.sendKey,
                                        visitorData: visitorData, poToken: poToken)
            }
            // The probe never clears the stored tokens:
            // one variant's dead token must not sign the
            // owner out of the remaining variants (the
            // production resolver clears after a double
            // 401; the probe deliberately does not).
        }
        outcome.httpStatus = call.http
        guard call.http == 200, let json = call.json else {
            if call.http == 0 {
                outcome.playability = "TRANSPORT_FAILURE"
                log("probe v\(variant.id) vid=\(videoId): /player lỗi mạng (không có HTTP response)")
            } else {
                let apiError = (call.json?["error"] as? [String: Any])?["message"] as? String ?? ""
                outcome.playability = "HTTP_\(call.http)"
                log("probe v\(variant.id) vid=\(videoId): /player HTTP \(call.http) client=\(spec.clientName)\(apiError.isEmpty ? "" : " — \(apiError)")")
            }
            return outcome
        }

        let playability = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "?"
        let reason = (json["playabilityStatus"] as? [String: Any])?["reason"] as? String ?? ""
        outcome.playability = playability
        outcome.reason = reason
        guard playability == "OK" else {
            log("probe v\(variant.id) vid=\(videoId): /player \(call.ms)ms playability=\(playability) reason=\(reason.isEmpty ? "-" : reason)")
            return outcome
        }

        let streaming = json["streamingData"] as? [String: Any]
        let muxed = (streaming?["formats"] as? [[String: Any]] ?? []).map(Self.mapFormat)
        let adaptive = (streaming?["adaptiveFormats"] as? [[String: Any]] ?? []).map(Self.mapFormat)
        let all = muxed + adaptive
        outcome.formatCount = all.count
        let cipheredCount = all.filter { $0.cipher != nil }.count
        let censusList = all.map { $0.itag }.sorted()
            .map { String($0) }.joined(separator: ",")
        log("probe v\(variant.id) vid=\(videoId): /player \(call.ms)ms client=\(spec.clientName) playability=OK formats=\(all.count) ciphered=\(cipheredCount) sts=\(sts.map(String.init) ?? "-") census=[\(censusList)]")

        // The probe tests exactly two formats: itag 140
        // (the assembly's audio leg) and itag 18 (the
        // muxed fallback). Other rungs are census data,
        // not test targets.
        let audio = adaptive.first { $0.itag == 140 && $0.isAudio }
        let muxed18 = muxed.first { $0.itag == 18 }
        var targets: [JoeYtFormat] = []
        if let audio { targets.append(audio) }
        if let muxed18 { targets.append(muxed18) }
        guard !targets.isEmpty else {
            outcome.playability = "NO_TARGET_FORMATS"
            log("probe v\(variant.id) vid=\(videoId): response không có itag 140 cũng không có itag 18")
            return outcome
        }

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
                outcome.solverStep = step
                log("probe v\(variant.id) vid=\(videoId): solverFailed step=\(step) — \(message)")
                return outcome
            case .solved(let sig, let n, _, let hash):
                sigResults = sig
                nResults = n
                log("probe v\(variant.id) vid=\(videoId): solver OK playerHash=\(hash)")
            }
            // Team D's cheap conviction: per n challenge,
            // input/output LENGTHS + a short hash of the
            // solved value (never the value itself).
            outcome.nDiagnostics = nChallenges.map { challenge in
                if let solved = nResults?[challenge], !solved.isEmpty {
                    return ProbeNDiagnostic(inputLength: challenge.count,
                                            outputLength: solved.count,
                                            outputHash8: Self.sha1Hash8(solved))
                }
                return ProbeNDiagnostic(inputLength: challenge.count,
                                        outputLength: -1, outputHash8: "-")
            }
            for diag in outcome.nDiagnostics {
                log("probe v\(variant.id) vid=\(videoId): n-diag in=\(diag.inputLength) out=\(diag.outputLength) sha1-8=\(diag.outputHash8)")
            }
        }

        for format in targets {
            let applied = applySolved(format: format,
                                      sigResults: sigResults, nResults: nResults,
                                      poToken: poToken?.token)
            switch applied {
            case .solved(let url):
                if format.itag == 140 { outcome.audioURL = url }
                if format.itag == 18 { outcome.muxedURL = url }
            case .failed(let why):
                log("probe v\(variant.id) vid=\(videoId): apply itag \(format.itag) thất bại — \(why)")
            }
        }
        return outcome
    }

    private static func reasonNamesMemberTier(_ reason: String) -> Bool {
        let lower = reason.lowercased()
        return lower.contains("member")
            || lower.contains("thành viên")
            || lower.contains("level:")
    }

    // MARK: /player call (Probe 16's shape, verbatim)

    // MARK: /player call (parameterized per variant)

    private func callPlayer(token: String?,
                            videoId: String,
                            spec: JoeYtClientSpec,
                            sts: Int?,
                            sendKey: Bool,
                            visitorData: String?,
                            poToken: JoeYtPoToken?) async -> (http: Int, json: [String: Any]?, ms: Int) {
        let urlString = sendKey
            ? "https://www.youtube.com/youtubei/v1/player?prettyPrint=false&key=\(spec.apiKey)"
            : "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
        guard let url = URL(string: urlString) else {
            return (0, nil, 0)
        }
        var clientContext: [String: Any] = [
            "clientName": spec.clientName,
            "clientVersion": spec.clientVersion,
            "hl": "en",
            "gl": "US",
            "userAgent": spec.userAgent,
        ]
        // Empty spec fields are OMITTED, not sent empty
        // (yt-dlp's `tv` context carries no device/os
        // fields at all).
        if !spec.deviceMake.isEmpty { clientContext["deviceMake"] = spec.deviceMake }
        if !spec.deviceModel.isEmpty { clientContext["deviceModel"] = spec.deviceModel }
        if !spec.osName.isEmpty { clientContext["osName"] = spec.osName }
        if !spec.osVersion.isEmpty { clientContext["osVersion"] = spec.osVersion }
        // Variant 3b (SmartTube delta, Team C): the
        // session's visitorData rides the client context,
        // and the same value rides the header below.
        if let visitorData { clientContext["visitorData"] = visitorData }
        // PO token (SPEC §5.2): the living-room id rides
        // INSIDE context.client as tvAppInfo (Player
        // requests only — this probe makes only Player
        // requests, so it is unconditional here).
        if let poToken {
            clientContext["tvAppInfo"] = ["livingRoomPoTokenId": poToken.livingRoomId]
        }
        // playbackContext, yt-dlp's shape — html5Preference
        // always, and the current player's
        // signatureTimestamp when it could be extracted
        // (run60's shape, every variant).
        var contentPlayback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
        if let sts { contentPlayback["signatureTimestamp"] = sts }
        var body: [String: Any] = [
            "videoId": videoId,
            "context": ["client": clientContext],
            "playbackContext": ["contentPlaybackContext": contentPlayback],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        // PO token (SPEC §5.1 + §5.3): the token at the
        // top level as serviceIntegrityDimensions.poToken,
        // and the SAME /tv fetch's visitorData as a body
        // field — both sent ONLY in token mode, so the
        // no-token request shape is byte-identical to
        // today's probe.
        if let poToken {
            body["serviceIntegrityDimensions"] = ["poToken": poToken.token]
            body["visitorData"] = poToken.visitorData
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(spec.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(spec.clientNumber, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(spec.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
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

    /// YT-403 round 3: the signatureTimestamp of the
    /// CURRENT player JS, extracted from the same
    /// file the solver uses (measured: player
    /// 7f755914 → 20775, its predecessor → 20774).
    /// yt-dlp declares this value in /player's
    /// playbackContext; before round 3 the app
    /// never sent it.
    private func currentSignatureTimestamp(videoId: String) async -> Int? {
        guard let playerJS = await acquirePlayerJS(videoId: videoId) else { return nil }
        guard let raw = regexCapture(in: playerJS.text,
                                     pattern: #"signatureTimestamp\D{0,3}(\d+)"#,
                                     group: 1),
              let sts = Int(raw) else {
            log("sts: không tìm thấy signatureTimestamp trong player JS (nguồn \(playerJS.source))")
            return nil
        }
        log("sts: player nguồn \(playerJS.source) signatureTimestamp=\(sts)")
        return sts
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

    /// Variant 3b's visitorData: scraped from the /tv
    /// page's ytcfg (the SmartTube recipe) and cached
    /// for the session. Only its length is ever logged.
    private func fetchVisitorData() async -> String? {
        if let cachedVisitorData { return cachedVisitorData }
        guard let rawHTML = await fetchText("https://www.youtube.com/tv",
                                            userAgent: Self.tvScrapeUA) else {
            log("visitorData: tải trang /tv THẤT BẠI")
            return nil
        }
        let html = rawHTML.replacingOccurrences(of: "\\/", with: "/")
        let patterns = [
            #""VISITOR_DATA"\s*:\s*"([^"]+)""#,
            #""visitorData"\s*:\s*"([^"]+)""#,
        ]
        for pattern in patterns {
            if let value = regexCapture(in: html, pattern: pattern, group: 1) {
                cachedVisitorData = value
                return value
            }
        }
        log("visitorData: trang /tv không thấy VISITOR_DATA trong ytcfg")
        return nil
    }

    /// First 8 hex chars of the SHA-1 of a solved n
    /// value — enough to compare solves across runs and
    /// against Team D's off-device reference without
    /// ever logging the value.
    private static func sha1Hash8(_ value: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
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
                             nResults: [String: String]?,
                             poToken: String?) -> ApplyOutcome {
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
        // PO token (SPEC §5.4): pot= rides EVERY deciphered
        // media URL — appended after the n replacement,
        // before URL(string:), the production insertion
        // point. The token is URL-safe base64 (padding
        // retained), appended raw exactly as SmartTube
        // appends it.
        if let poToken, !poToken.isEmpty {
            urlString += (urlString.contains("?") ? "&" : "?") + "pot=" + poToken
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
