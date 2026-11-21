import AVFoundation
import SwiftUI
import UIKit

// MARK: - Backdrop preview (2.0.48)
// The Netflix-style preview (owner-approved design,
// Option C as amended by the 2026-11-21 16:52 torrent
// ruling): when a DETAIL screen opens, a short MUTED
// segment of the title itself plays in the backdrop
// layer, over the static backdrop image and under the
// existing scrims. Static image first; the video
// crossfades in only when frames are really flowing.
//
// The rules, as ruled:
// - D1: ANY remote input kills the preview for that
//   visit, instantly — the detail wires every focus
//   binding, the Menu command, the player presentation
//   and scenePhase to kill(reason:). Once killed it
//   never restarts inside the same detail presentation
//   (killedForVisit latch). The latch engages from the
//   moment the detail appears, dwell included: the ONE
//   event that is not user input — the app's own
//   initial focus landing — is identified BY VALUE
//   (the visit's first transition of a focus binding
//   from unset to set) and routed through
//   focusInput(landingShaped:), never by timing.
// - Start position: 20–25% into the item Play would
//   play (the resume episode for a series, else the
//   first playable); the segment is capped at 120 s.
// - D3: skipped entirely when Reduce Motion is on.
// - D4: Settings toggle "Xem trước video trên ảnh nền",
//   default ON (JoePreviewSettings).
// - Torrent titles: NO preview, ever — their only
//   "trailer" upstream is a YouTube id this app cannot
//   play, and torrent media is never cached on this
//   device (playback streams from the debrid), so the
//   ruling's precondition (a clip from an already-cached
//   file) cannot occur; the static backdrop stays and
//   no debrid download is ever triggered for a preview.
// - The video layer is NOT focusable and takes no hit
//   testing: tvOS focus is OS-rendered and this layer
//   never fights it (no AVPlayerViewController — it
//   would trap focus; a bare AVPlayerLayer is used).
// - The preview's own code never writes WatchStore,
//   never fails over and never shows a slate. (Its
//   chain leg rides the shared Providers.ladderFor
//   path, whose VS/TP resolves record SourceHealth
//   outcomes exactly as the pre-existing dwell
//   pre-resolve through the same path already does —
//   the preview adds no health reporting of its own.)
//   Every failure is silent — the static
//   backdrop simply stays — and leaves ONE DiagLog line
//   (category PREVIEW: attempt / resolve kind /
//   fallback-with-reason / first frame with its ms /
//   kill / end), so the start latency is measurable
//   from the exported log. No URL is ever logged
//   (DiagLog scrubs regardless; the lines carry kinds
//   and ids only).

/// D4: the Settings toggle's storage. Default ON — an
/// absent key reads true.
enum JoePreviewSettings {
    private static let key = "previewBackdropEnabled"

    static var enabled: Bool {
        get {
            UserDefaults.standard.object(forKey: key) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// One detail presentation's preview: at most one
/// AVPlayer, owned end-to-end by this controller. The
/// detail creates it as a @StateObject, calls
/// beginAttempt + play (or abortAttempt) from its dwell
/// task, kill() from every input hook, and stop() on
/// disappear.
@MainActor
final class JoePreviewController: ObservableObject {

    /// True only while video frames are on screen —
    /// the backdrop layer's opacity binds to it.
    @Published private(set) var visible = false
    /// The preview player (nil outside an attempt's
    /// play phase). Published so the layer view attaches
    /// it the moment it exists — before the first frame,
    /// so the crossfade has a rendering layer to fade.
    @Published private(set) var player: AVPlayer?

    /// D1's latch: set by kill(), never cleared inside
    /// this controller's lifetime (one controller = one
    /// detail presentation).
    private var killedForVisit = false
    /// The initial focus landing's one-time pass: the
    /// first landing-shaped focus transition of the
    /// visit is the app focusing its default element,
    /// not user input. Consumed exactly once; every
    /// later focus transition is user input.
    private var landingConsumed = false
    /// Attempt bookkeeping: the kind label for the log
    /// lines and the stamp the first-frame latency is
    /// measured from (attempt = the moment the dwell
    /// fired, BEFORE any resolve — the honest "time
    /// until the backdrop moves" figure).
    private var attemptKind: String?
    private var attemptStartedAt: Date?
    private var generation = 0
    private var workTask: Task<Void, Never>?

    private func log(_ message: String) {
        DiagLog.write("PREVIEW", message)
    }

    // MARK: Attempt lifecycle

    /// Open an attempt: stamps the clock and writes the
    /// attempt line. Returns false when no attempt may
    /// start (killed earlier this visit, an attempt or a
    /// player already in flight) — the caller then does
    /// nothing more.
    @discardableResult
    func beginAttempt(kind: String) -> Bool {
        guard !killedForVisit, attemptKind == nil, player == nil
        else { return false }
        attemptKind = kind
        attemptStartedAt = Date()
        log("preview attempt kind=\(kind)")
        return true
    }

    /// The resolve behind the attempt failed or ruled
    /// the preview out: log the fallback (with its
    /// reason) and close the attempt. The static
    /// backdrop stays; nothing is shown, nothing latches
    /// — a later dwell in the same visit may retry only
    /// if the caller drives one (the detail does not).
    func abortAttempt(reason: String) {
        guard attemptKind != nil else { return }
        log("preview fallback reason=\(reason) — static backdrop stays")
        attemptKind = nil
        attemptStartedAt = nil
    }

    /// Play one resolved URL (the attempt's own stream,
    /// produced by the app's existing playback paths —
    /// a chain ladder entry or a YouTube assembly/direct
    /// URL). Muted, capped at 120 s of media from the
    /// 20–25% start point, crossfaded in by the view
    /// when `visible` flips at first frame. Returns true
    /// only when the variant was actually handed to a
    /// built player — callers that bank measurements
    /// (the Approach C ceiling map) key off this, so a
    /// kill that landed mid-resolve banks nothing.
    @discardableResult
    func play(url: URL, headers: [String: String]) -> Bool {
        guard let kind = attemptKind, !killedForVisit else {
            log("preview play refused — killed before resolve landed")
            attemptKind = nil
            attemptStartedAt = nil
            return false
        }
        generation += 1
        let gen = generation
        let startedAt = attemptStartedAt ?? Date()
        let asset = AVURLAsset(
            url: url,
            options: headers.isEmpty
                ? nil
                : [AVURLAssetHTTPHeaderFieldsKey: headers])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 10
        item.preferredPeakBitRate = 4_000_000
        item.preferredMaximumResolution = CGSize(width: 1920,
                                                 height: 1080)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.automaticallyWaitsToMinimizeStalling = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        player = p
        log("preview resolve kind=\(kind) — player built")
        workTask = Task { [weak self] in
            await self?.runPlayback(item: item, player: p,
                                    generation: gen,
                                    startedAt: startedAt)
        }
        return true
    }

    /// A focus transition reported by the detail's
    /// hooks. `landingShaped` is the transition's shape
    /// BY VALUE (a binding going from unset to set:
    /// nil→value, false→true). The visit's FIRST
    /// landing-shaped transition is the app's own
    /// initial focus landing — the focus engine sets
    /// exactly one binding when the screen appears,
    /// before any user press can move focus anywhere —
    /// so it is consumed as the landing and latches
    /// nothing. EVERY other transition (a later gain, a
    /// loss, a non-shaped change) is user input and
    /// kills, dwell included: there is no window in
    /// which a real press is ignored.
    func focusInput(landingShaped: Bool) {
        if !landingConsumed, landingShaped {
            landingConsumed = true
            return
        }
        kill(reason: "input")
    }

    /// D1: any input kills the preview for this visit.
    /// The cut is instant: teardown removes the player
    /// in the same update that drops `visible`, so the
    /// layer leaves with the input — there is no
    /// fade-out (the 0.8 s crossfade exists only on the
    /// way IN, at first frame).
    ///
    /// The latch is unconditional: it engages from the
    /// moment the detail appears — during the dwell,
    /// during a resolve, during playback. Teardown with
    /// nothing in flight is a no-op beyond the latch
    /// itself, and beginAttempt refuses from then on, so
    /// an owner who interacts during the dwell gets no
    /// preview at all this visit, exactly as ruled. The
    /// single non-input event, the app's own initial
    /// focus landing, never reaches this method — the
    /// detail routes focus transitions through
    /// focusInput(landingShaped:), which consumes it.
    /// A press that changes no hooked state at all (a
    /// Select on the favourite/follow toggle, a
    /// source-mode chip or row, the torrent row's no-op
    /// states, or a cast member while focus already
    /// rests on it: no transition, no hooked change)
    /// reaches this method directly from the button's
    /// own action — every such action in the detail
    /// calls kill() first (the source rows get it from
    /// the shared sourceRow construction itself).
    func kill(reason: String) {
        guard !killedForVisit else { return }
        killedForVisit = true
        log("preview kill reason=\(reason)")
        teardown()
    }

    /// The detail disappeared: full teardown, no latch
    /// semantics needed (the controller dies with the
    /// presentation).
    func stop() {
        teardown()
    }

    private func teardown() {
        generation += 1
        workTask?.cancel()
        workTask = nil
        visible = false
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        attemptKind = nil
        attemptStartedAt = nil
    }

    // MARK: Playback run

    /// Drive one built item to its first frame and on to
    /// its end: wait for readyToPlay, seek to the
    /// 20–25% point, play, flip `visible` when frames
    /// really flow, and finish at the 120 s cap. Every
    /// exit is either a logged finish or a logged
    /// fallback — never a hang: a 12 s first-frame
    /// deadline and a 150 s hard stop bound the run.
    private func runPlayback(item: AVPlayerItem, player p: AVPlayer,
                             generation gen: Int,
                             startedAt: Date) async {
        func alive() -> Bool {
            gen == generation && !Task.isCancelled && player === p
        }
        // Duration first (the start point and the cap
        // both derive from it). An unknown/indefinite
        // duration starts at 0 with the hard stop as
        // the only cap.
        let duration = try? await item.asset.load(.duration)
        guard alive() else { return }
        var startSeconds = 0.0
        var endSeconds = Double.greatestFiniteMagnitude
        if let duration, duration.isNumeric, duration.seconds > 0 {
            startSeconds = duration.seconds * 0.22
            endSeconds = min(duration.seconds, startSeconds + 120)
            item.forwardPlaybackEndTime = CMTime(
                seconds: endSeconds, preferredTimescale: 600)
        }
        // Wait for readyToPlay (deadline-bounded).
        while item.status == .unknown {
            if Date().timeIntervalSince(startedAt) > 12 {
                log("preview fallback reason=deadline — no ready item in 12s")
                teardown()
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard alive() else { return }
        }
        guard item.status == .readyToPlay else {
            let why = item.error?.localizedDescription ?? "unknown"
            log("preview fallback reason=item-failed — \(why)")
            teardown()
            return
        }
        if startSeconds > 0 {
            _ = await p.seek(to: CMTime(seconds: startSeconds,
                                        preferredTimescale: 600),
                             toleranceBefore: CMTime(seconds: 10,
                                                     preferredTimescale: 600),
                             toleranceAfter: CMTime(seconds: 10,
                                                    preferredTimescale: 600))
            guard alive() else { return }
        }
        p.play()
        // First frame = the player is actually playing
        // and its clock has moved past the start point.
        var shownAt: Date?
        while true {
            if Date().timeIntervalSince(startedAt) > 150 {
                log("preview end reason=hard-stop shown=\(shownAt != nil)")
                teardown()
                return
            }
            if shownAt == nil,
               Date().timeIntervalSince(startedAt) > 12 {
                log("preview fallback reason=deadline — no first frame in 12s")
                teardown()
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard alive() else { return }
            let now = p.currentTime().seconds
            if shownAt == nil {
                if p.timeControlStatus == .playing,
                   now.isFinite, now > startSeconds + 0.05 {
                    shownAt = Date()
                    visible = true
                    let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                    log("preview first frame ms=\(ms) startAt=\(Int(startSeconds))s")
                }
                continue
            }
            if now.isFinite, now >= endSeconds - 0.5 {
                let shown = Int(Date().timeIntervalSince(shownAt ?? Date()))
                log("preview end reason=cap shown=\(shown)s")
                teardown()
                return
            }
            if item.status == .failed {
                log("preview end reason=item-failed-midplay")
                teardown()
                return
            }
        }
    }
}

// MARK: - Layer host view

/// The bare AVPlayerLayer host for the backdrop stack:
/// not focusable, no hit testing, hidden from
/// accessibility — a decoration layer only, exactly as
/// the platform rules require (the OS focus engine is
/// never fought).
struct JoePreviewLayerView: UIViewRepresentable {
    @ObservedObject var controller: JoePreviewController

    func makeUIView(context: Context) -> JoePreviewHostView {
        JoePreviewHostView()
    }

    func updateUIView(_ uiView: JoePreviewHostView,
                      context: Context) {
        uiView.playerLayer.player = controller.player
    }
}

final class JoePreviewHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFocused: Bool { false }
}
