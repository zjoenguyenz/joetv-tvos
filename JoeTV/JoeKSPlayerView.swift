import AVFoundation
import AVKit
import CoreMedia
import KSPlayer
import SwiftUI
import UIKit

/// The FFmpeg-engine player for torrent candidates (v2.0.3).
///
/// Why this exists: Torrentio/Real-Debrid direct files are
/// predominantly Matroska (every BluRay/REMUX/x265 release, and
/// most WEB-DL too). AVFoundation has no Matroska demuxer, so on
/// the AVPlayer path those items could never produce a frame —
/// the item sat unready or failed, the director advanced, and
/// with a dozen-plus near-identically labelled candidates the
/// walk read as one endless black spinner. KSPlayer's ME engine
/// (FFmpeg) opens these files natively. Provider candidates are
/// NOT routed here — they keep the AVPlayer controller and its
/// system transport UI exactly as before (PlayCandidate.engine
/// is the only switch, and only TorrentClient sets .ffmpeg).
///
/// The director contract is the same one the AVPlayer
/// coordinator honours: ready → resume rule, ticks → progress
/// saves, end → finished rule, failure → the ladder advances.
/// Two budgets mirror the Android player's torrent behaviour
/// (PlayerActivity STALL / POSITION_STALL):
///   • first frame: if the engine has not reached its playing
///     state 30 s after the attempt starts, the attempt fails
///     with a visible notice and the ladder moves on;
///   • mid-play freeze: once playing, a playhead that does not
///     advance for 30 s (and is not user-paused) fails the same
///     way. No torrent attempt can spin forever any more.
/// Both budgets were 12 s until v2.0.15, when they were raised
/// to the Android direct route's 30 s as part of the Sony
/// 2.3.17 player-fix port: on the owner's TV a 12 s budget
/// killed healthy REMUX sources whose post-seek refill simply
/// takes longer than that, and the failure then restarted the
/// film — his "kéo luôn 1 phát đứt luôn" verdict. The Sony
/// device trials (16 sources, 5 films) showed 30 s separates
/// a slow refill from a dead link; the streaming (AVPlayer)
/// path keeps its own budgets untouched.
/// Transport: KSPlayerLayer registers the remote's media
/// commands itself (play/pause, ±15 s skip, position change);
/// the host controller adds click handling — Select toggles
/// play/pause, Left/Right clicks seek ∓30 s. Menu is never
/// swallowed: it propagates to the shell's exit command, like
/// the AVPlayer path — which since v2.0.31 (L5) first asks
/// the director whether this host's picker is open and
/// closes just the picker in that case.
///
/// Transport bar (v2.0.12, owner defect on 2.0.10): the bare
/// layer above had NO on-screen controls at all — the owner
/// found torrent playback missing the whole bottom bar the
/// streaming path gets free from AVPlayerViewController
/// ("Riêng phần torrent thì không có thanh bar... Không
/// chỉnh được sub... Mất toàn bộ thanh đó"). The library's
/// own control view (KSVideoPlayerView) cannot be adopted
/// here: it builds and owns its own KSPlayerLayer from a URL,
/// so the director contract this host exists for — deferred
/// layer creation, the failover ladder behind attemptID, the
/// resume rule, both watchdogs — would all be bypassed.
/// The bar below is therefore built against KSPlayerLayer
/// directly, in this file, mirroring the AVPlayer transport:
/// play/pause, a focusable seek bar with current/total time,
/// subtitle selection (the layer's own subtitle model
/// since KSPlayer 5.6.2, fed from the player's subtitle
/// data source and selected through the layer — the
/// pattern of the library's own player views — Off
/// included) and
/// audio-track selection (the documented
/// tracks(mediaType:) / select(track:) API). It auto-hides
/// while playing, exactly like the system bar, and any remote
/// press brings it back; Down moves focus into it, Up leaves
/// it, and Menu still exits (it only backs out of an open
/// track picker first, as the system menus do).
struct JoeKSPlayerController: UIViewControllerRepresentable {
    let candidate: PlayCandidate
    let director: PlayDirector

    final class Coordinator {
        weak var host: KSPlayerHostViewController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> KSPlayerHostViewController {
        let host = KSPlayerHostViewController()
        context.coordinator.host = host
        host.start(candidate: candidate, director: director)
        return host
    }

    func updateUIViewController(_ controller: KSPlayerHostViewController,
                                context: Context) {}

    static func dismantleUIViewController(_ controller: KSPlayerHostViewController,
                                          coordinator: Coordinator) {
        controller.teardown()
    }
}

@MainActor
final class KSPlayerHostViewController: UIViewController, KSPlayerLayerDelegate {
    private var layer: KSPlayerLayer?
    private var director: PlayDirector?
    /// v2.0.35 (REVIEW-2035B-LOOP3 E-1; the failure
    /// and ended funnels joined under
    /// REVIEW-2035C-LOOP3 E-1): the attempt this
    /// host was created under, captured in start() —
    /// makeUIViewController runs it during the SwiftUI
    /// commit for this attempt's .id(attemptID) identity,
    /// with the director's counter standing at exactly
    /// that attempt. The .readyToPlay funnel hands it to
    /// the director's attempt-scoped itemReady core, and
    /// fireFail / the finish delegate hand it to the
    /// equally scoped itemFailed / itemEnded, so a late
    /// ready, failure or ended from THIS host after the
    /// ladder has advanced (a slow candidate cut by the
    /// 8 s ladder deadline, its engine's terminal error
    /// landing a beat after the cut, readying before its
    /// teardown lands) is recognised as stale and ignored
    /// there.
    private var hostAttemptID = 0
    /// v2.0.16: the session's side-loaded subtitle URL (the
    /// candidate's subtitleURL — the subtitle addon's best
    /// Vietnamese), fed into the subtitle model beside the
    /// embedded tracks by prepareSubtitleModel.
    private var externalSubtitleURL: URL?
    /// The candidate start() was handed. Layer creation is
    /// DEFERRED until the first layout pass with real bounds
    /// (v2.0.5, error 3b — see beginPlaybackIfPossible), so the
    /// candidate waits here until the view has a true size.
    private var pendingCandidate: PlayCandidate?
    /// v2.0.27 (idea 10, tvOS-corrected): the display
    /// criteria built in start() from the candidate's
    /// display features. start() runs before the host has a
    /// window, so the criteria wait here and are handed to
    /// the window's AVDisplayManager by applyDisplayCriteria
    /// (retried from viewDidAppear, when a window exists).
    private var pendingDisplayCriteria: AVDisplayCriteria?
    private var failed = false
    private var ready = false
    private var playing = false
    private var ended = false
    /// The host's own play/pause INTENT — the only state the
    /// play/pause toggle and its glyph may read (v2.0.32,
    /// the owner's dead pause/play buttons on 2.0.31). The
    /// toggle used to read `layer.state.isPlaying`, but
    /// KSPlayerState is a LOAD-LIFECYCLE enum (initialized /
    /// preparing / readyToPlay / buffering / bufferFinished /
    /// paused / playedToTheEnd / error — there is no
    /// .playing case; bufferFinished is its playing face),
    /// so after a source or subtitle pick — moments when the
    /// engine churns its state machine — the toggle could
    /// command the verb the engine was already in: pause
    /// pressed while the lifecycle read "not playing" sent
    /// play() to a playing engine (nothing happened), and
    /// play pressed while it read "playing" sent pause() to
    /// a stopped engine (nothing happened, forever — only
    /// recreating the layer through the source panel, which
    /// calls play() directly, ever recovered it; the owner's
    /// exact workaround). The toggle now flips THIS flag and
    /// commands the engine from it; the flag is synced from
    /// the layer's own state events (.bufferFinished →
    /// true, .paused / .playedToTheEnd / .error → false)
    /// and from every place the host itself commands play
    /// (beginPlayback, seekBy's autoPlay). The engine's
    /// play()/pause() are idempotent, so a flag that is one
    /// step behind a state event still lands on the right
    /// command at the next press.
    private var intentPlaying = false
    /// First-frame budget (30 s, Android STALL parity): armed
    /// when the layer is created, cancelled the moment the
    /// engine reports readyToPlay or its playing state
    /// (v2.0.5: readyToPlay added — a slow-but-viable start
    /// that had announced itself ready was previously still
    /// killed at 12 s because only bufferFinished disarmed
    /// the budget).
    private var firstFrameWatchdog: Task<Void, Never>?
    /// Mid-play freeze watchdog (30 s without playhead advance,
    /// Android POSITION_STALL parity): a 1 s ticker, judging
    /// only after the first frame — the same shape as the
    /// AVPlayer coordinator's freeze watch.
    private var freezeTimer: Timer?
    private var lastPositionSec = -1.0
    private var lastAdvanceAt = Date()
    /// Director ticks ride the AV path's ~5 s cadence even
    /// though the engine reports time every 0.1 s.
    private var lastTickAt = Date.distantPast

    // MARK: - Transport bar (v2.0.12)

    /// The bar's container, added in viewDidLoad — BEFORE the
    /// player view exists, so beginPlayback inserts the player
    /// view UNDER it (insertSubview at 0). Hidden with
    /// isHidden (never just alpha) so the focus engine can
    /// never land on invisible controls.
    private let controlsView = UIView()
    private let transportBar = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    /// FIX4 (fix 4): the source switch, in the bar since
    /// this round — idea 13's "Đổi nguồn" existed only in
    /// the AVPlayer transport menu, so a torrent session
    /// (this host) offered no way to change source at all
    /// (owner finding on 2.0.27).
    private let switchSourceButton = UIButton(type: .system)
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let seekBar = KSSeekBarView()
    /// v2.0.33 (item 5): the focus guide that gives the
    /// play/pause button a DOWN path to the seek bar (see
    /// buildControls / layoutControls). Invisible by
    /// construction — a UIFocusGuide renders nothing; it
    /// only redirects focus that lands on its strip.
    private let seekFocusGuide = UIFocusGuide()
    /// The guide's strip is pinned with constraints exactly
    /// once (layoutControls) — its constants never change.
    private var seekFocusGuidePinned = false
    private let bufferingSpinner = UIActivityIndicatorView(style: .medium)
    private var controlsBuilt = false
    private var controlsVisible = false
    /// True while focus sits inside the bar or the picker.
    /// FIX4 (fix 5): this no longer vetoes auto-hide — it
    /// never could be false while the bar was up (showControls
    /// deliberately moves focus INTO the bar), so the bar
    /// could never hide at all. Focus moves inside the bar
    /// now simply re-arm the idle timer (see didUpdateFocus);
    /// when it fires, the bar hides and focus returns to the
    /// root through the same preferredFocusEnvironments path
    /// that brought it in — the remote is never stranded.
    private var focusInControls = false
    /// 0.5 s refresh for the bar (time labels, seek fill,
    /// play/pause icon, buffering spinner) — the JTV surface's
    /// proven cadence shape, half its rate.
    private var uiTimer: Timer?
    private var hideTimer: Timer?
    /// Track picker state: the centred panel that replaces
    /// the bar while a subtitle/audio choice is open. Its
    /// buttons are rebuilt per opening from the LIVE track
    /// lists, so a failover to a new candidate never shows a
    /// stale slate (the host itself is recreated per attempt
    /// via .id(attemptID) regardless).
    private let pickerView = UIView()
    private let pickerTitleLabel = UILabel()
    private var pickerButtons: [UIButton] = []
    private var pickerIsOpen = false
    private enum PickerKind { case subtitles, audio, sources }
    private var pickerKind: PickerKind = .subtitles
    /// The subtitle rows' infos, cached at picker opening so
    /// a button's tag indexes the same array the selection
    /// writes back into the host's subtitle model.
    private var pickerSubtitleInfos: [any SubtitleInfo] = []
    /// KSPlayer 5.6.2: MediaPlayerTrack is a protocol now
    /// (a class in 2.3.4), so the slate holds existentials.
    private var pickerAudioTracks: [any MediaPlayerTrack] = []
    /// v2.0.29 (item 3): the source chooser's rows, cached at
    /// opening like the track rows beside them — a button's
    /// tag is the candidate's ladder index, the value
    /// userSwitchSource(to:) consumes. pickerSourceIndex is
    /// the CURRENT candidate's index at opening: the focus
    /// landing (preferredFocusEnvironments) and the row's
    /// check mark both read it.
    private var pickerSourceLabels: [PlayDirector.SourceChoice] = []
    private var pickerSourceIndex = -1
    /// The subtitle selection model — owned by the LAYER
    /// since the KSPlayer 5.6.2 upgrade (2026-11-18). In
    /// 2.3.4 KSPlayerLayer had no model of its own (the first
    /// 2.0.12 draft wrote against `layer.subtitleModel` and
    /// CI run #38 rejected it), so this host owned one, fed
    /// it from the player's subtitle data source, and painted
    /// its parts itself with a timer + label/image pair. In
    /// 5.6.2 the layer owns `subtitleModel` (a final let) AND
    /// a MetalSubtitleView, and the library's own views show
    /// the intended integration (KSPlayerUI's VideoPlayerView,
    /// tag 5.6.2): feed `layer.subtitleModel` via
    /// addSubtitle(dataSource:), read selection state from
    /// the model, PERFORM selection via
    /// `layer.select(subtitleInfo:)` — the layer renders
    /// every subtitle kind itself. The host's hand paint
    /// pair is gone: 5.6.2's SubtitlePart no longer carries
    /// a UIImage at all (its image parts are raw bitmap
    /// sources for the Metal renderer), so the old pull
    /// could not have survived the upgrade anyway. One
    /// behaviour delta, stated plainly: the old strip lifted
    /// above the transport bar while the bar was up; the
    /// layer's renderer does not know about this host's bar,
    /// so subtitles now stay at the bottom edge under the
    /// (translucent) bar for the bar's few visible seconds.
    /// The player instance the model was fed for. The layer
    /// can swap its player in place (an error finish rebuilds
    /// it from the second player type), and addSubtitle
    /// APPENDS — feeding one source twice would duplicate
    /// every picker row, so the feed is once per instance.
    private var subtitleFedPlayerID: ObjectIdentifier?

    override func loadView() {
        view = KSPlayerHostRootView()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // While the track picker is open it owns the landing.
        // While the transport bar is up, the play button owns
        // it (v2.0.17): before this, focus stayed on the root
        // view and Left/Right could only seek — the track
        // buttons were reachable only by an undiscoverable
        // Down-then-Up path, and the owner reported exactly
        // that ("chỉ cho kéo tới kéo lui"). With focus IN the
        // bar, Left/Right walk the button row and Down drops
        // to the seek bar, where Left/Right step ∓30 s.
        if pickerIsOpen {
            // v2.0.29 (item 3): the source chooser lands on
            // the CURRENT source's row — the owner starts
            // from where he is and walks from there. The
            // track pickers keep their first-row landing.
            if pickerKind == .sources,
               let current = pickerButtons.first(where: { $0.tag == pickerSourceIndex }) {
                return [current]
            }
            if let first = pickerButtons.first {
                return [first]
            }
        }
        if controlsVisible {
            return [playPauseButton]
        }
        return [view]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildControls()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshTransport()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        showControls()
        // v2.0.31 (L4): force this fresh host's focus
        // landing (the play button, per
        // preferredFocusEnvironments) instead of leaving it
        // pending — after a source switch this host replaces
        // one the focus engine was still resolving, and a
        // landing left to the engine's leisure is the one
        // the owner's dead play press followed.
        updateFocusIfNeeded()
        // v2.0.33 (item 1b, the audit's A2): re-assert the
        // landing once more AFTER the current event cycle —
        // this host's single forced landing above can be
        // overtaken by the REPLACED host's late dismantle
        // (its teardown still runs after this viewDidAppear
        // on a source switch), and a landing undone that way
        // is never retried by anyone. The deferred perform
        // below runs on the runloop after this cycle
        // completes, by which point the old host's dismantle
        // has landed too, so the re-assert is the last word.
        // Any pending re-assert is cancelled first, so
        // repeated appearances never stack them.
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(reassertFocusLanding),
            object: nil)
        perform(#selector(reassertFocusLanding), with: nil, afterDelay: 0)
        // The host has a window by now: hand the window's
        // display manager the criteria start() prepared
        // (applyDisplayCriteria no-ops without a window).
        applyDisplayCriteria()
        beginPlaybackIfPossible()
    }

    /// v2.0.33 (item 1b): the deferred focus-landing
    /// re-assert scheduled by viewDidAppear (see there).
    /// It only ever re-asks for the landing this host's
    /// preferredFocusEnvironments already names, and only
    /// while this host is genuinely the live surface: a
    /// window must exist, the bar must be up (the landing
    /// is the play button), and no picker may be open (the
    /// picker owns its own landing). Anything else and the
    /// re-assert no-ops — it must never fight a state the
    /// host has moved into since it was scheduled.
    @objc private func reassertFocusLanding() {
        guard view.window != nil, controlsVisible, !pickerIsOpen else { return }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The library contract is frame-based: re-assert the
        // player surface's frame against the host's real
        // bounds on EVERY layout pass, so no later resize
        // (rotation-class changes, cover re-presentation) can
        // strand it at a stale size again.
        if let playerView = layer?.player.view {
            playerView.frame = view.bounds
        }
        if controlsBuilt {
            layoutControls()
        }
        beginPlaybackIfPossible()
    }

    func start(candidate: PlayCandidate, director: PlayDirector) {
        self.director = director
        // v2.0.35 (REVIEW-2035B-LOOP3 E-1): name the
        // attempt this host serves — see hostAttemptID.
        hostAttemptID = director.attemptID
        externalSubtitleURL = candidate.subtitleURL
        pendingCandidate = candidate
        // v2.0.26 (idea 10), tvOS-corrected in v2.0.27:
        // display-mode matching for the torrent path. The
        // AVPlayer path is matched by the system
        // automatically; KSPlayer/FFmpeg is not, so the host
        // states the candidate's display features (stamped
        // by TorrentClient.playCandidates from the stream's
        // own parse) as an AVDisplayCriteria on the window's
        // AVDisplayManager — Apple's prescribed mechanism
        // for non-AVPlayer playback (Tech Talk 503). The
        // v2.0.26 code set a `preferredDisplayCriteria`
        // property on the view controller and built the
        // criteria from an AVVideoDynamicRange: neither
        // exists in the tvOS SDK (verified against Apple's
        // documentation — AVDisplayCriteria's sole
        // initializer is init(refreshRate:formatDescription:)
        // and the manager is vended by the window as
        // UIWindow.avDisplayManager). This is a PREFERENCE
        // the system honours subject to the user's Match
        // Content settings (Settings > Video and Audio >
        // Match Content) — that is Apple's intended
        // behaviour; do not try to force or override system
        // settings. With no rate in the release name the
        // torrent path is film/series content, so the rate
        // defaults to 23.976.
        pendingDisplayCriteria = Self.makeDisplayCriteria(for: candidate)
        applyDisplayCriteria()
        view.backgroundColor = .black
        // makeUIViewController calls this BEFORE the view has
        // been laid out — creating the layer there froze the
        // surface at the pre-layout (safe-area) size forever
        // (error 3b). Actual creation waits for bounds.
        beginPlaybackIfPossible()
    }

    /// Builds the candidate's AVDisplayCriteria in the only
    /// form the tvOS SDK offers: a refresh rate plus a
    /// CMFormatDescription whose colour extensions carry the
    /// dynamic range (BT.2020 primaries/matrix + SMPTE
    /// ST 2084 PQ transfer for DV/HDR, BT.709 for SDR). The
    /// release-name parse carries no codec or resolution, so
    /// the description states HEVC at a nominal 3840×2160 —
    /// the torrent ladder is x265-dominated and the DV/HDR
    /// flags come from 2160p names; the display manager's
    /// mode decision rides on the rate and the colour
    /// extensions, not the stated size. Dolby Vision is
    /// expressed as its PQ base layer: a bare format
    /// description cannot carry the DV configuration
    /// record, so the system may match a DV candidate as
    /// HDR10 — the supported subset, stated plainly.
    /// Fail-soft: any failure returns nil (no preference).
    private static func makeDisplayCriteria(for candidate: PlayCandidate) -> AVDisplayCriteria? {
        let primaries: CFString
        let transfer: CFString
        let matrix: CFString
        if candidate.dv || candidate.hdr {
            primaries = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            transfer = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            matrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        } else {
            primaries = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            transfer = kCMFormatDescriptionTransferFunction_ITU_R_709_2
            matrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        }
        let extensions: [CFString: CFString] = [
            kCMFormatDescriptionExtension_ColorPrimaries: primaries,
            kCMFormatDescriptionExtension_TransferFunction: transfer,
            kCMFormatDescriptionExtension_YCbCrMatrix: matrix,
        ]
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 3840, height: 2160,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription)
        guard status == noErr, let formatDescription else { return nil }
        return AVDisplayCriteria(
            refreshRate: Float(candidate.fps ?? 23.976),
            formatDescription: formatDescription)
    }

    /// Hands the pending criteria to the window's
    /// AVDisplayManager (UIWindow.avDisplayManager — the
    /// manager "vended by the key UIWindow" in Apple's
    /// guidance). start() runs before the host has a window,
    /// so this no-ops then and is retried from
    /// viewDidAppear; assigning the (possibly nil) pending
    /// value also clears a previous session's preference.
    private func applyDisplayCriteria() {
        guard let window = view.window else { return }
        window.avDisplayManager.preferredDisplayCriteria = pendingDisplayCriteria
    }

    /// Creates the KSPlayerLayer and starts playback — but
    /// only once the host view has REAL, non-zero bounds (the
    /// first layout pass, or viewDidAppear as a backstop).
    /// KSPlayer's documented sizing contract is frame +
    /// autoresizingMask; the pre-v2.0.5 host violated it on
    /// both axes: it created the layer against the not-yet-
    /// laid-out view and pinned the player view with Auto
    /// Layout constraints, so the surface kept the 1760×960
    /// safe-area size at origin (0,0) inside the full-screen
    /// host — the right + bottom bands on the owner's TV.
    private func beginPlaybackIfPossible() {
        guard layer == nil,
              let candidate = pendingCandidate,
              view.bounds.width > 0, view.bounds.height > 0
        else { return }
        pendingCandidate = nil
        let options = KSOptions()
        // Same header discipline as the AVPlayer path: the
        // candidate's own headers, the house user agent when
        // none was set.
        options.userAgent = candidate.headers["User-Agent"] ?? JoeHTTP.userAgent
        if !candidate.headers.isEmpty {
            options.appendHeader(candidate.headers)
        }
        // v2.0.15 (Sony 2.3.17 port): hand FFmpeg's HTTP layer
        // the patience the Android direct route got — a 20 s
        // read/write timeout plus automatic reconnect (plain,
        // streamed and at-EOF, up to 5 s backoff) — so a
        // dropped debrid connection is resumed by the engine
        // itself before any watchdog has to judge. The keys
        // ride formatContextOptions, the dictionary MEPlayerItem
        // passes to avformat_open_input (verified in the
        // KSPlayer 2.3.4 sources; the library's own userAgent
        // and referer setters write into the same dictionary).
        options.formatContextOptions["rw_timeout"] = "20000000"
        options.formatContextOptions["reconnect"] = "1"
        options.formatContextOptions["reconnect_streamed"] = "1"
        options.formatContextOptions["reconnect_at_eof"] = "1"
        options.formatContextOptions["reconnect_delay_max"] = "5"
        // The FFmpeg engine, deterministically: KSPlayerLayer
        // reads this type-level default at creation, and torrent
        // candidates are the only KSPlayerLayers this app ever
        // creates, so setting it here scopes it to this path.
        KSOptions.firstPlayerType = KSMEPlayer.self
        let layer = KSPlayerLayer(url: candidate.url, options: options, delegate: self)
        self.layer = layer
        let playerView = layer.player.view
        playerView.frame = view.bounds
        playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // UNDER the transport bar: the controls were added
        // in viewDidLoad, before this layer existed, so a
        // plain addSubview here would bury them beneath
        // the picture surface forever.
        view.insertSubview(playerView, at: 0)
        // v2.0.5 (P2): play EXPLICITLY. The pre-fix host never
        // called play() at start — playback depended on the
        // library's autoplay behaviour, which this side has
        // never verified; a host that wants playback must ask
        // for it.
        layer.play()
        intentPlaying = true
        // Swift 6 specialist-review fix (B-2): the delayed
        // watchdog is a weak Task with a sleep — the house
        // watchdog form (JoeStores) — not a DispatchWorkItem
        // on the main queue: a GCD closure is a nonisolated
        // @Sendable closure and may not touch this host's
        // @MainActor state. The 30 s budget is unchanged.
        firstFrameWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, !self.playing else { return }
            self.stallFail(reason: "Chưa có hình sau 30 giây")
        }
        lastAdvanceAt = Date()
        let ticker = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkFreeze()
        }
        RunLoop.main.add(ticker, forMode: .common)
        freezeTimer = ticker
    }

    func teardown() {
        // v2.0.26 (idea 10), tvOS-corrected in v2.0.27:
        // clear the display criteria handed to the window's
        // display manager in start()/viewDidAppear, so no
        // preference lingers after the session — the system
        // returns to its default mode.
        //
        // FIX4 (fix 1): the clear is IDENTITY-GUARDED now.
        // Hosts are recreated per attempt (.id(attemptID)),
        // and SwiftUI's dismantle of an old attempt's host
        // can land AFTER the replacement host's viewDidAppear
        // already applied its own criteria to the SAME
        // window's manager — the old unconditional clear then
        // silently nilled the LIVE attempt's preference, and
        // nothing ever re-applied it: display matching was
        // dead for every session that churned an attempt
        // before settling (the owner's 2.0.27 test: two
        // torrent films, no badge, no mode change). Only
        // clear while the manager still holds THIS host's
        // object.
        if let window = view.window,
           let mine = pendingDisplayCriteria,
           window.avDisplayManager.preferredDisplayCriteria === mine {
            window.avDisplayManager.preferredDisplayCriteria = nil
        }
        pendingDisplayCriteria = nil
        // A dismantled host must never begin playback late:
        // drop the deferred candidate first.
        pendingCandidate = nil
        intentPlaying = false
        firstFrameWatchdog?.cancel()
        firstFrameWatchdog = nil
        freezeTimer?.invalidate()
        freezeTimer = nil
        // v2.0.33 (item 1b): cancel every pending deferred
        // perform aimed at this host (the deferred picker
        // close, the focus-landing re-assert) BEFORE the
        // close below — a dying host must never fire a
        // deferred close or landing into whatever surface
        // replaces it.
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        // Close the picker BEFORE killing the timers:
        // closePicker re-arms the hide timer via showControls,
        // and teardown must be the last word on timers.
        closePicker()
        uiTimer?.invalidate()
        uiTimer = nil
        hideTimer?.invalidate()
        hideTimer = nil
        layer?.delegate = nil
        layer?.stop()
        layer = nil
    }

    // MARK: - Remote clicks (Menu deliberately untouched)

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .select:
                showControls()
                // v2.0.34 (item 1, CONFIRMED by the owner's
                // 2.0.33 device log): ONE Select press was
                // reaching togglePlayPause() TWICE whenever
                // focus sat on the play/pause button — once
                // through the button's own
                // .primaryActionTriggered, once through this
                // branch — and the two toggles cancelled:
                // 15/15 dead presses in the log are
                // play→pause pairs 13–68 ms apart, all with
                // focused=playPauseButton, while presses with
                // focus anywhere else are single and work.
                // The same double delivery rode on every
                // picker pick (the pick plus a stray toggle).
                // Give Select exactly ONE consumer: when
                // focus is on one of the bar's own buttons,
                // the button's action is that consumer and
                // the host must not toggle. This is NOT a
                // debounce — the second delivery itself is
                // removed, not timed out. Select on
                // non-button surfaces keeps toggling here
                // (the log's focused=root press worked), and
                // .playPause below stays unconditional: no
                // button consumes that press type.
                if focusIsOnTransportButton() {
                    DiagLog.write("transport",
                                  "select owned by focused button focused=\(focusedViewName()) — host toggle skipped")
                } else {
                    togglePlayPause()
                }
                handled = true
            case .playPause:
                showControls()
                togglePlayPause()
                handled = true
            case .leftArrow:
                showControls()
                // v2.0.18: with focus inside the bar (or the
                // picker open), arrows belong to focus
                // movement; a press that still bubbles up to
                // the host is an edge-of-row press and must
                // never become a seek under the user's fingers.
                if pickerIsOpen || focusInControls { break }
                seekBy(-30)
                handled = true
            case .rightArrow:
                showControls()
                if pickerIsOpen || focusInControls { break }
                seekBy(30)
                handled = true
            case .menu:
                // v2.0.31 (L5): Menu is NOT handled here any
                // more, picker open or not — it propagates
                // to the shell's exit command, which asks the
                // director whether a picker is open: open →
                // the shell closes just the picker (through
                // this host's closePicker, registered with
                // the director); closed → the film exits, as
                // always. Pre-fix the host closed the picker
                // here AND the press still reached the shell
                // on the owner's set — one press, two
                // consumers — and the film exited behind the
                // closing panel (his subtitle-panel finding).
                break
            default:
                // Up/Down (and anything else) only wake the
                // bar; they are never swallowed, so the focus
                // engine still receives them and can move
                // focus into or out of the transport bar.
                showControls()
                break
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    /// v2.0.33 (item 1a): re-read the host's intent flag
    /// from the engine's own live playing state. The
    /// delegate syncs intentPlaying only on the named
    /// lifecycle events (.bufferFinished / .paused /
    /// .playedToTheEnd / .error), so any engine transition
    /// that arrives through the unnamed states — or a track
    /// selection, which churns the engine without a named
    /// event the host maps — can leave the shadow flag one
    /// step behind the engine, and the next toggle then
    /// commands the verb the engine is already in (the
    /// v2.0.32 dead-press shape, through the states the
    /// named sync does not cover). Callers re-sync at the
    /// exact points where that drift is produced: the
    /// unnamed delegate states, the head of .readyToPlay,
    /// and after a picker selection is performed.
    private func syncIntentFromEngine() {
        guard let layer else { return }
        intentPlaying = layer.player.isPlaying
    }

    /// v2.0.34 (item 1): the currently focused view in the
    /// host's subtree, or nil when nothing in it holds
    /// focus. Factored out of focusedViewName() (v2.0.33)
    /// so the pressesEnded Select guard and the transport
    /// log line read the SAME focus fact — the guard must
    /// judge the exact view the log names.
    private func focusedView() -> UIView? {
        func search(_ candidate: UIView) -> UIView? {
            if candidate.isFocused { return candidate }
            for subview in candidate.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return search(view)
    }

    /// v2.0.34 (item 1): true when focus sits on one of the
    /// transport bar's OWN buttons — play/pause, Phụ đề,
    /// Âm thanh, Đổi nguồn, or any picker row. Every one of
    /// them consumes Select itself through
    /// .primaryActionTriggered, so a Select the host ALSO
    /// answers is delivered twice (see pressesEnded).
    private func focusIsOnTransportButton() -> Bool {
        guard let focused = focusedView() else { return false }
        return focused === playPauseButton
            || focused === subtitleButton
            || focused === audioButton
            || focused === switchSourceButton
            || pickerButtons.contains(where: { $0 === focused })
    }

    /// v2.0.33 (item 1c): the name of the currently focused
    /// view, for the transport log line in togglePlayPause —
    /// the next device run must show WHERE focus actually
    /// sat when a press landed, not where it was supposed
    /// to sit. Names the known controls; anything else
    /// falls back to its class name, and "none" when
    /// nothing in the subtree holds focus (the dead-press
    /// signature itself).
    private func focusedViewName() -> String {
        guard let candidate = focusedView() else { return "none" }
        if candidate === playPauseButton { return "playPauseButton" }
        if candidate === seekBar { return "seekBar" }
        if candidate === subtitleButton { return "subtitleButton" }
        if candidate === audioButton { return "audioButton" }
        if candidate === switchSourceButton { return "switchSourceButton" }
        if pickerButtons.contains(where: { $0 === candidate }) {
            return "pickerButton"
        }
        if candidate === view { return "root" }
        return String(describing: type(of: candidate))
    }

    private func togglePlayPause() {
        guard let layer else { return }
        // v2.0.33 (item 1c): the entry evidence, written
        // BEFORE any command is sent — which view held
        // focus, what the intent flag read, what the engine
        // itself reported, and the layer's lifecycle state.
        // A dead press on the next device run separates
        // into its cause from this one line: focus nowhere
        // ("none"), intent drifted from the engine (intent
        // ≠ enginePlaying), or the command was right and
        // the engine ignored it (see the outcome line).
        // Hosts and names only — never a URL.
        DiagLog.write("transport",
                      "toggle entry focused=\(focusedViewName()) intentBefore=\(intentPlaying) enginePlaying=\(layer.player.isPlaying) state=\(String(describing: layer.state))")
        // v2.0.32: command from the host's intent flag, not
        // from the layer's lifecycle state (see intentPlaying).
        if intentPlaying {
            layer.pause()
            intentPlaying = false
        } else {
            layer.play()
            intentPlaying = true
        }
        // v2.0.33 (item 1c): the outcome — the verb actually
        // commanded, and the intent flag as it now stands.
        DiagLog.write("transport",
                      "toggle outcome command=\(intentPlaying ? "play" : "pause") intentAfter=\(intentPlaying)")
        refreshTransport()
    }

    /// v2.0.35 (seek logging, DIAG-2034 (g)): one-decimal
    /// seconds for the seek log lines; a non-finite read
    /// (a layer with no clock yet) logs as 0.0 rather
    /// than "nan". Twin of PlayDirector's helper — the
    /// two hosts each format their own lines.
    private static func seekLogSeconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value.isFinite ? value : 0)
    }

    private func seekBy(_ delta: TimeInterval) {
        guard let layer else { return }
        let from = layer.player.currentPlaybackTime
        let target = max(0, from + delta)
        // v2.0.35 (seek logging, DIAG-2034 (g)): every
        // app-executed seek leaves one line — engine,
        // from-position, to-position, in seconds — so the
        // next export can place a seek immediately before
        // any freeze/fail line that follows it (the
        // owner's "tua nhanh là đứt" report is unprovable
        // from a log with no seek lines). Positions only,
        // never a URL. This is the user-seek site: the
        // remote Left/Right steps and the seek bar's steps
        // both funnel through here. (KSPlayerLayer's own
        // media-command seeks are library-internal and
        // pass no app code.)
        DiagLog.write("play", "seek engine=ffmpeg from=\(Self.seekLogSeconds(from)) to=\(Self.seekLogSeconds(target))")
        layer.seek(time: target, autoPlay: true) { _ in }
        intentPlaying = true
        refreshTransport()
    }

    // MARK: - Transport bar: build & layout

    private func buildControls() {
        guard !controlsBuilt else { return }
        controlsBuilt = true
        controlsView.frame = view.bounds
        controlsView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controlsView.isHidden = true
        view.addSubview(controlsView)

        transportBar.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        transportBar.layer.cornerRadius = 24
        controlsView.addSubview(transportBar)

        // v2.0.30 (FIX6, the owner's close-ups): the plate
        // lives in the button's CONFIGURATION, not in a
        // hand-set backgroundColor + layer radius. A .system
        // button draws its OWN focus platter over a hand
        // plate, at the system's size, radius and offset —
        // the two rounded rects rendered doubled and
        // ghosted on every bar control in the owner's
        // photos. With the plate inside the configuration,
        // the system renders ONE plate in both states. See
        // transportButtonConfiguration.
        playPauseButton.configuration = Self.transportButtonConfiguration(
            font: nil, backgroundAlpha: 0.14, cornerRadius: 14,
            contentInsets: .zero)
        playPauseButton.configurationUpdateHandler = Self.transportFocusHandler
        playPauseButton.setImage(Self.transportSymbol("play.fill"), for: .normal)
        playPauseButton.addTarget(self, action: #selector(playPauseButtonTapped),
                                  for: .primaryActionTriggered)
        transportBar.addSubview(playPauseButton)

        bufferingSpinner.color = .white
        bufferingSpinner.hidesWhenStopped = true
        transportBar.addSubview(bufferingSpinner)

        styleTransportButton(subtitleButton, title: "Phụ đề: Tắt")
        subtitleButton.addTarget(self, action: #selector(subtitleButtonTapped),
                                 for: .primaryActionTriggered)
        transportBar.addSubview(subtitleButton)
        styleTransportButton(audioButton, title: "Âm thanh")
        audioButton.addTarget(self, action: #selector(audioButtonTapped),
                              for: .primaryActionTriggered)
        transportBar.addSubview(audioButton)

        // FIX4 (fix 4): same dress as the track buttons,
        // same right-hand cluster (laid out in
        // layoutControls, left of Phụ đề).
        styleTransportButton(switchSourceButton, title: "Đổi nguồn")
        switchSourceButton.addTarget(self, action: #selector(switchSourceButtonTapped),
                                     for: .primaryActionTriggered)
        transportBar.addSubview(switchSourceButton)

        for label in [currentTimeLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 25, weight: .medium)
            label.textColor = .white
            label.text = "0:00"
            transportBar.addSubview(label)
        }
        durationLabel.textAlignment = .right

        seekBar.backgroundColor = .clear
        seekBar.onStep = { [weak self] delta in
            self?.showControls()
            self?.seekBy(delta)
        }
        seekBar.onTogglePlayPause = { [weak self] in
            self?.showControls()
            self?.togglePlayPause()
        }
        transportBar.addSubview(seekBar)

        // v2.0.33 (item 5): the seek bar's focus guide,
        // owned by the bar itself. Its strip is pinned in
        // layoutControls (below the play button); any focus
        // movement that lands on the strip is redirected to
        // the seek bar through the guide's preferred focus
        // environment — the kit's own machinery for a focus
        // gap, instead of any hand-drawn geometry.
        transportBar.addLayoutGuide(seekFocusGuide)
        seekFocusGuide.preferredFocusEnvironments = [seekBar]

        pickerView.backgroundColor = UIColor.black.withAlphaComponent(0.88)
        pickerView.layer.cornerRadius = 20
        pickerView.isHidden = true
        controlsView.addSubview(pickerView)
        pickerTitleLabel.font = .systemFont(ofSize: 29, weight: .bold)
        pickerTitleLabel.textColor = .white
        pickerView.addSubview(pickerTitleLabel)

        layoutControls()
    }

    /// Standard tvOS button dress (v2.0.30, FIX6 — the
    /// house doctrine applied literally): white text on a
    /// quiet plate, and the plate lives INSIDE the button's
    /// configuration so the system renders exactly one
    /// plate in both states. Pre-fix this painted a hand
    /// plate (backgroundColor + layer.cornerRadius) on a
    /// .system button, and tvOS drew its own focus platter
    /// over it at the system's geometry — the doubled,
    /// offset ghost outlines in the owner's close-ups of
    /// the Phụ đề / Âm thanh pills. Resting values are
    /// unchanged (white 0.14 plate, radius 14, white 25
    /// semibold, insets 10×22); the focused title still
    /// goes dark, via the configuration update handler —
    /// a state title colour would be overridden by the
    /// configuration the system actually renders.
    private func styleTransportButton(_ button: UIButton, title: String) {
        button.configuration = Self.transportButtonConfiguration(
            title: title,
            font: .systemFont(ofSize: 25, weight: .semibold),
            backgroundAlpha: 0.14, cornerRadius: 14,
            contentInsets: NSDirectionalEdgeInsets(top: 10, leading: 22,
                                                   bottom: 10, trailing: 22))
        button.configurationUpdateHandler = Self.transportFocusHandler
    }

    /// v2.0.30 (FIX6): the one-plate configuration shared
    /// by every bar and picker button — the resting dress
    /// (translucent plate at the standing radius, white
    /// foreground, the title's font carried by the text
    /// attributes transformer so later setTitle-shaped
    /// updates keep it). The system renders its focused
    /// face from THIS background, so no second plate can
    /// appear.
    private static func transportButtonConfiguration(
        title: String? = nil,
        font: UIFont?,
        backgroundAlpha: CGFloat,
        cornerRadius: CGFloat,
        contentInsets: NSDirectionalEdgeInsets
    ) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.background.backgroundColor =
            UIColor.white.withAlphaComponent(backgroundAlpha)
        config.background.cornerRadius = cornerRadius
        config.contentInsets = contentInsets
        if let font {
            config.titleTextAttributesTransformer =
                UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.font = font
                    return outgoing
                }
        }
        return config
    }

    /// The focused-foreground flip shared by every bar and
    /// picker button (v2.0.30): the system's focused face
    /// is light, so the title/glyph goes dark on it — the
    /// intent the pre-fix setTitleColor(.black, for:
    /// .focused) expressed, moved into the configuration.
    private static let transportFocusHandler:
        UIButton.ConfigurationUpdateHandler = { button in
            guard var config = button.configuration else { return }
            config.baseForegroundColor =
                button.state.contains(.focused) ? .black : .white
            button.configuration = config
        }

    /// Title writes for the configured buttons (v2.0.30):
    /// the title lives in the configuration now, so the
    /// live re-titles (the selected track's name after
    /// readyToPlay, after every picker selection) write
    /// through it directly instead of relying on the
    /// legacy setter's bridging.
    private func setConfiguredTitle(_ button: UIButton, _ title: String) {
        if var config = button.configuration {
            config.title = title
            button.configuration = config
        } else {
            button.setTitle(title, for: .normal)
        }
    }

    /// v2.0.30 (FIX6): a subtitle whose name is a bare ISO
    /// language code ("spa" in the owner's close-up) reads
    /// as the language's own Vietnamese name instead — the
    /// code alone told him nothing. Only a whole-string
    /// 2–3 letter code that Locale recognises is mapped
    /// ("sdh" excluded: it is a real code — Southern
    /// Kurdish — but on subtitle tracks it overwhelmingly
    /// means SDH captions); any real name ("Vietsub", a
    /// file's own label) passes through untouched.
    private static func friendlyTrackName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard (2...3).contains(trimmed.count),
              trimmed.allSatisfy({ $0.isLetter }),
              trimmed.lowercased() != "sdh",
              let name = Locale(identifier: "vi_VN")
                .localizedString(forLanguageCode: trimmed.lowercased())
        else { return raw }
        return name
    }

    /// Frame layout, in the file's frame-based contract (the
    /// player surface is frame-sized too; no Auto Layout
    /// anywhere in this host). Recomputed on every layout
    /// pass, so the bar tracks the real bounds like the
    /// player view does.
    private func layoutControls() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        controlsView.frame = bounds
        let inset = max(view.safeAreaInsets.left, 48)
        let barWidth = bounds.width - inset * 2
        let barHeight: CGFloat = 168
        let barY = bounds.height - max(view.safeAreaInsets.bottom, 36) - barHeight
        transportBar.frame = CGRect(x: inset, y: barY, width: barWidth, height: barHeight)

        playPauseButton.frame = CGRect(x: 24, y: 12, width: 104, height: 64)
        bufferingSpinner.frame = CGRect(x: 144, y: 34, width: 20, height: 20)

        // Track buttons hug the right edge, sized to their
        // current titles (set by refreshTrackButtons).
        subtitleButton.sizeToFit()
        audioButton.sizeToFit()
        let audioW = audioButton.isHidden ? 0 : max(audioButton.frame.width, 170)
        let subW = subtitleButton.isHidden ? 0 : max(subtitleButton.frame.width, 190)
        if !audioButton.isHidden {
            audioButton.frame = CGRect(x: barWidth - 24 - audioW, y: 12,
                                       width: audioW, height: 64)
        }
        if !subtitleButton.isHidden {
            subtitleButton.frame = CGRect(x: barWidth - 24 - audioW - (audioW > 0 ? 16 : 0) - subW,
                                          y: 12, width: subW, height: 64)
        }
        // FIX4 (fix 4): Đổi nguồn closes the right cluster
        // on the left — its offset walks past whichever
        // track buttons are visible (their widths are 0
        // while hidden, and the gaps follow the same rule
        // as the subtitle button's own math above).
        let switchW: CGFloat = 190
        switchSourceButton.frame = CGRect(
            x: barWidth - 24 - audioW - (audioW > 0 ? 16 : 0)
               - subW - (subW > 0 ? 16 : 0) - switchW,
            y: 12, width: switchW, height: 64)

        currentTimeLabel.frame = CGRect(x: 24, y: 94, width: 150, height: 48)
        durationLabel.frame = CGRect(x: barWidth - 24 - 150, y: 94, width: 150, height: 48)
        let seekX: CGFloat = 24 + 150 + 20
        seekBar.frame = CGRect(x: seekX, y: 94,
                               width: barWidth - seekX - 150 - 24 - 20, height: 48)
        // v2.0.33 (item 5): pin the seek focus guide to the
        // strip directly below the play button — the rect
        // (x 24, y 76, width 104, height barHeight − 76) in
        // transportBar coordinates. WHY: the play button
        // spans x 24…128, y 12…76, while the seek bar starts
        // at x 194 — the two share no vertical strip, and
        // the only view below the play button (the
        // current-time label) is not focusable, so the focus
        // engine found NO Down target from play/pause at
        // all. The guide sits in that Down path and
        // redirects the landing to the seek bar. Its strip
        // is confined to the play button's own x-range on
        // purpose: it must NOT extend under the other bar
        // buttons (their strips already overlap the seek
        // bar, so Down from them reaches it unaided, and a
        // wider guide could only compete with that), and it
        // must NOT cover the seek bar's own x-range (from
        // x 194 on), so an Up press from the seek bar is
        // never trapped back into the guide that just sent
        // focus down. The guide is inert whenever the bar
        // is not on screen: it is owned by transportBar,
        // which showPickerPanel hides while a picker
        // replaces it (closePicker unhides it), and its
        // container controlsView is hidden whenever the bar
        // itself hides (hideControlsIfIdle) — a guide in a
        // hidden subtree takes no part in focus movement.
        // NOTE on form: UILayoutGuide.layoutFrame is
        // read-only (it is the layout engine's OUTPUT), so
        // the strip cannot be assigned as a frame the way
        // the bar's views are; it is pinned with four
        // constraints whose constants ARE that rect, which
        // makes the guide's resulting layoutFrame exactly
        // the prescribed strip. The constants never change,
        // so the pin is installed once.
        if !seekFocusGuidePinned {
            seekFocusGuidePinned = true
            NSLayoutConstraint.activate([
                seekFocusGuide.leadingAnchor.constraint(
                    equalTo: transportBar.leadingAnchor, constant: 24),
                seekFocusGuide.topAnchor.constraint(
                    equalTo: transportBar.topAnchor, constant: 76),
                seekFocusGuide.widthAnchor.constraint(equalToConstant: 104),
                seekFocusGuide.heightAnchor.constraint(
                    equalToConstant: barHeight - 76),
            ])
        }
        if pickerIsOpen {
            layoutPicker()
        }
    }

    private func layoutPicker() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let panelW = min(780, bounds.width - 120)
        // Rows compress on tall slates (a REMUX can carry a
        // dozen subtitle tracks): the panel must never grow
        // past the screen, or its lower rows — and their
        // focus — would live off-screen.
        let count = max(pickerButtons.count, 1)
        let maxPanelH = bounds.height - 80
        let rowH = min(66, (maxPanelH - 108) / CGFloat(count))
        let panelH = 108 + CGFloat(pickerButtons.count) * rowH
        pickerView.frame = CGRect(x: (bounds.width - panelW) / 2,
                                  y: (bounds.height - panelH) / 2,
                                  width: panelW, height: panelH)
        pickerTitleLabel.frame = CGRect(x: 32, y: 24, width: panelW - 64, height: 44)
        for (index, button) in pickerButtons.enumerated() {
            button.frame = CGRect(x: 32, y: 92 + CGFloat(index) * rowH,
                                  width: panelW - 64, height: rowH - 8)
        }
    }

    // MARK: - Transport bar: show / hide

    /// v2.0.18: flip the root view's focus eligibility and
    /// ask for the update that relocates focus accordingly —
    /// into the bar when it wakes (the host's preferred
    /// environment is the play button), back to the root when
    /// the bar hides (the preferred environment is the root).
    private func setRootAcceptsFocus(_ on: Bool) {
        guard let root = view as? KSPlayerHostRootView,
              root.acceptsFocus != on else { return }
        root.acceptsFocus = on
        setNeedsFocusUpdate()
    }

    private func showControls() {
        guard controlsBuilt else { return }
        // v2.0.18: the bar being up means the root must not
        // hold focus (see KSPlayerHostRootView.acceptsFocus).
        setRootAcceptsFocus(false)
        // v2.0.29 (item 2): the shell's status capsule is
        // bound to the bar through the director — the bar
        // waking wakes the capsule (source label / resume
        // line) with it, and only with it.
        director?.setTransportBarVisible(true)
        if !controlsVisible {
            controlsVisible = true
            controlsView.isHidden = false
            refreshTransport()
            // v2.0.17: the bar waking is the moment focus moves
            // into it (onto the play button, per
            // preferredFocusEnvironments) — but only when focus
            // is not already inside the bar or the picker, so a
            // press that merely re-arms the hide timer never
            // yanks the user's place.
            if !focusInControls, !pickerIsOpen {
                setNeedsFocusUpdate()
            }
        }
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.hideControlsIfIdle()
        }
    }

    /// The system bar's contract: it fades only while the
    /// picture is actually playing, never while paused, and
    /// never under an open picker. FIX4 (fix 5): "never while
    /// the user is standing inside it" is GONE — standing in
    /// the bar is the bar's normal state (focus moves in when
    /// it wakes), so that clause vetoed every hide and the
    /// bar stayed on screen forever (owner finding on
    /// 2.0.27). Idleness is now measured by the timer alone:
    /// every show and every focus move inside the bar re-arms
    /// it, and when it fires the bar hides and focus returns
    /// to the root (setRootAcceptsFocus below).
    private func hideControlsIfIdle() {
        guard controlsVisible, !pickerIsOpen, let layer else { return }
        guard layer.player.isPlaying else {
            // v2.0.29 (item 2, the Billboard single-source
            // case): the pre-fix guard simply returned, and
            // NOTHING ever re-armed the timer — one veto at
            // the fire instant (the engine momentarily not
            // reporting its playing state: a slow first
            // buffer, a rebuffer dip) retired the hide
            // mechanism for the rest of the session, and the
            // bar stayed on screen forever. The veto now
            // re-arms the idle timer and the decision is
            // retried on the next cycle. The paused contract
            // is unchanged — the bar still never hides while
            // the engine is not playing; it merely keeps
            // checking instead of giving up after one check.
            scheduleControlsHide()
            return
        }
        controlsVisible = false
        controlsView.isHidden = true
        // v2.0.29 (item 2): the capsule hides WITH the bar —
        // the same director flag the AVPlayer path's
        // delegate callback drives.
        director?.setTransportBarVisible(false)
        // v2.0.18: the bar is gone — the root takes focus back.
        setRootAcceptsFocus(true)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView else { return }
        focusInControls = next.isDescendant(of: controlsView)
        if focusInControls {
            controlsVisible = true
            controlsView.isHidden = false
            // v2.0.29 (item 2): focus resurrecting the bar
            // resurrects the capsule with it.
            director?.setTransportBarVisible(true)
            // FIX4 (fix 5): a focus move inside the bar is
            // activity — restart the idle clock instead of
            // cancelling it. The pre-fix invalidate here,
            // combined with showControls moving focus into
            // the bar, meant the hide timer was cancelled the
            // moment the bar appeared and could never fire.
            scheduleControlsHide()
        }
    }

    // MARK: - Transport bar: state

    private func refreshTransport() {
        guard controlsBuilt, let layer else { return }
        let cur = layer.player.currentPlaybackTime
        let dur = layer.player.duration
        currentTimeLabel.text = Self.clockText(cur)
        durationLabel.text = (dur.isFinite && dur > 0) ? Self.clockText(dur) : "--:--"
        if dur.isFinite, dur > 0, cur.isFinite {
            seekBar.fraction = max(0, min(1, cur / dur))
        } else {
            seekBar.fraction = 0
        }
        seekBar.setNeedsDisplay()
        playPauseButton.setImage(
            Self.transportSymbol(intentPlaying ? "pause.fill" : "play.fill"),
            for: .normal)
        if !ready || layer.state == .buffering {
            bufferingSpinner.startAnimating()
        } else {
            bufferingSpinner.stopAnimating()
        }
    }

    /// The play/pause glyph at a size the focused platter
    /// cannot swallow (v2.0.17): the bare system symbol
    /// renders at its small default point size inside the
    /// button, and the owner's close-up showed the focused
    /// plate huge with the glyph invisible inside it.
    private static func transportSymbol(_ name: String) -> UIImage? {
        UIImage(systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .bold))
    }

    private static func clockText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        return WatchStore.fmtClock(Int64(seconds * 1000))
    }

    /// Sizes and labels the two track buttons from the LIVE
    /// lists. Called at readyToPlay and after every selection:
    /// the audio button exists only when the file carries a
    /// choice (≥2 tracks, the system player's rule), the
    /// subtitle button only when the host's subtitle model
    /// holds at least one embedded info.
    private func refreshTrackButtons() {
        guard controlsBuilt, let layer else { return }
        let audioTracks = layer.player.tracks(mediaType: .audio)
        audioButton.isHidden = audioTracks.count < 2
        if let current = audioTracks.first(where: { $0.isEnabled }) {
            setConfiguredTitle(audioButton, "Âm thanh: \(Self.trackLabel(current))")
        } else {
            setConfiguredTitle(audioButton, "Âm thanh")
        }
        prepareSubtitleModel(layer: layer)
        subtitleButton.isHidden = layer.subtitleModel.subtitleInfos.isEmpty
        if let selected = layer.subtitleModel.selectedSubtitleInfo {
            // v2.0.30 (FIX6): a bare language code reads as
            // the language's name (see friendlyTrackName).
            setConfiguredTitle(subtitleButton,
                               "Phụ đề: \(Self.friendlyTrackName(selected.name))")
        } else {
            setConfiguredTitle(subtitleButton, "Phụ đề: Tắt")
        }
        layoutControls()
    }

    /// Feeds the host's SubtitleModel from the player's own
    /// subtitle data source — the library's readyToPlay
    /// pattern, verbatim in shape (VideoPlayerView and
    /// KSVideoPlayer.Coordinator both do exactly this): the
    /// feed is delayed 1 s because embedded subtitles carried
    /// inside the video stream can land after readyToPlay,
    /// and the default-enabled embed is auto-selected when
    /// the options ask for it (KSOptions' default is yes).
    /// A player with no source (the AVPlayer engine returns
    /// nil) simply never feeds, and the button stays hidden.
    ///
    /// v2.0.16: the session's side-loaded subtitle (the
    /// candidate's subtitleURL) is fed in the same pass and
    /// SELECTED — the Android player's auto-attach mirrored.
    /// Pre-fix the model only ever saw embedded tracks, so a
    /// file whose only subtitle was "default eng" offered no
    /// Vietnamese choice even though the app had already
    /// fetched one (the owner's Dune: Part Two clip). The
    /// feed no longer requires an embedded source at all: a
    /// file with no embedded subtitles still receives the
    /// side-loaded one. The picker lists it beside the
    /// embeds, and the owner can still switch or turn
    /// subtitles off.
    private func prepareSubtitleModel(layer: KSPlayerLayer) {
        let playerID = ObjectIdentifier(layer.player as AnyObject)
        guard subtitleFedPlayerID != playerID else { return }
        // KSPlayer 5.6.2: the property lost 2.3.4's misspelt
        // name (subtitleDataSouce) and its type is the
        // ConstantSubtitleDataSource protocol.
        let dataSource = layer.player.subtitleDataSource
        let externalURL = externalSubtitleURL
        guard dataSource != nil || externalURL != nil else { return }
        subtitleFedPlayerID = playerID
        // Swift 6 specialist-review fix (B-2): the 1 s
        // delayed feed is a weak Task with a sleep (the
        // house delayed form, JoeStores), not a GCD
        // asyncAfter — the closure touches this host's
        // @MainActor state, which a nonisolated @Sendable
        // GCD closure may not do. Delay unchanged.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled,
                  let layer = self.layer,
                  ObjectIdentifier(layer.player as AnyObject) == playerID
            else { return }
            let model = layer.subtitleModel
            if let dataSource {
                model.addSubtitle(dataSource: dataSource)
                // The owner's standing defaults (2026-11-17):
                // subtitle starts Vietnamese when the file
                // carries one, else English, else the file's
                // own default-flagged track; the side-loaded
                // Vietnamese below still outranks every embed,
                // and the picker stays free for any manual
                // choice. Skipped while the picker is open, so
                // a late feed can never override a choice the
                // owner is making. Selection goes through the
                // layer (5.6.2's canonical path — the library's
                // own VideoPlayerView selects exactly this
                // way); the model only carries the state.
                if model.selectedSubtitleInfo == nil,
                   !self.pickerIsOpen {
                    let infos = model.subtitleInfos
                    let pick = infos.first { Self.isVietnameseSubtitle($0) }
                        ?? infos.first { Self.isEnglishSubtitle($0) }
                        ?? (layer.options.autoSelectEmbedSubtitle
                            ? infos.first {
                                // 5.6.2's SubtitleInfo has no
                                // isEnabled; the embedded infos
                                // ARE FFmpegAssetTracks, whose
                                // MediaPlayerTrack.isEnabled is
                                // the default-flagged marker this
                                // read always meant.
                                ($0 as? FFmpegAssetTrack)?.isEnabled ?? false
                            } : nil)
                    if let pick {
                        layer.select(subtitleInfo: pick)
                    }
                }
            }
            if let externalURL {
                let info = URLSubtitleInfo(
                    subtitleID: "joetv-external-vi",
                    name: "Tiếng Việt",
                    url: externalURL,
                    userAgent: JoeHTTP.userAgent)
                model.addSubtitle(
                    dataSource: JoeExternalSubtitleDataSource(info: info))
                layer.select(subtitleInfo: info)
            }
            self.refreshTrackButtons()
        }
    }

    /// Language sniffing for the default-track rules: the
    /// engine's names are inconsistent across sources (ISO
    /// codes like "vie"/"eng", full words, the side-load's
    /// "Tiếng Việt"), so matching is by word token over the
    /// name + id, never by substring.
    private static func subtitleTokens(_ info: any SubtitleInfo) -> Set<String> {
        let raw = (info.name + " " + info.subtitleID).lowercased()
        return Set(raw.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func isVietnameseSubtitle(_ info: any SubtitleInfo) -> Bool {
        let t = subtitleTokens(info)
        return t.contains("vie") || t.contains("vi") || t.contains("viet")
            || t.contains("việt") || t.contains("vietnamese")
    }

    private static func isEnglishSubtitle(_ info: any SubtitleInfo) -> Bool {
        let t = subtitleTokens(info)
        return t.contains("eng") || t.contains("en") || t.contains("english")
    }

    private static func isEnglishAudio(_ track: any MediaPlayerTrack) -> Bool {
        let raw = ((track.languageCode ?? "") + " " + track.name).lowercased()
        let tokens = Set(raw.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return tokens.contains("eng") || tokens.contains("en")
            || tokens.contains("english")
    }

    /// The audio half of the owner's defaults (2026-11-17):
    /// when a file offers a choice and its default track is
    /// not English while an English track exists, start in
    /// English (his Dune stream opened on the file's Spanish
    /// default). Once per player instance, at readyToPlay —
    /// a manual pick in the picker is never overridden,
    /// because this runs before any pick can exist and never
    /// again for the same player.
    private var audioDefaultPlayerID: ObjectIdentifier?
    private func applyDefaultAudio(layer: KSPlayerLayer) {
        let playerID = ObjectIdentifier(layer.player as AnyObject)
        guard audioDefaultPlayerID != playerID else { return }
        audioDefaultPlayerID = playerID
        let tracks = layer.player.tracks(mediaType: .audio)
        guard tracks.count >= 2,
              let current = tracks.first(where: { $0.isEnabled }),
              !Self.isEnglishAudio(current),
              let english = tracks.first(where: { Self.isEnglishAudio($0) })
        else { return }
        if let mePlayer = layer.player as? KSMEPlayer,
           let concrete = english as? FFmpegAssetTrack {
            mePlayer.select(track: concrete)
        } else {
            for track in tracks {
                track.isEnabled = track === english
            }
        }
    }

    // v2.0.32 (KSPlayer 5.6.2): the host's subtitle paint
    // machinery that stood here (buildSubtitleViewsIfNeeded /
    // layoutSubtitleViews / startSubtitleTimerIfNeeded /
    // updateSubtitles — a 0.25 s timer pulling the model's
    // parts into a hand-built label/image pair) is DELETED,
    // not adapted: 5.6.2's layer renders subtitles itself
    // through its own MetalSubtitleView driven by its own
    // subtitleModel (none of the library's three player
    // views inserts or paints anything), and 5.6.2's
    // SubtitlePart carries no UIImage for a host to paint
    // (image parts are raw bitmap sources for the Metal
    // renderer; the model's pull API also changed shape —
    // subtitle(currentTime:playRatio:screenSize:) -> Void).
    // See the subtitleModel note at the top of this class.

    /// v2.0.29 (item 3): a candidate label flattened for a
    /// one-line picker row — Torrentio/MF stream names are
    /// multi-line (a source line, a quality line), and the
    /// picker rows are single-line, so the lines join with
    /// " · " instead of truncating at the first break.
    /// Display only; the candidate's own label is unchanged
    /// everywhere else (the status capsule shows it whole).
    private static func flattenedSourceLabel(_ label: String) -> String {
        label.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private static func trackLabel(_ track: any MediaPlayerTrack) -> String {
        var parts: [String] = []
        // KSPlayer 5.6.2: the track's language is
        // `languageCode` (2.3.4's `language` is gone).
        if let language = track.languageCode, !language.isEmpty {
            parts.append(language)
        }
        if !track.name.isEmpty {
            parts.append(track.name)
        }
        return parts.isEmpty ? "Track \(track.trackID)" : parts.joined(separator: " - ")
    }

    // MARK: - Transport bar: actions & track picker

    @objc private func playPauseButtonTapped() {
        showControls()
        togglePlayPause()
    }

    @objc private func subtitleButtonTapped() {
        openPicker(kind: .subtitles)
    }

    @objc private func audioButtonTapped() {
        openPicker(kind: .audio)
    }

    @objc private func switchSourceButtonTapped() {
        // v2.0.29 (item 3): the button now OPENS THE SOURCE
        // CHOOSER — the same picker panel the subtitle/audio
        // buttons open, listing the session's candidates —
        // instead of the FIX4 behaviour of blindly advancing
        // to the next candidate (owner finding on 2.0.28:
        // "bấm là nó tự lấy một nguồn khác, không hiện danh
        // sách cho chọn"; manual selection is his standing
        // rule). The pick itself goes through
        // PlayDirector.userSwitchSource(to:) — see
        // pickerButtonTapped's .sources case. The bar is
        // woken first so the press registers as activity.
        showControls()
        openPicker(kind: .sources)
    }

    private func openPicker(kind: PickerKind) {
        // v2.0.29 (item 3): the source chooser's rows come
        // from the director's ladder, not the engine, so it
        // is not held to the track pickers' ready + layer
        // guard below — their rows ARE the engine's live
        // lists, its rows exist from the session's start.
        if kind == .sources {
            openSourceChooser()
            return
        }
        guard ready, let layer else { return }
        pickerKind = kind
        for button in pickerButtons { button.removeFromSuperview() }
        pickerButtons.removeAll()
        switch kind {
        case .subtitles:
            pickerTitleLabel.text = "Phụ đề"
            pickerSubtitleInfos = layer.subtitleModel.subtitleInfos
            pickerAudioTracks = []
            pickerSourceLabels = []
            pickerSourceIndex = -1
            addPickerButton(title: "Tắt", checked: layer.subtitleModel.selectedSubtitleInfo == nil, tag: -1)
            for (index, info) in pickerSubtitleInfos.enumerated() {
                let checked = layer.subtitleModel.selectedSubtitleInfo?.subtitleID == info.subtitleID
                addPickerButton(title: info.name.isEmpty ? "Phụ đề \(index + 1)" : Self.friendlyTrackName(info.name),
                                checked: checked, tag: index)
            }
        case .audio:
            pickerTitleLabel.text = "Âm thanh"
            pickerAudioTracks = layer.player.tracks(mediaType: .audio)
            pickerSubtitleInfos = []
            pickerSourceLabels = []
            pickerSourceIndex = -1
            for (index, track) in pickerAudioTracks.enumerated() {
                addPickerButton(title: Self.trackLabel(track),
                                checked: track.isEnabled, tag: index)
            }
        case .sources:
            // Unreachable — routed to openSourceChooser()
            // above; the case exists so the switch stays
            // exhaustive over PickerKind.
            break
        }
        showPickerPanel()
    }

    /// v2.0.29 (item 3): the "Đổi nguồn" chooser — the
    /// session's candidate list in the host's standing
    /// picker panel: one row per candidate in the current
    /// ladder, the candidate's own label (flattened to one
    /// line), the current candidate checked, focus landing
    /// on the current row (preferredFocusEnvironments).
    /// Picking a row switches through
    /// PlayDirector.userSwitchSource(to:) — the position
    /// is kept by the standing itemReady resume rule, the
    /// same machinery the old blind advance used.
    private func openSourceChooser() {
        guard let director else { return }
        pickerKind = .sources
        for button in pickerButtons { button.removeFromSuperview() }
        pickerButtons.removeAll()
        pickerTitleLabel.text = "Chọn nguồn"
        let choices = director.sourceChoices
        pickerSourceLabels = choices
        pickerSubtitleInfos = []
        pickerAudioTracks = []
        pickerSourceIndex = choices.first(where: { $0.isCurrent })?.index ?? -1
        for choice in choices {
            addPickerButton(title: Self.flattenedSourceLabel(choice.label),
                            checked: choice.isCurrent, tag: choice.index)
        }
        showPickerPanel()
    }

    /// The picker tail shared by every kind (extracted in
    /// v2.0.29 from openPicker, byte-identical in effect):
    /// the panel replaces the bar, the hide timer stands
    /// down while a choice is open, focus moves to the
    /// picker's preferred landing.
    private func showPickerPanel() {
        guard !pickerButtons.isEmpty else { return }
        pickerIsOpen = true
        pickerView.isHidden = false
        transportBar.isHidden = true
        controlsVisible = true
        controlsView.isHidden = false
        // v2.0.29 (item 2): the picker is summoned chrome —
        // the status capsule stays with the chrome while a
        // choice is open, like it does with the bar.
        director?.setTransportBarVisible(true)
        // v2.0.31 (L5): the shell's exit command owns Menu
        // now — register this host's close so its first
        // press closes just this panel (see PlayDirector
        // .pickerOpen). Registered on every opening; the
        // matching clear rides closePicker.
        director?.setPickerOpen(true) { [weak self] in
            self?.closePicker()
        }
        hideTimer?.invalidate()
        layoutPicker()
        setNeedsFocusUpdate()
        // v2.0.31 (L4/L5): force the landing NOW — the
        // picker's first row must actually hold focus when
        // the panel is up, not whenever the engine gets to
        // the pending update: a panel whose rows never took
        // focus is the panel whose presses go nowhere.
        updateFocusIfNeeded()
    }

    private func addPickerButton(title: String, checked: Bool, tag: Int) {
        let button = UIButton(type: .system)
        button.tag = tag
        // v2.0.30 (FIX6): same one-plate configuration as
        // the bar buttons — the pre-fix hand plate (white
        // 0.10 + layer radius 12) doubled with the system's
        // focus platter here too. Resting values unchanged
        // (27 medium, insets 8×20, left-aligned).
        button.configuration = Self.transportButtonConfiguration(
            title: (checked ? "✓   " : "      ") + title,
            font: .systemFont(ofSize: 27, weight: .medium),
            backgroundAlpha: 0.10, cornerRadius: 12,
            contentInsets: NSDirectionalEdgeInsets(top: 8, leading: 20,
                                                   bottom: 8, trailing: 20))
        button.configurationUpdateHandler = Self.transportFocusHandler
        button.contentHorizontalAlignment = .left
        button.addTarget(self, action: #selector(pickerButtonTapped(_:)),
                         for: .primaryActionTriggered)
        pickerView.addSubview(button)
        pickerButtons.append(button)
    }

    @objc private func pickerButtonTapped(_ sender: UIButton) {
        guard let layer else {
            closePicker()
            return
        }
        // v2.0.33 (item 1c): the pick itself, logged before
        // it is performed — the picker kind and the row's
        // tag only (for subtitles the tag IS the choice:
        // −1 = off, otherwise the track's index; for
        // sources it is the candidate's ladder index).
        // Track NAMES are never logged: an index is all the
        // evidence a selection dispute needs, and a name
        // could carry anything a file chose to embed.
        DiagLog.write("transport",
                      "picker pick kind=\(pickerKind) tag=\(sender.tag)")
        switch pickerKind {
        case .subtitles:
            // KSPlayer 5.6.2: selection is PERFORMED through
            // the layer (the library's own views select this
            // way; the layer keeps its model's
            // selectedSubtitleInfo in step) — writing the
            // model's property directly, the 2.3.4 way, no
            // longer reaches the layer's renderer.
            if sender.tag < 0 {
                layer.select(subtitleInfo: nil)
            } else if pickerSubtitleInfos.indices.contains(sender.tag) {
                layer.select(subtitleInfo: pickerSubtitleInfos[sender.tag])
            }
        case .audio:
            if pickerAudioTracks.indices.contains(sender.tag) {
                // KSPlayer 2.3.4's select(track:) takes an opaque
                // `some MediaPlayerTrack` — an existential straight
                // out of the picker array cannot satisfy it (that
                // was CI run #39's only error). Hand it the concrete
                // track the FFmpeg engine vends, via the concrete
                // player, so the generic binds to a concrete type.
                let chosen = pickerAudioTracks[sender.tag]
                if let mePlayer = layer.player as? KSMEPlayer,
                   let concrete = chosen as? FFmpegAssetTrack {
                    mePlayer.select(track: concrete)
                } else {
                    // Any other engine: select() ultimately flips
                    // isEnabled across the same media type (see
                    // MEPlayerItem.select) — mirror that directly.
                    for track in pickerAudioTracks {
                        track.isEnabled = track === chosen
                    }
                }
            }
        case .sources:
            // v2.0.29 (item 3): the tag IS the candidate's
            // ladder index (openSourceChooser). The panel
            // closes first — the switch recreates this host
            // for the chosen attempt (.id(attemptID)), so no
            // track refresh applies here — then the director
            // switches, keeping the position through the
            // standing itemReady resume rule. Picking the
            // current row is the director's no-op.
            // v2.0.35: the LIVE playhead is read from the
            // layer synchronously HERE, at the pick — the
            // same currentPlaybackTime the freeze watchdog
            // reads — and handed to the director with the
            // switch: the switch recreates this host, so
            // after this call the playhead is gone, and the
            // pre-fix carry (the director's latest tick
            // value) was destroyed by the NEW host's first
            // ~0 report before the resume seek read it
            // (AUDIT-2034-SWITCHRESUME).
            let index = sender.tag
            let nowSec = layer.player.currentPlaybackTime
            let playheadMs = (nowSec.isFinite && nowSec > 0)
                ? Int64(nowSec * 1000) : nil
            closePicker()
            director?.userSwitchSource(to: index, playheadMs: playheadMs)
            return
        }
        // v2.0.33 (item 1a): only the two TRACK kinds reach
        // here (the source kind returned inside its case,
        // and its switch recreates this host, so no flag of
        // this host's survives to resync). A subtitle or
        // audio selection churns the engine — it may pause
        // or resume underneath the pick without a named
        // lifecycle event the delegate maps — so the intent
        // flag is re-read from the engine itself BEFORE the
        // refresh below paints the glyph from it.
        syncIntentFromEngine()
        refreshTrackButtons()
        // v2.0.31 (L4): the track pickers close DEFERRED —
        // never inside the tapped row's own press dispatch
        // (see closePickerDeferred). The source chooser
        // above keeps its immediate close: its switch tears
        // this host down and rebuilds it, so no focus state
        // of this host's survives to be stranded.
        closePickerDeferred()
    }

    /// v2.0.31 (L4): close the picker on the next runloop
    /// turn instead of inside the tapped button's action.
    /// The tapped row IS the focused view; the pre-fix
    /// closePicker removed it from the hierarchy in the
    /// middle of its own .primaryActionTriggered dispatch,
    /// and on the owner's set the focus engine never
    /// landed anywhere afterwards — later presses were
    /// delivered to no focused view at all, so with the
    /// film paused his play press (the button showing the
    /// triangle, its state read correctly by
    /// refreshTransport) did nothing, every time, until
    /// the session changed. Deferred, the press cycle
    /// completes with the hierarchy intact; the close then
    /// runs as an ordinary state change, and closePicker's
    /// forced focus update lands focus on the play button
    /// deterministically — the same landing the bar-wake
    /// path has always made. Idempotent: a second queued
    /// close reads pickerIsOpen false and no-ops.
    private func closePickerDeferred() {
        // v2.0.33 (item 1b): the deferral mechanism changed
        // from an unstructured Task hop to the runloop's own
        // deferred perform. A Task { @MainActor in … } hop
        // is ACTOR-scheduled: it can be picked up the moment
        // the current actor job yields, which can still be
        // inside the tail of the tapped row's own press /
        // focus cycle — the exact window the deferral exists
        // to escape. perform(afterDelay: 0) is
        // RUNLOOP-scheduled: by construction it fires only
        // after the current event cycle has completed and
        // the runloop comes back around, so the press cycle
        // always finishes with the hierarchy intact first.
        // It also carries no closure, so there is nothing to
        // capture — the Swift 6 closure-capture problem the
        // B-2 note guarded against cannot arise here at all.
        // Cancel-then-perform keeps at most one close
        // pending; closePicker itself already guards on
        // pickerIsOpen, so the fired close stays idempotent.
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(closePickerDeferredFired),
            object: nil)
        perform(#selector(closePickerDeferredFired), with: nil, afterDelay: 0)
    }

    /// v2.0.33 (item 1b): the runloop-fired half of
    /// closePickerDeferred (see there). A separate @objc
    /// entry point is what the perform machinery addresses;
    /// the body is only ever the ordinary close.
    @objc private func closePickerDeferredFired() {
        closePicker()
    }

    private func closePicker() {
        guard pickerIsOpen else { return }
        pickerIsOpen = false
        // v2.0.31 (L5): the shell's Menu routing stands
        // down with the panel.
        director?.setPickerOpen(false)
        pickerView.isHidden = true
        transportBar.isHidden = false
        for button in pickerButtons { button.removeFromSuperview() }
        pickerButtons.removeAll()
        pickerSubtitleInfos = []
        pickerAudioTracks = []
        pickerSourceLabels = []
        pickerSourceIndex = -1
        setNeedsFocusUpdate()
        // v2.0.31 (L4): force the relocation to the play
        // button NOW (the host's preferredFocusEnvironments
        // names it while the bar is up) instead of leaving
        // it to the engine's next cycle — the relocation is
        // the step whose absence stranded the owner's
        // presses after a pick. Skipped during teardown
        // (no window): a dying host must not reach for
        // focus on its way out.
        if view.window != nil {
            updateFocusIfNeeded()
        }
        showControls()
    }

    // MARK: - KSPlayerLayerDelegate

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        // v2.0.33 (engine logging, audit item 4b): EVERY
        // state transition leaves one line — the sports live
        // streams stall INSIDE the engine, and until now the
        // only record of which lifecycle states a dying
        // stream actually passed through was the unified
        // log the owner cannot retrieve. The line carries
        // the state, the host's intent flag and the engine's
        // own playing read (their disagreement is itself
        // diagnostic), plus the candidate's HOST ONLY, read
        // from the director's current candidate (the host's
        // own pendingCandidate was consumed at layer
        // creation; it is kept as the fallback for any
        // transition reported before the director's
        // candidate is visible). Never a full URL: torrent
        // candidate URLs embed the debrid token in the path.
        DiagLog.write("engine",
                      "state=\(String(describing: state)) intent=\(intentPlaying) enginePlaying=\(layer.player.isPlaying) host=\(director?.candidate?.url.host ?? pendingCandidate?.url.host ?? "?")")
        switch state {
        case .readyToPlay:
            // v2.0.33 (item 1a): re-sync the intent flag from
            // the engine at the head of this branch, before
            // any of the branch's own logic runs — the engine
            // has just announced its real state, and every
            // later read of the flag in this attempt (the
            // resume seek's own assignment included, which is
            // untouched below) starts from the engine's truth
            // rather than whatever the preparing churn left
            // in the shadow flag.
            syncIntentFromEngine()
            // FIX4 (fix 1): re-assert the display criteria at
            // the moment playback actually starts. Apple's
            // choreography (Tech Talk 503) is: state the
            // criteria on the key window's AVDisplayManager,
            // then start playback — the switch keys off the
            // preference standing when frames begin. The
            // viewDidAppear application can be lost before
            // this point (a stale host's teardown landing
            // late, the cover transition), so the preference
            // is stated again here, per attempt, where it
            // cannot be overtaken.
            applyDisplayCriteria()
            // v2.0.5 (P3): readyToPlay disarms the first-frame
            // budget too — the engine has announced itself; a
            // start that is merely slow to fill its buffer is
            // viable and must not be killed at the budget. (The
            // mid-play freeze watchdog still guards a playhead
            // that never advances after this point.)
            firstFrameWatchdog?.cancel()
            if !ready {
                ready = true
                let dur = layer.player.duration
                let durMs = dur.isFinite ? Int64(dur * 1000) : 0
                Task { @MainActor in
                    // The track lists exist only from this
                    // point on: size the bar's subtitle/audio
                    // buttons from the live lists now (a file
                    // with no second audio track gets no audio
                    // button, like the system player).
                    self.applyDefaultAudio(layer: layer)
                    self.refreshTrackButtons()
                    self.refreshTransport()
                    self.director?.itemReady(durationMs: durMs,
                                             reportingAttemptID: self.hostAttemptID) { ms in
                        // v2.0.35 (seek logging, DIAG-2034
                        // (g)): the resume seek leaves the
                        // same line as every app-executed
                        // seek (see seekBy) — from is the
                        // fresh layer's clock (≈0), to is
                        // the target the director applied.
                        let fromSec = layer.player.currentPlaybackTime
                        DiagLog.write("play", "seek engine=ffmpeg from=\(Self.seekLogSeconds(fromSec)) to=\(Self.seekLogSeconds(TimeInterval(ms) / 1000))")
                        layer.seek(time: TimeInterval(ms) / 1000,
                                   autoPlay: true) { _ in }
                        // Swift 6 specialist-review fix
                        // (SF5): the resume seek auto-plays —
                        // state the intent, symmetric with
                        // seekBy. Without it a pause taken
                        // during preparing left the flag
                        // false over a playing engine: the
                        // glyph showed play and the next
                        // Select sent play() again (a no-op)
                        // until a state event re-synced.
                        self.intentPlaying = true
                    }
                }
            }
        case .bufferFinished:
            intentPlaying = true
            if !playing {
                playing = true
                firstFrameWatchdog?.cancel()
                lastAdvanceAt = Date()
                let now = layer.player.currentPlaybackTime
                lastPositionSec = now.isFinite ? now : -1
            }
            refreshTransport()
        case .paused, .playedToTheEnd:
            // v2.0.32: the engine's own pause/end events sync
            // the toggle's intent flag (see intentPlaying) —
            // including a pause the engine takes on its own
            // during a track switch, which is exactly the
            // state the owner's dead play press met.
            intentPlaying = false
            refreshTransport()
        case .error:
            intentPlaying = false
            fireFail(cause: "Engine báo lỗi (KSPlayer state .error)")
        default:
            // v2.0.33 (item 1a): the states that land here —
            // .initialized / .preparing / .buffering — carry
            // no named intent assignment above, but the
            // engine's playing read can still change across
            // them (a buffering dip that ends paused, a
            // prepare that auto-starts). Sync the shadow flag
            // from the engine instead of leaving it at
            // whatever the previous named state set, so the
            // toggle never inherits a stale intent from the
            // unnamed half of the lifecycle.
            syncIntentFromEngine()
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        let now = Date()
        guard now.timeIntervalSince(lastTickAt) >= 5 else { return }
        lastTickAt = now
        director?.tick(positionMs: Int64(currentTime * 1000),
                       durationMs: totalTime.isFinite ? Int64(totalTime * 1000) : 0)
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        intentPlaying = false
        if let error {
            // v2.0.33 (engine logging, audit item 4b): the
            // finish cause reaches the persistent file too,
            // beside the state-transition lines above — the
            // error's description is an engine-generated
            // string (no URL is written by this host; the
            // DiagLog layer also scrubs any URL-shaped text
            // to scheme://host as a backstop).
            DiagLog.write("engine", "finish error=\(error.localizedDescription)")
            // v2.0.5 (error 8a): the Error is READ before the
            // failure is reported — pre-fix this delegate
            // checked only `error != nil` and discarded the
            // value, so the one artefact that could convict
            // the failure cause never reached any log or UI.
            fireFail(cause: error.localizedDescription)
        } else if !ended {
            ended = true
            Task { @MainActor in
                // v2.0.35: hand in this host's captured
                // attempt — the director ignores an ended
                // that names a superseded attempt (see
                // PlayDirector.itemEnded).
                self.director?.itemEnded(reportingAttemptID: self.hostAttemptID)
            }
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}

    // MARK: - Stall handling

    /// One freeze-watchdog tick (1 s, main run loop). Mirrors
    /// the AVPlayer coordinator's judgement exactly: user
    /// pause holds the clock open, the end of the file belongs
    /// to the finish delegate, any playhead movement counts as
    /// alive.
    private func checkFreeze() {
        guard playing, !ended, !failed, let layer else { return }
        if layer.state == .paused || !layer.player.isPlaying {
            lastAdvanceAt = Date()
            let now = layer.player.currentPlaybackTime
            if now.isFinite { lastPositionSec = now }
            return
        }
        let pos = layer.player.currentPlaybackTime
        guard pos.isFinite else { return }
        let dur = layer.player.duration
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
        if Date().timeIntervalSince(lastAdvanceAt) >= 30 {
            stallFail(reason: "Hình đứng yên 30 giây (đóng băng)")
        }
    }

    /// A stall (first-frame budget or frozen playhead): the
    /// owner SEES why the picture changed — the notice rides
    /// the shell's status capsule — then the ladder advances.
    /// `reason` also rides to the director as the failure
    /// cause, so a watchdog kill is labelled as a watchdog
    /// kill in the log and on the exhausted slate, never
    /// mistaken for an engine error.
    private func stallFail(reason: String) {
        guard !failed else { return }
        // v2.0.33 (engine logging, audit item 4b): a watchdog
        // kill is logged as a watchdog kill in the file too
        // (the reason is an app-generated label, never a
        // URL) — fireFail below logs the same string as the
        // failure cause, so the stall and the failover it
        // caused read as one event in the export.
        DiagLog.write("engine", "stall \(reason)")
        director?.notice = "Nguồn này không phát được — đang chuyển nguồn khác…"
        fireFail(cause: reason)
    }

    private func fireFail(cause: String? = nil) {
        guard !failed else { return }
        // v2.0.33 (engine logging, audit item 4b): every
        // failure that advances the ladder — engine error,
        // finish error, watchdog stall (stallFail forwards
        // its reason as the cause) — leaves its cause string
        // in the persistent file at the moment it fires, so
        // an exhausted slate can be diagnosed from the
        // export instead of from impressions. Causes are
        // app-generated labels or engine error descriptions;
        // no URL is passed (DiagLog also scrubs URL-shaped
        // text to scheme://host as a backstop).
        DiagLog.write("engine", "fail cause=\(cause ?? "none")")
        failed = true
        firstFrameWatchdog?.cancel()
        freezeTimer?.invalidate()
        freezeTimer = nil
        // v2.0.35: capture this host's last playhead NOW,
        // synchronously, before the director call is
        // dispatched — by the time the task runs, the
        // switch may already have torn this layer down.
        // The live read is the same currentPlaybackTime
        // the freeze watchdog reads; lastPositionSec (the
        // watchdog's own tracked position) is the fallback
        // when the layer is already gone or reports
        // nothing usable. The director snapshots it so the
        // next candidate resumes where this one died (see
        // PlayDirector.captureSwitchSnapshot).
        let liveSec = layer?.player.currentPlaybackTime ?? -1
        let playheadSec = (liveSec.isFinite && liveSec > 0)
            ? liveSec
            : (lastPositionSec > 0 ? lastPositionSec : -1)
        let playheadMs: Int64? = playheadSec > 0
            ? Int64(playheadSec * 1000) : nil
        Task { @MainActor in
            // v2.0.35: hand in this host's captured attempt
            // — a failure whose hop lands after the ladder
            // advanced past this host is ignored by the
            // director (see PlayDirector.itemFailed).
            self.director?.itemFailed(cause: cause, playheadMs: playheadMs,
                                      reportingAttemptID: self.hostAttemptID)
        }
    }
}

/// The host's root view — the one focusable surface of the KS
/// player screen. tvOS focus can only land on a UIView: a view
/// controller has no `canBecomeFocused` to override (that line
/// is what CI run #24 rejected). With focus on this view,
/// remote presses bubble up the responder chain to the host
/// controller's `pressesEnded`, which is where Select and
/// Left/Right are handled; Menu is never swallowed there.
/// v2.0.16: a one-info data source carrying the session's
/// side-loaded subtitle. KSPlayer's URLSubtitleInfo
/// downloads and parses the file lazily when it becomes
/// the selected info. v2.0.32 (KSPlayer 5.6.2): the
/// library fixed the protocol's misspelt name and split
/// it — a source with a fixed slate conforms to
/// ConstantSubtitleDataSource and vends its infos through
/// `infos()` (2.3.4's SubtitleDataSouce wanted a stored
/// `infos` property). The class is final with a single
/// immutable stored property, which is what the
/// protocol's Sendable requirement asks of a class.
private final class JoeExternalSubtitleDataSource: ConstantSubtitleDataSource {
    private let info: URLSubtitleInfo
    init(info: URLSubtitleInfo) { self.info = info }
    func infos() -> [any SubtitleInfo] { [info] }
}

private final class KSPlayerHostRootView: UIView {
    /// v2.0.18: DYNAMIC, not a constant. While the transport
    /// bar (or the picker) is up, the root REFUSES focus: a
    /// focus update then has no eligible incumbent and MUST
    /// relocate, and only relocation consults the host's
    /// preferredFocusEnvironments. That was the 2.0.17 fix's
    /// missing half — preferred environments guide focus
    /// ENTERING an environment (or being evicted from an
    /// ineligible view); they cannot pull focus off an
    /// eligible full-screen view that already holds it, so
    /// focus stayed glued to this root, its full-screen frame
    /// offered the focus engine no directional exit, and
    /// every arrow fell through to the host's seek handler —
    /// the owner's "không cho mình bấm qua để chỉnh".
    var acceptsFocus = true
    override var canBecomeFocused: Bool { acceptsFocus }
}

/// The transport bar's seek bar (v2.0.12). UISlider cannot
/// take tvOS focus or answer the remote at all, so the bar is
/// a plain focusable view that draws track / played fill /
/// knob itself (growing the knob under focus, the system's
/// own emphasis language) and answers the presses the system
/// player answers on its timeline: Left/Right clicks step
/// ∓30 s (the host's standing seek step), Select toggles
/// play/pause. Presses it does not handle — Up back to the
/// button row, Menu out of the player — are passed up the
/// responder chain untouched. No buffered fill is drawn: the
/// KS layer's verified delegate surface exposes no buffered
/// time range (bufferedCount is an event count, not a time),
/// and an invented fill would be a lie on screen.
private final class KSSeekBarView: UIView {
    /// Played fraction, 0...1.
    var fraction: Double = 0
    var onStep: ((TimeInterval) -> Void)?
    var onTogglePlayPause: (() -> Void)?

    override var canBecomeFocused: Bool { true }

    override func draw(_ rect: CGRect) {
        let barHeight: CGFloat = isFocused ? 10 : 6
        let y = (rect.height - barHeight) / 2
        let trackRect = CGRect(x: 0, y: y, width: rect.width, height: barHeight)
        UIColor.white.withAlphaComponent(0.35).setFill()
        UIBezierPath(roundedRect: trackRect, cornerRadius: barHeight / 2).fill()
        let fillWidth = rect.width * CGFloat(max(0, min(1, fraction)))
        if fillWidth > 0 {
            let fillRect = CGRect(x: 0, y: y, width: fillWidth, height: barHeight)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: fillRect, cornerRadius: barHeight / 2).fill()
        }
        let knob: CGFloat = isFocused ? 30 : 18
        let knobX = max(0, min(rect.width - knob, fillWidth - knob / 2))
        let knobRect = CGRect(x: knobX, y: (rect.height - knob) / 2,
                              width: knob, height: knob)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: knobRect).fill()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        setNeedsDisplay()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .leftArrow:
                onStep?(-30)
                handled = true
            case .rightArrow:
                onStep?(30)
                handled = true
            case .select:
                onTogglePlayPause?()
                handled = true
            default:
                break
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }
}
