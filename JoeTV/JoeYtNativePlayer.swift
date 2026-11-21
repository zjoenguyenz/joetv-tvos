import SwiftUI
import AVKit

// MARK: - Native YouTube player (AVQueuePlayer spine)
//
// The playback leg of the native YouTube route. Ported
// from the probe's proven player shape (Probe 3+7:
// AVQueuePlayer + prefetch insert + clean auto-advance
// on the owner's TV) and fed by the resolver + the local
// HLS assembly:
//
// - The current episode resolves and plays IMMEDIATELY;
//   exactly ONE next episode is pre-resolved behind it
//   (hiding the ~2.4 s solver cost) and inserted into the
//   same queue — prefetch depth is 1, never a second
//   player pulling media in parallel (FL-065).
// - Auto-advance is the queue's own. Manual next rides
//   the window-level press consumer (the bridge's proven
//   routing): it takes ONLY the Right-arrow press — the
//   owner's settled YouTube priorities are full-screen,
//   next-episode and auto-next, with seeking dropped —
//   and declines everything else so the native player's
//   own transport (play/pause, the Down-panel with the
//   subtitle/audio pickers) is untouched.
// - NO focusable SwiftUI buttons overlay the player
//   (the 2026-11-20 11:15 device lesson: AVPlayerView-
//   Controller traps focus — overlay buttons are
//   unreachable). Slates (veil / failure / end) appear
//   only when the player is NOT the live surface.
// - Every resolve/advance chain runs through ONE
//   in-flight gate and carries an attempt token
//   (FL-330 rules 4–5, FL-041): a late completion of a
//   superseded attempt never touches the live player,
//   and state verdicts read the same quantities on both
//   sides (currentItem identity + timeControlStatus).
// - A stalled or failed item gets ONE re-resolve of the
//   same episode (fresh signed URLs), seeking back to
//   the last vouched checkpoint; a second failure is
//   terminal and hands back through the same Auto
//   fall-through wiring the page player uses.

@MainActor
final class JoeYtNativePlayerModel: ObservableObject {
    @Published private(set) var phase: Phase = .starting
    @Published private(set) var currentIndex: Int
    @Published var statusLine: String?

    enum Phase: Equatable {
        case starting
        case playing
        case failed(String)
        case ended
    }

    let player = AVQueuePlayer()
    private let request: JoeYtPlayRequest
    private let firstPlayable: JoeYtPlayable

    private var started = false
    private var terminal = false
    /// Monotonic attempt token: bumped by every new
    /// resolve/advance/recovery chain; completions check
    /// it before touching the player (FL-041).
    private var attempt = 0
    /// The FL-330 in-flight gate: one operation chain at
    /// a time on this player.
    private var opInFlight = false
    private var prefetchTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var supervisorTask: Task<Void, Never>?
    /// The queue item currently carrying the NEXT episode
    /// (inserted by prefetch), and the index it belongs
    /// to. Nil while a prefetch is still resolving.
    private var queuedItem: AVPlayerItem?
    private var queuedIndex: Int?
    /// Set when the owner pressed Next before the
    /// prefetched item landed: the advance fires the
    /// moment the insert completes.
    private var advancePending = false
    /// Stall bookkeeping: how long the current item has
    /// been continuously waiting, and whether the ONE
    /// re-resolve recovery has been spent on it.
    private var waitingSince: Date?
    private var recoverySpent = false
    private var firstFrameLogged = false
    private var playStartedAt = Date()
    /// The last position the supervisor itself vouched
    /// for (the recovery seek checkpoint — FL-041: the
    /// target is remembered, never re-derived from a
    /// collapsed playhead).
    private var checkpointSeconds: Double = 0
    /// The owner's manual subtitle/audio picks, captured
    /// from the outgoing item and re-applied to the next
    /// (FL-049) — the player's own UI writes them; the
    /// model only carries them across items.
    private var manualSelections: [AVMediaCharacteristic: AVMediaSelectionOption?] = [:]
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    /// FL-343 (A) paused-limbo bookkeeping. The leg's
    /// precondition is POSITIVE evidence the pause is
    /// not the owner's: performAdvance() stamps the
    /// moment (and playhead) of a model-issued
    /// advanceToNextItem, and the stamp lives until the
    /// supervisor's transition bookkeeping confirms the
    /// queue actually moved. A pause the OWNER commands
    /// can never create that stamp — the native player's
    /// transport is not routed through this model — so
    /// the leg cannot fire on a user pause BY
    /// CONSTRUCTION (review round 1, Lens C F-C2/F-C3:
    /// the earlier buffer/waiting classifier both
    /// swallowed a user pause issued mid-rebuffer and
    /// latched a real stall as a user pause when its
    /// buffer had not drained yet; a one-shot classifier
    /// cannot separate the two, so the leg keys on the
    /// model's own unconfirmed advance instead — the
    /// exact FL-343 incident shape. A mid-item stall
    /// with no advance in flight is the
    /// AVPlayerItemPlaybackStalled observer's leg, and
    /// a .waiting park is the waiting leg's.)
    private var advanceUnconfirmedSince: Date?
    private var advanceUnconfirmedPosition: Double = 0
    private var pausedStallSince: Date?
    private var pausedStallPosition: Double = 0

    var onFallThrough: ((MovieRoute) -> Void)?
    var onDetailFallThrough: ((JoeYtChainPlay) -> Void)?
    /// Design §4.6's trigger from inside the player:
    /// the native construction itself is dead (the
    /// assembly server would not start AND no muxed
    /// fallback URL exists) — the router swaps this
    /// surface for the degraded door+page player. Wired
    /// by the view from the router (review round 7,
    /// MAJOR: this hand-over did not exist — the two
    /// construction-failure exits went straight to the
    /// terminal slate/chain, skipping §4.6).
    var onPageFallback: (() -> Void)?

    /// The app's WatchStore, handed in by the view from
    /// the environment (design §3.4). Optional on
    /// purpose: progress recording must never be able
    /// to block playback — a missing store only skips
    /// the writes.
    private var watchStore: WatchStore?
    /// Supervisor ticks since the last periodic
    /// progress save, and the position that save
    /// carried (the periodic save fires on a 15 s
    /// cadence and only when the position has actually
    /// moved — the JoePlayerView points, §3.4).
    private var ticksSinceSave = 0
    private var lastSavedPosition: Double = -1
    /// The CURRENT item's duration, refreshed by the
    /// supervisor on every tick while that item is
    /// current (review count round 1, Lens A F-2): at
    /// the episode-transition tick, player.currentItem
    /// is ALREADY the incoming episode, so a save for
    /// the OUTGOING episode that read the live item
    /// would stamp the new episode's duration onto the
    /// old episode's row — a pos/dur pair that can
    /// exceed 1.0. The transition save passes this
    /// tracked value explicitly instead.
    private var currentDurationSeconds: Double = 0

    func attachStore(_ store: WatchStore) {
        watchStore = store
    }

    init(request: JoeYtPlayRequest, firstPlayable: JoeYtPlayable) {
        self.request = request
        self.firstPlayable = firstPlayable
        self.currentIndex = request.startIndex
    }

    var episodeLabel: String {
        "Tập \(currentIndex + 1) / \(request.videoIds.count)"
    }

    var hasNextEpisode: Bool {
        currentIndex + 1 < request.videoIds.count
    }

    private func log(_ message: String) {
        DiagLog.write("YT-PLAY", message)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        player.automaticallyWaitsToMinimizeStalling = true
        startSupervisor()
        // The initial build chain carries the attempt
        // token like every other chain (review round 1,
        // BLOCKER 3): if any gated operation has run
        // meanwhile, this completion must not touch the
        // player.
        let startAttempt = attempt
        Task { [weak self] in
            guard let self else { return }
            let item = await self.buildItem(for: self.firstPlayable)
            // If stop() landed during buildItem, this
            // completion is stale twice over (terminal +
            // the attempt bump in stop()). A session the
            // build may have registered on the shared
            // HLS server for this now-dead player is
            // inert: it is never handed to any player,
            // its signed origins expire on their own,
            // and the server's 4-session cap evicts it
            // (review round 7, MINOR — accepted residue,
            // recorded here rather than hidden).
            guard !self.terminal, self.attempt == startAttempt else { return }
            guard let item else {
                self.handOverToPageFallback(reason: "không dựng được item đầu tiên — assembly chết và không có muxed dự phòng")
                return
            }
            self.player.replaceCurrentItem(with: item)
            self.observeCurrentItem(item)
            self.playStartedAt = Date()
            self.player.play()
            self.log("mở player — ep=\(self.currentIndex + 1) kind=\(self.kindName(self.firstPlayable.kind)) itag=\(self.firstPlayable.videoItag)")
            self.startPrefetch()
        }
    }

    func stop() {
        terminal = true
        // Invalidate every in-flight chain by TOKEN as
        // well as by the terminal flag (review round 7,
        // MINOR): a completion that wakes after stop()
        // is stale on both checks, not just one.
        attempt += 1
        // The end-point progress save (design §3.4):
        // the last vouched position of the episode on
        // screen leaves with the player.
        saveProgressSnapshot()
        JoeWebBridge.setRemotePressConsumer(nil)
        // Reset the prefetch bookkeeping synchronously —
        // the cancelled task's defer only runs if the
        // model is still alive to execute it (review
        // round 2, BLOCKER 1).
        prefetchInFlight = false
        advancePending = false
        prefetchTask?.cancel()
        statusTask?.cancel()
        supervisorTask?.cancel()
        itemStatusObservation?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
        }
        player.pause()
        player.removeAllItems()
    }

    // MARK: Item construction

    private func kindName(_ kind: JoeYtPlayable.Kind) -> String {
        switch kind {
        case .assembly: return "assembly"
        case .muxed: return "muxed"
        case .hlsManifest: return "hls"
        }
    }

    /// Item construction (assembly sessions are
    /// created here; the result is applied by the caller
    /// under its attempt token).
    private func buildItem(for playable: JoeYtPlayable) async -> AVPlayerItem? {
        switch playable.kind {
        case .hlsManifest, .muxed:
            guard let url = playable.directURL else { return nil }
            return AVPlayerItem(url: url)
        case .assembly:
            if let url = await JoeYtHlsServer.shared.makeSession(
                playable: playable, userAgent: JoeYtClientSpec.tvSamsung.userAgent) {
                return AVPlayerItem(url: url)
            }
            if let fallback = playable.fallbackDirectURL {
                log("assembly server không khởi động được — rơi xuống bản muxed dự phòng")
                return AVPlayerItem(url: fallback)
            }
            return nil
        }
    }

    private func observeCurrentItem(_ item: AVPlayerItem?) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
        guard let item else { return }
        // [.new, .initial] (review round 2, MINOR): the
        // supervisor installs this observation up to
        // 500 ms after a queue-advanced item becomes
        // current — an item ALREADY .failed by then never
        // fires a .new-only callback and recovery would
        // wait for the 20 s stall leg instead of failing
        // over at once.
        //
        // The error text is read from the OBSERVED item
        // inside the callback (FL-343): the pre-fix
        // handler read player.currentItem?.error on the
        // main actor, which during an advance/replace is
        // a DIFFERENT item than the one that failed — its
        // error is nil, so real failures reached the log
        // (and the recovery reason) as the textless
        // "item failed (không có error text)". The read
        // itself mirrors the .status read directly above
        // it — same delivery context, property reads
        // only; the AVPlayerItem reference never crosses
        // the hop, only the two Sendable values do
        // (review round 1, Lens A F-A2).
        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) {
            [weak self] observed, _ in
            let status = observed.status
            let errorText = observed.error?.localizedDescription
            Task { @MainActor in
                self?.handleItemStatus(status, errorText: errorText)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleItemEnded()
            }
        }
        // FL-343 (A): AVPlayer's own stall signal. The
        // incident item never failed and never ended —
        // it sat cut mid-stream while no status changed;
        // this notification is the one signal AVFoundation
        // raises for exactly that shape, and the pre-fix
        // model never subscribed to it.
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackStalled()
            }
        }
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status,
                                  errorText: String?) {
        guard !terminal else { return }
        switch status {
        case .readyToPlay:
            applyMediaSelections(to: player.currentItem)
        case .failed:
            let message = errorText
                ?? "item failed (không có error text)"
            log("item FAILED ep=\(currentIndex + 1) — \(message)")
            recoverOrFail(reason: message)
        default:
            break
        }
    }

    private func handlePlaybackStalled() {
        guard !terminal else { return }
        log("playback stalled ep=\(currentIndex + 1) tại \(Int(checkpointSeconds))s — AVPlayer báo item đứng giữa chừng")
        recoverOrFail(reason: "playback stalled")
    }

    private func handleItemEnded() {
        guard !terminal else { return }
        // The outgoing item is still the current item at
        // this instant — capture the owner's manual
        // subtitle/audio picks from it before the queue
        // moves on (FL-049).
        captureManualSelections(from: player.currentItem)
        log("item hết ep=\(currentIndex + 1)")
        if !hasNextEpisode {
            phase = .ended
            log("hết tập cuối — end slate")
            return
        }
        // With the next item already queued, the queue
        // itself advances; the supervisor's currentItem
        // watch performs the index bookkeeping (one code
        // path for both the automatic and the manual
        // advance — FL-330).
        //
        // With NOTHING queued (review round 2, BLOCKER
        // 2) the queue cannot advance: the player sits
        // paused on the ended item, timeControlStatus is
        // .paused — never .waiting — so the stall leg can
        // never fire. Drive the same path a press would
        // take: arm behind the in-flight prefetch, or run
        // the gated chain now.
        if queuedItem == nil {
            if prefetchInFlight || opInFlight {
                // opInFlight = a recovery chain is
                // re-placing this episode (review round
                // 3, MINOR): arm exactly like the prefetch
                // case — the recovery completion consumes
                // the arm when its gate frees. (Arming was
                // previously skipped here, and the advance
                // was silently lost.)
                advancePending = true
                log("hết tập trong lúc đang bận (prefetch/recovery) — advance đã arm")
            } else {
                runAdvanceChain()
            }
        }
    }

    // MARK: Supervisor (500 ms — the probe's cadence)

    private func startSupervisor() {
        supervisorTask?.cancel()
        supervisorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !self.terminal else { return }
                self.supervisorTick()
            }
        }
    }

    private func supervisorTick() {
        // Episode bookkeeping: the queue advanced (auto
        // or manual) — the current item is now the one
        // prefetch inserted.
        if let queued = queuedItem, player.currentItem === queued,
           let index = queuedIndex {
            // The outgoing episode's final progress
            // leaves BEFORE the bookkeeping switches the
            // index (design §3.4's end point for it) —
            // with the OUTGOING episode's tracked
            // duration, not the incoming item's (Lens A
            // F-2).
            saveProgressSnapshot(durationOverride: currentDurationSeconds)
            currentIndex = index
            queuedItem = nil
            queuedIndex = nil
            // An arm the natural advance just satisfied is
            // spent (review round 2, BLOCKER 1).
            advancePending = false
            recoverySpent = false
            firstFrameLogged = false
            waitingSince = nil
            // The advance the stamp waited on HAS landed
            // (this block IS the supervisor's identity
            // confirmation) — the limbo leg's precondition
            // is spent.
            advanceUnconfirmedSince = nil
            pausedStallSince = nil
            checkpointSeconds = 0
            playStartedAt = Date()
            observeCurrentItem(player.currentItem)
            phase = .playing
            flashStatus("Tập \(currentIndex + 1)")
            log("đã qua tập — currentItem là ep=\(currentIndex + 1) (đọc cùng đại lượng: item identity)")
            startPrefetch()
        }

        // Refresh the tracked duration from the item
        // that is current NOW — after the transition
        // block above has consumed the outgoing value
        // (Lens A F-2).
        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { currentDurationSeconds = d }
        }

        let status = player.timeControlStatus
        if status == .playing {
            waitingSince = nil
            // Playback is moving: any paused-limbo
            // bookkeeping is spent.
            advanceUnconfirmedSince = nil
            pausedStallSince = nil
            if !firstFrameLogged,
               let item = player.currentItem, item.status == .readyToPlay {
                firstFrameLogged = true
                phase = .playing
                let ms = Int(Date().timeIntervalSince(playStartedAt) * 1000)
                log("first frame ep=\(currentIndex + 1) sau \(ms)ms")
                // The start-point progress save (§3.4):
                // the Continue Watching row exists from
                // the episode's first frame, not only
                // after the first periodic tick.
                saveProgressSnapshot(force: true)
            }
            let position = player.currentTime().seconds
            if position.isFinite, position > 1 {
                checkpointSeconds = position
            }
            // The periodic save (§3.4): every ~15 s of
            // ticks, and only when the position has
            // genuinely moved since the last save.
            ticksSinceSave += 1
            if ticksSinceSave >= 30, position.isFinite,
               abs(position - lastSavedPosition) >= 5 {
                saveProgressSnapshot()
            }
        } else if status == .waitingToPlayAtSpecifiedRate {
            if waitingSince == nil { waitingSince = Date() }
            if let since = waitingSince,
               Date().timeIntervalSince(since) > 20, !opInFlight {
                log("stall — waiting 20s ở ep=\(currentIndex + 1) tại \(Int(checkpointSeconds))s")
                recoverOrFail(reason: "stall 20s")
            }
        } else {
            waitingSince = nil
            tickPausedLimbo()
        }
    }

    /// FL-343 (A), second leg: recovery watches PROGRESS,
    /// not only the player's nominal state. In the
    /// incident the queue was told to advance over an
    /// item whose origin had been cut mid-stream; the
    /// item neither failed nor ended, and the player
    /// parked at .paused awaiting a supervisor
    /// confirmation that could never come — the pre-fix
    /// supervisor only watched .waiting, so nothing ever
    /// fired.
    ///
    /// The leg's precondition is the model's OWN
    /// unconfirmed advance (see the stamp's declaration):
    /// performAdvance() issued advanceToNextItem and the
    /// transition bookkeeping never confirmed it. That
    /// stamp is something a user pause can never
    /// produce, so the leg is safe for the owner's pause
    /// BY CONSTRUCTION — it never has to guess intent
    /// from buffer or waiting signals (review round 1,
    /// Lens C F-C2/F-C3: those signals misclassify in
    /// both directions). The fire condition: phase
    /// .playing, the stamp live, the player parked at
    /// .paused (this leg only runs on .paused ticks),
    /// the playhead frozen within 0.5 s of where the
    /// stretch found it, for over 20 s. A playhead that
    /// moves again spends the stamp — the advance (or
    /// playback) is alive after all. A player parked at
    /// the item's END is excluded: the end-of-item paths
    /// own that state.
    private func tickPausedLimbo() {
        guard phase == .playing, !opInFlight,
              advanceUnconfirmedSince != nil,
              let item = player.currentItem else {
            pausedStallSince = nil
            return
        }
        let position = player.currentTime().seconds
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0, position.isFinite,
           position >= duration - 0.5 {
            pausedStallSince = nil
            return
        }
        if position.isFinite,
           abs(position - advanceUnconfirmedPosition) >= 0.5 {
            // The playhead moved well past the point the
            // advance was issued from — playback is
            // alive; the stamp is spent.
            advanceUnconfirmedSince = nil
            pausedStallSince = nil
            return
        }
        if pausedStallSince == nil {
            pausedStallSince = Date()
            pausedStallPosition = position
            return
        }
        if position.isFinite,
           abs(position - pausedStallPosition) >= 0.5 {
            // Still creeping — re-baseline instead of
            // firing on a slow-but-alive item.
            pausedStallSince = Date()
            pausedStallPosition = position
            return
        }
        if let since = pausedStallSince,
           Date().timeIntervalSince(since) > 20 {
            log("stall — paused-limbo 20s ở ep=\(currentIndex + 1) tại \(Int(checkpointSeconds))s (advance không được supervisor xác nhận, vị trí đứng yên)")
            advanceUnconfirmedSince = nil
            pausedStallSince = nil
            recoverOrFail(reason: "stall paused-limbo")
        }
    }

    // MARK: Recovery — ONE re-resolve per item

    private func recoverOrFail(reason: String) {
        guard !terminal, !opInFlight else { return }
        if recoverySpent {
            terminalFailure(reason: reason)
            return
        }
        recoverySpent = true
        attempt += 1
        let myAttempt = attempt
        opInFlight = true
        let videoId = request.videoIds[currentIndex]
        let seekTo = checkpointSeconds
        // The episode this recovery belongs to (review
        // round 5, MINOR): re-validated in the completion
        // before the replace — if the stalled item
        // un-stalled and the queue auto-advanced during
        // the awaits, the current item is a DIFFERENT
        // episode and replacing it would desync the
        // screen from the index bookkeeping.
        let episodeIndex = currentIndex
        log("re-resolve ep=\(currentIndex + 1) (lần duy nhất) — lý do: \(reason); checkpoint \(Int(seekTo))s")
        Task { [weak self] in
            guard let self else { return }
            let result = await JoeYtResolver.shared.resolve(videoId: videoId)
            guard !self.terminal, self.attempt == myAttempt else {
                self.opInFlight = false
                return
            }
            switch result {
            case .playable(let playable, _):
                if let item = await self.buildItem(for: playable) {
                    guard !self.terminal, self.attempt == myAttempt else {
                        self.opInFlight = false
                        return
                    }
                    guard self.currentIndex == episodeIndex else {
                        self.opInFlight = false
                        self.log("recovery: tập hiện tại đã đổi trong lúc resolve (item tự hết stall và queue đã qua tập) — bỏ replace")
                        return
                    }
                    self.player.replaceCurrentItem(with: item)
                    self.observeCurrentItem(item)
                    // Reconcile the prefetched queue entry
                    // with the replace (review round 3,
                    // MINOR): Apple's text documents
                    // removal of the replaced item only and
                    // is silent about followers — if tvOS
                    // dropped the queued item, its
                    // bookkeeping must not go stale (a
                    // stale queuedItem would re-create the
                    // episode-end dead-end after any
                    // recovery). Correct under either
                    // semantics.
                    if let queued = self.queuedItem,
                       !self.player.items().contains(where: { $0 === queued }) {
                        self.queuedItem = nil
                        self.queuedIndex = nil
                        self.log("recovery: item prefetch không còn trong hàng đợi sau replace — dọn sổ, prefetch lại")
                        self.startPrefetch()
                    }
                    if seekTo > 2 {
                        await self.player.seek(
                            to: CMTime(seconds: seekTo, preferredTimescale: 600))
                    }
                    self.waitingSince = nil
                    self.advanceUnconfirmedSince = nil
                    self.pausedStallSince = nil
                    self.playStartedAt = Date()
                    self.player.play()
                    self.opInFlight = false
                    self.log("re-resolve xong — phát lại ep=\(self.currentIndex + 1) từ \(Int(seekTo))s")
                    // An advance armed while this recovery
                    // ran (the episode ended, or the owner
                    // pressed Next, mid-recovery — review
                    // round 3, MINOR) is consumed now that
                    // the gate is free — UNLESS a prefetch
                    // is still in flight (review round 4,
                    // BLOCKER): starting the chain here
                    // would resolve the same next episode a
                    // second time and race the prefetch's
                    // insert. Leave the arm set; with
                    // opInFlight now cleared, the
                    // prefetch's success consumption (or
                    // its failure hand-off) owns it.
                    if self.advancePending, !self.prefetchInFlight {
                        self.advancePending = false
                        self.runAdvanceChain()
                    }
                } else {
                    self.opInFlight = false
                    self.handOverToPageFallback(reason: "recovery: không dựng được item sau re-resolve — assembly chết và không có muxed dự phòng")
                }
            case .solverFailed:
                // §4.6 trigger one, on the RECOVERY leg
                // (review count round 1, Lens C F2): the
                // same result at first resolve goes to
                // the page fallback through the router —
                // the recovery leg must not cut the page
                // tier out of the native → page →
                // chain/slate order.
                self.opInFlight = false
                self.handOverToPageFallback(reason: "recovery: solver chết ở lần re-resolve — \(reason)")
            case .unplayable(let status, _) where status == "NO_FORMATS":
                // §4.6 trigger two, same reasoning: the
                // router maps NO_FORMATS to the page
                // fallback at first resolve; recovery
                // agrees.
                self.opInFlight = false
                self.handOverToPageFallback(reason: "recovery: re-resolve không còn format nào dùng được — \(reason)")
            default:
                self.opInFlight = false
                self.terminalFailure(reason: reason)
            }
        }
    }

    /// The §4.6 hand-over for a dead native
    /// construction: the assembly leg and the muxed leg
    /// are BOTH unusable, so the episode goes to the
    /// degraded door+page surface through the router —
    /// never straight to a terminal slate while a
    /// proven fallback surface exists. This model
    /// latches terminal and strips its queue first, so
    /// nothing of the native machinery can touch the
    /// screen after the swap.
    private func handOverToPageFallback(reason: String) {
        guard !terminal else { return }
        terminal = true
        player.pause()
        player.removeAllItems()
        log("pageFallback — \(reason)")
        onPageFallback?()
    }

    /// One WatchStore progress write for the episode
    /// on screen (design §3.4 — the native player
    /// records at the same points as JoePlayerView:
    /// start / periodic / end). Identity is the stable
    /// title identity (FL-058): the catalogue pid keys
    /// the row, and the matched title's TMDB id is
    /// stamped when the request carries it, so the row
    /// canonical-matches the same film's chain rows.
    /// One row per series (the store's own same-series
    /// rule keeps the latest episode), never per
    /// episode — a long series must not flood the
    /// shared 40-row progress store.
    private func saveProgressSnapshot(force: Bool = false,
                                      durationOverride: Double? = nil) {
        guard let store = watchStore else { return }
        var position = checkpointSeconds
        let live = player.currentTime().seconds
        if live.isFinite, live > position { position = live }
        guard force || position > 1 else { return }
        var entry = WatchStore.Entry()
        entry.kind = WatchStore.kindYT
        entry.key = WatchStore.ytProgressKey(pid: request.pid)
        entry.ep = "Tập \(currentIndex + 1)"
        entry.epLabel = "Đang xem: Tập \(currentIndex + 1)"
        entry.title = request.seriesTitle
        entry.slug = request.pid
        entry.source = "yt"
        if request.tmdbId > 0 {
            entry.tmdbId = "\(request.tmdbId)"
        }
        entry.pos = Int64(position * 1000)
        if let override = durationOverride, override > 0 {
            entry.dur = Int64(override * 1000)
        } else if let item = player.currentItem {
            let duration = item.duration.seconds
            if duration.isFinite, duration > 0 {
                entry.dur = Int64(duration * 1000)
            }
        }
        entry.ts = Int64(Date().timeIntervalSince1970 * 1000)
        store.saveProgress(entry)
        lastSavedPosition = position
        ticksSinceSave = 0
    }

    private func terminalFailure(reason: String) {
        guard !terminal else { return }
        log("terminal failure ep=\(currentIndex + 1) — \(reason)")
        if let chainPlay = request.chainPlay {
            terminal = true
            log("Auto: native route hỏng hẳn — trả tập về detail chuỗi")
            onDetailFallThrough?(chainPlay)
        } else if request.mode == .auto, let route = request.chainRoute {
            terminal = true
            log("Auto: native route hỏng hẳn — rơi về chuỗi")
            onFallThrough?(route)
        } else {
            // Pause BEFORE the slate (review round 3,
            // MINOR): this branch does not latch terminal,
            // so an un-stalling item would otherwise keep
            // playing (audio) behind the failure slate
            // with the supervisor machinery still live.
            player.pause()
            // Drop any armed advance (review round 6,
            // MINOR): this branch is the sole producer of
            // the failure slate retry() serves, and an arm
            // left set here would be consumed by the
            // retry's recovery completion — skipping the
            // very episode the owner asked to replay. All
            // three recovery failure exits land here.
            advancePending = false
            phase = .failed("Không phát được qua YouTube. Anh bấm Thử lại, hoặc quay lại rồi chọn nguồn khác.")
        }
    }

    /// The failure slate's retry: a fresh resolve of the
    /// current episode with the recovery budget restored.
    func retry() {
        guard !terminal else { return }
        phase = .starting
        recoverySpent = false
        checkpointSeconds = 0
        recoverOrFail(reason: "owner retry")
    }

    // MARK: Prefetch (exactly one episode deep)

    /// Whether a prefetch is ACTUALLY running. A stored
    /// Task handle cannot answer this (a finished task
    /// stays non-nil — review round 1, BLOCKER 1: after
    /// a failed prefetch the handle lived on forever and
    /// Manual Next armed an advance no live task would
    /// ever consume). The flag is set at start and
    /// cleared by the task's own defer, generation-
    /// guarded so a superseded task cannot clear its
    /// successor's flag.
    private var prefetchInFlight = false
    private var prefetchGeneration = 0

    private func startPrefetch() {
        prefetchTask?.cancel()
        guard hasNextEpisode, queuedItem == nil else { return }
        let nextIndex = currentIndex + 1
        let videoId = request.videoIds[nextIndex]
        prefetchGeneration += 1
        let generation = prefetchGeneration
        prefetchInFlight = true
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.prefetchGeneration == generation {
                    self.prefetchInFlight = false
                    // advancePending's lifecycle ends with
                    // the prefetch that could have consumed
                    // it (review round 2, BLOCKER 1): a
                    // stale arm left true here made a LATER
                    // episode's successful prefetch skip an
                    // episode nobody asked to skip. The two
                    // failure exits below hand a LIVE arm
                    // off to the advance chain BEFORE this
                    // backstop clears it. Exception (review
                    // round 3, MINOR): while a recovery
                    // chain holds the gate, the arm belongs
                    // to the recovery completion — the
                    // backstop must not clear it first.
                    if !self.opInFlight {
                        self.advancePending = false
                    }
                }
            }
            let result = await JoeYtResolver.shared.resolve(videoId: videoId)
            guard !self.terminal, !Task.isCancelled,
                  self.currentIndex + 1 == nextIndex, self.queuedItem == nil
            else { return }
            guard case .playable(let playable, let metrics) = result else {
                self.log("prefetch ep=\(nextIndex + 1): resolve không ra playable — tập kế sẽ resolve khi tới lượt")
                self.handOffArmedAdvance()
                return
            }
            guard let item = await self.buildItem(for: playable) else {
                self.log("prefetch ep=\(nextIndex + 1): dựng item thất bại")
                self.handOffArmedAdvance()
                return
            }
            guard !self.terminal, !Task.isCancelled,
                  self.currentIndex + 1 == nextIndex, self.queuedItem == nil
            else { return }
            self.player.insert(item, after: nil)
            self.queuedItem = item
            self.queuedIndex = nextIndex
            self.log("prefetch ep=\(nextIndex + 1) đã vào hàng đợi (solver \(metrics.solverMs)ms)")
            // Consume an armed advance — UNLESS a
            // recovery chain holds the gate (review round
            // 3, MINOR): advancing now and letting the
            // recovery then replaceCurrentItem back would
            // desync the index bookkeeping from the
            // screen. The recovery completion consumes
            // the arm instead.
            if self.advancePending, !self.opInFlight {
                self.advancePending = false
                self.performAdvance()
            }
        }
    }

    // MARK: Manual next (Right-arrow press)

    /// The window-level press consumer (bridge routing):
    /// registered while this player is on screen, it
    /// takes ONLY Right-arrow — the next-episode press —
    /// and declines everything else (PlayPause, Select,
    /// arrows for the player's own panel, Menu above all:
    /// the bridge never offers Menu).
    func registerPressConsumer() {
        JoeWebBridge.setRemotePressConsumer { [weak self] pressType in
            MainActor.assumeIsolated {
                // ONLY while actually playing (review
                // round 1, BLOCKER 3): during .starting
                // the first item is not live yet, and an
                // advance chain in that window corrupts
                // the queue bookkeeping — presses then
                // belong to the native panel, not to us.
                guard let self, !self.terminal,
                      self.phase == .playing
                else { return false }
                if pressType == UIPress.PressType.rightArrow.rawValue {
                    self.advanceManually()
                    return true
                }
                return false
            }
        }
    }

    /// Manual next, serialised through the in-flight
    /// gate: with the prefetched item in the queue the
    /// advance is immediate; without it, the advance is
    /// armed and fires when the prefetch lands (or a
    /// resolve-then-advance chain runs if no prefetch is
    /// in flight).
    func advanceManually() {
        // player.currentItem != nil: no advance chain may
        // run before the first item is live (BLOCKER 3).
        guard !terminal, hasNextEpisode, !opInFlight,
              player.currentItem != nil
        else { return }
        if queuedItem != nil {
            performAdvance()
        } else if prefetchInFlight {
            advancePending = true
            log("next bằng tay: prefetch chưa xong — advance đã arm, bắn khi item vào hàng đợi")
        } else {
            // No prefetch running (its resolve failed
            // earlier): the gated chain.
            runAdvanceChain()
        }
    }

    /// The gated resolve → insert → advance chain: ONE
    /// operation under the in-flight gate + attempt
    /// token. Three callers share it: a manual press with
    /// nothing queued and no prefetch running; the
    /// episode-end handler in the same state (review
    /// round 2, BLOCKER 2); and a failed prefetch that
    /// had an advance armed (handOffArmedAdvance).
    private func runAdvanceChain() {
        guard !terminal, hasNextEpisode, !opInFlight,
              player.currentItem != nil
        else { return }
        // A caller that armed during a recovery can land
        // here with the next item ALREADY queued (the
        // prefetch finished meanwhile): advance to it
        // instead of resolving a second copy (review
        // round 3, MINOR).
        if queuedItem != nil {
            performAdvance()
            return
        }
        opInFlight = true
        attempt += 1
        let myAttempt = attempt
        let nextIndex = currentIndex + 1
        let videoId = request.videoIds[nextIndex]
        Task { [weak self] in
            guard let self else { return }
            let result = await JoeYtResolver.shared.resolve(videoId: videoId)
            guard !self.terminal, self.attempt == myAttempt else {
                self.opInFlight = false
                return
            }
            switch result {
            case .playable(let playable, _):
                if let item = await self.buildItem(for: playable),
                   !self.terminal, self.attempt == myAttempt {
                    // Re-check the queue AFTER the awaits
                    // (review round 4, BLOCKER): a prefetch
                    // that landed meanwhile already inserted
                    // its copy — inserting a second one
                    // overwrites queuedItem with an item the
                    // supervisor can never match to the
                    // playing copy, stalling the index
                    // bookkeeping for a whole episode.
                    // Advance to the queued copy instead.
                    if self.queuedItem != nil {
                        self.opInFlight = false
                        self.log("advance chain: prefetch đã kịp vào hàng đợi — advance tới bản đó, không insert trùng")
                        self.performAdvance()
                    } else {
                        self.player.insert(item, after: nil)
                        self.queuedItem = item
                        self.queuedIndex = nextIndex
                        self.opInFlight = false
                        self.performAdvance()
                    }
                } else if !self.terminal, self.attempt == myAttempt {
                    // buildItem nil: the construction is
                    // dead — a §4.6 trigger, handed over
                    // exactly like start() and recovery
                    // (review count round 1, Lens C F1).
                    // The old log-only else left the
                    // player parked on the ENDED item with
                    // phase still .playing when this chain
                    // ran from the episode-end handler —
                    // the FL-029 silent-death shape.
                    self.opInFlight = false
                    self.advancePending = false
                    self.handOverToPageFallback(reason: "advance chain: không dựng được item cho tập kế — assembly chết và không có muxed dự phòng")
                } else {
                    self.opInFlight = false
                }
            case .solverFailed:
                // §4.6 trigger one on the advance leg:
                // same hand-over as everywhere else.
                self.opInFlight = false
                self.advancePending = false
                self.handOverToPageFallback(reason: "advance chain: solver chết khi resolve tập kế")
            case .unplayable(let status, _) where status == "NO_FORMATS":
                // §4.6 trigger two on the advance leg.
                self.opInFlight = false
                self.advancePending = false
                self.handOverToPageFallback(reason: "advance chain: tập kế không còn format nào dùng được")
            default:
                self.opInFlight = false
                // The chain WAS the arm's consumer
                // (review round 5, MINOR): an advance
                // armed while this chain ran (the episode
                // ended mid-chain) must not survive its
                // failure — a stale arm would be consumed
                // by a later owner retry()'s recovery and
                // skip the episode he asked to replay.
                // Every OTHER failure class here is
                // terminal for the chain (Lens C F1):
                // Auto falls through to the next series,
                // manual shows the slate — never a silent
                // park on the ended item.
                self.advancePending = false
                self.terminalFailure(reason: "advance chain: resolve tập \(nextIndex + 1) thất bại")
            }
        }
    }

    /// A prefetch that failed while an advance was armed
    /// (a press, or the episode ending mid-prefetch)
    /// hands the arm to the gated chain instead of
    /// dropping it (review round 2, BLOCKERs 1+2).
    /// Gated EXACTLY like the success path (review round
    /// 5, BLOCKER): while a recovery holds the gate, the
    /// arm must SURVIVE — clearing it here and calling a
    /// chain whose guard then refuses is how an advance
    /// gets silently destroyed. The recovery completion
    /// is the arm's consumer in that ordering.
    private func handOffArmedAdvance() {
        if advancePending, !opInFlight {
            advancePending = false
            runAdvanceChain()
        }
    }

    private func performAdvance() {
        guard let queued = queuedItem, player.currentItem !== queued else { return }
        player.advanceToNextItem()
        // An advance consumed after the current item had
        // already ENDED (the late-prefetch path) leaves
        // the player paused on the new item — press play
        // explicitly; while already playing this is a
        // no-op.
        player.play()
        // FL-343 (A): stamp the expectation. The
        // supervisor's transition bookkeeping clears it
        // when the queue's current item actually becomes
        // the queued one; if 20 s pass with the player
        // parked .paused and the playhead frozen, the
        // advance never landed — the paused-limbo leg.
        advanceUnconfirmedSince = Date()
        advanceUnconfirmedPosition = player.currentTime().seconds
        pausedStallSince = nil
        log("advanceToNextItem — chờ supervisor xác nhận bằng item identity")
    }

    // MARK: Media selections (defaults + owner's manual picks)

    /// On an item's ready: apply the standing defaults
    /// (subtitles vi → en, audio en) ONLY where the owner
    /// has not picked manually; a manual pick is captured
    /// from the outgoing item and re-applied instead
    /// (FL-049). The assembled HLS carries the single
    /// resolved audio rendition and no subtitle rendition
    /// — the groups are then simply absent and this is a
    /// no-op, which the log records once per item.
    private func applyMediaSelections(to item: AVPlayerItem?) {
        guard let item else { return }
        let asset = item.asset
        for characteristic in [AVMediaCharacteristic.legible,
                               AVMediaCharacteristic.audible] {
            guard let group = asset.mediaSelectionGroup(forMediaCharacteristic: characteristic),
                  !group.options.isEmpty else { continue }
            if let manual = manualSelections[characteristic] {
                item.select(manual, in: group)
                continue
            }
            if characteristic == .legible {
                // Locale.languageCode is deprecated
                // since tvOS 16 (review round 7, MINOR);
                // the supported replacement is in-slice
                // for the tvOS 17 floor.
                let pick = group.options.first { $0.locale?.language.languageCode?.identifier == "vi" }
                    ?? group.options.first { $0.locale?.language.languageCode?.identifier == "en" }
                if let pick { item.select(pick, in: group) }
            } else {
                let pick = group.options.first { $0.locale?.language.languageCode?.identifier == "en" }
                    ?? group.defaultOption
                if let pick { item.select(pick, in: group) }
            }
        }
    }

    private func captureManualSelections(from item: AVPlayerItem?) {
        guard let item else { return }
        for characteristic in [AVMediaCharacteristic.legible,
                               AVMediaCharacteristic.audible] {
            if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) {
                manualSelections[characteristic] = item.currentMediaSelection
                    .selectedMediaOption(in: group)
            }
        }
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
}

// MARK: - Player controller host

/// AVPlayerViewController as the ONLY transport surface:
/// the OS renders its focus, its panel carries the
/// subtitle/audio pickers, and no SwiftUI control is
/// overlaid on it (the 11:15 lesson).
private struct JoeYtPlayerControllerView: UIViewControllerRepresentable {
    let player: AVQueuePlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController,
                                context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

// MARK: - Player view

struct JoeYtNativePlayerView: View {
    let request: JoeYtPlayRequest
    /// The router's §4.6 swap: fired by the model when
    /// the native construction dies outright (assembly
    /// + muxed both unusable).
    var onPageFallback: (() -> Void)? = nil
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var watch: WatchStore
    @Environment(\.joeTheme) private var theme
    @StateObject private var model: JoeYtNativePlayerModel
    @FocusState private var retryFocused: Bool

    init(request: JoeYtPlayRequest, firstPlayable: JoeYtPlayable,
         onPageFallback: (() -> Void)? = nil) {
        self.request = request
        self.onPageFallback = onPageFallback
        _model = StateObject(wrappedValue: JoeYtNativePlayerModel(
            request: request, firstPlayable: firstPlayable))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // The controller is in the tree ONLY while it
            // is the live surface (starting/playing). On
            // the failure/end slates it leaves the tree, so
            // the slate's button is the only focusable
            // thing on screen — an AVPlayerViewController
            // left mounted under an overlay is a focus
            // trap (the 2026-11-20 11:15 lesson).
            if model.phase == .starting || model.phase == .playing {
                JoeYtPlayerControllerView(player: model.player)
                    .ignoresSafeArea()
            }
            if model.phase == .starting {
                veil
            }
            if let line = model.statusLine {
                statusPill(line)
            }
            if model.phase == .ended {
                endSlate
            }
            if case .failed(let text) = model.phase {
                failureSlate(text)
            }
        }
        // Menu closes THIS player back to the detail (the
        // house own-root construction).
        .onExitCommand { nav.ytPlayer = nil }
        .onAppear {
            model.attachStore(watch)
            model.onPageFallback = onPageFallback
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
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    /// The veil (Sony lesson 2's shape, the page player's
    /// own construction): the owner never sees a dead
    /// surface — this slate, then film.
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
}
