import AVFoundation
import SwiftUI
import UIKit

// MARK: - Backdrop preview (2.0.48; v2.0.49 trailer redesign)
// The Netflix-style preview (owner-approved design,
// Option C as amended by the 2026-11-21 22:39 torrent
// ruling): when a DETAIL screen opens, the title's
// TRAILER plays MUTED in the backdrop layer, over the
// static backdrop image and under the existing scrims.
// Static image first; the video crossfades in only
// when frames are really flowing.
//
// v2.0.49 — THE PREVIEW IS THE TRAILER (owner contract
// 2026-11-21 22:34–22:39 CST): the shipped 2.0.48
// preview resolved the title's EPISODE stream and
// played a segment of the episode itself. The owner's
// exported DiagLog (joetv-diag_13) convicted it: 58
// PREVIEW lines, 16 attempts — every one an episode
// leg (chain / YouTube episode), ZERO trailer attempts;
// the legs failed (404, no first frame) or were
// killed, and no trailer was ever shown. Episode-
// content preview is therefore REMOVED in 2.0.49.
// The one preview source now: the title's trailer —
// TMDB's trailer for the title first (resolved to a
// YouTube key, then through the app's YouTube resolver),
// the title's own source trailer (the provider
// payload's trailer URL) as fallback. No trailer →
// no attempt; the static backdrop simply stays.
//
// The rules, as ruled:
// - D1: ANY remote input kills the preview for that
//   visit, instantly — the detail wires every focus
//   binding, the Menu command, the player presentation
//   and scenePhase to kill(reason:). Once killed it
//   never restarts inside the same detail presentation
//   (killedForVisit latch).
// - D1 ARMING (v2.0.49 — the kill latch's arming rule,
//   restated precisely): focus-driven kills engage ONLY
//   while an attempt is in flight (an attempt has begun
//   and not yet aborted, or a player exists). Input
//   BEFORE the attempt starts — the dwell included,
//   and with it every programmatic focus landing the
//   load itself performs — never latches: focusInput
//   ignores such transitions entirely. Once the dwell
//   completes and the attempt begins, ANY input kills
//   instantly and the visit never retries. A user who
//   opens a detail and simply waits therefore sees
//   the trailer. Explicit kill(reason:) calls (Menu,
//   a Play presentation, a provider switch, the scene
//   leaving the foreground) are deliberate actions and
//   keep their unconditional latch at any moment.
// - Start position: a trailer plays from its OWN
//   start (startFraction 0 — play(url:headers:
//   startFraction:) carries the fraction; the 0.22
//   default remains for any future mid-item use).
//   The shown segment is capped at 120 s.
// - QUALITY GATE (owner ruling 2026-11-21 17:50): a
//   preview segment whose resolved quality is LOW is
//   not shown at all — the static backdrop stays; only
//   a good-quality preview may pass. Concrete rule:
//   a resolved format height below 720p suppresses
//   the preview entirely. The gate judges THIS
//   attempt's resolved height only (v2.0.49: the
//   banked measured-ceiling pre-skip is retired —
//   the Approach C map still feeds the honest
//   quality badge, never a pre-emptive skip). The
//   gate is enforced at three points: the detail
//   refuses a variant whose resolver-known height is
//   below 720p before any hand-over; the built
//   item's presentation height is checked when it
//   becomes ready, and
//   again at the last moment before the first frame
//   can appear (a late-settling size below 720p
//   still suppresses); and CONTINUOUSLY while the
//   preview is on screen — an HLS size that settles
//   below 720p after the first frame, or an ABR step
//   down to one, cuts the preview the moment the low
//   reading has held for ~1 s (settled low quality,
//   not a ramp-up transient). An UNKNOWN height (0)
//   cannot convict and passes — HLS sizes can settle
//   late.
// - END CROSSFADE (owner ruling 2026-11-21 17:49):
//   when the segment ENDS, the layer crossfades
//   back to the static backdrop over 0.8 s — the
//   clip is never left frozen on its final frame.
//   "Ends" is detected three ways, so no stream
//   class escapes it: the media-time cap (120 s
//   from the start point, numeric durations), the
//   shown-time cap (120 s visible, the backstop
//   when the duration never becomes numeric), and
//   the item's own end via an
//   AVPlayerItemDidPlayToEndTime observer (which
//   also covers streams ending before their
//   metadata duration). The fade is for the
//   natural end only: a kill still cuts instantly
//   (D1).
// - D3: skipped entirely when Reduce Motion is on.
// - D4: Settings toggle "Xem trước video trên ảnh nền",
//   default ON (JoePreviewSettings).
// - Torrent titles (owner ruling 2026-11-21 22:39
//   CST, v2.0.49): the torrent backdrop is a STATIC
//   image by ruling — the cached-clip preview design
//   is retired entirely. Torrent titles get NO preview
//   machinery, full stop: no clip is ever built, no
//   debrid download is ever triggered for a preview,
//   and the static backdrop is the whole backdrop.
// - The video layer is NOT focusable and takes no hit
//   testing: tvOS focus is OS-rendered and this layer
//   never fights it (no AVPlayerViewController — it
//   would trap focus; a bare AVPlayerLayer is used).
// - The preview's own code never writes WatchStore,
//   never fails over and never shows a slate. Its one
//   resolve path is the trailer's YouTube resolve
//   (JoeYtResolver, the player's own route); there is
//   no chain ladder and no episode resolve behind a
//   preview any more (v2.0.49). Every failure is
//   silent — the static
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
    /// True during the natural-end crossfade back to
    /// the static backdrop (the 17:49 ruling): the
    /// layer's opacity animates to 0 over 0.8 s while
    /// `visible` stays true, then teardown removes the
    /// player. Never set by kill()/stop() — those cut
    /// instantly.
    @Published private(set) var fadingOut = false
    /// The preview player (nil outside an attempt's
    /// play phase). Published so the layer view attaches
    /// it the moment it exists — before the first frame,
    /// so the crossfade has a rendering layer to fade.
    @Published private(set) var player: AVPlayer?

    /// D1's latch: set by kill(), never cleared inside
    /// this controller's lifetime (one controller = one
    /// detail presentation).
    private var killedForVisit = false
    /// Attempt bookkeeping: the kind label for the log
    /// lines and the stamp the first-frame latency is
    /// measured from (attempt = the moment the dwell
    /// fired, BEFORE any resolve — the honest "time
    /// until the backdrop moves" figure).
    private var attemptKind: String?
    private var attemptStartedAt: Date?
    private var generation = 0
    private var workTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    /// AVPlayerItemDidPlayToEndTime state for the
    /// current item: the natural-end signal that does
    /// not depend on the item's duration ever becoming
    /// numeric (review round 3, defect 3). The observer
    /// token is removed in teardown().
    private var itemEnded = false
    private var endObserver: NSObjectProtocol?

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

    /// Play one resolved URL (the attempt's own stream:
    /// v2.0.49 — the trailer's YouTube assembly/direct
    /// URL, produced by JoeYtResolver). Muted, capped at
    /// 120 s of shown media, crossfaded in by the view
    /// when `visible` flips at first frame.
    /// `startFraction` is where playback begins inside
    /// the item: the trailer leg passes 0 (a trailer
    /// plays from its own start); the 0.22 default is
    /// the old mid-item point, kept for any future use.
    /// Returns true only when the variant was actually
    /// handed to a built player — callers that bank
    /// measurements (the Approach C ceiling map) key
    /// off this, so a kill that landed mid-resolve
    /// banks nothing.
    @discardableResult
    func play(url: URL, headers: [String: String],
            startFraction: Double = 0.22) -> Bool {
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
                : ["AVURLAssetHTTPHeaderFieldsKey": headers])
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
        // Natural-end detection that does not depend on
        // the duration ever becoming numeric: the item
        // posts DidPlayToEndTime when it plays to its
        // end, whatever its metadata claims (review
        // round 3, defect 3).
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        itemEnded = false
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.itemEnded = true }
        }
        workTask = Task { [weak self] in
            await self?.runPlayback(item: item, player: p,
                                    generation: gen,
                                    startedAt: startedAt,
                                    startFraction: startFraction)
        }
        // First-frame deadline watchdog (review round
        // 1/3, defect): the pre-play phase contains
        // awaits no in-loop deadline can interrupt —
        // the asset's duration load and the seek can
        // each suspend indefinitely on a stalled
        // stream, and every deadline check sits
        // downstream of them. This task owns the 12 s
        // first-frame bound from OUTSIDE that chain:
        // at the deadline it tears the attempt down
        // itself (which also cancels the parked
        // workTask). Once a first frame has shown, the
        // playback loop's own bounds own the run and
        // the watchdog stands down.
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            let remaining = 12 - Date().timeIntervalSince(startedAt)
            if remaining > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled, let self,
                  self.generation == gen, self.player === p,
                  !self.visible else { return }
            self.log("preview fallback reason=deadline-watchdog — no first frame in 12s")
            self.teardown()
        }
        return true
    }

    /// A focus transition reported by the detail's
    /// hooks. v2.0.49 arming rule: a focus transition
    /// is user input ONLY while an attempt is in
    /// flight (attemptKind != nil || player != nil) —
    /// then it kills instantly, exactly as before.
    /// Before the attempt starts (the dwell included)
    /// a transition is ignored ENTIRELY: no latch, no
    /// landing bookkeeping — the programmatic focus
    /// landings the load itself performs (the initial
    /// landing, a default-focus move when content
    /// lands) can no longer kill a preview that has
    /// not begun. `landingShaped` (the transition's
    /// shape BY VALUE: a binding going from unset to
    /// set) is kept in the signature so the details'
    /// hook call sites stay unchanged; under the new
    /// arming rule the shape no longer decides anything.
    func focusInput(landingShaped: Bool) {
        guard attemptKind != nil || player != nil else { return }
        kill(reason: "input")
    }

    /// D1: any input kills the preview for this visit.
    /// The cut is instant: teardown removes the player
    /// in the same update that drops `visible`, so the
    /// layer leaves with the input — a kill has NO
    /// fade-out (the 0.8 s crossfades belong to the
    /// first frame on the way IN and to the natural
    /// END on the way out, never to a kill).
    ///
    /// This method's latch is unconditional — but it is
    /// reached only by DELIBERATE actions (Menu, a Play
    /// presentation, a provider switch, the scene
    /// leaving the foreground, a hooked button's own
    /// action below) or by focusInput while an attempt
    /// is in flight (v2.0.49 arming rule — see the file
    /// header's D1 ARMING note). A bare focus transition
    /// before the attempt starts never reaches this
    /// method at all. Teardown with nothing in flight is
    /// a no-op beyond the latch itself, and beginAttempt
    /// refuses from then on.
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

    /// v2.0.49 (gate R1, lens C): the ARMED kill — for
    /// input that does NOT end the visit (a Menu press
    /// spent on the Back-to-top jump, a source-chip press
    /// or an episode tap on the YouTube-only detail while
    /// the user stays on the page). It acts only when an
    /// attempt is actually in flight — the same guard
    /// focusInput applies — so pre-attempt input (the
    /// dwell included) never latches the visit: a user
    /// who jumps to the top and then simply waits still
    /// sees the trailer. Actions that LEAVE the page keep
    /// the unconditional kill() above.
    func killIfAttempting(reason: String) {
        guard attemptKind != nil || player != nil else { return }
        kill(reason: reason)
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
        deadlineTask?.cancel()
        deadlineTask = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        itemEnded = false
        visible = false
        fadingOut = false
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        attemptKind = nil
        attemptStartedAt = nil
    }

    // MARK: Playback run

    /// Drive one built item to its first frame and on to
    /// its end: wait for readyToPlay, seek to the
    /// startFraction point (0 for a trailer — its own
    /// start), play, flip `visible` when frames
    /// really flow, and finish at the 120 s cap. Every
    /// exit is either a logged finish or a logged
    /// fallback — never a hang: a 12 s first-frame
    /// deadline and a 150 s hard stop bound the run,
    /// and the deadline watchdog armed in play()
    /// enforces the first-frame bound even while one
    /// of this run's own pre-play awaits (duration
    /// load, seek) is suspended past it.
    private func runPlayback(item: AVPlayerItem, player p: AVPlayer,
                             generation gen: Int,
                             startedAt: Date,
                             startFraction: Double) async {
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
            // v2.0.49: the start point is the caller's
            // fraction (0 for the trailer leg), no longer
            // a hard-coded mid-item point.
            startSeconds = duration.seconds * startFraction
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
        // QUALITY GATE (17:50 ruling): a segment whose
        // resolved height is KNOWN to be below 720p is
        // never shown — teardown here, before play(),
        // so not one frame of it reaches the layer. An
        // unknown height (0) cannot convict and passes;
        // the check repeats at first frame below for a
        // size that settles late.
        if item.presentationSize.height > 0,
           item.presentationSize.height < 720 {
            log("preview suppressed reason=low-quality height=\(Int(item.presentationSize.height)) — static backdrop stays")
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
        // Consecutive on-screen polls whose presented
        // height is known to be below 720p (the
        // continuous quality gate below).
        var lowPolls = 0
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
                    // The quality gate once more, at the
                    // last moment before the layer can
                    // appear: a presentation size that
                    // settled late below 720p suppresses
                    // here, before a single frame shows.
                    if item.presentationSize.height > 0,
                       item.presentationSize.height < 720 {
                        log("preview suppressed reason=low-quality-late height=\(Int(item.presentationSize.height)) — static backdrop stays")
                        teardown()
                        return
                    }
                    shownAt = Date()
                    visible = true
                    let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                    log("preview first frame ms=\(ms) startAt=\(Int(startSeconds))s")
                }
                continue
            }
            // QUALITY GATE, continuous (17:50 ruling;
            // review round 2, defect 1): the presented
            // height is re-read on every pass while the
            // preview is on screen. An HLS size routinely
            // settles only AFTER the first frame, and ABR
            // can step down mid-segment — neither is
            // visible to the two pre-show checks. A
            // height that stays below 720p for five
            // consecutive polls (~1 s) is SETTLED low
            // quality, not a ramp-up transient (a stream
            // still climbing to its real variant recovers
            // inside the window and resets the counter),
            // and it cuts the preview instantly — it
            // should never have shown, so there is no
            // fade — back to the static backdrop.
            // The counter resets ONLY on a poll whose
            // height is KNOWN to be at least 720p —
            // positive evidence of recovery. An unknown
            // poll (height 0) HOLDS the counter: after
            // the first frame, a size flickering to 0
            // during a variant switch or rebuffer is
            // not evidence the quality recovered, and
            // resetting on it would let a settled-low
            // stream whose size flickers evade the
            // gate forever (review round 1, defect 1).
            if shownAt != nil {
                if item.presentationSize.height > 0,
                   item.presentationSize.height < 720 {
                    lowPolls += 1
                    if lowPolls >= 5 {
                        log("preview suppressed reason=low-quality-drop height=\(Int(item.presentationSize.height)) — static backdrop stays")
                        teardown()
                        return
                    }
                } else if item.presentationSize.height >= 720 {
                    lowPolls = 0
                }
            }
            // The item played to its end (the
            // DidPlayToEndTime observer): the natural
            // end for items whose duration never became
            // numeric, and for streams that end before
            // their metadata duration — crossfade out;
            // the layer must never sit frozen on the
            // final frame until the hard stop (17:49
            // ruling; review round 3, defect 3).
            if itemEnded {
                let shown = Int(Date().timeIntervalSince(shownAt ?? Date()))
                log("preview end reason=item-ended shown=\(shown)s — crossfade to static")
                await fadeOutToStatic(generation: gen, player: p)
                return
            }
            // Shown-time cap: 120 s of VISIBLE preview —
            // the backstop bound for indefinite-duration
            // items, whose media-time cap can never fire.
            if let shownAt,
               Date().timeIntervalSince(shownAt) >= 120 {
                log("preview end reason=cap-time shown=120s — crossfade to static")
                await fadeOutToStatic(generation: gen, player: p)
                return
            }
            if now.isFinite, now >= endSeconds - 0.5 {
                let shown = Int(Date().timeIntervalSince(shownAt ?? Date()))
                log("preview end reason=cap shown=\(shown)s — crossfade to static")
                await fadeOutToStatic(generation: gen, player: p)
                return
            }
            if item.status == .failed {
                log("preview end reason=item-failed-midplay")
                teardown()
                return
            }
        }
    }

    /// The natural end of the segment (owner ruling
    /// 2026-11-21 17:49): crossfade back to the static
    /// backdrop — `fadingOut` flips and the view
    /// animates the layer's opacity to 0 over 0.8 s
    /// (the player sits paused at its end point while
    /// the static image re-emerges beneath it); only
    /// then is the player torn down. The clip is never
    /// LEFT frozen on its final frame. This path is
    /// only for the natural end: a kill or stop during
    /// the fade cancels the sleep via teardown's
    /// generation bump and cuts at once, as D1 rules.
    private func fadeOutToStatic(generation gen: Int,
                                 player p: AVPlayer) async {
        fadingOut = true
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard gen == generation, player === p else { return }
        teardown()
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
