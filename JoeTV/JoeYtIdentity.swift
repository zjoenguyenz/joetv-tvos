import SwiftUI

// MARK: - YouTube OAuth identity (device-code flow)
//
// The identity leg of the native YouTube route (owner's
// single-route ruling, 2026-11-20): EVERY tier — Free,
// Gold, Silver, Super VIP — plays through the
// authenticated tv_samsung route proven end-to-end by
// YT Probe 16 on the owner's Apple TV (verdict ĐẠT,
// 2026-11-20 15:45 CST). The TV never renders a Google
// page: the client credentials are SCRAPED at runtime
// from youtube.com/tv (SmartTube recipe — no constants
// are baked in), the owner approves the shown activation
// code on his phone, and the app polls the token
// endpoint. Ported from the probe's proven chain
// (ProbeEjs.acquireToken / deviceCodeFlow /
// scrapeTVClientCredentials + Probe9TokenStore), with
// the API reshaped for the resolver and the router.
//
// Token VALUES are never logged — presence, lengths and
// expiry only. Tokens live in the app sandbox
// (UserDefaults), so a Signulous delete+reinstall wipes
// them and the device-code approval runs again on the
// next install — the refresh token only persists within
// one install's lifetime (the probes' measured reality).

// MARK: Token store

/// Sendable refresh outcome — the note is log-safe by
/// construction (status + lengths, never a value).
struct JoeYtRefreshOutcome: Sendable {
    var token: String?
    var note: String
}

enum JoeYtOAuthStore {
    static let accessTokenKey = "joetv.yt.oauth.accessToken"
    static let refreshTokenKey = "joetv.yt.oauth.refreshToken"
    static let clientIDKey = "joetv.yt.oauth.clientID"
    static let clientSecretKey = "joetv.yt.oauth.clientSecret"
    static let expiryKey = "joetv.yt.oauth.accessTokenExpiry"

    static var accessToken: String? {
        UserDefaults.standard.string(forKey: accessTokenKey)
    }

    static var refreshToken: String? {
        UserDefaults.standard.string(forKey: refreshTokenKey)
    }

    static var clientID: String? {
        UserDefaults.standard.string(forKey: clientIDKey)
    }

    static var clientSecret: String? {
        UserDefaults.standard.string(forKey: clientSecretKey)
    }

    /// Nil when no expiry was ever stamped (a token saved
    /// by a flow that did not report expires_in) — callers
    /// then treat the token as usable and let /player
    /// arbitrate (401 → refresh), the probe's own rule.
    static var accessTokenExpiry: Date? {
        let epoch = UserDefaults.standard.double(forKey: expiryKey)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    static func saveClientCredentials(id: String, secret: String) {
        UserDefaults.standard.set(id, forKey: clientIDKey)
        UserDefaults.standard.set(secret, forKey: clientSecretKey)
    }

    static func saveTokens(access: String, refresh: String?, expiresIn: Int?) {
        UserDefaults.standard.set(access, forKey: accessTokenKey)
        if let refresh {
            UserDefaults.standard.set(refresh, forKey: refreshTokenKey)
        }
        if let expiresIn {
            UserDefaults.standard.set(
                Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970,
                forKey: expiryKey)
        }
    }

    static func clearTokens() {
        UserDefaults.standard.removeObject(forKey: accessTokenKey)
        UserDefaults.standard.removeObject(forKey: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: expiryKey)
    }

    /// Exchange the stored refresh token for a fresh
    /// access token (Google OAuth refresh_token grant
    /// against the same token endpoint the device-code
    /// flow polls — the probe's Probe9TokenStore.refresh,
    /// verbatim in shape).
    static func refresh() async -> JoeYtRefreshOutcome {
        guard let refreshToken, let clientID, let clientSecret else {
            return JoeYtRefreshOutcome(
                token: nil,
                note: "refresh: thiếu refresh token hoặc clientId/secret — không refresh được")
        }
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            return JoeYtRefreshOutcome(token: nil, note: "refresh: URL token endpoint không hợp lệ")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        let fields = ["client_id": clientID,
                      "client_secret": clientSecret,
                      "refresh_token": refreshToken,
                      "grant_type": "refresh_token"]
        request.httpBody = Data(fields.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)"
        }.joined(separator: "&").utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard http == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let access = json["access_token"] as? String else {
                return JoeYtRefreshOutcome(
                    token: nil,
                    note: "refresh: token endpoint HTTP \(http) — refresh thất bại")
            }
            let newRefresh = json["refresh_token"] as? String
            let expiresIn = (json["expires_in"] as? NSNumber)?.intValue
            saveTokens(access: access, refresh: newRefresh, expiresIn: expiresIn)
            let expiresNote = expiresIn.map { "\($0)" } ?? "?"
            return JoeYtRefreshOutcome(
                token: access,
                note: "refresh: OK — access token mới len \(access.count), expires_in \(expiresNote)s")
        } catch {
            return JoeYtRefreshOutcome(
                token: nil,
                note: "refresh: lỗi mạng — \(error.localizedDescription)")
        }
    }
}

// MARK: Identity model

/// The app-facing identity state machine. The resolver
/// asks `validAccessToken()`; the router drives the
/// device-code surface off `userCode` / `flowFinished`.
@MainActor
final class JoeYtIdentity: ObservableObject {
    static let shared = JoeYtIdentity()

    /// Where the owner approves the activation code.
    let verificationURL = "https://www.google.com/device"

    /// An access token is stored (its validity is proven
    /// by use; `validAccessToken()` is the real check).
    @Published private(set) var hasToken = false
    /// The activation code currently shown on the sign-in
    /// surface; nil outside an approval wait.
    @Published var userCode: String?
    /// Set when a device-code flow ends (true = token
    /// acquired). The router observes this to resume the
    /// pending playback; the surface reads it to close.
    @Published private(set) var flowFinished: Bool?
    /// Human-readable failure for the sign-in surface.
    @Published private(set) var flowError: String?

    private var flowTask: Task<Void, Never>?
    private var flowGeneration = 0

    private init() {
        hasToken = JoeYtOAuthStore.accessToken != nil
    }

    private func log(_ message: String) {
        DiagLog.write("YT-ID", message)
    }

    // MARK: Token acquisition for the resolver

    /// Stored token → refresh → nil (the probe's
    /// acquireToken ladder, minus the in-line device-code
    /// leg: in production the code flow is a UI surface
    /// the router presents, never a mid-resolve surprise).
    func validAccessToken() async -> String? {
        let stored = JoeYtOAuthStore.accessToken
        if let stored, let expiry = JoeYtOAuthStore.accessTokenExpiry {
            if expiry > Date().addingTimeInterval(120) {
                return stored
            }
            if expiry > Date() {
                // Inside the 120 s safety margin but NOT
                // expired: refresh early if possible, but
                // never discard a still-live token when
                // refresh is unavailable (review round 1,
                // MINOR) — it very likely survives the
                // seconds-long /player call, whose own
                // 401 leg refreshes again.
                if JoeYtOAuthStore.refreshToken != nil {
                    let outcome = await JoeYtOAuthStore.refresh()
                    log(outcome.note)
                    if let token = outcome.token {
                        hasToken = true
                        return token
                    }
                }
                return stored
            }
            log("access token đã lưu ĐÃ HẾT HẠN — thử refresh")
        }
        if stored != nil, JoeYtOAuthStore.accessTokenExpiry == nil {
            // No expiry stamp: usable until a 401 says
            // otherwise (the probe's Probe-9-era rule).
            return stored
        }
        if JoeYtOAuthStore.refreshToken != nil {
            let outcome = await JoeYtOAuthStore.refresh()
            log(outcome.note)
            if let token = outcome.token {
                hasToken = true
                return token
            }
        }
        return nil
    }

    /// The resolver cleared the stored tokens (a second
    /// 401 proved them dead): keep the published state in
    /// step with the store (review round 1, MINOR —
    /// hasToken otherwise drifted stale-true).
    func noteTokensCleared() {
        hasToken = false
    }

    /// Force one refresh attempt (the resolver's 401
    /// recovery leg). Returns the fresh token or nil.
    func refreshAccessToken() async -> String? {
        let outcome = await JoeYtOAuthStore.refresh()
        log(outcome.note)
        if let token = outcome.token {
            hasToken = true
            return token
        }
        return nil
    }

    // MARK: Device-code flow (router-driven)

    var flowRunning: Bool { flowTask != nil }

    /// Start (or restart) the device-code approval flow:
    /// scrape credentials if needed → request a code →
    /// publish it → poll until approval / expiry. The
    /// outcome lands in `flowFinished` (+ `flowError` on
    /// failure). Restarting cancels the previous flow.
    func beginDeviceCodeFlow() {
        flowTask?.cancel()
        flowGeneration += 1
        let generation = flowGeneration
        flowFinished = nil
        flowError = nil
        userCode = nil
        flowTask = Task { [weak self] in
            guard let self else { return }
            let token = await self.deviceCodeFlow(generation: generation)
            guard generation == self.flowGeneration else { return }
            self.flowTask = nil
            self.userCode = nil
            if let token {
                self.hasToken = true
                self.flowFinished = true
                _ = token
            } else {
                self.flowFinished = false
            }
        }
    }

    func cancelDeviceCodeFlow() {
        flowTask?.cancel()
        flowTask = nil
        flowGeneration += 1
        userCode = nil
    }

    /// Publish a flow failure ONLY if this flow is still
    /// the current generation (review round 1, MINOR: a
    /// superseded/cancelled flow failing late must not
    /// overwrite the restarted flow's surface state).
    private func setFlowError(_ message: String, generation: Int) {
        guard generation == flowGeneration else { return }
        flowError = message
    }

    /// The probe's deviceCodeFlow, verbatim in mechanism:
    /// scrape → POST device/code → poll the token
    /// endpoint honouring interval / slow_down until the
    /// owner approves or the code expires.
    private func deviceCodeFlow(generation: Int) async -> String? {
        var clientID = JoeYtOAuthStore.clientID
        var clientSecret = JoeYtOAuthStore.clientSecret
        if clientID == nil || clientSecret == nil {
            log("device-code: chưa có clientId/secret — cạo base-js từ youtube.com/tv…")
            if let scraped = await scrapeTVClientCredentials() {
                JoeYtOAuthStore.saveClientCredentials(id: scraped.id, secret: scraped.secret)
                clientID = scraped.id
                clientSecret = scraped.secret
                log("device-code: cạo OK — clientId len \(scraped.id.count), secret len \(scraped.secret.count) (không ghi giá trị)")
            } else {
                log("device-code: cạo base-js THẤT BẠI — không lấy được clientId/secret")
                setFlowError("Không lấy được thông tin đăng nhập từ YouTube. Anh kiểm tra mạng rồi thử lại.", generation: generation)
                return nil
            }
        }
        guard let cid = clientID, let secret = clientSecret else { return nil }
        log("device-code: dùng clientId/secret (id len \(cid.count), secret len \(secret.count))")

        let device = await formJSONPost(
            "https://oauth2.googleapis.com/device/code",
            fields: ["client_id": cid,
                     "scope": "https://www.googleapis.com/auth/youtube"])
        guard device.http == 200, let deviceJSON = device.json,
              let deviceCode = deviceJSON["device_code"] as? String,
              let code = deviceJSON["user_code"] as? String else {
            log("device-code: POST device/code HTTP \(device.http) — không lấy được mã kích hoạt")
            setFlowError("YouTube không cấp mã kích hoạt (HTTP \(device.http)). Anh thử lại sau.", generation: generation)
            return nil
        }
        var waitSeconds = max(5, (deviceJSON["interval"] as? NSNumber)?.intValue ?? 5)
        let expiresIn = (deviceJSON["expires_in"] as? NSNumber)?.intValue ?? 1800
        guard generation == flowGeneration else { return nil }
        userCode = code
        log("device-code: MÃ KÍCH HOẠT hiện trên màn hình TV — mở \(verificationURL) trên iPhone, nhập mã, duyệt bằng tài khoản Gold")
        log("device-code: đang chờ duyệt, tối đa \(expiresIn)s…")

        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        while Date() < deadline {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
            if Task.isCancelled { return nil }
            let poll = await formJSONPost(
                "https://oauth2.googleapis.com/token",
                fields: ["client_id": cid,
                         "client_secret": secret,
                         "device_code": deviceCode,
                         "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            // Re-check cancellation AFTER the await
            // (review round 2, MINOR): a poll that returns
            // 200 after the owner cancelled the flow must
            // not save tokens — a cancelled flow never
            // silently signs the app in.
            if Task.isCancelled { return nil }
            if poll.http == 200, let pollJSON = poll.json,
               let access = pollJSON["access_token"] as? String {
                let refresh = pollJSON["refresh_token"] as? String
                let expires = (pollJSON["expires_in"] as? NSNumber)?.intValue
                JoeYtOAuthStore.saveTokens(access: access, refresh: refresh, expiresIn: expires)
                let refreshNote = refresh.map { "CÓ (len \($0.count))" } ?? "KHÔNG"
                let expiresNote = expires.map { "\($0)" } ?? "?"
                log("device-code: DUYỆT OK — access token len \(access.count), refresh token \(refreshNote), expires_in \(expiresNote)s")
                return access
            }
            let error = (poll.json?["error"] as? String) ?? "http_\(poll.http)"
            switch error {
            case "authorization_pending":
                log("device-code: chưa duyệt (authorization_pending) — vẫn chờ…")
            case "slow_down":
                waitSeconds += 5
                log("device-code: slow_down — giãn nhịp chờ thành \(waitSeconds)s")
            default:
                log("device-code: DỪNG — lỗi \(error)")
                setFlowError("Đăng nhập bị dừng ở phía Google (\(error)). Anh thử lại.", generation: generation)
                return nil
            }
        }
        log("device-code: HẾT THỜI GIAN chờ duyệt (\(expiresIn)s)")
        setFlowError("Mã kích hoạt đã hết hạn mà chưa được duyệt. Anh bấm Thử lại để lấy mã mới.", generation: generation)
        return nil
    }

    // MARK: Credential scrape (probe-proven)

    /// Probe 9/16's proven scrape: youtube.com/tv with the
    /// Tizen TV UA → `id="base-js"` script → base.js →
    /// clientId + the field right after it (the secret).
    /// Falls back to pattern-matching the /tv HTML itself.
    private func scrapeTVClientCredentials() async -> (id: String, secret: String)? {
        let tvUA = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/5.0 Chrome/85.0.4183.120 TV Safari/537.36"
        guard let tvHTML = await fetchText("https://www.youtube.com/tv", userAgent: tvUA) else {
            return nil
        }
        if let src = firstRegexCapture(in: tvHTML, pattern: "id=\"base-js\" src=\"([^\"]+)\"") {
            let jsURL = src.hasPrefix("http") ? src : "https://www.youtube.com" + src
            if let js = await fetchText(jsURL, userAgent: tvUA),
               let credentials = findClientCredentials(in: js) {
                return credentials
            }
        }
        return findClientCredentials(in: tvHTML)
    }

    private func findClientCredentials(in text: String) -> (id: String, secret: String)? {
        if let id = firstRegexCapture(in: text, pattern: "clientId:\"([-\\w]+\\.apps\\.googleusercontent\\.com)\""),
           let secret = firstRegexCapture(in: text, pattern: "clientId:\"[-\\w]+\\.apps\\.googleusercontent\\.com\",\n?[$\\w]+:\"(\\w+)\"") {
            return (id, secret)
        }
        if let id = firstRegexCapture(in: text, pattern: "([-\\w]+\\.apps\\.googleusercontent\\.com)"),
           let secret = firstRegexCapture(in: text, pattern: "client_secret\"?\\s*:\\s*\"(\\w+)\"") {
            return (id, secret)
        }
        return nil
    }

    // MARK: HTTP helpers (probe shapes, verbatim)

    private func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else { return nil }
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

    private func formJSONPost(_ urlString: String,
                              fields: [String: String]) async -> (http: Int, json: [String: Any]?) {
        guard let url = URL(string: urlString) else { return (0, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)"
        }.joined(separator: "&").utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (http, json)
        } catch {
            return (0, nil)
        }
    }
}
