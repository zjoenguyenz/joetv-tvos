import AVFoundation
import AVKit
import Combine
import OSLog
import SwiftUI
import UIKit

/// Playback failure log (v2.0.5, error 8a): the torrent path
/// used to discard every engine error unread — the KS delegate
/// received the finish Error and threw it away, RD resolution
/// failures vanished into a bare `try?`, and the exhausted
/// slate carried no evidence at all. Failures are now logged
/// with engine + HOST ONLY: Torrentio URLs embed the owner's
/// RD token in the path, so a full URL (or any token) must
/// never reach the log.
enum PlaybackLog {
    static let logger = Logger(subsystem: "com.luun.nguyen.joetv",
                               category: "playback")
}

/// One playable stream candidate: a freshly resolved URL plus
/// the headers its CDN demands (never a blanket header — see the
/// house rule in Channel.swift).
/// Swift 6: Sendable — candidates are built by the
/// nonisolated TorrentClient/Providers workers and handed
/// to the @MainActor director; every member is a value
/// type, so the conformance is structural.
struct PlayCandidate: Sendable {
    /// Which engine plays this candidate. Provider ladders stay
    /// on AVPlayer (the house player, untouched). Torrent
    /// candidates (TorrentClient.playCandidates — the torrent
    /// section AND the Phim substitution rung) carry .ffmpeg:
    /// the files Torrentio/Real-Debrid serve are predominantly
    /// Matroska, which AVFoundation cannot demux at all — those
    /// items never became ready and the session walked a long
    /// list of them as one endless black spinner (v2.0.3).
    enum Engine {
        case avPlayer
        case ffmpeg
    }

    var url: URL
    var headers: [String: String] = [:]
    var label: String = ""
    var engine: Engine = .avPlayer

    /// v2.0.16: the side-loaded subtitle the session resolved
    /// for this title — the subtitle addon's best Vietnamese
    /// (JoeTorrentDetail attaches it to every ladder
    /// candidate). The KSPlayer host adds it to its subtitle
    /// model beside the file's embedded tracks and selects
    /// it, the Android player's auto-attach mirrored. Nil
    /// for provider candidates and titles without one.
    var subtitleURL: URL? = nil

    /// v2.0.26 (idea 10): the torrent stream's parsed display
    /// features, stamped by TorrentClient.playCandidates from
    /// the TorStream's own ranking parse. The KSPlayer host
    /// reads them to build its preferredDisplayCriteria (the
    /// AVPlayer path is matched by the system and ignores
    /// them). Defaults = SDR / unknown rate: provider
    /// candidates never set them.
    var dv = false
    var hdr = false
    /// Frame rate parsed from the release name when present
    /// (e.g. 59.94 / 50); nil = no explicit rate in the name.
    var fps: Double? = nil

    /// The AVURLAsset the AVPlayer path opens for this
    /// candidate: exactly the candidate's headers, plus the
    /// house user agent when none was set. Shared by the
    /// cold path (PlayerController) and the dwell warmer
    /// (StreamWarmer) so both open the stream identically —
    /// the warmer's whole value is that the tap re-opens
    /// nothing it already loaded.
    func makeAsset() -> AVURLAsset {
        var headers = self.headers
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = JoeHTTP.userAgent
        }
        return AVURLAsset(url: url,
                          options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }
}

/// Everything the player needs to keep WatchStore honest: the
/// entry template saved on ticks, and the key the resume position
/// was read from. After a cross-provider hop the detail view
/// re-issues the session with the NEW provider's identity — the
/// resume position itself is carried over by the director.
/// Swift 6: Sendable, like PlayCandidate — identities ride
/// the director's resolver closures across the same
/// boundaries (WatchStore.Entry is Sendable).
struct PlayIdentity: Sendable {
    var entry: WatchStore.Entry
    var progressKey: String { entry.key }
}

/// The play session's brain: resolves ladders, drives the
/// Android-verified failover ladder (same-provider refresh once,
/// then one cross-provider hop), applies the resume rule and saves
/// progress at the Android cadence. The SwiftUI view below is a
/// thin shell over it.
@MainActor
final class PlayDirector: ObservableObject {
    enum Phase {
        case resolving
        case playing
        case exhausted
    }

    @Published private(set) var phase: Phase = .resolving
    @Published private(set) var attemptID = 0
    @Published var notice: String?
    @Published private(set) var currentLabel = ""
    /// v2.0.29 (item 2): the live host's transport-bar
    /// visibility, reported by the host itself — the KS
    /// host from its show/hide path, the AVPlayer host from
    /// the fix-9 delegate callback. The shell binds the
    /// status capsule's visibility to this, so the capsule
    /// (the candidate's source label / the resume and
    /// failover notices) hides and returns WITH the bar on
    /// both engines and can never linger on its own: the
    /// capsule itself has no timer and no other state.
    /// Starts true — both hosts open with their bar up.
    @Published private(set) var transportBarVisible = true

    /// Hosts report their bar's visibility here. Only a
    /// change publishes, so a host re-asserting its state
    /// (every press wakes the KS bar) costs no re-render.
    func setTransportBarVisible(_ visible: Bool) {
        if transportBarVisible != visible {
            transportBarVisible = visible
        }
    }

    /// v2.0.31 (L5): the KS host's picker state, reported
    /// by the host on the same pattern as the bar
    /// visibility above. The shell's exit command consults
    /// it: a Menu press while a picker is open closes the
    /// PICKER — through the host's own closePicker, via the
    /// registered handler — instead of dismissing the
    /// player. The host deliberately no longer intercepts
    /// Menu in its pressesEnded: on the owner's set the
    /// press reached BOTH consumers (the host closed the
    /// panel and the shell still dismissed), so Back out
    /// of the subtitle panel exited the film. With the
    /// host's interception gone, the shell is the one
    /// Menu arbiter for both engines, exactly as it
    /// already was whenever no picker was open.
    @Published private(set) var pickerOpen = false
    /// The live KS host's close-the-picker action,
    /// registered while its picker is open (nil on the
    /// AVPlayer path, between attempts, and once closed).
    private var pickerCloseHandler: (() -> Void)?

    func setPickerOpen(_ open: Bool, closeHandler: (() -> Void)? = nil) {
        pickerCloseHandler = open ? closeHandler : nil
        if pickerOpen != open {
            pickerOpen = open
        }
    }

    /// Menu with a picker open: close just the picker.
    /// The handler is the host's closePicker, so focus
    /// landing and bar state are restored by the same code
    /// that closes the panel after a selection.
    func requestPickerClose() {
        pickerCloseHandler?()
    }
    /// The most recent candidate failure's short cause (an
    /// engine error's description, or a watchdog label) — the
    /// exhausted slate shows it ("Lỗi cuối: …") so a dead
    /// slate finally says WHY, and itemFailed logs it. Set by
    /// whichever engine/watchdog reports the failure; cleared
    /// on a manual retry.
    @Published private(set) var lastFailure: String?

    // MARK: Up Next contract (v2.0.25, Idea 6 core)
    //
    // The factories that build the NEXT episode's session
    // (detail views / episode lists) wire these three
    // members on the CURRENT director before playback; the
    // player view itself only renders the countdown and
    // performs the handover (see JoePlayerView below).
    // Sessions that never set a factory keep the exact
    // pre-Up-Next end behaviour: itemEnded() just drops
    // the progress entry and nothing else happens.

    /// Builds the next episode's director, or nil when no
    /// next episode could be resolved. Called at most once
    /// per countdown (at zero, or from advanceNow()).
    var nextEpisodeFactory: (@MainActor () async -> PlayDirector?)?
    /// The next episode's display title, shown on the
    /// countdown card.
    var nextEpisodeTitle: String = ""
    /// Fired exactly once per session, from the shared
    /// itemReady core, on the FIRST ready item — the hook
    /// the shared warming system uses to warm the upcoming
    /// episode while this one plays.
    var onPlayingStarted: (@MainActor () -> Void)?

    /// Seconds left on the Up Next countdown (10 → 1);
    /// nil = no countdown is active.
    @Published private(set) var upNextSecondsLeft: Int?
    /// The next episode's director, published when the
    /// countdown's factory resolves one. The view observes
    /// this and swaps its session director in place.
    @Published private(set) var advanceTarget: PlayDirector?

    /// The countdown / advance task (one at a time) and a
    /// generation counter that invalidates a superseded
    /// run: cancelAdvance() and advanceNow() both bump the
    /// generation, so a factory result that lands after a
    /// cancel can never publish an advanceTarget.
    private var upNextTask: Task<Void, Never>?
    private var upNextGeneration = 0
    /// FIX4 (fix 6): latched the first time the Up Next card
    /// is armed for this item — by the last-10-seconds tick
    /// trigger, or by itemEnded's fallback. A user cancel
    /// must not let a later tick (or the end itself) re-arm
    /// the card for the same item.
    private var upNextArmed = false
    /// Once-per-session guard for onPlayingStarted (the
    /// firstFrameMarked guard below is its model).
    private var playingStartedNotified = false

    /// What the view should render right now.
    private(set) var candidate: PlayCandidate?

    private let store: WatchStore
    private var identity: PlayIdentity
    /// Builds a fresh ladder for the CURRENT identity (detail
    /// views own this: re-fetch detail → Providers.ladderFor).
    private let resolveLadder: (PlayIdentity) async -> [PlayCandidate]
    /// nil for sources with no cross-provider hop (torrent).
    private let hopIdentity: ((PlayIdentity) async -> PlayIdentity?)?
    /// The substitution rung (owner law, v1.9): when the ladder
    /// AND the hop are both exhausted, the director asks this
    /// closure for replacement candidates for the SAME title
    /// from another source family, still under the CURRENT
    /// identity (resume/Continue Watching stay on the original
    /// entry). The Phim detail wires it to the torrent side,
    /// matched by TMDB/IMDB id. nil for sources with nothing
    /// behind them (the torrent section's own sessions) — those
    /// exhaust exactly as before.
    private let fallbackCandidates: ((PlayIdentity) async -> [PlayCandidate])?
    /// Resume position read at session start (>20 s rule applied
    /// by the caller against the stored entry).
    private let resumeMs: Int64

    // v2.0.33 (item 8): per-press timing bookkeeping for
    // the persistent DiagLog file — logging only, no
    // behaviour change. `ladderStartedAt` is stamped at
    // the head of loadLadder() so the ladder-resolution
    // line can report how long resolveLadder took;
    // `attemptStartedAt` is re-stamped by beginCandidate()
    // for every candidate the ladder tries, so
    // itemFailed() can report how long that one attempt
    // lived before it failed. Together with the PerfLog
    // file mirror (JoeHTTP.swift) these are the timing
    // marks the press-to-play regression hunt reads from
    // ONE device run.
    private var attemptStartedAt = Date()
    private var ladderStartedAt = Date()

    private var candidates: [PlayCandidate] = []
    private var candidateIndex = 0
    private var refreshed = false
    private var hopped = false
    private var fallbackTried = false
    private var seekApplied = false
    private var lastPosMs: Int64 = 0
    private var lastDurMs: Int64 = 0
    /// v2.0.35 (AUDIT-2034-SWITCHRESUME): the session's
    /// FURTHEST reached position — the value itemReady's
    /// own v2.0.15 comment always promised ("the session's
    /// furthest position") but never had: pre-fix the
    /// carry rode on lastPosMs alone, which tick() keeps
    /// as the LATEST report, so the incoming host's first
    /// ~0 report after a switch (the new KS layer's
    /// currentTime delegate passes its fresh per-host 5 s
    /// throttle immediately) collapsed the carry to ~0
    /// before itemReady read it, and the new source
    /// restarted from 0:00. furthestPosMs is raised by
    /// tick() with max() and lowered in exactly one
    /// place — captureSwitchSnapshot re-baselines it to
    /// an accepted user-initiated capture (a deliberate
    /// rewind is the owner stating where they are now) —
    /// so an incoming item's early reports can never drag
    /// it down. Session scoping is lastPosMs's own:
    /// both live on the director, and a session (one film
    /// / one episode) is one director — the next episode's
    /// factory builds a fresh director, so the furthest
    /// starts clean exactly where lastPosMs does.
    /// lastPosMs keeps its latest-value role for the CW
    /// save rule and flush(); only the itemReady target
    /// reads the furthest.
    private var furthestPosMs: Int64 = 0
    /// v2.0.35 (AUDIT-2034-SWITCHRESUME): the LIVE
    /// playhead snapshot taken at an in-session switch
    /// entry (see captureSwitchSnapshot) — the exact
    /// position on screen at the moment the owner switched
    /// source or the playing candidate failed. tick()
    /// NEVER writes this field: it is written only by an
    /// accepted switch capture (a sub-window capture is
    /// ignored — see captureSwitchSnapshot) and read only
    /// by itemReady's target, so neither the outgoing
    /// host's silence nor the incoming host's early ~0
    /// reports can touch it.
    /// itemReady CONSUMES it — clears it right after
    /// computing a readied candidate's target — so one
    /// snapshot serves exactly one advance. 0 = no
    /// unconsumed snapshot is held.
    private var switchSnapshotMs: Int64 = 0
    private var started = false

    // v2.0.8 (Phase 3): ONE stored resolution task + ONE
    // end-to-end deadline for the ladder+failover sequence.
    // Every resolution spawn (start, candidate exhaustion,
    // manual retry) stores its handle in `resolutionTask`, so
    // the deadline watchdog can cancel the whole chain; the
    // in-task chain itself (loadLadder ↔ failoverStep) runs
    // as direct awaits inside that one task. The watchdog is
    // a second stored task, armed when the session's first
    // resolution starts and re-armed by a manual retry; it
    // STANDS DOWN the moment the torrent substitution rung
    // starts (see failoverStep) — the debrid resolve is never
    // cancelled mid-flight, hedged, or retried.
    private var resolutionTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    /// The one Play budget: 60 s from the first resolution
    /// start to a playing candidate or the exhausted slate.
    private static let resolutionDeadline: TimeInterval = 60
    /// v2.0.34 (item 8 tightening): the KSPlayer path's
    /// per-candidate first-frame budget, enforced by the
    /// ladder-level deadline in armCandidateDeadline().
    /// Evidence (the owner's 2.0.33 device log, DIAG-2033):
    /// a warmed candidate's first frame lands in ~100 ms
    /// and the slowest HEALTHY cold start in that log took
    /// ~4.4 s in preparing, while a dead TorBox CDN
    /// candidate rode 11,706 ms before the engine's own
    /// "Cannot Open" error failed it over. 8 s is ~1.8× the
    /// worst healthy cold start observed, ~80× the warmed
    /// time, and cuts both that measured dead ride and the
    /// KS host watchdog's 30 s silent ride (see
    /// armCandidateDeadline) to a third or less — while
    /// staying well under the AVPlayer path's 20 s U-1
    /// watchdog, the loosest in-tree precedent.
    private static let ksFirstFrameDeadline: TimeInterval = 8
    /// v2.0.35: the LIVE first-frame budget for the same
    /// ladder deadline (see armCandidateDeadline).
    /// Measured basis (the owner's 2.0.34 device log,
    /// DIAG-2034 (f)): Nuvio live FFmpeg candidates
    /// produced NO picture in 30 s twice (the KS host
    /// watchdog's full ride) and none in ~18 s on a third
    /// the owner abandoned, while the AVPlayer twin of
    /// the same stream readied in 4.53 s. 12 s is ~2.6×
    /// that measured healthy live start — room for a
    /// genuinely slow live start — and cuts the
    /// black-screen ride to the twin from 30 s to 12 s.
    /// The 2.0.34 live exemption stood only because no
    /// healthy live first-frame time had ever been
    /// measured; now one has.
    private static let ksLiveFirstFrameDeadline: TimeInterval = 12
    /// The armed candidate deadline (nil = disarmed). One
    /// at a time: beginCandidate() cancels the previous
    /// attempt's task before arming the next, and
    /// itemReady / itemFailed stand it down.
    private var candidateDeadlineTask: Task<Void, Never>?
    /// Per-attempt ready flag for the candidate deadline:
    /// beginCandidate() re-arms it (false) for every new
    /// candidate; the shared itemReady core sets it the
    /// first time the live attempt's engine reports ready.
    private var attemptReadied = false
    /// Manual-pick exemption for the candidate deadline
    /// (owner law: a manual source pick is never
    /// overridden by an automatic mechanism).
    /// userSwitchSource(to:) — the explicit chooser pick —
    /// sets nextAttemptManualPick; beginCandidate()
    /// consumes it into attemptManualPick for the attempt
    /// it begins. The blind userSwitchSource() advance is
    /// NOT a pick and does not set it.
    private var nextAttemptManualPick = false
    private var attemptManualPick = false
    /// v2.0.35 (AUDIT-2034-PROVIDER-RETRY (a)): the
    /// session's never-ready failure memory — the keys of
    /// every candidate that failed in THIS session without
    /// ever readying (attemptReadied was still false when
    /// itemFailed ran for it). Two keys are recorded per
    /// failure: the candidate's absolute URL string, and
    /// its host when the host is not loopback. Both are
    /// needed because of how candidates are built:
    ///   • a DIRECT candidate (KK, torrent, sports, and
    ///     Film4K whenever the proxy fallback fires — the
    ///     incident's shape): the host key survives the
    ///     provider's rotating URL tokens;
    ///   • a PROXY-WRAPPED candidate (the designed path
    ///     for VSMOV / Tủ Phim / Film4K): its URL is
    ///     loopback, so a host key would be 127.0.0.1 for
    ///     every provider — useless and dangerous, hence
    ///     never recorded — but the proxy token is a
    ///     deterministic hash of (upstream, headers,
    ///     kind), so the same upstream playlist produces
    ///     the identical absoluteString in the initial
    ///     ladder and in a refresh ladder, and the URL key
    ///     identifies it exactly.
    /// Automatic ladder commits (loadLadder, the failover
    /// hedge) filter recorded candidates out, so a refresh
    /// can never re-serve the candidate whose death
    /// triggered it — the 23:48 Film4K incident: the
    /// refresh rung re-resolved the incumbent in ~52 ms,
    /// beat the cross-provider hop, and the same dead
    /// stream host burned a second full 20 s U-1 window
    /// (40.2 s of black for one dead host). Scoped by
    /// failureMemoryArmed — the same hop/fallback
    /// predicate armResolutionDeadline uses — so
    /// torrent-section sessions stay byte-identical to
    /// their protected baseline and live/sports sessions
    /// (which carry neither closure) are doubly out: the
    /// sports FFmpeg→AVPlayer twins share a host by
    /// design and must never filter each other. Manual
    /// picks are never filtered: userSwitchSource(to:)
    /// indexes the LIVE ladder, which the filter never
    /// mutates — filtering shapes only future automatic
    /// commits. Cleared by retryFromExhausted: the
    /// owner's manual retry is a deliberate fresh start.
    private var neverReadyFailedKeys: Set<String> = []

    /// The failure memory's scope predicate — the same
    /// one armResolutionDeadline arms under (the sessions
    /// that carry a hop/fallback structure).
    private var failureMemoryArmed: Bool {
        hopIdentity != nil || fallbackCandidates != nil
    }

    /// Loopback hosts are never failure keys: a
    /// proxy-wrapped candidate's URL host is the house
    /// proxy's own loopback address, shared by every
    /// provider — keying on it would blacklist them all.
    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost"
            || host == "::1" || host == "[::1]"
    }

    /// v2.0.35 (AUDIT-2034-PROVIDER-RETRY (a)): drop the
    /// candidates this session has already watched fail
    /// without readying (see neverReadyFailedKeys) from a
    /// ladder an AUTOMATIC commit is about to adopt.
    /// Returns the ladder untouched when the mechanism is
    /// out of scope for this session or the memory is
    /// empty. MAY return an empty array — each call site
    /// applies its own never-empty rule (loadLadder falls
    /// back to the unfiltered ladder; the hedge treats an
    /// emptied branch as not having won, with an
    /// unfiltered last resort only when both branches
    /// produced ladders that filtered to empty). Every
    /// drop is logged — host only; a proxy-wrapped
    /// candidate dropped by its URL key has no host worth
    /// printing (its loopback host names nothing).
    private func filteringNeverReadyFailures(
        _ ladder: [PlayCandidate]
    ) -> [PlayCandidate] {
        guard failureMemoryArmed, !neverReadyFailedKeys.isEmpty
        else { return ladder }
        return ladder.filter { candidate in
            let hostKeyed = candidate.url.host.map {
                !Self.isLoopbackHost($0)
                    && neverReadyFailedKeys.contains($0)
            } ?? false
            let keyed = hostKeyed
                || neverReadyFailedKeys.contains(
                    candidate.url.absoluteString)
            if keyed {
                if let host = candidate.url.host,
                   !Self.isLoopbackHost(host) {
                    DiagLog.write("play", "failure memory filtered host=\(host)")
                } else {
                    DiagLog.write("play", "failure memory filtered candidate (proxy-wrapped)")
                }
            }
            return !keyed
        }
    }

    /// v2.0.34 (live exemption, REVIEW-2034-LOOP3 R-1;
    /// E-1 closure, REVIEW-2034-LOOP4): true when this
    /// session plays a LIVE stream. The determination is
    /// the entry's explicit live stamp (WatchStore.Entry
    /// .isLive) OR the "mf-event|" key prefix:
    ///   • The stamp is set at the one live mint —
    ///     JoeTVSection.playEvent, the Thể Thao Torrent
    ///     tap-to-play flow covering both the live sports
    ///     events and the standing live channels — and it
    ///     SURVIVES the two re-mints the prefix did not:
    ///     the player's favourite copy and the progress
    ///     tick copy the entry whole, and the torrent
    ///     detail's reopen threading (the Favourites /
    ///     Continue Watching rails → TorMeta.isLive →
    ///     makePlayDirector) carries it back onto the
    ///     fresh "tor|…" session entry. A live row is
    ///     therefore known live however it was opened.
    ///   • The prefix remains as the direct flow's own
    ///     marker (playEvent keys its entry "mf-event|…";
    ///     WatchStore.canonicalEligible reads the same
    ///     prefix as the tree's live/sports marker). No
    ///     VOD factory can mint it (torrent films/series
    ///     key under "tor|…", provider films under their
    ///     provider prefixes), and no VOD path sets the
    ///     stamp — it is written `true` at playEvent only
    ///     and everywhere else copied, never derived from
    ///     the meta type ("tv" is shared with torrent
    ///     series) or the serving base (owner-editable).
    /// A live session's candidates arm the ladder
    /// candidate deadline at the LIVE budget
    /// (ksLiveFirstFrameDeadline, 12 s) instead of the
    /// film budget — v2.0.35, on the first measured live
    /// evidence (see armCandidateDeadline); in 2.0.34
    /// they were exempt from it entirely and the KS
    /// host's 30 s first-frame watchdog governed them
    /// alone, which it still does as the backstop behind
    /// the ladder cut. Session-level and immutable: the
    /// flag is
    /// computed once from the identity the session was
    /// built with; live sessions carry no hop/fallback,
    /// and a reopened session's identity is the stamped
    /// entry makePlayDirector built for it.
    private let sessionIsLive: Bool
    /// PerfLog once-per-session guards (Phase 3 marks).
    private var ladderReadyMarked = false
    private var firstFrameMarked = false

    /// Race box for the hedged failover pair (Phase 3): the
    /// refresh branch and the hop branch each publish their
    /// ladder (nil = still running) and a done flag; the
    /// failover poll reads them. Both branches run as tasks
    /// on the main actor, so the box is only ever touched
    /// between awaits — no lock needed.
    private final class HedgeBox {
        var refreshLadder: [PlayCandidate]?
        var refreshDone = false
        var hopIdentity: PlayIdentity?
        var hopLadder: [PlayCandidate]?
        var hopDone = false
    }

    init(store: WatchStore,
         identity: PlayIdentity,
         resumeMs: Int64,
         resolveLadder: @escaping (PlayIdentity) async -> [PlayCandidate],
         hopIdentity: ((PlayIdentity) async -> PlayIdentity?)?,
         fallbackCandidates: ((PlayIdentity) async -> [PlayCandidate])? = nil) {
        self.store = store
        self.identity = identity
        self.sessionIsLive = identity.entry.isLive
            || identity.entry.key.hasPrefix("mf-event|")
        self.resumeMs = resumeMs
        self.resolveLadder = resolveLadder
        self.hopIdentity = hopIdentity
        self.fallbackCandidates = fallbackCandidates
    }

    deinit {
        // The Up Next countdown must never outlive its
        // session (its factory would swap a director into
        // a player that no longer exists).
        upNextTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        armResolutionDeadline()
        resolutionTask = Task { await loadLadder() }
    }

    /// Arm (or re-arm) the 60 s Play deadline. When it fires
    /// with the phase still .resolving, the stored resolution
    /// task is cancelled and the session lands on the
    /// exhausted slate with a timeout note — a resolution
    /// chain that outlives its budget is a dead slate with a
    /// reason, never an endless spinner. Firing in any other
    /// phase is a no-op (playback started, or the slate is
    /// already up), and the torrent rung cancels the watchdog
    /// outright when it starts.
    private func armResolutionDeadline() {
        // Coordinator ruling (v2.0.8 close-out, protecting
        // the torrent-tab baseline): the deadline governs
        // the Phim play chain — the sessions that carry a
        // hop/fallback structure. A torrent-tab session has
        // neither closure and its resolveLadder IS the
        // debrid resolve, so no watchdog is armed for it
        // and its behaviour stays exactly the pre-v2.0.8
        // one (the debrid resolve is never cancelled).
        guard hopIdentity != nil || fallbackCandidates != nil else { return }
        deadlineTask?.cancel()
        deadlineTask = Task {
            try? await Task.sleep(
                nanoseconds: UInt64(Self.resolutionDeadline * 1_000_000_000))
            guard !Task.isCancelled, phase == .resolving else { return }
            resolutionTask?.cancel()
            lastFailure = "Quá 60 giây chưa tìm được nguồn phát"
            phase = .exhausted
        }
    }

    private func markLadderReadyIfFirst() {
        guard !ladderReadyMarked else { return }
        ladderReadyMarked = true
        PerfLog.mark("play.ladderReady")
    }

    private func loadLadder() async {
        phase = .resolving
        // v2.0.33 (item 8): stamp the ladder-resolution
        // start, then — once resolveLadder returns — write
        // the resolution time and one line per candidate
        // (index / engine / host only / label truncated to
        // 60 chars) to the DiagLog "play" category. Hosts
        // only, never a full URL: Torrentio URLs carry the
        // owner's debrid token in the path.
        ladderStartedAt = Date()
        let ladder = await resolveLadder(identity)
        let ladderMs = Int(Date().timeIntervalSince(ladderStartedAt) * 1000)
        DiagLog.write("play", "ladder resolved count=\(ladder.count) in \(ladderMs)ms")
        for (index, candidate) in ladder.enumerated() {
            let engineName = candidate.engine == .ffmpeg ? "ffmpeg" : "avplayer"
            let host = candidate.url.host ?? "?"
            let label = String(candidate.label.prefix(60))
            DiagLog.write("play", "candidate \(index) engine=\(engineName) host=\(host) label=\(label)")
        }
        // A deadline-cancelled chain must not resurrect the
        // session over the exhausted slate the watchdog set.
        if Task.isCancelled { return }
        if ladder.isEmpty {
            await failoverStep()
            return
        }
        markLadderReadyIfFirst()
        // v2.0.35 (AUDIT-2034-PROVIDER-RETRY (a)): an
        // automatic commit never re-serves a candidate
        // this session already watched fail without
        // readying — but never at the price of an empty
        // ladder: if the failure memory would empty it,
        // the unfiltered ladder stands (today's behaviour
        // as the last resort; the failure simply recurs
        // and re-records). At session start the memory is
        // empty and this is a no-op; on the failover
        // refresh rung (the no-hop path reaches this same
        // function) it is what stops the re-served dead
        // host.
        let filteredLadder = filteringNeverReadyFailures(ladder)
        candidates = filteredLadder.isEmpty ? ladder : filteredLadder
        candidateIndex = 0
        beginCandidate()
    }

    private func beginCandidate() {
        // v2.0.34: a new attempt supersedes the old one —
        // its candidate deadline (if armed) stands down
        // here, whichever path led in (ladder, failover,
        // manual switch).
        candidateDeadlineTask?.cancel()
        candidateDeadlineTask = nil
        guard candidates.indices.contains(candidateIndex) else {
            resolutionTask = Task { await failoverStep() }
            return
        }
        let c = candidates[candidateIndex]
        candidate = c
        currentLabel = c.label
        attemptID += 1
        // v2.0.33 (item 8): a new attempt starts here —
        // stamp its clock (itemFailed reads it back for
        // the elapsed time) and log the attempt line
        // (position in the ladder / engine / host only)
        // to the DiagLog "play" category.
        attemptStartedAt = Date()
        let attemptEngine = c.engine == .ffmpeg ? "ffmpeg" : "avplayer"
        let attemptHost = c.url.host ?? "?"
        DiagLog.write("play", "attempt \(candidateIndex + 1)/\(candidates.count) engine=\(attemptEngine) host=\(attemptHost)")
        // v2.0.15: every NEW candidate re-arms the resume seek
        // — itemReady applies it once per candidate, against
        // the session's furthest position (see itemReady).
        seekApplied = false
        // v2.0.34: the same per-attempt re-arm for the
        // candidate deadline — not readied yet, and the
        // manual-pick marker is consumed from the switch
        // that (maybe) led here.
        attemptReadied = false
        attemptManualPick = nextAttemptManualPick
        nextAttemptManualPick = false
        phase = .playing
        armCandidateDeadline()
    }

    /// v2.0.34 (item 8 tightening): the ladder-level
    /// first-frame deadline for KSPlayer-path candidates.
    ///
    /// Why this exists: the KS host already carries a
    /// first-frame watchdog of its own (30 s, armed in
    /// JoeKSPlayerView.start, disarmed at readyToPlay) —
    /// but 30 s is far too loose for a ladder: in the
    /// owner's 2.0.33 device log a dead TorBox CDN
    /// candidate burned 11,706 ms before the engine's own
    /// error failed it over, and a candidate that never
    /// errors at all would ride the host's full 30 s. The
    /// AVPlayer path bounds its items at 20 s (the
    /// Coordinator's U-1 watchdog); the ladder now bounds
    /// a KS candidate at ksFirstFrameDeadline (8 s) the
    /// same way — abandon it and advance — but ONLY where
    /// advancing costs nothing:
    ///   • the candidate's engine is .ffmpeg (the KSPlayer
    ///     path; AVPlayer candidates keep their own U-1);
    ///   • a NEXT candidate exists in the current ladder —
    ///     on the last candidate nothing changes: the
    ///     engine's own error, the host's 30 s watchdog
    ///     and the failover rungs proceed exactly as
    ///     before;
    ///   • the attempt is not the owner's explicit
    ///     chooser pick (attemptManualPick) — a manual
    ///     pick is never cut by an automatic mechanism.
    /// A LIVE session (sessionIsLive) arms under the
    /// same conditions at its own budget,
    /// ksLiveFirstFrameDeadline (12 s) — v2.0.35. The
    /// 2.0.34 exemption (live never armed; the KS host's
    /// 30 s watchdog alone) stood on an absence: the 8 s
    /// budget is justified entirely on film-VOD timings
    /// (warmed ~100 ms, worst healthy cold start
    /// ~4.4 s), and no healthy live first-frame time had
    /// ever been measured, so no ladder budget could be
    /// justified on the sports path. The owner's 2.0.34
    /// device log (DIAG-2034 (f)) is that measurement:
    /// live FFmpeg candidates produced no picture in
    /// 30 s (twice, the watchdog's full ride) while the
    /// AVPlayer twin of the same stream readied in
    /// 4.53 s — the exemption's cost was 30 s of black
    /// screen in front of a 4.5 s rescue. Live now arms
    /// at 12 s (~2.6× the measured healthy start); the
    /// host's 30 s watchdog remains as the backstop
    /// behind the ladder cut.
    /// Firing routes through itemFailed(cause:) — handing
    /// in the armedAttemptID validated just above, so the
    /// director's attempt guard passes it — so the
    /// advance, the failover rungs and the exported log
    /// lines are the standing ones; the dedicated
    /// "ks deadline fired" line below is written first so
    /// the next device export shows the deadline — with
    /// the candidate's ladder position, host and elapsed
    /// time — as the cause of that attempt's end. The
    /// ready signal is the shared itemReady core, the
    /// same "readied" notion U-1 uses: a candidate that
    /// has readied and is merely filling its buffer is
    /// never cut (the host's freeze watchdog guards that
    /// phase instead).
    private func armCandidateDeadline() {
        guard let current = candidate, current.engine == .ffmpeg,
              candidateIndex + 1 < candidates.count,
              !attemptManualPick else { return }
        // v2.0.35: a live candidate arms at the LIVE
        // budget instead of being skipped (the 2.0.34
        // exemption — REVIEW-2034-LOOP3 R-1 — stood only
        // until a healthy live start was measured; see
        // the doc comment above and
        // ksLiveFirstFrameDeadline). Every other arming
        // condition is the guard above, unchanged: ffmpeg
        // engine, a next candidate exists, not a manual
        // pick. The arming is logged with its budget so
        // the next sports device export shows the live
        // deadline in force, replacing the 2.0.34
        // "ks deadline skipped live" line.
        let armedBudget = sessionIsLive
            ? Self.ksLiveFirstFrameDeadline
            : Self.ksFirstFrameDeadline
        if sessionIsLive {
            DiagLog.write("play", "ks deadline armed live \(Int(armedBudget * 1000))ms candidate \(candidateIndex + 1)/\(candidates.count) host=\(current.url.host ?? "?")")
        }
        let armedAttemptID = attemptID
        let armedIndex = candidateIndex
        let armedCount = candidates.count
        let armedHost = current.url.host ?? "?"
        candidateDeadlineTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(armedBudget * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Fire only against the very attempt that armed
            // it, still un-readied and still on screen:
            // every transition to another attempt cancels
            // this task first, so a mismatch here means the
            // session moved on without us.
            guard phase == .playing, attemptID == armedAttemptID,
                  !attemptReadied else { return }
            let elapsedMs = Int(Date().timeIntervalSince(attemptStartedAt) * 1000)
            DiagLog.write("play", "ks deadline fired candidate \(armedIndex + 1)/\(armedCount) host=\(armedHost) after=\(elapsedMs)ms budget=\(Int(armedBudget * 1000))ms")
            itemFailed(cause: "Nguồn không phát sau \(Int(armedBudget)) giây",
                       reportingAttemptID: armedAttemptID)
        }
    }

    /// v2.0.35 (AUDIT-2034-SWITCHRESUME): snapshot the
    /// outgoing host's LIVE playhead at an in-session
    /// switch entry — the picker pick (userSwitchSource
    /// (to:)), the blind advance (userSwitchSource()) and
    /// the automatic failover (itemFailed) all funnel
    /// through here BEFORE the ladder moves, so the value
    /// is the position on screen at the switch moment,
    /// read synchronously by the host from its own engine
    /// (the KS layer's currentPlaybackTime / the AVPlayer
    /// coordinator's currentTime()) and handed in as
    /// `playheadMs`. The failover rungs beyond the entry
    /// (refresh / hop / substitution) reuse this same
    /// machinery — they run inside the director and reach
    /// beginCandidate/itemReady with the snapshot (and
    /// furthestPosMs) already held, so no rung needs a
    /// capture of its own. A live session never snapshots:
    /// position is meaningless there (see the itemReady
    /// live gate). A nil or non-positive playhead (nothing
    /// playing yet, a candidate that died before its first
    /// frame) leaves any earlier snapshot standing — there
    /// is nothing truer to replace it with. So does a
    /// positive playhead at or below the seek window's
    /// 20 s floor (itemReady: targetMs > 20_000): it
    /// carries no seekable information, so it is ignored
    /// entirely — never stored, never re-baselined from —
    /// and only logged (marked ignored=subwindow); see
    /// the gate in the body (REVIEW-2035B-LOOP2 E-1).
    /// Only an accepted (window-passing) capture is
    /// stored. The one DiagLog line per capture (kind +
    /// position + the candidate on screen; no URL) is
    /// what the next device export proves the carry from,
    /// together with itemReady's standing "Tiếp tục từ …"
    /// notice.
    /// An accepted user-initiated capture (kind "pick" /
    /// "advance") also RE-BASELINES furthestPosMs to the
    /// captured playhead — the only place the furthest
    /// may decrease (see the rewind note in the body). A
    /// failover capture never re-baselines.
    private func captureSwitchSnapshot(kind: String, playheadMs: Int64?) {
        guard !sessionIsLive else { return }
        guard let playheadMs, playheadMs > 0 else { return }
        // v2.0.35 (REVIEW-2035B-LOOP2 E-1): a capture at
        // or below the seek window's 20 s floor — the
        // SAME literal itemReady's window applies
        // (targetMs > 20_000) — carries NO seekable
        // information: its target would be window-blocked
        // in every trace ("≤20 s is the beginning" is
        // the standing rule), so it must not destroy
        // seekable state. It is IGNORED entirely: never
        // stored into switchSnapshotMs, never
        // re-baselined from. The dangerous read is a
        // fresh layer's small POSITIVE clock report
        // (≈300 ms of first frames / preroll, before a
        // resume seek is reflected in the new layer's
        // clock) when the owner picks again during a
        // candidate's loading window, or a just-readied
        // candidate dying in its first instants: honoured,
        // it overwrote the snapshot a failover had just
        // taken (and, via itemReady's snapshot
        // precedence, blocked the furthest fallback) and
        // dragged the furthest down to itself
        // irreversibly — the next source restarted at
        // 0:00 and every later snapshot-less advance in
        // the session fell back to the tiny value. A
        // genuine sub-20 s position loses nothing by
        // being ignored: unseekable under the standing
        // rule whether the capture is honoured or not,
        // and playback restarts within seconds of the
        // truth. The capture is still logged — marked
        // ignored=subwindow — so a device export shows
        // it was seen and deliberately not held.
        guard playheadMs > 20_000 else {
            DiagLog.write("play", "switch snapshot kind=\(kind) pos=\(playheadMs)ms candidate=\(candidateIndex + 1)/\(candidates.count) ignored=subwindow")
            return
        }
        switchSnapshotMs = playheadMs
        // v2.0.35 (rewind fix, REVIEW-2035-LOOP2 E-1 /
        // LOOP3 R-1): an ACCEPTED user-initiated capture
        // (picker pick / blind advance — a sub-window
        // capture already returned at the gate above) is
        // read live from a healthy host at the owner's
        // own hand — the freshest possible statement of
        // where the owner IS — so it also RE-BASELINES
        // the furthest to the captured playhead. This is
        // the ONLY place furthestPosMs may decrease: after a deliberate
        // rewind (30:00 → 10:00 to rewatch a scene) the
        // tick-fed furthest still reads 30:00, and left
        // standing it outranked the snapshot in
        // itemReady's target and jumped the new source
        // FORWARD past the passage the owner rewound to
        // see. A failover capture does NOT re-baseline:
        // the host is dying, its read can be the
        // watchdog's ≤1 s-stale fallback, and the
        // furthest must stay the safety net for the
        // snapshot-less advances behind it (the
        // deadline's nil-playhead firing). The log line
        // notes the re-baseline when the value moves.
        var rebaseNote = ""
        if kind == "pick" || kind == "advance" {
            if furthestPosMs != playheadMs {
                rebaseNote = " rebase=\(furthestPosMs)ms->\(playheadMs)ms"
            }
            furthestPosMs = playheadMs
        }
        DiagLog.write("play", "switch snapshot kind=\(kind) pos=\(playheadMs)ms candidate=\(candidateIndex + 1)/\(candidates.count)\(rebaseNote)")
    }

    /// The current item failed (status .failed or failed-to-end).
    /// `cause` is the failing engine's own error description
    /// (or a watchdog label): it is remembered for the
    /// exhausted slate and logged with the candidate's engine
    /// and HOST ONLY — never the full URL (Torrentio URLs
    /// carry the owner's RD token in the path).
    ///
    /// v2.0.35 (REVIEW-2035C-LOOP3 E-1): ATTEMPT-SCOPED,
    /// exactly as the itemReady core (REVIEW-2035B-LOOP3
    /// E-1). A superseded attempt's host can still deliver
    /// a late failure after the ladder has advanced — its
    /// terminal error was already in flight through the
    /// funnel's Task hops when the owner, BECAUSE the
    /// stream died, picked the next source — and the phase
    /// gate below cannot tell it apart from the current
    /// attempt's own failure: the phase is .playing for the
    /// NEW attempt throughout the advance. Pre-fix the
    /// stale report ran this whole body against the
    /// innocent new attempt: it ended and skipped it
    /// untried (overriding even a manual pick), the
    /// failure-memory record below read the NEW attempt's
    /// ready flag and candidate and recorded them as
    /// never-ready for the rest of the session, and the
    /// failover snapshot capture overwrote the pick
    /// snapshot. Each funnel now hands in the attemptID it
    /// was created under (the AV coordinator's observe()
    /// capture, the KS host's start() capture; the
    /// candidate deadline's internal firing passes its
    /// already-validated armedAttemptID), and a failure
    /// that does not name the current attempt is ignored
    /// WHOLE — before the snapshot capture, before the
    /// record, before any advance — and logged in the
    /// stale-ready line's shape. The phase gate stays as
    /// an additional condition below.
    func itemFailed(cause: String? = nil, playheadMs: Int64? = nil,
                    reportingAttemptID: Int) {
        guard reportingAttemptID == attemptID else {
            DiagLog.write("play", "itemFailed ignored stale failure attempt=\(reportingAttemptID) current=\(attemptID)")
            return
        }
        guard phase == .playing else { return }
        // v2.0.35: the failing host hands its last live
        // playhead in with the failure (its fireFail funnel
        // read it synchronously, before teardown) — snapshot
        // it before the ladder advances, so the next
        // candidate resumes where this one died (see
        // captureSwitchSnapshot). The candidate deadline's
        // own firing passes no playhead: that candidate
        // never readied, so there is nothing to carry
        // beyond furthestPosMs.
        captureSwitchSnapshot(kind: "failover", playheadMs: playheadMs)
        // v2.0.34: the attempt is over — its candidate
        // deadline stands down NOW, before the ladder
        // advances or the failover step runs, so it can
        // never fire against the resolution that follows.
        candidateDeadlineTask?.cancel()
        candidateDeadlineTask = nil
        // v2.0.35 (AUDIT-2034-PROVIDER-RETRY (a)): if the
        // failed attempt NEVER readied, record it in the
        // session failure memory (see
        // neverReadyFailedKeys) so no automatic ladder
        // commit can re-serve it. Ordering: the snapshot
        // capture above ran first and is untouched — it
        // reads the playhead hand-in; this reads the
        // ready flag and the failing candidate; neither
        // writes the other's state. attemptReadied still
        // holds the FAILED attempt's value here —
        // beginCandidate resets it for the next attempt
        // only when the ladder advances below — and
        // `candidate` still names the failed candidate
        // (candidateIndex increments at the foot). A
        // failure AFTER ready (a mid-play freeze, an
        // engine error) is NOT recorded: the memory is
        // for never-ready candidates only.
        if failureMemoryArmed, !attemptReadied,
           let failedCandidate = candidate {
            neverReadyFailedKeys.insert(
                failedCandidate.url.absoluteString)
            if let host = failedCandidate.url.host,
               !Self.isLoopbackHost(host) {
                neverReadyFailedKeys.insert(host)
                DiagLog.write("play", "failure memory recorded host=\(host)")
            }
        }
        if let cause, !cause.isEmpty {
            lastFailure = String(cause.prefix(80))
        }
        let engineName = candidate?.engine == .ffmpeg ? "ffmpeg" : "avplayer"
        let host = candidate?.url.host ?? "?"
        PlaybackLog.logger.error(
            "candidate failed engine=\(engineName, privacy: .public) host=\(host, privacy: .public) cause=\(cause ?? "—", privacy: .public)")
        // v2.0.33 (item 8): the same failure in the
        // persistent DiagLog file (category "play"), with
        // the attempt's elapsed time measured from the
        // beginCandidate() stamp — the OSLog line above is
        // untouched and stays the in-log record; this line
        // is the one the owner can export after the run.
        let attemptElapsedMs = Int(Date().timeIntervalSince(attemptStartedAt) * 1000)
        DiagLog.write("play", "attempt failed engine=\(engineName) host=\(host) after=\(attemptElapsedMs)ms cause=\(cause ?? "—")")
        candidateIndex += 1
        if candidateIndex < candidates.count {
            beginCandidate()
        } else {
            resolutionTask = Task { await failoverStep() }
        }
    }

    /// Failover: hedged refresh+hop → substitution rung once →
    /// exhausted, all inside the one Play deadline (see the
    /// stored-task/deadline note at the properties).
    ///
    /// v2.0.8 (Phase 3) design — read before touching:
    /// • The first two rungs used to run strictly one after
    ///   the other (refresh the whole chain, THEN one
    ///   cross-provider hop), so a dead incumbent taxed the
    ///   tap twice in series. They are now a HEDGED PAIR: on
    ///   the first exhaustion, the refresh (resolveLadder for
    ///   the current identity) and the hop (hopIdentity →
    ///   resolveLadder under the new identity) run
    ///   CONCURRENTLY, and the first NON-EMPTY candidate list
    ///   wins — a refresh win leaves the identity unchanged, a
    ///   hop win adopts the new identity and shows the
    ///   existing "Đổi nguồn: …" notice; the loser is
    ///   cancelled. Neither branch touches session state
    ///   while racing (both publish into the HedgeBox); the
    ///   winner is committed here, once.
    /// • After the hedge resolves either way, BOTH `refreshed`
    ///   and `hopped` count as consumed — a later exhaustion
    ///   goes to the torrent rung, never back into the hedge.
    /// • Sessions with no hop (the torrent section builds its
    ///   director with hopIdentity nil) degrade to the classic
    ///   refresh-only rung, byte-identical to the pre-hedge
    ///   behaviour.
    /// • The torrent substitution rung is NEVER hedged and
    ///   keeps its exact position and behaviour; the deadline
    ///   watchdog stands down the moment it starts, so the
    ///   debrid resolve is never cancelled mid-flight.
    private func failoverStep() async {
        if Task.isCancelled { return }
        guard let hopIdentity else {
            // No hop exists for this session: refresh once,
            // then the substitution rung / exhausted, exactly
            // as before the hedge.
            if !refreshed {
                refreshed = true
                notice = "Đang tải lại nguồn…"
                await loadLadder()
                return
            }
            await torrentRungOrExhausted()
            return
        }
        if !refreshed || !hopped {
            let doRefresh = !refreshed
            let doHop = !hopped
            refreshed = true
            hopped = true
            phase = .resolving
            notice = "Đang tải lại nguồn…"
            let origin = identity
            let box = HedgeBox()
            var refreshTask: Task<Void, Never>?
            var hopTask: Task<Void, Never>?
            if doRefresh {
                refreshTask = Task {
                    let ladder = await resolveLadder(origin)
                    box.refreshLadder = ladder
                    box.refreshDone = true
                }
            } else {
                box.refreshLadder = []
                box.refreshDone = true
            }
            if doHop {
                hopTask = Task {
                    if let next = await hopIdentity(origin) {
                        let ladder = await resolveLadder(next)
                        box.hopIdentity = next
                        box.hopLadder = ladder
                    }
                    box.hopDone = true
                }
            } else {
                box.hopDone = true
            }
            // Poll for the first non-empty ladder (the house
            // race pattern — cf. the KK host race and the
            // alternatives search box). Refresh is checked
            // first within a tick: on a simultaneous landing
            // the incumbent wins and the identity stays put.
            // v2.0.35 (AUDIT-2034-PROVIDER-RETRY (a)): each
            // branch's ladder is passed through the session
            // failure memory the first time it lands — the
            // filtered result is cached here, so the drops
            // are logged once, not on every 50 ms poll —
            // and the win test reads the FILTERED ladder: a
            // branch whose ladder filters to empty does NOT
            // win. That is the incident's exact shape: the
            // ~52 ms refresh re-served the just-died Film4K
            // host and beat the hop, which never got its
            // race; filtered, the refresh cannot win and
            // the hop runs in full. The commit below adopts
            // the same filtered ladder the test accepted.
            var winner: (identity: PlayIdentity,
                         ladder: [PlayCandidate], isHop: Bool)?
            var refreshFiltered: [PlayCandidate]?
            var hopFiltered: [PlayCandidate]?
            while winner == nil {
                if refreshFiltered == nil, let raw = box.refreshLadder {
                    refreshFiltered = filteringNeverReadyFailures(raw)
                }
                if let ladder = refreshFiltered, !ladder.isEmpty {
                    winner = (origin, ladder, false)
                    break
                }
                if hopFiltered == nil, let raw = box.hopLadder {
                    hopFiltered = filteringNeverReadyFailures(raw)
                }
                if let ladder = hopFiltered, !ladder.isEmpty,
                   let next = box.hopIdentity {
                    winner = (next, ladder, true)
                    break
                }
                if box.refreshDone && box.hopDone { break }
                if Task.isCancelled {
                    refreshTask?.cancel()
                    hopTask?.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            refreshTask?.cancel()
            hopTask?.cancel()
            if Task.isCancelled { return }
            // The never-empty last resort (AUDIT-2034 (a)):
            // BOTH branches produced ladders and BOTH
            // filtered to empty — the hop landed on a
            // front for an already-failed host too — so
            // commit the unfiltered refresh ladder rather
            // than strand the session: exactly today's
            // behaviour, with the failures simply recurring
            // and re-recording. (When a branch produced
            // NOTHING — the incident's empty hop — there is
            // no last resort: control falls to the torrent
            // rung below, at ~20 s instead of 40.2 s.)
            if winner == nil,
               let refreshRaw = box.refreshLadder, !refreshRaw.isEmpty,
               let hopRaw = box.hopLadder, !hopRaw.isEmpty {
                DiagLog.write("play", "failure memory last resort — committing unfiltered refresh ladder")
                winner = (origin, refreshRaw, false)
            }
            if let winner {
                if winner.isHop {
                    identity = winner.identity
                    notice = "Đổi nguồn: \(Providers.displayName(winner.identity.entry.source))"
                }
                markLadderReadyIfFirst()
                candidates = winner.ladder
                candidateIndex = 0
                beginCandidate()
                return
            }
            // Both branches produced nothing: fall through to
            // the torrent rung, as the serial ladder did after
            // its hop came back empty.
        }
        await torrentRungOrExhausted()
    }

    /// The substitution rung (owner law, v1.9) and the
    /// exhausted end state, shared by the hedged path and the
    /// no-hop path. Reached from every exhaustion path (an
    /// empty ladder, a failed item, the stall watchdog
    /// advancing past the last candidate). The rung's own
    /// behaviour is byte-identical to the pre-v2.0.8 inline
    /// version; the one addition is the deadline stand-down
    /// at its head.
    private func torrentRungOrExhausted() async {
        if !fallbackTried, let fallbackCandidates {
            fallbackTried = true
            // The deadline watchdog stands down NOW: the
            // debrid resolve inside the rung is never
            // cancelled mid-flight, hedged, or retried.
            deadlineTask?.cancel()
            notice = "Đang tìm nguồn thay thế…"
            let extra = await fallbackCandidates(identity)
            if !extra.isEmpty {
                notice = "Nguồn thay thế: Torrent"
                candidates = extra
                candidateIndex = 0
                beginCandidate()
                return
            }
        }
        // v2.0.33 (item 8): the session's terminal line in
        // the DiagLog "play" category. This assignment is
        // the failover machinery's central exhausted site —
        // the hedged path and the no-hop path both end
        // here, and an empty initial ladder reaches it via
        // failoverStep — so the one line here closes every
        // failover-driven session in the exported file,
        // carrying the last recorded failure cause.
        DiagLog.write("play", "session exhausted lastFailure=\(lastFailure ?? "—")")
        phase = .exhausted
    }

    /// Manual retry from the exhausted slate (§8): reset the
    /// failover bookkeeping and run the whole ladder again —
    /// sources that were down may have recovered, and the owner
    /// must never be stranded on a dead slate with only Menu.
    /// v2.0.8: the retry also re-arms the Play deadline and
    /// re-stores the resolution task, like start().
    func retryFromExhausted() {
        guard phase == .exhausted else { return }
        refreshed = false
        hopped = false
        fallbackTried = false
        // v2.0.35 (AUDIT-2034-PROVIDER-RETRY (a)): the
        // manual retry also clears the never-ready failure
        // memory — a deliberate fresh start, exactly as
        // the rung flags above reset: a host that was down
        // may have recovered, and the owner's explicit
        // retry must be able to reach it again.
        neverReadyFailedKeys.removeAll()
        seekApplied = false
        lastFailure = nil
        notice = "Đang thử lại…"
        armResolutionDeadline()
        resolutionTask = Task { await loadLadder() }
    }

    /// Item is ready: apply the resume seek once per candidate
    /// (the view's
    /// coordinator performs it and reports back the position it
    /// landed on — here we just record that it happened and show
    /// the Android toast text). The coordinator hands in the
    /// attemptID it was created under (reportingAttemptID) —
    /// the core is attempt-scoped (REVIEW-2035B-LOOP3 E-1;
    /// see the core below).
    func itemReady(player: AVPlayer, reportingAttemptID: Int) {
        let durSec = player.currentItem?.duration.seconds ?? 0
        let durMs = durSec.isFinite ? Int64(durSec * 1000) : 0
        itemReady(durationMs: durMs,
                  reportingAttemptID: reportingAttemptID) { ms in
            // v2.0.35 (seek logging, DIAG-2034 (g)): every
            // app-executed seek leaves one line — engine,
            // from-position, to-position, in seconds — so
            // the next export can place a seek immediately
            // before any freeze/fail line that follows it
            // (the owner's "tua nhanh là đứt" report is
            // unprovable from a log with no seek lines).
            // Positions only, never a URL. This closure is
            // the AVPlayer path's ONLY app seek call site:
            // the system transport bar performs the owner's
            // own scrubs inside AVKit, past no app code.
            let fromSec = player.currentTime().seconds
            DiagLog.write("play", "seek engine=avplayer from=\(Self.seekLogSeconds(fromSec)) to=\(Self.seekLogSeconds(TimeInterval(ms) / 1000))")
            player.seek(to: CMTime(milliseconds: ms),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// v2.0.35 (seek logging): one-decimal seconds for the
    /// seek log lines; a non-finite read (an item with no
    /// clock yet) logs as 0.0 rather than "nan".
    private static func seekLogSeconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value.isFinite ? value : 0)
    }

    /// The same resume rule for the FFmpeg engine (v2.0.3): the
    /// KSPlayer coordinator supplies the duration it measured
    /// and performs the seek itself. One rule, two engines —
    /// the >20 s / last-30 s window is identical.
    func itemReady(durationMs: Int64, reportingAttemptID: Int,
                   seek: (Int64) -> Void) {
        // v2.0.35 (REVIEW-2035B-LOOP3 E-1): the core is
        // ATTEMPT-SCOPED. A superseded attempt's host can
        // still deliver a late ready after the ladder has
        // advanced: a slow-but-viable candidate cut by a
        // deadline (the 8 s ladder deadline, the 20 s U-1)
        // was cut for slowness, not death, so its ready is
        // imminent — and hosts are dismantled in a LATER
        // SwiftUI pass than beginCandidate (the tree's own
        // FIX4 history: an old host's teardown can land
        // after its replacement is up). Pre-fix this
        // preamble ran for ANY caller: the stale ready set
        // attemptReadied, cancelled the NEW attempt's
        // candidate deadline, sought through the DYING
        // host's closure and consumed the switch snapshot,
        // so the real candidate's own ready then hit the
        // seekApplied gate below and played from 0:00 —
        // the owner's original symptom by a second road.
        // Each funnel now hands in the attemptID it was
        // created under (captured at host creation — the
        // hosts live under .id(attemptID)), and a ready
        // that does not name the current attempt is
        // ignored WHOLE: no ready flag, no deadline
        // stand-down, no first-frame mark, no seek, no
        // snapshot consumption. The ignored ready is
        // logged (attempt ids only, no URL/host) so the
        // next device export shows the guard holding. The
        // shape mirrors the fire validation
        // armCandidateDeadline already applies to its own
        // task (phase + attemptID + !attemptReadied).
        guard reportingAttemptID == attemptID else {
            DiagLog.write("play", "itemReady ignored stale ready attempt=\(reportingAttemptID) current=\(attemptID)")
            return
        }
        // v2.0.34: the live attempt has readied — the
        // candidate deadline (armCandidateDeadline) stands
        // down. Both engines funnel through this core
        // (itemReady(player:) delegates here), so neither
        // can skip the stand-down.
        attemptReadied = true
        candidateDeadlineTask?.cancel()
        // Phase 3 mark: the session's first ready item, once
        // per session, from this shared core so both engines
        // (AVPlayer above, KSPlayer via durationMs) report it.
        if !firstFrameMarked {
            firstFrameMarked = true
            PerfLog.mark("play.firstFrame")
        }
        // Up Next (v2.0.25): the playing-started hook fires
        // from this same shared core, exactly once per
        // session, on the first ready — both engines funnel
        // through here (itemReady(player:) delegates to this
        // method), so neither engine can fire it twice or
        // skip it.
        if !playingStartedNotified {
            playingStartedNotified = true
            onPlayingStarted?()
        }
        guard !seekApplied else { return }
        seekApplied = true
        // The Android rule, checked with the real duration in
        // hand: seek only when the stored position is past 20 s
        // AND outside the last 30 s (a finished title restarts).
        // v2.0.15 (Sony 2.3.17 port): the target is the
        // FURTHEST position this session has reached — the
        // stored resume point for the first candidate, the
        // live playhead (lastPosMs, kept current by tick())
        // once playback has moved past it. Pre-fix the target
        // was the fixed session-start resumeMs and the seek
        // was never re-armed for a new candidate, so a mid-play
        // failure advanced the ladder into a restart at 0:00 —
        // the exact fault behind the owner's Sony verdict
        // ("kéo luôn 1 phát đứt luôn", the film restarts).
        // v2.0.35 (AUDIT-2034-SWITCHRESUME): the v2.0.15
        // rule above is now implemented as written.
        // furthestPosMs is the TRUE monotonic furthest
        // (pre-fix this formula read lastPosMs — the
        // LATEST report — and the incoming KS host's first
        // ~0 currentTime report landed before itemReady
        // and collapsed it, so an in-player source switch
        // restarted the film at 0:00 even though the
        // machinery all existed), and switchSnapshotMs is
        // the live playhead the outgoing host captured at
        // the switch moment itself
        // (captureSwitchSnapshot). PRECEDENCE (rewind fix,
        // REVIEW-2035-LOOP2 E-1; snapshot-exact,
        // REVIEW-2035B-LOOP3 R-1): a held snapshot IS the
        // target — exactly, not maxed with anything. The
        // snapshot is the live playhead at the switch
        // moment itself, the freshest truth the session
        // has; only a snapshot-less advance (the candidate
        // deadline's nil-playhead firing) falls back to
        // max(resumeMs, furthestPosMs), the anti-clobber
        // safety net. A single max() of all three let the
        // tick-fed furthest — which cannot know the owner
        // scrubbed — outrank the exact capture after a
        // DELIBERATE REWIND (30:00 → 10:00 to rewatch a
        // scene), jumping the new source FORWARD past the
        // passage the owner rewound to see; and a rewind
        // out of the final 30 s left that furthest inside
        // the seek window's last-30-s exclusion, so no
        // seek fired at all and the new source restarted
        // at 0:00 — the owner's original symptom via that
        // one sequence. Keeping resumeMs inside the max
        // repeated the same override one floor down: open
        // from Continue Watching at 30:00 (resumeMs =
        // 30:00), rewind to 10:00, pick — max(resumeMs,
        // snapshot) landed back at 30:00, dragging the
        // owner past the passage they rewound to see.
        // resumeMs is the SESSION-START floor; it has no
        // claim against a position the owner is verifiably
        // at NOW. The snapshot is then CONSUMED (cleared
        // below) so it serves exactly this one advance. The seek still
        // happens HERE only — once per candidate under the
        // seekApplied gate above, through the host's own
        // closure — so the open path's resume (resumeMs on
        // the first candidate) cannot double-seek with a
        // switch: the fix changed the VALUE fed to this one
        // seek, never the number of seeks. A LIVE session
        // never seeks: position is meaningless at the live
        // edge, and pre-fix a large accumulated lastPosMs
        // could in theory have sought a live candidate
        // whose duration read 0 — the gate closes that too.
        if !sessionIsLive {
            let targetMs = switchSnapshotMs > 0
                ? switchSnapshotMs
                : max(resumeMs, furthestPosMs)
            if targetMs > 20_000 && (durationMs <= 0 || targetMs < durationMs - 30_000) {
                seek(targetMs)
                notice = "Tiếp tục từ \(WatchStore.fmtClock(targetMs))"
            }
            // Consume the snapshot: it has now fed the
            // one target it was captured for, whether the
            // window let the seek fire or blocked it, so a
            // later, unrelated advance can never reuse a
            // stale one. The failover rungs that run
            // BEFORE any candidate readies (refresh / hop
            // / substitution inside failoverStep) never
            // pass through this core, and this consuming
            // path is reached only by the CURRENT
            // attempt's ready — the attempt guard at the
            // core's head turns a superseded host's late
            // ready away before it can touch any of this
            // (REVIEW-2035B-LOOP3 E-1) — so an in-flight
            // advance keeps its snapshot until its first
            // candidate actually readies; and a
            // candidate that readies and later dies gets a
            // FRESH capture at its fireFail (its live
            // playhead, kind "failover"), never this
            // consumed one back.
            switchSnapshotMs = 0
        }
    }

    /// Periodic tick from the player (~every 5 s): the Android
    /// save rule — under 10 s records nothing; inside the last
    /// 30 s the entry is dropped (finished); otherwise save.
    func tick(positionMs: Int64, durationMs: Int64) {
        lastPosMs = positionMs
        // v2.0.35: tick() only ever RAISES the furthest —
        // an incoming candidate's early ~0 reports after
        // a switch lower lastPosMs (its CW save role
        // below tolerates that) but must never lower the
        // resume carry. The one decrease lives in
        // captureSwitchSnapshot's re-baseline on a
        // user-initiated capture (see furthestPosMs at
        // its declaration).
        furthestPosMs = max(furthestPosMs, positionMs)
        lastDurMs = durationMs
        // FIX4 (fix 6): the Up Next trigger moves from the
        // END of the item to its last 10 seconds (owner
        // finding on 2.0.27: the card appeared only once the
        // episode had already ended). tick() runs ≈ every
        // 5 s on both engines, so the first tick inside the
        // window opens the card with the countdown started
        // at the seconds ACTUALLY remaining (rounded up, so
        // the factory fires at — never before — the item's
        // end). Runs before the save rule below on purpose:
        // the last-30 s branch returns early.
        if nextEpisodeFactory != nil, !upNextArmed, durationMs > 0 {
            let remainingMs = durationMs - positionMs
            if remainingMs > 0, remainingMs <= 10_000 {
                upNextArmed = true
                startUpNextCountdown(
                    initialSeconds: Int((remainingMs + 999) / 1000))
            }
        }
        guard durationMs > 0, positionMs > 10_000 else { return }
        if positionMs >= durationMs - 30_000 {
            store.removeProgress(matching: identity.entry)
            return
        }
        var e = identity.entry
        e.pos = positionMs
        e.dur = durationMs
        e.ts = Int64(Date().timeIntervalSince1970 * 1000)
        store.saveProgress(e)
    }

    /// Playback reached the end cleanly: the title is finished —
    /// drop the progress entry (the Android STATE_ENDED rule).
    /// Up Next (v2.0.25): when the session carries a next-
    /// episode factory, the clean end ALSO starts the
    /// 10-second countdown; errors never reach here (they
    /// go through itemFailed), so the countdown only ever
    /// follows a genuine finish. With no factory set this
    /// is byte-for-byte the pre-Up-Next behaviour.
    ///
    /// v2.0.35 (REVIEW-2035C-LOOP3 E-1): ATTEMPT-SCOPED
    /// like itemFailed/itemReady — each funnel hands in
    /// the attemptID it was created under, and an ended
    /// report that does not name the current attempt is
    /// ignored (and logged) before it can strip the
    /// session's Continue Watching entry or arm the Up
    /// Next countdown over a replacement source's playback
    /// of the same episode.
    func itemEnded(reportingAttemptID: Int) {
        guard reportingAttemptID == attemptID else {
            DiagLog.write("play", "itemEnded ignored stale ended attempt=\(reportingAttemptID) current=\(attemptID)")
            return
        }
        store.removeProgress(matching: identity.entry)
        guard nextEpisodeFactory != nil else { return }
        // FIX4 (fix 6): fallback only — when the tick
        // trigger already armed the card, a countdown still
        // running (or one the user cancelled inside the
        // window) is left exactly as it stands.
        guard !upNextArmed else { return }
        upNextArmed = true
        startUpNextCountdown()
    }

    /// Start (or restart) the 10-second Up Next countdown:
    /// publishes 10 immediately, then one tick per second
    /// down to 1; at zero the factory runs (see
    /// runAdvanceFactory). Cancellable at every tick via
    /// cancelAdvance() / advanceNow() / deinit.
    private func startUpNextCountdown() {
        startUpNextCountdown(initialSeconds: 10)
    }

    /// FIX4 (fix 6): the countdown's starting value as a
    /// parameter — the tick trigger fires inside the
    /// last-10 s window, not at its edge, so the card opens
    /// showing the seconds actually left.
    private func startUpNextCountdown(initialSeconds: Int) {
        upNextGeneration += 1
        let generation = upNextGeneration
        upNextTask?.cancel()
        let start = max(1, min(10, initialSeconds))
        upNextSecondsLeft = start
        upNextTask = Task { [weak self] in
            guard let self else { return }
            var remaining = start
            while remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                guard generation == self.upNextGeneration else { return }
                remaining -= 1
                if remaining > 0 {
                    self.upNextSecondsLeft = remaining
                } else {
                    self.upNextSecondsLeft = nil
                    await self.runAdvanceFactory(generation: generation)
                    return
                }
            }
        }
    }

    /// Run the next-episode factory for `generation` and
    /// publish its director as advanceTarget. A nil result
    /// (or a generation superseded while the factory was
    /// in flight — a cancel, a manual advance) simply
    /// clears the countdown and publishes nothing, so a
    /// cancelled countdown can never fire late.
    private func runAdvanceFactory(generation: Int) async {
        guard generation == upNextGeneration,
              let factory = nextEpisodeFactory else { return }
        let next = await factory()
        guard generation == upNextGeneration, !Task.isCancelled else { return }
        upNextSecondsLeft = nil
        if let next {
            advanceTarget = next
        }
    }

    /// "Phát ngay": skip the rest of the countdown and run
    /// the factory immediately. A no-op when no countdown
    /// is active.
    func advanceNow() {
        guard upNextSecondsLeft != nil, nextEpisodeFactory != nil else { return }
        upNextGeneration += 1
        let generation = upNextGeneration
        upNextTask?.cancel()
        upNextSecondsLeft = nil
        upNextTask = Task { [weak self] in
            guard let self else { return }
            await self.runAdvanceFactory(generation: generation)
        }
    }

    /// Cancel the countdown: the finished item simply stays
    /// ended (the view's normal end behaviour resumes —
    /// Menu dismisses again once no countdown is active).
    /// Deliberately does NOT clear advanceTarget: a cancel
    /// that lands after the factory already published its
    /// director must not undo the handover.
    func cancelAdvance() {
        upNextGeneration += 1
        upNextTask?.cancel()
        upNextTask = nil
        upNextSecondsLeft = nil
    }

    // MARK: Player chrome actions (v2.0.27, Idea 13)
    //
    // The AVPlayer path's transport-bar menu (PlayerController
    // below) drives these three; the KSPlayer path has its own
    // settled chrome and never calls them. Each one reuses the
    // standing machinery — no forked ladder, no forked advance.

    /// "Đổi nguồn": a USER-initiated source switch while
    /// playing. Advances the ladder exactly like itemFailed
    /// (next candidate in the ladder, else the failover step
    /// with its refresh → hop → substitution rungs), but it
    /// is not a failure: lastFailure is left untouched and
    /// the log records a switch, not an error. When no rung
    /// remains the failover machinery lands on the exhausted
    /// slate, which is the correct end state. A no-op
    /// outside .playing.
    func userSwitchSource(playheadMs: Int64? = nil) {
        guard phase == .playing else { return }
        // v2.0.35: snapshot the live playhead handed in by
        // the calling host before the ladder advances (see
        // captureSwitchSnapshot). No chrome calls this
        // entry in the current build — the chooser replaced
        // the blind advance in v2.0.29 — but the entry keeps
        // the same carry contract as the pick.
        captureSwitchSnapshot(kind: "advance", playheadMs: playheadMs)
        // v2.0.34: the current attempt ends here — stand
        // its candidate deadline down before advancing
        // (the failover branch below does not pass through
        // beginCandidate's own stand-down first).
        candidateDeadlineTask?.cancel()
        candidateDeadlineTask = nil
        let host = candidate?.url.host ?? "?"
        PlaybackLog.logger.info(
            "user switch source host=\(host, privacy: .public)")
        candidateIndex += 1
        if candidateIndex < candidates.count {
            beginCandidate()
        } else {
            resolutionTask = Task { await failoverStep() }
        }
    }

    /// One row of the source chooser (v2.0.29, item 3): the
    /// session's CURRENT candidate ladder as the player
    /// chrome presents it — the index into the ladder, the
    /// candidate's own label (the text the status capsule
    /// shows for it), and whether it is the candidate on
    /// screen. An unlabelled candidate falls back to a
    /// numbered name, so a chooser row is never blank.
    struct SourceChoice {
        let index: Int
        let label: String
        let isCurrent: Bool
    }

    /// The chooser's rows, rebuilt from the live ladder on
    /// every read — a failover hop replaces the ladder, and
    /// the next menu/picker opening must show the NEW list
    /// with the NEW current candidate marked.
    var sourceChoices: [SourceChoice] {
        candidates.enumerated().map { pair in
            SourceChoice(
                index: pair.offset,
                label: pair.element.label.isEmpty
                    ? "Nguồn \(pair.offset + 1)" : pair.element.label,
                isCurrent: pair.offset == candidateIndex)
        }
    }

    /// "Đổi nguồn" to a CHOSEN candidate (v2.0.29, item 3):
    /// the owner picks from sourceChoices in the player
    /// chrome (the KS host's source picker; the AVPlayer
    /// transport-bar submenu) instead of the button blindly
    /// advancing to the next candidate — manual source
    /// selection is his standing rule. The switch itself is
    /// beginCandidate(), the same re-arm the failover ladder
    /// uses, so the standing itemReady resume rule carries
    /// the position onto the chosen candidate exactly as it
    /// does for userSwitchSource() and itemFailed.
    /// v2.0.35: the calling host hands its LIVE playhead in
    /// with the pick (playheadMs — read synchronously from
    /// its engine at the tap, before that host is torn
    /// down) and the pick snapshots it before the ladder
    /// moves (see captureSwitchSnapshot); the itemReady
    /// target also rides the session's true furthest
    /// position, so the carry no longer depends on the
    /// incoming host's first position reports. Picking the
    /// current candidate, an out-of-ladder index, or
    /// picking outside .playing is a no-op. Auto failover
    /// (itemFailed and its rungs) is untouched.
    func userSwitchSource(to index: Int, playheadMs: Int64? = nil) {
        guard phase == .playing,
              candidates.indices.contains(index),
              index != candidateIndex else { return }
        captureSwitchSnapshot(kind: "pick", playheadMs: playheadMs)
        let host = candidates[index].url.host ?? "?"
        PlaybackLog.logger.info(
            "user switch source (chosen) host=\(host, privacy: .public)")
        // v2.0.34: mark the attempt beginCandidate() is
        // about to begin as the owner's explicit pick —
        // the candidate deadline never cuts a manual pick
        // (see armCandidateDeadline).
        nextAttemptManualPick = true
        candidateIndex = index
        beginCandidate()
    }

    /// "Yêu thích": toggle this title's favourite in
    /// WatchStore. NOTE the key: identity.entry.key is the
    /// PROGRESS key ("kk|<slug>|<episode name>"), while
    /// favourites live under their own key (the detail
    /// screens' favKey — WatchStore.movieFavKey /
    /// torFavKey), so the entry handed to the store is a
    /// copy of the session entry re-keyed to the favourite
    /// key, exactly as the detail screens build theirs;
    /// toggling the progress-keyed entry verbatim would
    /// strand the favourite where no other screen ever
    /// looks for it.
    func toggleFavourite() {
        var fav = identity.entry
        fav.key = favouriteKey
        fav.ts = Int64(Date().timeIntervalSince1970 * 1000)
        store.toggleFavorite(fav)
    }

    /// "Tập tiếp theo": skip straight to the next episode,
    /// from mid-play or from the countdown alike. The
    /// current item's bookkeeping ends exactly like
    /// itemEnded's (progress removed — the episode counts
    /// as finished for Continue Watching), any active
    /// countdown is cancelled through the standing cancel
    /// path, and the advance itself runs through the same
    /// runAdvanceFactory the countdown and "Phát ngay" use.
    /// Sessions without a next episode do nothing.
    func skipToNextEpisode() {
        guard nextEpisodeFactory != nil else { return }
        store.removeProgress(matching: identity.entry)
        cancelAdvance()
        upNextGeneration += 1
        let generation = upNextGeneration
        upNextTask = Task { [weak self] in
            guard let self else { return }
            await self.runAdvanceFactory(generation: generation)
        }
    }

    /// The favourite key for this session's title — the
    /// detail screens' derivation, shared by toggleFavourite
    /// and isFavourite so the two can never disagree.
    private var favouriteKey: String {
        let e = identity.entry
        if e.kind == WatchStore.kindTor {
            return WatchStore.torFavKey(metaId: e.metaId, type: e.metaType)
        }
        return WatchStore.movieFavKey(provider: e.source, slug: e.slug)
    }

    /// Read by the player chrome (the menu's favourite
    /// label) — the director owns the store, so the check
    /// lives here.
    var isFavourite: Bool { store.isFavorite(key: favouriteKey) }

    /// Whether the transport menu offers "Tập tiếp theo".
    var hasNextEpisode: Bool { nextEpisodeFactory != nil }

    /// The session's identity entry, read by the player
    /// chrome for the item metadata + info tab (title,
    /// episode label, poster). Read-only: identity itself
    /// stays private and changes only through the failover
    /// hop, exactly as before.
    var sessionEntry: WatchStore.Entry { identity.entry }

    /// Leaving the player: one last save under the same rule.
    func flush() {
        tick(positionMs: lastPosMs, durationMs: lastDurMs)
    }
}

/// Handover box for Up Next (v2.0.25): holds the session's
/// CURRENT director and swaps it when that director
/// publishes an advanceTarget. The swap is deferred to the
/// next main-runloop tick — @Published fires in willSet, so
/// publishing the box's own director inside the sink would
/// nest one publish inside another. After the swap the box
/// re-subscribes to the NEW director, so a chain of
/// episodes (each factory-built director carrying its own
/// factory) advances repeatedly through the same box.
@MainActor
private final class JoeDirectorBox: ObservableObject {
    @Published private(set) var director: PlayDirector
    private var advanceSubscription: AnyCancellable?

    init(director: PlayDirector) {
        self.director = director
        observe(director)
    }

    private func observe(_ director: PlayDirector) {
        advanceSubscription = director.$advanceTarget
            .sink { [weak self] target in
                guard let target, let self else { return }
                Task { @MainActor in
                    guard self.director !== target,
                          self.director.advanceTarget === target else { return }
                    self.director = target
                    self.observe(target)
                }
            }
    }
}

/// Full-screen player shell: AVPlayerViewController + a status
/// capsule (candidate label / failover notices), driven by
/// PlayDirector. Menu exits, like the house player.
///
/// v2.0.25 (Up Next handover): JoePlayerView itself is now a
/// thin identity shell over JoePlayerSessionView. The
/// session view is keyed by the current director's identity
/// (ObjectIdentifier), so when the box swaps in the next
/// episode's director the old session view is torn down and
/// a fresh one appears for the new director — whose start()
/// therefore fires through the exact same .onAppear path as
/// the first episode's did. The public init is unchanged.
struct JoePlayerView: View {
    @StateObject private var box: JoeDirectorBox

    /// v2.0.0 (UI-5): design F's exhausted slate lists the tried
    /// source families as rows (the render's shape). The Phim
    /// detail passes the four provider names; torrent sessions
    /// pass nil and F falls back to the plain slate.
    private let attemptRows: [String]?

    /// UI-6 defect D-18: the slate's kicker carries the film
    /// title + episode (the renders' slate heading), and the
    /// source line names the active source mode (owner
    /// source-priority policy: Tự động / ưu tiên Torrent / the
    /// pinned source). Both default empty — torrent sessions
    /// pass their own values.
    private let filmTitle: String
    private let filmEpisode: String
    private let sourceLine: String

    init(director: PlayDirector, attemptRows: [String]? = nil,
         filmTitle: String = "", filmEpisode: String = "",
         sourceLine: String = "") {
        _box = StateObject(wrappedValue: JoeDirectorBox(director: director))
        self.attemptRows = attemptRows
        self.filmTitle = filmTitle
        self.filmEpisode = filmEpisode
        self.sourceLine = sourceLine
    }

    var body: some View {
        JoePlayerSessionView(director: box.director,
                             attemptRows: attemptRows,
                             filmTitle: filmTitle,
                             filmEpisode: filmEpisode,
                             sourceLine: sourceLine)
            .id(ObjectIdentifier(box.director))
    }
}

/// One episode's player session (the pre-v2.0.25 JoePlayerView
/// body, verbatim in behaviour): the engine dispatch, the
/// status capsule, the exhausted slate, plus the Up Next
/// countdown card overlay. A fresh instance is created per
/// director by the identity shell above.
private struct JoePlayerSessionView: View {
    @ObservedObject var director: PlayDirector
    @Environment(\.dismiss) private var dismiss
    @Environment(\.joeTheme) private var theme
    @FocusState private var slateFocus: SlateButton?

    private enum SlateButton: Hashable { case retry, back, playNext }

    private let attemptRows: [String]?
    private let filmTitle: String
    private let filmEpisode: String
    private let sourceLine: String

    init(director: PlayDirector, attemptRows: [String]? = nil,
         filmTitle: String = "", filmEpisode: String = "",
         sourceLine: String = "") {
        self.director = director
        self.attemptRows = attemptRows
        self.filmTitle = filmTitle
        self.filmEpisode = filmEpisode
        self.sourceLine = sourceLine
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch director.phase {
            case .resolving:
                // §7.10 loading slate: black, white spinner, the
                // label bottom-left (TV360 language).
                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        ProgressView()
                            .tint(.white)
                        Text("Đang tải…")
                            .font(.system(size: 29))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.leading, 48)
                    .padding(.bottom, 36)
                }
                .ignoresSafeArea()
            case .playing:
                if let candidate = director.candidate {
                    // Engine dispatch is a value on the candidate
                    // (torrent candidates carry .ffmpeg — see
                    // PlayCandidate); the shell, the capsule and
                    // the director contract are shared.
                    if candidate.engine == .ffmpeg {
                        JoeKSPlayerController(candidate: candidate,
                                              director: director)
                            .id(director.attemptID)
                            .ignoresSafeArea()
                    } else {
                        PlayerController(candidate: candidate,
                                         director: director)
                            .id(director.attemptID)
                            .ignoresSafeArea()
                    }
                }
                // v2.0.29 (item 2): the capsule — the source
                // label, the resume line, every failover
                // notice — is bound to the SAME visibility
                // state as the live host's transport bar,
                // reported into the director by the host
                // itself (KS: its show/hide path; AVPlayer:
                // the fix-9 delegate callback). Bar hidden →
                // capsule hidden; bar summoned → capsule back.
                // No separate timer exists for it any more:
                // pre-fix it was rendered unconditionally in
                // .playing, and since `notice` is never
                // cleared, the "Tiếp tục từ …" line in
                // particular stayed on screen for the whole
                // film after the bar had gone.
                statusCapsule
                    .opacity(director.transportBarVisible ? 1 : 0)
            case .exhausted:
                // §8 error slate: message + cause + reachable
                // buttons, focus on the first button. (v1.8's
                // slate was text-only — the only way out was
                // Menu, which read as part of the freeze.)
                // 1.9.2 (Team 9 item 1a): the text column is
                // CAPPED (≈1150) and the padding sits INSIDE the
                // flexible frame.
                // v2.0.0 (UI-5): the slate's placement follows
                // the active design — A a left column, D centred,
                // F bottom-left with the tried sources as rows.
                // v2.0.5 (error 8b): the slate's focus landing
                // is a standing .defaultFocus DECLARATION on the
                // slate container (one attachment covers all
                // three anatomies) — the focus engine consults
                // it at every focus update, including the one
                // the engine representable's teardown triggers.
                // The pre-fix construction was a one-shot
                // @FocusState write in .onChange racing that
                // teardown, with no declared landing to fall
                // back on: focus landed nowhere and the slate's
                // buttons were unreachable (Menu-only trap).
                exhaustedSlate
                    .defaultFocus($slateFocus, .retry)
            }
            // Up Next countdown card (v2.0.25): overlays the
            // finished item's last frame while the director
            // counts down. The card's focus landing is a
            // standing .defaultFocus declaration, the slate's
            // own construction (see the error-8b note above).
            if director.upNextSecondsLeft != nil {
                upNextCard
                    .defaultFocus($slateFocus, .playNext)
            }
        }
        .onAppear { director.start() }
        .onDisappear {
            director.flush()
            // Teardown: a countdown must not outlive its
            // session view. cancelAdvance() deliberately
            // leaves advanceTarget untouched, so the
            // handover teardown (this view disappearing
            // BECAUSE the box swapped directors) is safe.
            director.cancelAdvance()
        }
        .onExitCommand {
            // Menu during an active countdown cancels the
            // advance instead of leaving the player; with
            // no countdown active Menu exits as always.
            // v2.0.31 (L5): a picker open in the KS host owns
            // the FIRST Menu press — it closes, and focus /
            // playback state are restored by the host; the
            // countdown rule and the plain exit keep their
            // order behind it.
            if director.pickerOpen {
                director.requestPickerClose()
            } else if director.upNextSecondsLeft != nil {
                director.cancelAdvance()
            } else {
                dismiss()
            }
        }
    }

    /// The Up Next countdown card: next episode title, the
    /// remaining seconds, a focusable "Phát ngay" button and
    /// the Menu-cancels hint. Theme tokens and the file's
    /// existing button construction (slateButton →
    /// JoePrimaryLabel / .joeCardButton(), the custom style)
    /// only — no .card platter, no hand-drawn focus rings.
    private var upNextCard: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    Text("TẬP TIẾP THEO")
                        .font(.system(size: 22, weight: .bold))
                        .tracking(4)
                        .foregroundStyle(theme.focusTitle)
                    if !director.nextEpisodeTitle.isEmpty {
                        Text(director.nextEpisodeTitle)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(theme.text)
                            .lineLimit(2)
                    }
                    if let seconds = director.upNextSecondsLeft {
                        Text("Tập tiếp theo sau \(seconds)s")
                            .font(.system(size: 25))
                            .foregroundStyle(theme.meta)
                    }
                    HStack(spacing: 18) {
                        slateButton("Phát ngay", tag: .playNext, primary: true) {
                            director.advanceNow()
                        }
                    }
                    .padding(.top, 8)
                    Text("Nhấn Menu để hủy")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.meta)
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .frame(maxWidth: 560, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: theme.rField)
                    .fill(theme.surfaceGradient))
                .overlay(RoundedRectangle(cornerRadius: theme.rField)
                    .strokeBorder(theme.stroke, lineWidth: 1.5))
            }
            .padding(.trailing, 48)
            .padding(.bottom, 36)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var exhaustedSlate: some View {
        switch theme.id {
        case .posterWall:
            VStack(alignment: .center, spacing: 18) {
                slateTexts(centred: true)
                // Design-D player slate: button row gap 18,
                // margin-top 40 above the row (the column's 18
                // spacing + this 22 padding — the A branch's
                // construction, whose drawing agrees).
                HStack(spacing: 18) {
                    slateButton("Thử lại", tag: .retry, primary: true) {
                        director.retryFromExhausted()
                    }
                    slateButton("Quay lại", tag: .back, primary: false) {
                        dismiss()
                    }
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: 1150)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .billboard, .ultra:
            VStack(alignment: .leading, spacing: 18) {
                slateTexts(centred: false)
                // Design-A player slate: button row gap 18,
                // margin-top 40 above the row (the column's 18
                // spacing + this 22 padding).
                HStack(spacing: 18) {
                    slateButton("Thử lại", tag: .retry, primary: true) {
                        director.retryFromExhausted()
                    }
                    slateButton("Quay lại", tag: .back, primary: false) {
                        dismiss()
                    }
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: 1150, alignment: .leading)
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .sourceBoard:
            VStack(alignment: .leading, spacing: 18) {
                slateTexts(centred: false)
                if let attemptRows {
                    // Design-F player: the attempt rows are
                    // the drawing's .srcrow at full slate-column
                    // width — name 30 bold, the failed state 25
                    // semibold in the bad colour, padding 22/30,
                    // radius 18 (theme.rField under F), the
                    // surface gradient with the resting inset
                    // stroke 1.5, rows at margin-bottom 16; the
                    // block's margin-top is 28 (the column's 18
                    // + this 10 padding).
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(attemptRows, id: \.self) { name in
                            HStack(spacing: 22) {
                                Text(name)
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundStyle(theme.text)
                                Spacer()
                                Text("✗ Không phát được")
                                    .font(.system(size: 25, weight: .semibold))
                                    .foregroundStyle(JoeTheme.accentRed)
                            }
                            .padding(.horizontal, 30)
                            .padding(.vertical, 22)
                            .background(RoundedRectangle(cornerRadius: theme.rField)
                                .fill(theme.surfaceGradient))
                            .overlay(RoundedRectangle(cornerRadius: theme.rField)
                                .strokeBorder(theme.stroke, lineWidth: 1.5))
                        }
                    }
                    .padding(.top, 10)
                }
                // Design-F player: button row gap 18,
                // margin-top 30 (the column's 18 + this 12).
                HStack(spacing: 18) {
                    slateButton("Thử lại", tag: .retry, primary: true) {
                        director.retryFromExhausted()
                    }
                    slateButton("Quay lại", tag: .back, primary: false) {
                        dismiss()
                    }
                }
                .padding(.top, 12)
            }
            .frame(maxWidth: 1150, alignment: .leading)
            .padding(.leading, 48)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    /// The slate's text block (UI-6 defect D-18 — the renders'
    /// slate composition): the kicker (film title — episode,
    /// focusTitle colour, tracked uppercase), the 52 pt heavy
    /// headline, the explanation, the tried-sources line
    /// (designs A/D; F renders the same data as rows below),
    /// and the active source-mode line.
    private func slateTexts(centred: Bool) -> some View {
        // Design .slate text rhythm (shared stylesheet, all
        // three drawings): headline margin-top 12 below the
        // kicker, message 16 below the headline in FULL white,
        // tried line 18 below the message in the theme's meta
        // colour. One spacing-0 column with per-line top
        // paddings, so an absent line collapses with its
        // margin, like CSS. The "Lỗi cuối" and source-mode
        // lines are app-only (v2.0.5 error 8a) and keep their
        // dimmed white at the same 18 rhythm.
        VStack(alignment: centred ? .center : .leading, spacing: 0) {
            if !filmTitle.isEmpty {
                Text(filmEpisode.isEmpty ? filmTitle : "\(filmTitle) — \(filmEpisode)")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(4)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.focusTitle)
                    .multilineTextAlignment(centred ? .center : .leading)
            }
            // Headline/message sizes follow each drawing's own
            // slate classes: A and F inline the slate sizes
            // (52 headline, 29 message, full white); design-D's
            // player drawing reuses its hero classes instead —
            // .hero-title at D's 56px override and .hero-syn
            // at 27px, white at the base rule's .92 opacity.
            Text("Không phát được nguồn này")
                .font(.system(size: theme.id == .posterWall ? 56 : 52, weight: .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(centred ? .center : .leading)
                .padding(.top, filmTitle.isEmpty ? 0 : 12)
            Text("Đã thử lấy link mới và đổi nguồn nhưng vẫn không phát được.")
                .font(.system(size: theme.id == .posterWall ? 27 : 29))
                .foregroundStyle(theme.id == .posterWall ? .white.opacity(0.92) : .white)
                .multilineTextAlignment(centred ? .center : .leading)
                .padding(.top, 16)
            if let lastFailure = director.lastFailure {
                // v2.0.5 (error 8a): the last failure's own cause,
                // remembered by the director — a dead slate used
                // to say nothing about why every attempt died.
                Text("Lỗi cuối: \(lastFailure)")
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(centred ? .center : .leading)
                    .padding(.top, 18)
            }
            if theme.id != .sourceBoard, let attemptRows, !attemptRows.isEmpty {
                Text("Đã thử: " + attemptRows.joined(separator: " · "))
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
                    .multilineTextAlignment(centred ? .center : .leading)
                    .padding(.top, 18)
            }
            if !sourceLine.isEmpty {
                Text(sourceLine)
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(centred ? .center : .leading)
                    .padding(.top, 18)
            }
        }
    }

    private func slateButton(_ title: String, tag: SlateButton, primary: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if primary {
                JoePrimaryLabel(title: title)
            } else {
                JoeSecondaryLabel(title: title)
            }
        }
        .joeCardButton()
        .focused($slateFocus, equals: tag)
    }

    private var statusCapsule: some View {
        VStack {
            Spacer()
            HStack {
                if let notice = director.notice {
                    Text(notice)
                        .font(.system(size: 25))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                } else if !director.currentLabel.isEmpty {
                    Text(director.currentLabel)
                        .font(.system(size: 25))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                }
                Spacer()
            }
            .padding(.leading, 48)
            .padding(.bottom, 36)
        }
        .ignoresSafeArea()
    }
}

/// Info-tab page for the AVPlayer chrome (v2.0.27, Idea 13):
/// the system player's info panel hosts this controller
/// (AVPlayerViewController.customInfoViewControllers) — the
/// film title, the episode label and the current source line
/// as plain labels on a dark ground matching the player. The
/// PlayerController Coordinator owns the one instance and
/// re-points its labels at every new item.
private final class JoePlayerInfoViewController: UIViewController {
    private let titleLabel = UILabel()
    private let episodeLabel = UILabel()
    private let sourceLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        titleLabel.font = .systemFont(ofSize: 38, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        episodeLabel.font = .systemFont(ofSize: 29)
        episodeLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        episodeLabel.numberOfLines = 1
        sourceLabel.font = .systemFont(ofSize: 29)
        sourceLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        sourceLabel.numberOfLines = 2
        let stack = UIStackView(arrangedSubviews: [titleLabel, episodeLabel, sourceLabel])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 48),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -48),
            stack.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 48),
        ])
    }

    /// Point the labels at a (new) item: the film title, its
    /// episode label (hidden for single-episode titles) and
    /// the live source line. Safe to call before the view has
    /// loaded — the first item is observed before the info
    /// panel is ever opened.
    func update(title: String, episode: String, source: String) {
        loadViewIfNeeded()
        titleLabel.text = title
        episodeLabel.text = episode
        episodeLabel.isHidden = episode.isEmpty
        sourceLabel.text = source
        sourceLabel.isHidden = source.isEmpty
    }
}

private struct PlayerController: UIViewControllerRepresentable {
    let candidate: PlayCandidate
    let director: PlayDirector

    func makeCoordinator() -> Coordinator {
        Coordinator(director: director)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        // v2.0.24: adopt the dwell-warmed player when this
        // candidate is the one the detail screen warmed
        // (StreamWarmer) — its item has been loading since
        // the dwell, so playback starts from warm playlists
        // and buffered initial segments instead of a cold
        // build. Any other candidate takes the cold build
        // below, byte-identical to before.
        let player: AVPlayer
        let item: AVPlayerItem
        if let warm = StreamWarmer.shared.take(url: candidate.url,
                                               headers: candidate.headers),
           let warmItem = warm.currentItem {
            player = warm
            item = warmItem
        } else {
            item = AVPlayerItem(asset: candidate.makeAsset())
            player = AVPlayer(playerItem: item)
        }
        controller.player = player
        context.coordinator.attach(controller)
        context.coordinator.observe(item, player: player)
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.invalidate()
        controller.player?.pause()
        controller.player = nil
    }

    /// Watches the item: ready → resume seek via the director;
    /// failed → director's failover; periodic ticks → progress
    /// saves; end → finished rule. Each event fires at most the
    /// transitions the director allows, so stale items from a
    /// previous attempt can never double-drive the machine (the
    /// view recreates the controller per attempt via .id()).
    /// Swift 6 (v2.0.32): the coordinator is @MainActor — its
    /// tokens, watchdog and freeze state were previously
    /// mutated from whichever thread KVO / NotificationCenter
    /// delivered on; every off-main callback below now reads
    /// the Sendable value it needs and hops to the main queue
    /// before touching this state (the same shape the iOS
    /// player's migrated view controller uses).
    @MainActor
    final class Coordinator: NSObject {
        private let director: PlayDirector
        private var statusToken: NSKeyValueObservation?
        private var failToken: NSObjectProtocol?
        private var endToken: NSObjectProtocol?
        private var timeToken: Any?
        private weak var player: AVPlayer?
        /// Idea 13 chrome (v2.0.27): the hosting controller
        /// (the transport menu + info tab are set on it), the
        /// one info-tab controller whose labels follow the
        /// item, and the in-flight poster fetch behind the
        /// artwork metadata.
        private weak var viewController: AVPlayerViewController?
        private let infoController = JoePlayerInfoViewController()
        private var artworkTask: Task<Void, Never>?
        private var failed = false
        /// v2.0.35 (REVIEW-2035B-LOOP3 E-1; the failure
        /// and ended funnels joined under
        /// REVIEW-2035C-LOOP3 E-1): the attempt this
        /// coordinator was created under, captured in
        /// observe() — makeUIViewController runs it during
        /// the SwiftUI commit for this attempt's
        /// .id(attemptID) identity, with the director's
        /// counter standing at exactly that attempt.
        /// handleReady hands it to the director's
        /// attempt-scoped itemReady core, and fireFail /
        /// the end observer hand it to the equally scoped
        /// itemFailed / itemEnded, so a late ready, failure
        /// or ended from THIS coordinator after the ladder
        /// has advanced (its item readied only after a U-1
        /// cut, its terminal error still in flight through
        /// the Task hops when the owner picked the next
        /// source, the teardown landing later still) is
        /// recognised as stale and ignored there.
        private var attemptID = 0
        /// U-1 stall watchdog: fires itemFailed() if the item
        /// has neither readied nor failed 20 s after observe().
        private var watchdog: Task<Void, Never>?
        /// Mid-play freeze watchdog (latency round, audit
        /// §3.2/§6): the U-1 watchdog is cancelled the moment
        /// the item readies, and before this round NOTHING
        /// bounded a silent mid-play stall on tvOS — a stream
        /// could freeze forever without AVPlayer ever raising
        /// an error. This 1 s ticker watches the playhead
        /// after readyToPlay: 12 s without advance while the
        /// player is meant to be playing routes through
        /// fireFail(), the same failure path as an error, so
        /// the director's ladder advances (refresh → hop →
        /// torrent rung → exhausted). 12 s = two missed
        /// segments at the 6 s cadence of VS/TP/CV (audit §6);
        /// the value is CONSTANT this round — SourceHealth
        /// does not move it.
        /// v2.0.35 (AUDIT-2035-SEEKPATH #1): the 12 s
        /// judgement is a MID-PLAY budget; a post-seek
        /// refill is a start-class fetch the player spends
        /// in .waitingToPlayAtSpecifiedRate, a state this
        /// watchdog previously never read — so checkFreeze
        /// now holds its clock open while waiting, capped
        /// at 30 s of continuous waiting (see waitingSince).
        private var freezeTimer: Timer?
        private var freezeReady = false
        private var freezeEnded = false
        private var lastPositionSec = -1.0
        private var lastAdvanceAt = Date()
        /// v2.0.35 (AUDIT-2035-SEEKPATH #1): the start of
        /// the current CONTINUOUS
        /// .waitingToPlayAtSpecifiedRate stretch — nil
        /// whenever the player is not in that state.
        /// checkFreeze holds the freeze clock open while
        /// waiting (the same hold-open the .paused state
        /// gets, kept with the watchdog's existing tick
        /// bookkeeping — no second timer): after a seek
        /// the playhead sits AT the target while AVPlayer
        /// refills, and pre-fix that refill was judged by
        /// the 12 s mid-play budget, so a refill past
        /// ~12 s (a +2′ scrub onto these CDNs; the 2.0.34
        /// log measured a 13.04 s cold-offset first frame
        /// even on a warm hit) failed a healthy attempt —
        /// the owner's "kéo 2' là đứt". The hold is CAPPED:
        /// a stretch past 30 s — the budget the KS path
        /// has carried since v2.0.15 for this same disease
        /// — lets the freeze verdict proceed, so a stream
        /// that waits forever still fails over.
        private var waitingSince: Date?

        init(director: PlayDirector) {
            self.director = director
            super.init()
        }

        /// Idea 13 (v2.0.27): adopt the hosting controller —
        /// the info tab is installed here, once per session
        /// view; the transport menu and the item metadata are
        /// (re)built per item in refreshChrome, from
        /// observe().
        func attach(_ controller: AVPlayerViewController) {
            viewController = controller
            infoController.title = "Thông tin"
            controller.customInfoViewControllers = [infoController]
            // FIX4 (fix 9): this coordinator is the player
            // controller's delegate so the Title View can be
            // bound to the transport bar's visibility (the
            // delegate callback below). The Title View starts
            // INCLUDED — it belongs with the bar.
            controller.delegate = self
            controller.transportBarIncludesTitleView = true
            // v2.0.29 (item 2): a freshly attached
            // controller's bar starts visible — report that
            // to the director so the status capsule starts
            // with the bar even when a previous attempt in
            // this session (e.g. a KS attempt before the
            // torrent substitution rung, or the reverse) had
            // reported its own bar hidden.
            // Swift 6 specialist-review fix (B-2): Task hop,
            // not DispatchQueue.main.async — a GCD closure is
            // a nonisolated @Sendable closure and may not
            // touch this coordinator's @MainActor state.
            Task { @MainActor in
                self.director.setTransportBarVisible(true)
            }
        }

        /// FIX4 (fix 9): the Title View binding. AVKit renders
        /// the film's title + poster — idea 13's
        /// externalMetadata, set in refreshChrome — in a Title
        /// View above the transport bar. On tvOS 27.2.1 the
        /// owner observed the title still sitting on screen
        /// after the bar auto-hid; his ruling: the title hides
        /// WITH the bar and returns WITH the bar, never on its
        /// own schedule. AVKit announces every transport-bar
        /// visibility transition to its delegate (this is the
        /// documented "responding to transport bar changes"
        /// surface), and the Title View's inclusion follows
        /// the announced state, so the two cannot drift
        /// apart: bar coming up → title included; bar going
        /// away → title excluded. No separate title timer
        /// exists anywhere in this binding.
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willTransitionToVisibilityOfTransportBar visible: Bool,
            with _: AVPlayerViewControllerAnimationCoordinator
        ) {
            playerViewController.transportBarIncludesTitleView = visible
            // v2.0.29 (item 2): the SAME announced state is
            // reported into the director, where the shell's
            // status capsule is bound to it — the capsule
            // (source label / resume line) now follows this
            // path's bar exactly as the Title View does,
            // from the one announcement, so the three can
            // never drift apart. (Pre-fix the capsule was
            // rendered unconditionally and the resume line
            // lingered after bar + title had hidden — the
            // owner's normal-film finding on 2.0.28.)
            Task { @MainActor in
                self.director.setTransportBarVisible(visible)
            }
        }

        /// v2.0.29 (item 3): a candidate label flattened for
        /// a one-line menu row — the same treatment as the
        /// KS host's chooser rows (multi-line stream names
        /// join with " · " instead of truncating at the
        /// first line break). Display only; the candidate's
        /// own label is unchanged everywhere else.
        private static func flattenedSourceLabel(_ label: String) -> String {
            label.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }

        /// The metadata title for an item: the film title,
        /// plus the episode label when the entry carries one.
        private static func displayTitle(for entry: WatchStore.Entry) -> String {
            if entry.title.isEmpty { return entry.epLabel }
            if entry.epLabel.isEmpty { return entry.title }
            return "\(entry.title) — \(entry.epLabel)"
        }

        /// Per-item chrome refresh, called from observe():
        /// the item's external metadata (title now, artwork
        /// when the poster lands), a rebuilt transport menu
        /// (favourite state / next-episode presence are read
        /// at build time) and the info tab's labels.
        @MainActor
        private func refreshChrome(for item: AVPlayerItem) {
            let entry = director.sessionEntry
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = Self.displayTitle(for: entry) as NSString
            titleItem.extendedLanguageTag = nil
            Task { @MainActor in
                item.externalMetadata = [titleItem]
            }
            // Artwork: fetch the poster fail-soft and add it
            // only if this item is still the player's current
            // one when the data lands — a slow poster must
            // never stamp itself onto the NEXT candidate.
            artworkTask?.cancel()
            artworkTask = nil
            if let posterURL = entry.posterURL {
                artworkTask = Task { [weak self] in
                    // FIX4 (HTTP consolidation): the poster
                    // fetch rides the shared JoeHTTP pool like
                    // every other data fetch — pre-fix it used
                    // URLSession.shared, outside the pool,
                    // outside the metrics and outside every
                    // house timeout. Fail-soft exactly as
                    // before (any error → no artwork).
                    let data = try? await JoeHTTP.getData(
                        posterURL.absoluteString, timeout: 15)
                    guard let data, !data.isEmpty, let self else { return }
                    Task { @MainActor in
                        guard self.player?.currentItem === item else { return }
                        let artItem = AVMutableMetadataItem()
                        artItem.identifier = .commonIdentifierArtwork
                        artItem.value = data as NSData
                        artItem.extendedLanguageTag = nil
                        item.externalMetadata = [titleItem, artItem]
                    }
                }
            }
            refreshTransportMenu()
            infoController.update(title: entry.title,
                                  episode: entry.epLabel,
                                  source: director.currentLabel)
        }

        /// (Re)build the "Joe TV" transport-bar menu from the
        /// director's CURRENT state. Called per item (from
        /// refreshChrome) and again right after a favourite
        /// toggle, so the label the owner sees on the next
        /// long-press is never stale.
        @MainActor
        private func refreshTransportMenu() {
            guard let viewController else { return }
            let isFav = director.isFavourite
            // v2.0.29 (item 3): "Đổi nguồn" is a SUBMENU —
            // the session's candidate list, each row the
            // candidate's own label with the current one
            // checked (.on) — instead of the pre-fix single
            // action that blindly advanced to the next
            // candidate. Picking a row switches to THAT
            // candidate through userSwitchSource(to:),
            // which keeps the playback position via the
            // standing itemReady resume rule. The menu is
            // rebuilt per item (refreshChrome) and after a
            // favourite toggle, so the check mark is never
            // stale. Same transport-menu pattern as the
            // rest of this menu — no new presentation form.
            let switchMenu = UIMenu(
                title: "Đổi nguồn",
                image: UIImage(systemName: "arrow.triangle.2.circlepath"),
                children: director.sourceChoices.map { choice in
                    UIAction(
                        title: Self.flattenedSourceLabel(choice.label),
                        state: choice.isCurrent ? .on : .off
                    ) { [weak self] _ in
                        guard let self else { return }
                        // v2.0.35: hand the director this
                        // player's LIVE playhead at the tap,
                        // read synchronously here — the same
                        // currentTime() handleReady reads —
                        // because the switch recreates the
                        // host and the position must be
                        // captured before it (see PlayDirector
                        // .captureSwitchSnapshot).
                        let nowSec = self.player?.currentTime().seconds ?? 0
                        let playheadMs = (nowSec.isFinite && nowSec > 0)
                            ? Int64(nowSec * 1000) : nil
                        self.director.userSwitchSource(
                            to: choice.index, playheadMs: playheadMs)
                    }
                })
            let favouriteAction = UIAction(
                title: isFav ? "Bỏ yêu thích" : "Yêu thích",
                image: UIImage(systemName: isFav ? "heart.fill" : "heart")
            ) { [weak self] _ in
                guard let self else { return }
                self.director.toggleFavourite()
                self.refreshTransportMenu()
            }
            var children: [UIMenuElement] = [switchMenu, favouriteAction]
            if director.hasNextEpisode {
                children.append(UIAction(
                    title: "Tập tiếp theo",
                    image: UIImage(systemName: "forward.end.fill")
                ) { [weak self] _ in
                    self?.director.skipToNextEpisode()
                })
            }
            viewController.transportBarCustomMenuItems = [
                UIMenu(title: "Joe TV", children: children)
            ]
        }

        @MainActor
        func observe(_ item: AVPlayerItem, player: AVPlayer) {
            self.player = player
            // v2.0.35 (REVIEW-2035B-LOOP3 E-1): capture
            // the attempt this coordinator serves — see
            // the attemptID property. observe() runs once
            // per coordinator, from makeUIViewController,
            // under this attempt's .id() identity.
            attemptID = director.attemptID
            // U-1: without this, an item whose status stays
            // .unknown (a stream that accepts the connection and
            // then never sends a byte) leaves the player on a
            // silent black screen forever — AVPlayer raises no
            // error for it. The watchdog feeds the stall into
            // the director's normal failover path.
            // Swift 6 specialist-review fix (B-2): the
            // watchdog is a weak Task with a sleep — the
            // house watchdog form (JoeStores) — not a
            // DispatchWorkItem on the main queue: a GCD
            // closure is a nonisolated @Sendable closure and
            // may not touch this coordinator's @MainActor
            // state. The 20 s budget is unchanged, and
            // cancellation keeps the DispatchWorkItem shape
            // (watchdog?.cancel() at every stand-down site).
            watchdog?.cancel()
            watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled else { return }
                // v2.0.33 (item 8): logging only — the U-1
                // firing is recorded in the persistent
                // DiagLog file just before the failover, so
                // a device run shows this watchdog (rather
                // than an engine error) ended the attempt.
                DiagLog.write("play", "avplayer watchdog U-1 fired — item never readied in 20s")
                self.fireFail(cause: "Quá 20 giây vẫn chưa sẵn sàng phát")
            }
            // Mid-play freeze watchdog: armed now, but it only
            // starts judging once the item readies — until
            // then the pre-ready watchdog above owns the start
            // phase and the two never overlap.
            freezeTimer?.invalidate()
            freezeReady = false
            freezeEnded = false
            waitingSince = nil
            lastPositionSec = -1
            lastAdvanceAt = Date()
            let ticker = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkFreeze()
            }
            RunLoop.main.add(ticker, forMode: .common)
            freezeTimer = ticker
            statusToken = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                // Swift 6: the KVO handler is a non-isolated
                // context — read the status VALUE here and
                // hop; the coordinator's state is main-actor
                // state and is only touched after the hop.
                let status = item.status
                guard let self else { return }
                Task { @MainActor in
                    switch status {
                    case .readyToPlay:
                        self.handleReady()
                    case .failed:
                        self.fireFail()
                    default:
                        break
                    }
                }
            }
            // v2.0.24: a dwell-warmed item (StreamWarmer) may
            // ALREADY be .readyToPlay when the observation is
            // installed — KVO with .new reports only changes
            // after registration, so without this check the
            // ready transition would never fire for it: no
            // resume seek, and the U-1 watchdog would kill a
            // healthy item at 20 s. For a cold item the status
            // is .unknown here and the check is a no-op.
            if item.status == .readyToPlay {
                handleReady()
            }
            failToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] note in
                // The notification carries the error that
                // ended playback — hand it to the director
                // (pre-v2.0.5 it was discarded unread). Only
                // the Sendable description crosses the hop
                // (Swift 6); the funnel itself runs on the
                // main actor like every other state touch.
                let cause = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                    as? Error)?.localizedDescription
                guard let self else { return }
                Task { @MainActor in
                    self.fireFail(cause: cause)
                }
            }
            endToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    // The freeze watchdog stands down at the
                    // end: a finished item is the end-observer's
                    // transition, never a stall.
                    self.freezeEnded = true
                    // v2.0.35: hand in this coordinator's
                    // captured attempt — the director ignores
                    // an ended that names a superseded
                    // attempt (see PlayDirector.itemEnded).
                    self.director.itemEnded(reportingAttemptID: self.attemptID)
                }
            }
            timeToken = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 5, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                // Swift 6: the tick's state reads (the current
                // item, the director) happen after the hop,
                // on the main actor — the observer block
                // itself carries only the Sendable time.
                let seconds = time.seconds
                guard let self else { return }
                Task { @MainActor in
                    guard let item = self.player?.currentItem else { return }
                    let pos = Int64(seconds * 1000)
                    let dur = item.duration.seconds.isFinite ? Int64(item.duration.seconds * 1000) : 0
                    self.director.tick(positionMs: pos, durationMs: dur)
                }
            }
            // Idea 13: the new item gets its metadata, menu
            // and info-tab labels (see refreshChrome).
            refreshChrome(for: item)
        }

        /// The .readyToPlay transition, shared by the KVO
        /// above and observe()'s already-ready check: stand
        /// the pre-ready watchdog down, arm the freeze
        /// watchdog's judgement from a fresh clock, and hand
        /// the resume seek to the director.
        private func handleReady() {
            watchdog?.cancel()
            freezeReady = true
            lastAdvanceAt = Date()
            if let p = player {
                let now = p.currentTime().seconds
                lastPositionSec = now.isFinite ? now : -1
            }
            Task { @MainActor in
                guard let player = self.player else { return }
                self.director.itemReady(player: player,
                                         reportingAttemptID: self.attemptID)
            }
        }

        /// One freeze-watchdog tick (1 s, main run loop).
        /// Judgement is deliberately narrow — it fires ONLY
        /// on a playhead that has not advanced for 12 s while
        /// playback is supposed to be running:
        ///   • not ready yet → the pre-ready watchdog owns
        ///     the phase; stay out of its way;
        ///   • user-paused (timeControlStatus == .paused,
        ///     which is also where the controller sits during
        ///     a scrub) → hold the clock open, so a resume
        ///     always gets a fresh 12 s and a pause can never
        ///     be misread as a stall;
        ///   • waiting to play at the specified rate
        ///     (.waitingToPlayAtSpecifiedRate — the post-seek
        ///     / rebuffer refill state) → hold the clock open
        ///     the same way, CAPPED at 30 s of CONTINUOUS
        ///     waiting; past the cap the freeze verdict
        ///     proceeds (v2.0.35, AUDIT-2035-SEEKPATH #1 —
        ///     pre-fix this state was never read, so a
        ///     refill longer than the 12 s budget was judged
        ///     a freeze and killed a healthy attempt);
        ///   • ended / within a breath of the end → the
        ///     end-observer owns the transition;
        ///   • any playhead movement — including a seek jump
        ///     in either direction — counts as alive.
        private func checkFreeze() {
            guard freezeReady, !freezeEnded, !failed,
                  let player, let item = player.currentItem else { return }
            // v2.0.35 (AUDIT-2035-SEEKPATH #1): the waiting
            // hold-open. While AVPlayer refills — after a
            // seek lands outside the forward buffer, or a
            // mid-play rebuffer — the playhead sits parked
            // AT its position and the state is
            // .waitingToPlayAtSpecifiedRate; that is a
            // start-class fetch, not a freeze. Hold the
            // clock open exactly as the .paused branch
            // below does (refresh lastAdvanceAt, track the
            // position), tracked with the watchdog's own
            // tick bookkeeping (waitingSince), and log the
            // episode's edges so the next export can show
            // seek → waiting held → resume (or the cap).
            if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                if let since = waitingSince {
                    if Date().timeIntervalSince(since) > 30 {
                        // The cap: 30 s of CONTINUOUS
                        // waiting — the KS path's budget
                        // for this same disease — is a dead
                        // stream, not a refill. Clear the
                        // stretch and let the freeze verdict
                        // proceed through the standing
                        // funnel, cause line and all.
                        DiagLog.write("play", "freeze watchdog waiting cap reached after=\(Int(Date().timeIntervalSince(since)))s — freeze verdict proceeds")
                        waitingSince = nil
                        fireFail(cause: "Hình đứng yên 12 giây (đóng băng)")
                        return
                    }
                } else {
                    waitingSince = Date()
                    DiagLog.write("play", "freeze watchdog waiting hold-open began")
                }
                lastAdvanceAt = Date()
                let now = player.currentTime().seconds
                if now.isFinite { lastPositionSec = now }
                return
            }
            if let since = waitingSince {
                DiagLog.write("play", "freeze watchdog waiting hold-open ended after=\(Int(Date().timeIntervalSince(since)))s")
                waitingSince = nil
            }
            if player.timeControlStatus == .paused {
                lastAdvanceAt = Date()
                let now = player.currentTime().seconds
                if now.isFinite { lastPositionSec = now }
                return
            }
            let pos = player.currentTime().seconds
            guard pos.isFinite else { return }
            let dur = item.duration.seconds
            if dur.isFinite, dur > 0, pos >= dur - 1.5 {
                lastAdvanceAt = Date()
                lastPositionSec = pos
                return
            }
            if lastPositionSec >= 0 {
                if abs(pos - lastPositionSec) > 0.05 {
                    lastAdvanceAt = Date()
                }
            } else {
                lastAdvanceAt = Date()
            }
            lastPositionSec = pos
            if Date().timeIntervalSince(lastAdvanceAt) >= 12 {
                fireFail(cause: "Hình đứng yên 12 giây (đóng băng)")
            }
        }

        /// Failure funnel: the cause (the caller's explicit
        /// label, else the item's own error — read here before
        /// it is thrown away) rides to the director, which logs
        /// it and remembers it for the exhausted slate.
        private func fireFail(cause: String? = nil) {
            guard !failed else { return }
            failed = true
            watchdog?.cancel()
            freezeTimer?.invalidate()
            freezeTimer = nil
            let resolved = cause ?? player?.currentItem?.error?.localizedDescription
            // v2.0.35: capture this player's last playhead
            // NOW, synchronously, before the director call
            // is dispatched — the live read is the same
            // currentTime() handleReady and the freeze
            // watchdog read; lastPositionSec (the watchdog's
            // own tracked position) is the fallback when the
            // player is already gone or reports nothing
            // usable. The director snapshots it so the next
            // candidate resumes where this one died (see
            // PlayDirector.captureSwitchSnapshot).
            let liveSec = player?.currentTime().seconds ?? -1
            let playheadSec = (liveSec.isFinite && liveSec > 0)
                ? liveSec
                : (lastPositionSec > 0 ? lastPositionSec : -1)
            let playheadMs: Int64? = playheadSec > 0
                ? Int64(playheadSec * 1000) : nil
            Task { @MainActor in
                // v2.0.35: hand in this coordinator's
                // captured attempt — a failure whose hops
                // land after the ladder advanced past this
                // coordinator is ignored by the director
                // (see PlayDirector.itemFailed).
                self.director.itemFailed(cause: resolved,
                                         playheadMs: playheadMs,
                                         reportingAttemptID: self.attemptID)
            }
        }

        func invalidate() {
            artworkTask?.cancel()
            artworkTask = nil
            watchdog?.cancel()
            watchdog = nil
            freezeTimer?.invalidate()
            freezeTimer = nil
            statusToken?.invalidate()
            statusToken = nil
            if let failToken { NotificationCenter.default.removeObserver(failToken) }
            if let endToken { NotificationCenter.default.removeObserver(endToken) }
            failToken = nil
            endToken = nil
            if let timeToken, let player {
                player.removeTimeObserver(timeToken)
            }
            timeToken = nil
        }
    }
}

/// Swift 6 (SE-0470, global-actor isolated conformances):
/// the AVPlayerViewControllerDelegate conformance is
/// isolated to the main actor instead of declared on the
/// class line. The class-line conformance was nonisolated
/// while every witness is main-actor code (Coordinator is a
/// @MainActor class), which Swift 6 rejects as a conformance
/// "crossing into main actor-isolated code". AVKit only ever
/// invokes this delegate on the main queue, and the sole use
/// site — `controller.delegate = self` in
/// Coordinator.attach — is itself main-actor code, so the
/// isolated conformance states the real contract rather than
/// suppressing the check (@preconcurrency was considered
/// and rejected for exactly that reason). The delegate
/// witness itself (playerViewController(_:
/// willTransitionToVisibilityOfTransportBar:with:)) stays in
/// the class body above, where its @MainActor isolation
/// satisfies this conformance.
extension PlayerController.Coordinator: @MainActor AVPlayerViewControllerDelegate {}

extension CMTime {
    init(milliseconds: Int64) {
        self.init(value: milliseconds, timescale: 1000)
    }
}
