import Foundation

// MARK: - YT PROBE — bridge slice for the PO-token minter
//
// EXTRACTED (not copied wholesale) from JoeTV's
// JoeYtWeb.swift @ claude/po-minter-core 694d2b7: ONLY the
// two types the PO-token minter touches —
// JoeWebController (the ObjC bridge's Swift delegate) and
// JoeWebOffscreenHost (the MinterLockdown offscreen
// surface). The web player model, the sign-in door and
// the JoeYtJS payloads are NOT carried into the probe.
// Both types are verbatim except the one omission noted
// inline in JoeWebController (startPoll).

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
        // The completion MUST fire on every path (review
        // round 1, BLOCKER 2): with a nil host the old
        // optional-chain simply dropped it, and any
        // caller waiting on it — the door chooser's
        // continuation in evaluateAsync — hung forever.
        guard let host else {
            completion(nil)
            return
        }
        // The completion closure captures the host
        // STRONGLY (review round 2, MINOR): the controller
        // holds it weakly, and a host deallocated mid-
        // evaluation could take the completion with it —
        // the capture keeps the host (and its web view)
        // alive until the handler has fired.
        host.evaluateJavaScript(js) { result in
            _ = host
            Task { @MainActor in completion(result) }
        }
    }

    /// v2.0.42: document-start scripts (the door's
    /// capability masking). Sticky by design: the script
    /// is remembered and applied to the current host AND
    /// to any host created later, so the install lands
    /// before the first navigation regardless of the
    /// exact order the view and the model start in.
    private var startScripts: [String] = []

    @MainActor
    func installDocumentStartScript(_ js: String) {
        startScripts.append(js)
        host?.addDocumentStartScript(js)
    }

    /// Called by the representable when a host is born.
    @MainActor
    func applyStartScripts(to newHost: JoeWebHostView) {
        for js in startScripts {
            newHost.addDocumentStartScript(js)
        }
    }

    // PROBE EXTRACTION NOTE: startPoll() from the app
    // source is omitted — it is the only member that
    // drags in JoeYtJS.poll (the web PLAYER's state-
    // polling payload). The minter never starts the
    // bridge poll timer; JoeYtPoPage polls from Swift
    // via evaluateForResult. stopPoll() below is kept
    // (no outside dependency; the offscreen host's
    // teardown calls the bridge's stopPolling).
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

// MARK: - Offscreen host (PO-token minter)
//
// claude/po-minter-core: the third bridge surface. A
// JoeWebHostView created OFFSCREEN — never added to a window
// or a SwiftUI hierarchy — in the MinterLockdown navigation
// mode, kept alive by its owner (JoeYtPoMinter) for as long
// as the minter needs the page. The two existing surfaces
// (JoeWebView for the player and the door) are untouched:
// this type only reuses JoeWebController's delegate plumbing.
@MainActor
final class JoeWebOffscreenHost {
    let controller = JoeWebController()
    private(set) var host: JoeWebHostView?

    init() {
        // A real, non-zero frame: WebKit lays the page out
        // against it even though no window ever shows it.
        let host = JoeWebHostView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
        host.navigationMode = .minterLockdown
        host.playbackPressesEnabled = false
        host.delegate = controller
        controller.host = host
        self.host = host
    }

    /// Loads a local page (no network) as `baseURL`, with
    /// `userAgent` as navigator.userAgent. Outcome arrives on
    /// the controller's onFinishLoad / onFailLoad callbacks.
    func loadLocalPage(html: String, baseURL: String, userAgent: String) {
        host?.loadHTMLString(html, baseURLString: baseURL, userAgent: userAgent)
    }

    /// Drops the web view. Idempotent.
    func teardown() {
        host?.stopPolling()
        host?.delegate = nil
        controller.host = nil
        host = nil
    }
}
