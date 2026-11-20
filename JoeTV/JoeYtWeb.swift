import SwiftUI

// MARK: - YouTube web surfaces (player + Gold sign-in door)
//
// The Swift half of the WebKit bridge (design plan §2/§3).
// JoeWebBridge (ObjC) is mechanics only; everything that
// decides WHAT happens — the watchmax payload (carried over
// VERBATIM from the Sony proof, §2.3), the AUTO surface chain
// (§2.4), the remote model (§2.5), the cookie mirror and the
// SAPISID presence rule (§3.3) — lives in this file.
//
// Secret-handling (design §3.4, hard rules): cookie VALUES
// are never written to the diagnostic log, never shown in
// UI, never sent anywhere except back into the app's own
// cookie store. The log records signedIn=true/false, counts
// and event names only.

// MARK: JS payloads

enum JoeYtJS {
    /// Desktop user agent (Sony PlayerActivity DESKTOP_UA,
    /// PROVEN-SONY — design §2.3, verbatim).
    static let desktopUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// The SIGN-IN DOOR's user agent — a desktop SAFARI UA,
    /// deliberately different from the player's (community
    /// research 2026-11-19, phonk-jazz measured against the
    /// live site): Google refuses sign-in inside a web view
    /// whose UA betrays it ("this browser or app may not be
    /// secure") — the default WKWebView UA carries the app
    /// name and lacks Version/, and a Chrome/Windows UA on a
    /// WebKit engine is exactly the mismatched identity the
    /// check is built to catch. WKWebView IS Safari's engine,
    /// so the Safari UA is the honest, accepted one. Cookies
    /// live in the shared data store, not the UA, so the
    /// door's session carries into the player untouched.
    /// applicationNameForUserAgent is never set anywhere.
    static let safariUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    /// The watchmax CSS injection (Sony PlayerActivity poll,
    /// style id tvbyt-max-css, PROVEN-SONY — design §2.3,
    /// verbatim). ⛔ #page-manager must NEVER enter the
    /// hide-list: it is an ANCESTOR of #movie_player and
    /// hiding it paints the player black while the state
    /// keeps playing (Sony v0.3 defect, caps v03-09/10).
    static let injectWatchmaxCSS = """
        (function(){
          if (document.getElementById('tvbyt-max-css')) { return 'already'; }
          var s = document.createElement('style');
          s.id = 'tvbyt-max-css';
          s.textContent = 'html,body{overflow:hidden!important;background:#000!important}'
            + '#movie_player{position:fixed!important;left:0!important;top:0!important;width:100vw!important;height:100vh!important;z-index:2147483647!important;background:#000!important}'
            + '#masthead-container,#secondary,#below,#comments,#related,#footer{display:none!important}';
          document.head.appendChild(s);
          window.dispatchEvent(new Event('resize'));
          return 'injected';
        })()
        """

    /// State poll (design §2.3): one small JS read every 2 s.
    /// TRUST ORDER (community research 2026-11-19, phonk-jazz
    /// measured live): the #movie_player API is AUTHORITATIVE
    /// — the <video> element's readings can be indefinitely
    /// wrong in the MSE stall state (duration NaN, currentTime
    /// 0 while playback is fine). So state/position/duration
    /// come from getPlayerState()/getCurrentTime()/
    /// getDuration()/getVideoData() first; the element is the
    /// fallback and corroboration only. Also carried: the
    /// player pin check (the #movie_player rect against the
    /// viewport — the VEIL's release signal, Sony lesson 2),
    /// any .ytp-error text, and the page URL (the §2.5 wander
    /// check).
    static let poll = """
        (function(){
          var v = document.querySelector('video');
          var p = document.getElementById('movie_player');
          var err = '';
          var e = document.querySelector('.ytp-error');
          if (e) { err = (e.innerText || '').slice(0, 120); }
          var pin = 0;
          if (p) {
            var r = p.getBoundingClientRect();
            if (Math.abs(r.width - window.innerWidth) < 2
                && Math.abs(r.height - window.innerHeight) < 2) { pin = 1; }
          }
          var state = -99, vid = '', t = 0, d = 0, api = 0;
          try {
            if (p && p.getPlayerState) {
              api = 1;
              state = p.getPlayerState();
              if (p.getCurrentTime) { t = p.getCurrentTime() || 0; }
              if (p.getDuration) { d = p.getDuration() || 0; }
              if (p.getVideoData) {
                var vd = p.getVideoData();
                vid = (vd && (vd.video_id || vd.videoId)) || '';
              }
            }
          } catch (ex) { api = 0; state = -99; }
          if (v) {
            if (!(d > 0) && isFinite(v.duration)) { d = v.duration; }
            if (!t && isFinite(v.currentTime)) { t = v.currentTime; }
          }
          var playing, ended, paused;
          if (api) {
            playing = (state === 1);
            ended = (state === 0);
            paused = (state === 2);
          } else {
            playing = !!(v && !v.paused && !v.ended && v.readyState > 2);
            ended = !!(v && v.ended);
            paused = !!(v && v.paused);
          }
          return JSON.stringify({
            has: !!v, api: api, state: state, vid: vid,
            playing: playing, paused: paused, ended: ended,
            muted: !!(v && v.muted),
            t: t, d: d,
            pin: pin, err: err, url: location.href
          });
        })()
        """

    /// Play/pause toggle — through the PLAYER object first
    /// (research 2026-11-19: element state can lie during MSE
    /// playback); the element is the fallback.
    static let togglePlay = """
        (function(){
          var p = document.getElementById('movie_player');
          try {
            if (p && p.getPlayerState) {
              if (p.getPlayerState() === 1) { p.pauseVideo(); return 'pause'; }
              p.playVideo(); return 'play';
            }
          } catch (ex) {}
          var v = document.querySelector('video');
          if (!v) { return 'novideo'; }
          if (v.paused) { v.play(); return 'play'; }
          v.pause(); return 'pause';
        })()
        """

    /// Seek — used ONLY by the web-process-death recovery
    /// (research 2026-11-19): after a termination reload, the
    /// player seeks back to the poll-checkpointed position.
    /// Through seekTo: assigning video.currentTime can
    /// silently no-op in the MSE state. (User-facing seek
    /// stays out of scope by the owner's ruling.)
    static func seekTo(_ seconds: Double) -> String {
        """
        (function(){
          var p = document.getElementById('movie_player');
          try {
            if (p && p.seekTo) { p.seekTo(\(seconds), true); return 'api'; }
          } catch (ex) {}
          var v = document.querySelector('video');
          if (v) { v.currentTime = \(seconds); return 'element'; }
          return 'none';
        })()
        """
    }

    /// Startup nudge (Sony poll shape): unmute + play while a
    /// surface has not reached its first playing frame yet.
    /// NEVER evaluated after first play — after that, a pause
    /// is the owner's own and is respected.
    static let nudgePlay = """
        (function(){
          var v = document.querySelector('video');
          if (!v) { return 'novideo'; }
          if (v.muted) { v.muted = false; }
          if (v.paused) { v.play(); }
          return 'nudged';
        })()
        """

    // MARK: Door payloads (design §3.2 + research 2026-11-19)
    //
    // A bridged tvOS web view has NO native text entry (the
    // flagship's hand-built keyboard exists for exactly this
    // reason). The door's mechanism instead: the owner types
    // into NATIVE SwiftUI fields (the tvOS system keyboard),
    // and these payloads type the values into Google's page
    // fields — the prototype value setter plus dispatched
    // input/change events, the shape the page's own framework
    // observes. The values travel inside the evaluated script
    // only; they are never logged (no evaluate payload is).

    /// Which credential field the door page is showing:
    /// 'email' | 'password' | 'none'.
    static let doorProbe = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var pw = document.querySelector('input[name="Passwd"], input[type="password"]');
          if (vis(pw)) { return 'password'; }
          var idn = document.querySelector('input[name="identifier"], input[type="email"]');
          if (vis(idn)) { return 'email'; }
          return 'none';
        })()
        """

    private static func jsLiteral(_ value: String) -> String {
        var out = "'"
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out + "'"
    }

    private static func fillField(selector: String, value: String,
                                  nextSelector: String) -> String {
        """
        (function(){
          var el = document.querySelector(\(jsLiteral(selector)));
          if (!el) { return 'nofield'; }
          el.focus();
          var setter = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, 'value').set;
          setter.call(el, \(jsLiteral(value)));
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
          setTimeout(function(){
            var next = document.querySelector(\(jsLiteral(nextSelector)));
            if (next) { next.click(); }
          }, 350);
          return 'filled';
        })()
        """
    }

    static func fillIdentifier(_ email: String) -> String {
        fillField(selector: "input[name=\"identifier\"], input[type=\"email\"]",
                  value: email,
                  nextSelector: "#identifierNext button, #identifierNext")
    }

    static func fillPassword(_ password: String) -> String {
        fillField(selector: "input[name=\"Passwd\"], input[type=\"password\"]",
                  value: password,
                  nextSelector: "#passwordNext button, #passwordNext")
    }
}

// MARK: - Gold session (design §3)

/// The Gold session: SAPISID-presence state + the cookie
/// mirror that makes the one-time sign-in persist on a
/// platform whose web store may drop it between launches
/// (design §3.1/§3.3). Persistence is engineered here, not
/// assumed: persistent store + mirror in app storage +
/// restore-before-load.
@MainActor
final class JoeYtSession: ObservableObject {
    static let shared = JoeYtSession()

    @Published private(set) var signedIn = false
    let bridgeAvailable = JoeWebBridge.webKitAvailable()

    private init() {}

    private struct CookieRecord: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var expires: Date?
    }

    private static var mirrorURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("joetv-yt-mirror.json")
    }

    /// Presence-only re-read of the live store. A fresh
    /// getAllCookies round-trip IS the re-check — the Sony
    /// door's stale-read fault (its check only saw the
    /// session after an exit-time flush) is designed against
    /// by re-reading WHILE the door is open (Sony lesson 1).
    func refresh() async {
        signedIn = await Self.fetchPresence()
    }

    /// Restore-before-load (design §3.3 item 3): check; if
    /// the store has lost the session, write the mirror back
    /// and check again. Called when the player or the door
    /// opens, before any page loads.
    func ensureSession() async {
        await refresh()
        if !signedIn {
            await restoreFromMirror()
            await refresh()
        }
    }

    /// Copies the live YouTube/Google cookies into the app's
    /// own mirror file (design §3.3 item 2). Called when the
    /// door closes signed-in and when a members-tier play
    /// first reaches picture. Only the cookie COUNT reaches
    /// the diagnostic log — never a value (§3.4).
    func mirrorNow() async {
        let cookies = await Self.fetchAllCookies()
        let records = cookies
            .compactMap { Self.record(from: $0) }
            .filter {
                $0.domain.contains("youtube.com")
                    || $0.domain.contains("google.com")
            }
        guard records.contains(where: { $0.name == "SAPISID" }) else { return }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.mirrorURL, options: .atomic)
            DiagLog.write("YT", "session mirror saved cookies=\(records.count)")
        }
    }

    private func restoreFromMirror() async {
        guard let data = try? Data(contentsOf: Self.mirrorURL),
              let records = try? JSONDecoder().decode([CookieRecord].self,
                                                      from: data),
              !records.isEmpty else { return }
        let dicts = records.map { Self.dictionary(from: $0) }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            JoeWebBridge.restoreCookies(dicts) { cont.resume() }
        }
        DiagLog.write("YT", "session mirror restored cookies=\(records.count)")
    }

    // MARK: Bridge wrappers

    private static func fetchAllCookies() async -> [[String: Any]] {
        await withCheckedContinuation {
            (cont: CheckedContinuation<[[String: Any]], Never>) in
            JoeWebBridge.fetchAllCookies { cookies in
                // The bridge's completion is nonisolated, so
                // `cookies` arrives in that closure's own
                // region; resuming with it from there passes
                // a non-Sendable value as `sending` across
                // regions — a Swift 6 error (CI run #16, the
                // build's only one). Hop into the owning
                // actor's context first, the file's own
                // delegate idiom below: this function's
                // consumer is @MainActor, so the value's
                // region transfers with the hop and the
                // resume inside the actor is legal. Same
                // cookies, same caller-visible behaviour.
                Task { @MainActor in
                    cont.resume(returning: cookies)
                }
            }
        }
    }

    private static func fetchPresence() async -> Bool {
        let cookies = await fetchAllCookies()
        return cookies.contains { entry in
            (entry["name"] as? String) == "SAPISID"
                && ((entry["domain"] as? String) ?? "").contains("youtube.com")
        }
    }

    private static func record(from entry: [String: Any]) -> CookieRecord? {
        guard let name = entry["name"] as? String,
              let value = entry["value"] as? String,
              let domain = entry["domain"] as? String else { return nil }
        return CookieRecord(
            name: name,
            value: value,
            domain: domain,
            path: (entry["path"] as? String) ?? "/",
            secure: (entry["secure"] as? NSNumber)?.boolValue ?? false,
            expires: entry["expires"] as? Date)
    }

    private static func dictionary(from record: CookieRecord) -> [String: Any] {
        var entry: [String: Any] = [
            "name": record.name,
            "value": record.value,
            "domain": record.domain,
            "path": record.path,
            "secure": NSNumber(value: record.secure),
        ]
        if let expires = record.expires { entry["expires"] = expires }
        return entry
    }
}

// MARK: - Bridge controller

/// The NSObject delegate between JoeWebHostView (ObjC) and
/// the Swift models. Plain NSObject, the JoePlayerView
/// Coordinator idiom: WebKit delivers every callback on the
/// main queue, and each one hops formally into the model's
/// @MainActor closures. The class itself stays nonisolated
/// (the ObjC delegate requirements must), but every wrapper
/// that touches the host view is @MainActor — JoeWebHostView
/// is a UIView, so its methods and properties are
/// main-actor-isolated, and every caller of these wrappers
/// is one of the two @MainActor models (CI run #16 warned
/// on each of these call sites).
final class JoeWebController: NSObject, JoeWebHostDelegate {
    weak var host: JoeWebHostView?

    var onPoll: (@MainActor (String?) -> Void)?
    var onFinishLoad: (@MainActor () -> Void)?
    var onFailLoad: (@MainActor (String) -> Void)?
    var onTerminated: (@MainActor () -> Void)?
    var onExitURL: (@MainActor (String) -> Void)?

    @MainActor
    func load(url: String, userAgent: String?, lockedURL: String?) {
        host?.lockedURLString = lockedURL
        host?.loadURLString(url, userAgent: userAgent)
    }

    /// Re-aims the PlayerLockdown at a new watch URL WITHOUT
    /// loading it — used when the page advanced ITSELF to the
    /// next episode (playlist context) and the player model
    /// adopted the landed episode: the lock must follow the
    /// model's current episode or the next self-advance would
    /// read as a wander and exit.
    @MainActor
    func relock(url: String) {
        host?.lockedURLString = url
    }

    @MainActor
    func evaluate(_ js: String) {
        host?.evaluateJavaScript(js, completion: nil)
    }

    @MainActor
    func evaluateForResult(_ js: String,
                           completion: @escaping @MainActor (String?) -> Void) {
        host?.evaluateJavaScript(js) { result in
            Task { @MainActor in completion(result) }
        }
    }

    @MainActor
    func startPoll() {
        host?.startPolling(withInterval: 2.0, javaScript: JoeYtJS.poll)
    }

    @MainActor
    func stopPoll() {
        host?.stopPolling()
    }

    // MARK: JoeWebHostDelegate

    func joeHost(_ host: JoeWebHostView, didPollResult result: String?) {
        let callback = onPoll
        Task { @MainActor in callback?(result) }
    }

    func joeHostDidFinishLoad(_ host: JoeWebHostView) {
        let callback = onFinishLoad
        Task { @MainActor in callback?() }
    }

    func joeHost(_ host: JoeWebHostView, didFailLoadWithMessage message: String) {
        let callback = onFailLoad
        Task { @MainActor in callback?(message) }
    }

    func joeHostDidTerminateWebContent(_ host: JoeWebHostView) {
        let callback = onTerminated
        Task { @MainActor in callback?() }
    }

    func joeHost(_ host: JoeWebHostView, didRequestExitForURL url: String) {
        let callback = onExitURL
        Task { @MainActor in callback?(url) }
    }
}

// MARK: - SwiftUI host

struct JoeWebView: UIViewRepresentable {
    let controller: JoeWebController
    let navigationMode: JoeWebNavigationMode
    let playbackPresses: Bool

    func makeUIView(context: Context) -> JoeWebHostView {
        let host = JoeWebHostView(frame: .zero)
        host.navigationMode = navigationMode
        host.playbackPressesEnabled = playbackPresses
        host.delegate = controller
        controller.host = host
        return host
    }

    func updateUIView(_ uiView: JoeWebHostView, context: Context) {}

    static func dismantleUIView(_ uiView: JoeWebHostView, coordinator: ()) {
        uiView.stopPolling()
        uiView.delegate = nil
    }
}

// MARK: - Player

/// One poll read, decoded from JoeYtJS.poll's JSON.
private struct JoeYtPollState: Decodable {
    let has: Bool
    /// 1 when the #movie_player API answered (authoritative);
    /// state is then its getPlayerState() (1 playing,
    /// 3 buffering, 2 paused, 0 ended, -1 unstarted).
    let api: Int
    let state: Int
    /// The page's current video id per getVideoData().
    let vid: String
    let playing: Bool
    let paused: Bool
    let ended: Bool
    let muted: Bool
    let t: Double
    let d: Double
    let pin: Int
    let err: String
    let url: String
}

/// The YouTube player surface's state machine (design
/// §2.4/§2.5 + the Sony lessons):
/// - AUTO chain watchmax → watch → mobile, stepping down on
///   a page error or ~18 s (9 polls) without playing.
/// - The VEIL covers the surface from load until the
///   watchmax pin is VERIFIED in-page (Sony lesson 2: no
///   visible web background, ever); fallback surfaces lift
///   it on first playing; a pin that never verifies lifts it
///   after 9 playing polls so the veil can never trap.
/// - The owner's acceptance points (2026-11-19) are the
///   contract: (1) full-screen immediately — the veil above;
///   (2) a next-episode BUTTON in the player — the SwiftUI
///   control bar the view renders from `controlsUp`, with
///   the Down press as its shortcut; (3) auto-advance at
///   the end — `ended` is an observable poll field and
///   scheduleAutoNext rides it. Seek is out of scope by his
///   ruling (playback runs on YouTube's page).
/// - Auto (and only Auto) falls through to the chain when
///   every YouTube surface fails and a chain match exists —
///   the app substitutes a working source itself (the house
///   "always ready" standard, design §1.6). A manual YouTube
///   pick is never overridden.
@MainActor
final class JoeYtPlayerModel: ObservableObject {
    @Published var veilUp = true
    @Published var statusLine: String?
    /// The control bar (episode label + the next-episode
    /// button) is up at open and after every press, and
    /// auto-hides ~4 s later so the film owns the screen.
    @Published var controlsUp = true
    @Published var endSlate = false
    @Published var failureText: String?
    @Published private(set) var bridgeMissing = false
    @Published private(set) var currentIndex: Int

    let controller = JoeWebController()
    private let request: JoeYtPlayRequest
    private var surface = 0
    private var started = false
    private var pollsWithoutPlay = 0
    private var playingPolls = 0
    private var firstPlaying = false
    private var cssInjected = false
    private var endedHandled = false
    private var terminal = false
    private var mirroredThisPlay = false
    /// True from loadSurface until the load commits (the
    /// bridge's finish callback, or a poll whose URL already
    /// carries the current episode's id). While it is set,
    /// the wander check below MUST NOT fire: the poll can
    /// still be reading the PREVIOUS episode's page, whose
    /// video id legitimately differs from the just-advanced
    /// currentIndex (review MAJOR, 2026-11-19 — without the
    /// gate, next-episode and auto-next could exit the
    /// player instead of advancing).
    private var loadInFlight = false
    /// Process-death recovery (research 2026-11-19): the
    /// last position the poll vouched for, and the seek-back
    /// owed after a termination reload. tvOS kills the web
    /// content process under memory pressure with no warning;
    /// the bridge reports it, the model reloads the same
    /// episode and seeks back to the checkpoint.
    private var checkpoint: Double = 0
    private var pendingSeek: Double?
    private var statusTask: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    private var controlsTask: Task<Void, Never>?

    var onFallThrough: ((MovieRoute) -> Void)?
    /// The unified-detail hand-back: the player was launched
    /// from inside JoeMovieDetail in Auto mode and every
    /// YouTube surface failed — the episode returns to that
    /// detail, which plays it via the chain.
    var onDetailFallThrough: ((JoeYtChainPlay) -> Void)?
    var onExitRequest: (() -> Void)?

    init(request: JoeYtPlayRequest) {
        self.request = request
        self.currentIndex = request.startIndex
    }

    var episodeLabel: String {
        "Tập \(currentIndex + 1) / \(request.videoIds.count)"
    }

    var hasNextEpisode: Bool {
        currentIndex + 1 < request.videoIds.count
    }

    /// Every press (and every episode change) raises the
    /// control bar; it lowers itself ~4 s after the last
    /// one. When it lowers, the view hands first responder
    /// back to the web host (see JoeYtPlayerView).
    func notePressActivity() {
        controlsUp = true
        controlsTask?.cancel()
        controlsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.controlsUp = false
        }
    }

    private var isMembersTier: Bool {
        request.tier == "gold" || request.tier == "vip"
            || request.tier == "members"
    }

    func start() {
        guard !started else { return }
        started = true
        guard JoeWebBridge.webKitAvailable() else {
            bridgeMissing = true
            DiagLog.write("YT", "bridge unavailable — player explanation shown")
            return
        }
        controller.onPoll = { [weak self] result in
            self?.handlePollResult(result)
        }
        controller.onFinishLoad = { [weak self] in
            // The current episode's page has committed; the
            // wander check may trust poll URLs again.
            self?.loadInFlight = false
        }
        controller.onFailLoad = { [weak self] _ in
            // A late failure for a superseded load can step
            // the chain one extra notch; the chain is bounded
            // (3 surfaces, terminal at the end) and the
            // no-play timeout reaches the same end state, so
            // the simplification is safe.
            self?.stepDown(reason: "load failed")
        }
        controller.onTerminated = { [weak self] in
            self?.handleTermination()
        }
        controller.onExitURL = { [weak self] _ in
            guard let self, !self.terminal else { return }
            self.terminal = true
            DiagLog.write("YT", "navigation lockdown exit — back to detail")
            self.onExitRequest?()
        }
        Task { [weak self] in
            // Restore-before-load (design §3.3): a dropped
            // store session is repaired from the mirror
            // before the watch page ever loads. If the view
            // was dismissed while the restore was in flight
            // (stop() ran), the load must NOT start on the
            // torn-down surface (review MINOR, 2026-11-19).
            await JoeYtSession.shared.ensureSession()
            guard let self, !self.terminal else { return }
            self.loadSurface(0)
            self.controller.startPoll()
        }
        notePressActivity()
    }

    func stop() {
        terminal = true
        JoeWebBridge.setRemotePressConsumer(nil)
        statusTask?.cancel()
        nextTask?.cancel()
        controlsTask?.cancel()
        controller.stopPoll()
    }

    // MARK: Remote presses (window-level routing)
    //
    // The presses are decided at the UIWindow level by the
    // bridge (research 2026-11-19): WebKit's content view is
    // first responder over the playing page and takes them
    // itself, so they never reach a hosting view. The model
    // registers ONE consumer while the player is on screen:
    // - PlayPause always toggles (it has no focus meaning).
    // - Select / Down act only while the control bar is DOWN
    //   (the page owns the screen): Select toggles, Down is
    //   the next-episode button's shortcut. While the bar is
    //   UP they belong to the focus engine and the focused
    //   button, so the consumer declines them.
    // - Menu is never offered by the bridge — it always
    //   reaches .onExitCommand.
    // Terminal slates (failure / end) decline everything:
    // their SwiftUI buttons own the remote.
    func registerPressConsumer() {
        JoeWebBridge.setRemotePressConsumer { [weak self] pressType in
            // sendEvent arrives on the main thread (UIKit's
            // own contract), so the main-actor body is sound.
            MainActor.assumeIsolated {
                guard let self, !self.terminal,
                      self.failureText == nil, !self.endSlate
                else { return false }
                if pressType == UIPress.PressType.playPause.rawValue {
                    self.togglePlay()
                    return true
                }
                guard !self.controlsUp else { return false }
                if pressType == UIPress.PressType.select.rawValue {
                    self.togglePlay()
                    return true
                }
                if pressType == UIPress.PressType.downArrow.rawValue {
                    self.advance()
                    return true
                }
                return false
            }
        }
    }

    func togglePlay() {
        controller.evaluate(JoeYtJS.togglePlay)
        notePressActivity()
    }

    // MARK: Web-process death

    /// The bridge reports the web content process died or
    /// hung. Recovery: reload the CURRENT surface for the
    /// current episode and, once it plays again, seek back
    /// to the checkpoint. If the reload never plays, the
    /// ordinary no-play timeout steps the chain down as
    /// usual — the recovery adds no new trap.
    private func handleTermination() {
        guard !terminal, started, !bridgeMissing else { return }
        DiagLog.write("YT", "web content process terminated/unresponsive — reloading ep=\(currentIndex + 1) at checkpoint \(Int(checkpoint))s")
        pendingSeek = checkpoint > 2 ? checkpoint : nil
        loadSurface(surface)
    }

    func retry() {
        guard !bridgeMissing else { return }
        failureText = nil
        terminal = false
        pendingSeek = nil
        loadSurface(0)
        controller.startPoll()
    }

    // MARK: Surfaces

    private func loadSurface(_ s: Int) {
        surface = s
        pollsWithoutPlay = 0
        playingPolls = 0
        firstPlaying = false
        cssInjected = false
        endedHandled = false
        mirroredThisPlay = false
        checkpoint = 0
        // Every load is a fresh playback attempt: the end
        // slate belongs only to the genuinely-ended moment
        // (scheduleAutoNext sets it WITHOUT a load). Leaving
        // it up across a termination reload or a post-end
        // retry would play the film behind a control-less
        // slate with all presses declined (review MINOR,
        // 2026-11-19).
        endSlate = false
        loadInFlight = true
        veilUp = true
        let vid = request.videoIds[currentIndex]
        // The playlist context rides the watch URL (research
        // 2026-11-19): with &list= the page's OWN up-next
        // follows playlist order instead of recommendations,
        // and if the page advances itself the poll's video id
        // lets the model adopt the landed episode (see the
        // wander check). The app-side load stays the primary
        // advance mechanism.
        let watch = "https://www.youtube.com/watch?v=\(vid)&list=\(request.pid)&autoplay=1"
        switch s {
        case 0, 1:
            controller.load(url: watch, userAgent: JoeYtJS.desktopUA,
                            lockedURL: watch)
        default:
            // The lockdown compares host + path + video id,
            // so each surface locks to its OWN host — the
            // mobile surface locks to m.youtube.com, never to
            // the desktop URL it conceptually mirrors.
            let mobile = "https://m.youtube.com/watch?v=\(vid)&list=\(request.pid)&autoplay=1"
            controller.load(url: mobile, userAgent: nil,
                            lockedURL: mobile)
        }
        DiagLog.write("YT", "surface load s=\(s) ep=\(currentIndex + 1)")
    }

    private func stepDown(reason: String) {
        guard !terminal else { return }
        DiagLog.write("YT", "surface \(surface) down (\(reason))")
        if surface >= 2 {
            terminal = true
            controller.stopPoll()
            if let chainPlay = request.chainPlay {
                DiagLog.write("YT", "Auto: all YouTube surfaces failed — handing the episode back to the chain detail")
                onDetailFallThrough?(chainPlay)
            } else if request.mode == .auto, let route = request.chainRoute {
                DiagLog.write("YT", "Auto: all YouTube surfaces failed — falling through to chain")
                onFallThrough?(route)
            } else {
                failureText = "Không phát được qua YouTube. Anh bấm Thử lại, hoặc quay lại rồi chọn nguồn khác."
                veilUp = false
            }
            return
        }
        loadSurface(surface + 1)
    }

    // MARK: Poll

    private func handlePollResult(_ result: String?) {
        guard !terminal else { return }
        guard let result,
              let data = result.data(using: .utf8),
              let state = try? JSONDecoder().decode(JoeYtPollState.self,
                                                    from: data)
        else { return }

        // The §2.5 wander check: if the page ever leaves the
        // locked video, leave the player instead of stranding
        // the owner on a web page. Gated on loadInFlight: a
        // poll taken while the current episode's page is
        // still loading can legitimately report the PREVIOUS
        // episode's URL — that is a load in progress, not a
        // wander (review MAJOR, 2026-11-19). A poll whose id
        // already matches the current episode also clears
        // the gate, in case a load shape never delivers the
        // finish callback.
        if state.has,
           let v = Self.videoId(fromWatchURL: state.url) {
            if v == request.videoIds[currentIndex] {
                loadInFlight = false
            } else if !loadInFlight,
                      currentIndex + 1 < request.videoIds.count,
                      v == request.videoIds[currentIndex + 1] {
                // The page advanced ITSELF to the next
                // episode (playlist context on the watch
                // URL): adopt the landed episode instead of
                // reading it as a wander — sync the index,
                // re-aim the lockdown, and let the poll loop
                // re-pin the watchmax styling on the new page.
                adoptSelfAdvance()
                return
            } else if !loadInFlight {
                terminal = true
                DiagLog.write("YT", "page left the locked video — exiting player")
                onExitRequest?()
                return
            }
        }

        // While the load is in flight, this poll still
        // describes the OUTGOING page (review MAJOR,
        // 2026-11-19): its err / ended / playing must NOT
        // act on the new surface — a stale `ended` would
        // schedule a second advance and skip an episode, a
        // stale `playing` would set firstPlaying and disarm
        // the no-play timeout for the new page, a stale
        // error would step the new surface down. Only the
        // timeout accounting runs, so a load that neither
        // finishes nor fails still steps down on schedule.
        if loadInFlight {
            pollsWithoutPlay += 1
            if pollsWithoutPlay >= 9 {
                stepDown(reason: "load timeout")
            }
            return
        }

        if !state.err.isEmpty {
            stepDown(reason: "page error")
            return
        }

        if state.ended {
            if !endedHandled {
                endedHandled = true
                scheduleAutoNext()
            }
            return
        }

        // Muted autoplay (the page started the film without
        // sound): nudge it unmuted before first picture
        // counts, the Sony poll shape — after first playing
        // a mute state is the page's/owner's own business.
        if state.has && state.muted && !firstPlaying {
            controller.evaluate(JoeYtJS.nudgePlay)
        }

        if state.playing {
            pollsWithoutPlay = 0
            playingPolls += 1
            // The process-death checkpoint: the last position
            // the page itself vouched for while playing.
            if state.t > 1 && state.d > 0 {
                checkpoint = state.t
            }
            if !firstPlaying {
                firstPlaying = true
                DiagLog.write("YT", "playing surface=\(surface) ep=\(currentIndex + 1)")
                if let seek = pendingSeek {
                    pendingSeek = nil
                    controller.evaluate(JoeYtJS.seekTo(seek))
                    DiagLog.write("YT", "recovery seek to \(Int(seek))s")
                }
                if isMembersTier && !mirroredThisPlay {
                    mirroredThisPlay = true
                    Task { await JoeYtSession.shared.mirrorNow() }
                }
            }
            if surface == 0 {
                if !cssInjected {
                    cssInjected = true
                    controller.evaluate(JoeYtJS.injectWatchmaxCSS)
                } else if state.pin == 1 {
                    if veilUp {
                        veilUp = false
                        DiagLog.write("YT", "watchmax pin verified — veil lifted")
                    }
                } else if playingPolls >= 9 && veilUp {
                    // No-trap fallback: the film is playing
                    // but the pin never verified (a page
                    // shape the CSS did not fit) — show the
                    // page as-is rather than veiling a
                    // playing film forever.
                    veilUp = false
                    DiagLog.write("YT", "pin unverified after 9 playing polls — veil lifted (fallback)")
                }
            } else if veilUp {
                veilUp = false
            }
        } else {
            playingPolls = 0
            if !firstPlaying {
                pollsWithoutPlay += 1
                if state.has && (state.paused || state.muted) {
                    controller.evaluate(JoeYtJS.nudgePlay)
                }
                if pollsWithoutPlay >= 9 {
                    stepDown(reason: "no-play timeout")
                }
            }
        }
    }

    // MARK: Episode flow

    private func scheduleAutoNext() {
        nextTask?.cancel()
        guard currentIndex + 1 < request.videoIds.count else {
            endSlate = true
            veilUp = false
            DiagLog.write("YT", "last episode ended — end slate")
            return
        }
        flashStatus("Hết tập — đang chuyển tập \(currentIndex + 2)…")
        nextTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    /// Manual next (Down press, the control-bar button) and
    /// auto-next share this. With no next episode a MANUAL
    /// call is a plain no-op — the end slate belongs to the
    /// genuinely-ended flow (scheduleAutoNext sets it when
    /// `ended` fires on the last episode); raising it from a
    /// stray Down press would trap a still-playing film
    /// behind a slate with no controls (review MAJOR,
    /// 2026-11-19).
    func advance() {
        nextTask?.cancel()
        guard !terminal else { return }
        guard currentIndex + 1 < request.videoIds.count else {
            return
        }
        currentIndex += 1
        endSlate = false
        pendingSeek = nil
        loadSurface(0)
        flashStatus("Tập \(currentIndex + 1)")
        notePressActivity()
    }

    /// The page advanced itself into the next episode (the
    /// wander check caught the landed id): sync to it WITHOUT
    /// a load — the film is already there. Per-episode state
    /// resets as for a load; the watchmax CSS must re-inject
    /// on the new page (cssInjected=false) and the veil
    /// re-covers until the pin re-verifies, so the owner
    /// never sits on an unstyled watch page.
    private func adoptSelfAdvance() {
        currentIndex += 1
        endSlate = false
        pollsWithoutPlay = 0
        playingPolls = 0
        firstPlaying = false
        cssInjected = false
        endedHandled = false
        checkpoint = 0
        veilUp = true
        let vid = request.videoIds[currentIndex]
        // The relock must keep the CURRENT surface's host
        // (the lockdown compares hosts): desktop surfaces
        // relock to www.youtube.com, the mobile surface to
        // m.youtube.com.
        let base = surface == 2
            ? "https://m.youtube.com/watch"
            : "https://www.youtube.com/watch"
        controller.relock(
            url: "\(base)?v=\(vid)&list=\(request.pid)&autoplay=1")
        flashStatus("Tập \(currentIndex + 1)")
        DiagLog.write("YT", "page self-advanced — adopted ep=\(currentIndex + 1)")
    }

    private func flashStatus(_ text: String) {
        statusLine = text
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.statusLine = nil
        }
    }

    private static func videoId(fromWatchURL string: String) -> String? {
        guard let components = URLComponents(string: string),
              components.path == "/watch" else { return nil }
        return components.queryItems?
            .first(where: { $0.name == "v" })?.value
    }
}

struct JoeYtPlayerView: View {
    let request: JoeYtPlayRequest
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    @StateObject private var model: JoeYtPlayerModel
    @FocusState private var retryFocused: Bool
    @FocusState private var nextFocused: Bool

    init(request: JoeYtPlayRequest) {
        self.request = request
        _model = StateObject(wrappedValue: JoeYtPlayerModel(request: request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.bridgeMissing {
                explanation
            } else {
                JoeWebView(controller: model.controller,
                           navigationMode: .playerLockdown,
                           playbackPresses: true)
                if model.veilUp {
                    veil
                }
                if let line = model.statusLine {
                    statusPill(line)
                }
                if model.controlsUp && model.hasNextEpisode
                    && model.failureText == nil {
                    controlBar
                }
                if model.endSlate {
                    endSlate
                }
                if let failure = model.failureText {
                    failureSlate(failure)
                }
            }
        }
        // Menu closes THIS player back to the detail (the
        // house own-root construction): the bridge never
        // consumes Menu, so the press lands here.
        .onExitCommand { nav.ytPlayer = nil }
        .onAppear {
            model.registerPressConsumer()
            model.onFallThrough = { route in
                nav.ytPlayer = nil
                nav.ytDetail = nil
                nav.movie = route
            }
            model.onDetailFallThrough = { token in
                nav.ytPlayer = nil
                nav.ytChainPlay = token
            }
            model.onExitRequest = { nav.ytPlayer = nil }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
        // When the control bar lowers itself, hand first
        // responder back to the web host so the playback
        // presses keep landing on it.
        .onChange(of: model.controlsUp) { _, up in
            if !up { model.controller.host?.focusContent() }
        }
    }

    /// The control bar — acceptance point 2: a real
    /// next-episode BUTTON inside the player. It rides above
    /// the veil at open (so the button is discoverable the
    /// moment the player opens), re-appears on every press,
    /// and auto-hides with the model's controls timer. The
    /// Down press is its shortcut (the window-level press
    /// routing asks the model for the same advance()).
    private var controlBar: some View {
        VStack {
            Spacer()
            HStack {
                Text(model.episodeLabel)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                Spacer()
                Button {
                    model.advance()
                } label: {
                    JoeSecondaryLabel(title: "Tập tiếp ⏭")
                }
                .joeCardButton()
                .focused($nextFocused)
            }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 60)
    }

    /// Sony lesson 2: the surface stays covered until the
    /// watchmax styling is verified in-page — the owner
    /// never sees a web page, only this slate, then film.
    private var veil: some View {
        ZStack {
            Color.black
            VStack(spacing: 18) {
                ProgressView()
                    .tint(.white)
                Text("Đang mở phim…")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(request.seriesTitle) · \(model.episodeLabel)")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .ignoresSafeArea()
    }

    private func statusPill(_ line: String) -> some View {
        VStack {
            Spacer()
            HStack {
                Text(line)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                Spacer()
            }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 60)
    }

    private var endSlate: some View {
        ZStack {
            Color.black.opacity(0.85)
            VStack(spacing: 14) {
                Text("Đã hết tập cuối của bộ này.")
                    .font(.system(size: 31, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Bấm Menu để quay lại danh sách tập.")
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .ignoresSafeArea()
    }

    private func failureSlate(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.9)
            VStack(spacing: 22) {
                Text(text)
                    .font(.system(size: 27))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
                Button {
                    model.retry()
                } label: {
                    JoeSecondaryLabel(title: "Thử lại")
                }
                .joeCardButton()
                .focused($retryFocused)
            }
        }
        .ignoresSafeArea()
        .defaultFocus($retryFocused, true)
    }

    private var explanation: some View {
        VStack(spacing: 16) {
            Text("Tính năng YouTube không khả dụng trên bản tvOS này.")
                .font(.system(size: 31, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Phần TVB còn lại — Tủ Phim · KKPhim · VSMOV · Film4K — vẫn dùng bình thường.")
                .font(.system(size: 25))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 80)
    }
}

// MARK: - Sign-in door (design §3.2)

/// Door-side loader: restores the mirror session first
/// (restore-before-load), then lands on the channel page
/// with the SAFARI user agent (research 2026-11-19: the
/// door's UA is the identity Google's sign-in check reads;
/// the player's Chrome UA stays on the player only). Every
/// finished page load re-reads the session state. The model
/// also probes which credential field the page is showing
/// and fills it from the door's native form on request.
@MainActor
private final class JoeYtDoorModel: ObservableObject {
    let controller = JoeWebController()
    @Published var fieldKind = "none"
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        controller.onFinishLoad = {
            Task { await JoeYtSession.shared.refresh() }
        }
        Task {
            await JoeYtSession.shared.ensureSession()
            // Land DIRECTLY on Google's sign-in page, not on
            // the channel page (a deliberate difference from
            // the Sony door): reaching the form must not
            // depend on clicking around a web page with the
            // remote — in-page navigation on a bridged tvOS
            // web view is unproven, while the form-first flow
            // needs no in-page click at all. After sign-in,
            // Google's own continue redirect lands on the
            // channel page, inside DoorRoam either way.
            controller.load(
                url: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fwww.youtube.com%2F%40TVB_Vietnam",
                userAgent: JoeYtJS.safariUA, lockedURL: nil)
        }
    }

    /// One probe of the page's credential field; the door's
    /// 2 s loop calls it alongside the presence refresh so
    /// the native form's buttons enable for the step the
    /// page is actually on.
    func probeField() {
        controller.evaluateForResult(JoeYtJS.doorProbe) { [weak self] result in
            if let result, result != self?.fieldKind {
                self?.fieldKind = result
            }
        }
    }

    func fillEmail(_ email: String) {
        controller.evaluate(JoeYtJS.fillIdentifier(email))
        DiagLog.write("YT", "door: identifier filled from native form")
    }

    func fillPassword(_ password: String) {
        controller.evaluate(JoeYtJS.fillPassword(password))
        DiagLog.write("YT", "door: password filled from native form")
    }
}

/// The Gold sign-in door. The owner signs in himself on
/// YouTube/Google's official pages; the app never sees,
/// types or stores a password.
///
/// Sony lesson 1 is built in: the session is re-checked
/// WHILE the door is open (a 2 s loop plus every page
/// finish), and the moment it flips, the door shows its
/// signed-in state with the forward action "Vào xem phim
/// Gold" — the owner is never left hunting for a way back
/// (he got lost twice on the Sony door tonight).
struct JoeYtSignInView: View {
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    @ObservedObject private var session = JoeYtSession.shared
    @StateObject private var doorModel = JoeYtDoorModel()
    @FocusState private var closeFocused: Bool
    @FocusState private var goldFocused: Bool
    /// The native credential form's fields. The password
    /// lives ONLY in this state while the door is open and
    /// is cleared the moment it has been filled into the
    /// page; neither value is ever logged or stored.
    @State private var emailText = ""
    @State private var passwordText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Đăng nhập TVB Gold")
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(theme.text)
            Text("Đăng nhập YouTube bằng tài khoản Gold của anh ngay trên trang chính thức của YouTube/Google. Joe TV không thấy và không lưu mật khẩu của anh — đăng nhập một lần là xem được phim Gold trong app.")
                .font(.system(size: 25))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1400, alignment: .leading)
            HStack(spacing: 14) {
                if session.signedIn {
                    Button {
                        nav.ytSignInOpen = false
                    } label: {
                        JoeChipLabel(
                            title: "✓ Đã đăng nhập — Vào xem phim Gold",
                            selected: true)
                    }
                    .joeCardButton()
                    .focused($goldFocused)
                } else {
                    Text("○ Chưa đăng nhập")
                        .font(.system(size: 25))
                        .foregroundStyle(theme.meta)
                }
                Button {
                    nav.ytSignInOpen = false
                } label: {
                    JoeSecondaryLabel(title: "Đóng")
                }
                .joeCardButton()
                .focused($closeFocused)
            }
            if !session.signedIn && session.bridgeAvailable {
                nativeForm
            }
            if session.bridgeAvailable {
                JoeWebView(controller: doorModel.controller,
                           navigationMode: .doorRoam,
                           playbackPresses: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Tính năng YouTube không khả dụng trên bản tvOS này.")
                    .font(.system(size: 27))
                    .foregroundStyle(theme.text)
                    .padding(.top, 30)
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        // Menu closes the door back to the screen that
        // opened it (own-root handler, the house rule).
        .onExitCommand { nav.ytSignInOpen = false }
        .defaultFocus($closeFocused, true)
        // Sony lesson 1, completed: the moment the session
        // flips WHILE the door is open, focus lands on the
        // forward action — "Vào xem phim Gold" is where the
        // owner's eyes and remote already are.
        .onChange(of: session.signedIn) { _, now in
            if now { goldFocused = true }
        }
        .task {
            doorModel.start()
            while !Task.isCancelled {
                await session.refresh()
                doorModel.probeField()
                if session.signedIn {
                    DiagLog.write("YT", "door: signed-in detected while open")
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .onDisappear {
            if session.signedIn {
                Task { await JoeYtSession.shared.mirrorNow() }
            }
        }
    }

    /// The text-entry mechanism (research 2026-11-19): a
    /// bridged web view on tvOS has no native typing, so the
    /// owner types here — native fields, the tvOS system
    /// keyboard — and the app types the values into Google's
    /// page fields for him. Each button enables when the
    /// door probe sees the page on that step. The password
    /// field clears itself the moment its value has been
    /// filled into the page.
    private var nativeForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trang Google trên TV không gõ trực tiếp được — anh gõ email và mật khẩu ở hai ô này (bàn phím TV hiện ra), app sẽ điền vào trang đăng nhập giúp anh.")
                .font(.system(size: 23))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1400, alignment: .leading)
            HStack(spacing: 14) {
                TextField("Email Google", text: $emailText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 25))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: 560)
                Button {
                    doorModel.fillEmail(emailText)
                } label: {
                    JoeSecondaryLabel(title: "Điền email & Tiếp tục")
                }
                .joeCardButton()
                .disabled(emailText.isEmpty
                    || doorModel.fieldKind != "email")
            }
            HStack(spacing: 14) {
                SecureField("Mật khẩu", text: $passwordText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 25))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: 560)
                Button {
                    let value = passwordText
                    passwordText = ""
                    doorModel.fillPassword(value)
                } label: {
                    JoeSecondaryLabel(title: "Điền mật khẩu & Đăng nhập")
                }
                .joeCardButton()
                .disabled(passwordText.isEmpty
                    || doorModel.fieldKind != "password")
            }
        }
    }
}
