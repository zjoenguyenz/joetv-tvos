import SwiftUI

// MARK: - YouTube play router (the single presentation slot)
//
// The ONE routing point for YouTube playback (owner's
// single-route ruling, 2026-11-20): JoeTVApp's
// `nav.ytPlayer` slot presents this router instead of a
// concrete player, and the router decides the surface:
//
//   resolve (authenticated tv_samsung route)
//     ├─ playable        → the native player (AVQueuePlayer)
//     ├─ needsIdentity   → the device-code sign-in surface;
//     │                    approval resumes the SAME resolve
//     ├─ membersRequired → the live signal outranks the
//     │                    catalogue label: the account's
//     │                    tier does not cover this episode
//     │                    → the honest above-tier slate
//     ├─ solverFailed    → the degraded fallback: the
//     │                    existing door+page player, with
//     │                    the failing step logged by name
//     └─ other failures  → Auto hands the episode back to
//                          the chain (the "always ready"
//                          standard); a manual YouTube pick
//                          gets the failure slate + retry
//
// Both detail screens keep their behaviour exactly —
// every JoeYtPlayRequest they mint lands here.

@MainActor
final class JoeYtPlayRouterModel: ObservableObject {
    enum State {
        case resolving
        case needsIdentity
        case playing(JoeYtPlayable)
        case membersLocked(reason: String)
        case pageFallback
        case failed(String)
    }

    @Published private(set) var state: State = .resolving
    private let request: JoeYtPlayRequest
    private var started = false
    private var attempt = 0
    /// The in-flight resolve's handle (review round 7,
    /// MINOR): stop() and a superseding runResolve()
    /// CANCEL the work — previously the task was
    /// fire-and-forget and a dismissed screen's resolve
    /// (network + player-JS fetch + solver) ran to
    /// completion behind the attempt guard, and a retry
    /// could run two resolves concurrently in the
    /// resolver actor, doubling the solver cost.
    private var resolveTask: Task<Void, Never>?
    /// How many device-code activations THIS play
    /// request has already presented. The resolver maps
    /// a stored-token LOGIN_REQUIRED back to
    /// .needsIdentity; if the answer is STILL
    /// LOGIN_REQUIRED after one completed activation,
    /// the shape is YouTube's bot-check, not a missing
    /// login — re-presenting the flow would loop the
    /// owner through approvals forever (review round 7,
    /// MINOR). One activation per request; a repeat is
    /// terminal by the §3.3 loginRequired class.
    private var identityActivations = 0
    /// Dismissal guard (review round 2, BLOCKER 3): set
    /// by the view's onDisappear. A resolve that lands
    /// after the owner has left must not mutate live
    /// navigation — correctness may not rest on the
    /// @StateObject's deallocation timing (the exit-and-
    /// immediately-reopen race).
    private var dismissed = false

    /// The view disappeared: invalidate every in-flight
    /// resolve and bar apply() from any side effect.
    func stop() {
        dismissed = true
        attempt += 1
        resolveTask?.cancel()
        resolveTask = nil
        // Own the identity flow's lifecycle too (review
        // count round 1, Lens A F-3): the Menu exit
        // through the device-code view cancels the flow
        // itself, but any OTHER router teardown (the
        // root handler clearing nav.ytPlayer, a
        // fall-through callback) would otherwise leave
        // the shared flow polling to its expiry — and
        // an approval tapped after leaving the screen
        // would save tokens silently for a surface that
        // no longer exists.
        if case .needsIdentity = state {
            JoeYtIdentity.shared.cancelDeviceCodeFlow()
        }
    }

    /// The native player reports its construction dead
    /// (assembly + muxed both unusable): swap to the
    /// degraded door+page surface — design §4.6's
    /// trigger, owned here at the routing point.
    func requestPageFallback() {
        guard !dismissed else { return }
        log("player native báo construction chết — chuyển bề mặt sang đường trang (door+page)")
        state = .pageFallback
    }

    var onFallThrough: ((MovieRoute) -> Void)?
    var onDetailFallThrough: ((JoeYtChainPlay) -> Void)?

    init(request: JoeYtPlayRequest) {
        self.request = request
    }

    private func log(_ message: String) {
        DiagLog.write("YT-ROUTE", message)
    }

    func start() {
        guard !started else { return }
        started = true
        runResolve()
    }

    /// The failure slate's retry — a fresh first
    /// resolve. The owner's own tap IS a fresh
    /// allowance (review count round 1, Lens C F3):
    /// without the reset, a request that terminated on
    /// the bot-check latch could never show the
    /// activation surface again — the latch would
    /// re-fire on the retry's first .needsIdentity and
    /// the slate would bounce instantly, contradicting
    /// this function's own "fresh" contract. §4.2's
    /// one-activation rule binds AUTOMATIC flow per
    /// play request; an explicit owner retry starts a
    /// new allowance.
    func retry() {
        identityActivations = 0
        runResolve()
    }

    /// The identity flow ended: on success, resume the
    /// resolve that was waiting for a token; on failure
    /// the sign-in surface stays up with its error (the
    /// view drives that off the identity's own state).
    func identityFlowFinished(success: Bool) {
        guard !dismissed else { return }
        if success {
            log("identity: duyệt xong — chạy lại resolve")
            runResolve()
        }
    }

    private func runResolve() {
        resolveTask?.cancel()
        attempt += 1
        let myAttempt = attempt
        state = .resolving
        let videoId = request.videoIds[request.startIndex]
        log("resolve đầu ep=\(request.startIndex + 1) tier=\(request.tier) mode=\(request.mode.rawValue)")
        resolveTask = Task { [weak self] in
            guard let self else { return }
            let result = await JoeYtResolver.shared.resolve(videoId: videoId)
            guard self.attempt == myAttempt else { return }
            self.apply(result)
        }
    }

    private func apply(_ result: JoeYtResolveResult) {
        guard !dismissed else { return }
        goldPlaybackSurface(result)
    }

    /// THE SWAP POINT (design §4.7 — the one named
    /// surface every YouTube play decision passes
    /// through): a resolve result becomes a playback
    /// surface here, in the design's order — the native
    /// route first (§4.2; the playable itself already
    /// carries the assembly→muxed order inside it),
    /// then the degraded door+page fallback (§4.6) for
    /// the failure shapes that name it (solver death,
    /// NO_FORMATS), the honest slate for a live
    /// above-tier signal, the activation surface for a
    /// missing identity, and the terminal path (Auto
    /// chain fall-through / manual slate) for the rest.
    /// Replacing a layer later means working behind
    /// this one function.
    private func goldPlaybackSurface(_ result: JoeYtResolveResult) {
        switch result {
        case .playable(let playable, _):
            identityActivations = 0
            state = .playing(playable)
        case .needsIdentity:
            if identityActivations >= 1 {
                // One full activation already completed
                // for this request and YouTube STILL
                // answers LOGIN_REQUIRED — the bot-check
                // shape (§3.3's loginRequired class), not
                // a missing login. Terminal, honestly
                // named; never a second approval loop.
                log("needsIdentity LẦN HAI sau một lượt duyệt trọn — LOGIN_REQUIRED dạng bot-check, terminal theo lớp §3.3")
                terminalFailure(message: "YouTube vẫn chặn dù đã đăng nhập (lớp chống bot).")
                return
            }
            identityActivations += 1
            log("chưa có danh tính — mở bề mặt device-code")
            state = .needsIdentity
            JoeYtIdentity.shared.beginDeviceCodeFlow()
        case .membersRequired(let reason):
            // The token existed (the resolve ran) but the
            // account's tier does not cover this episode —
            // YouTube's own reason is the honest message's
            // evidence; the slate speaks the owner's
            // above-tier language.
            log("membersRequired (tín hiệu sống thắng nhãn catalogue) — \(reason)")
            state = .membersLocked(reason: reason)
        case .solverFailed(let step, let message):
            log("solverFailed step=\(step) — \(message) → rơi xuống đường trang (door+page)")
            DiagLog.write("YT-SOLVER", "FALLBACK sang đường trang — step=\(step): \(message)")
            state = .pageFallback
        case .unplayable(let status, let reason):
            log("unplayable status=\(status) reason=\(reason.isEmpty ? "-" : reason)")
            if status == "NO_FORMATS" {
                // The authenticated response carried
                // nothing the native constructions can
                // use — §4.6's second trigger (the same
                // family as a dead assembly): the
                // door+page surface gets its chance
                // before anything goes terminal (review
                // round 7, MAJOR: this went straight to
                // terminalFailure before).
                log("NO_FORMATS — rơi xuống đường trang (door+page) theo §4.6")
                state = .pageFallback
                return
            }
            terminalFailure(message: "YouTube không cho phát tập này (\(status)).")
        case .httpFailure(let status):
            log("httpFailure status=\(status)")
            terminalFailure(message: "YouTube trả lỗi HTTP \(status) khi lấy thông tin tập.")
        case .transportFailure(let message):
            log("transportFailure — \(message)")
            terminalFailure(message: message)
        }
    }

    private func terminalFailure(message: String) {
        if let chainPlay = request.chainPlay {
            log("Auto: trả tập về detail chuỗi")
            onDetailFallThrough?(chainPlay)
        } else if request.mode == .auto, let route = request.chainRoute {
            log("Auto: rơi về chuỗi")
            onFallThrough?(route)
        } else {
            state = .failed(message + " Anh bấm Thử lại, hoặc quay lại rồi chọn nguồn khác.")
        }
    }
}

// MARK: - Router view

struct JoeYtPlayRouter: View {
    let request: JoeYtPlayRequest
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    @StateObject private var model: JoeYtPlayRouterModel
    @ObservedObject private var identity = JoeYtIdentity.shared
    @FocusState private var retryFocused: Bool
    /// FL-353 (2.0.45, leg 6): the membersLocked and
    /// loading slates each own a focus slot for their new
    /// back button — a slate with NO focusable element
    /// never receives Menu (its .onExitCommand is dead),
    /// which is exactly how the SVIP slate trapped the
    /// owner out to the tvOS Home screen.
    @FocusState private var membersLockedFocused: Bool
    @FocusState private var loadingFocused: Bool

    init(request: JoeYtPlayRequest) {
        self.request = request
        _model = StateObject(wrappedValue: JoeYtPlayRouterModel(request: request))
    }

    var body: some View {
        Group {
            switch model.state {
            case .resolving:
                loadingSlate
            case .needsIdentity:
                JoeYtDeviceCodeView(request: request)
            case .playing(let playable):
                JoeYtNativePlayerView(request: request, firstPlayable: playable,
                                      onPageFallback: { model.requestPageFallback() })
            case .membersLocked:
                membersLockedSlate
            case .pageFallback:
                // The degraded door+page surface — the
                // existing player, with its own fall-
                // through wiring, exactly as before.
                JoeYtPlayerView(request: request)
            case .failed(let text):
                failureSlate(text)
            }
        }
        .onAppear {
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
        .onDisappear {
            model.stop()
        }
        .task { model.start() }
        .onChange(of: identity.flowFinished) { _, finished in
            guard let finished else { return }
            if case .needsIdentity = model.state {
                model.identityFlowFinished(success: finished)
            }
        }
    }

    private var loadingSlate: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                ProgressView()
                    .tint(.white)
                Text("Đang mở phim…")
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(29, weight: .semibold)
                          : .system(size: 29, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(request.seriesTitle) · Tập \(request.startIndex + 1) / \(request.videoIds.count)")
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(24) : .system(size: 24))
                    .foregroundStyle(.white.opacity(0.7))
                // FL-353 sweep (2.0.45, leg 6): the same
                // latent trap as the SVIP slate — a
                // text-only slate owns no focus, so Menu
                // fell through to the system while a slow
                // resolve ran. A real button makes this
                // slate's own .onExitCommand reachable.
                Button {
                    DiagLog.write("YT-ROUTE", "slate loading — về detail (trigger=nút)")
                    nav.ytPlayer = nil
                } label: {
                    JoeSecondaryLabel(title: "Quay lại")
                }
                .joeCardButton()
                .focused($loadingFocused)
            }
        }
        // Own-root Menu handler while resolving (the
        // player surfaces carry their own once up).
        .onExitCommand {
            DiagLog.write("YT-ROUTE", "slate loading — về detail (trigger=menu)")
            nav.ytPlayer = nil
        }
        .defaultFocus($loadingFocused, true)
    }

    /// The honest above-tier slate: the live /player
    /// signal said this episode sits above the signed-in
    /// account's tier (the Super VIP shape — and any
    /// future tier YouTube adds above his).
    private var membersLockedSlate: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Tập này thuộc gói thành viên cao hơn gói của tài khoản đang đăng nhập, nên chưa xem được.")
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(29, weight: .semibold)
                          : .system(size: 29, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1200)
                Text("\(request.seriesTitle) · Tập \(request.startIndex + 1)")
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(24) : .system(size: 24))
                    .foregroundStyle(theme.meta)
                Text("Bấm Menu để quay lại danh sách tập.")
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(24) : .system(size: 24))
                    .foregroundStyle(theme.meta)
                // FL-353 (2.0.45, leg 6): the fix itself.
                // This slate was Text-only — no focusable
                // element, no default focus — so its
                // .onExitCommand never received Menu and
                // the press fell to the system, exiting
                // the app. The button below is
                // failureSlate's exact construction; with
                // it focused by default, Menu reaches the
                // slate's own handler again and the text
                // above tells the truth.
                Button {
                    DiagLog.write("YT-ROUTE", "slate membersLocked — về detail (trigger=nút)")
                    nav.ytPlayer = nil
                } label: {
                    JoeSecondaryLabel(title: "Quay lại danh sách tập")
                }
                .joeCardButton()
                .focused($membersLockedFocused)
            }
            .padding(.horizontal, 80)
        }
        .onExitCommand {
            DiagLog.write("YT-ROUTE", "slate membersLocked — về detail (trigger=menu)")
            nav.ytPlayer = nil
        }
        .defaultFocus($membersLockedFocused, true)
    }

    private func failureSlate(_ text: String) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Text(text)
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(27) : .system(size: 27))
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
        .onExitCommand { nav.ytPlayer = nil }
        .defaultFocus($retryFocused, true)
    }
}

// MARK: - Device-code sign-in surface
//
// The native route's sign-in: no Google page on the TV
// at all — the app shows the activation code, the owner
// approves it on his phone (google.com/device), and the
// router resumes the pending playback by itself. This
// surface replaces the player slot while it is up; Menu
// cancels the flow and returns to the detail.

struct JoeYtDeviceCodeView: View {
    let request: JoeYtPlayRequest
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    @ObservedObject private var identity = JoeYtIdentity.shared
    @FocusState private var retryFocused: Bool

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 22) {
                Text("Đăng nhập TVB bằng mã kích hoạt")
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(30, weight: .bold)
                          : .system(size: 40, weight: .heavy))
                    .foregroundStyle(theme.text)
                Text("Đường phát mới cần anh duyệt một lần trên điện thoại — không gõ mật khẩu trên TV, không qua trang Google trên TV.")
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(25) : .system(size: 25))
                    .foregroundStyle(theme.meta)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1250)
                if let code = identity.userCode {
                    VStack(spacing: 10) {
                        Text("MÃ KÍCH HOẠT")
                            .font(theme.id == .privateCinema
                                  ? JoePCType.outfit(22, weight: .semibold)
                                  : .system(size: 24, weight: .semibold))
                            .foregroundStyle(theme.meta)
                        Text(code)
                            .font(theme.id == .privateCinema
                                  ? JoePCType.outfit(54, weight: .bold)
                                  : .system(size: 76, weight: .heavy, design: .monospaced))
                            .foregroundStyle(theme.text)
                        Text("Mở \(identity.verificationURL) trên iPhone → nhập mã này → duyệt bằng tài khoản TVB của anh. Duyệt xong phim tự phát, không cần bấm gì thêm trên TV.")
                            .font(theme.id == .privateCinema
                                  ? JoePCType.outfit(25) : .system(size: 25))
                            .foregroundStyle(theme.meta)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 1250)
                    }
                } else if let error = identity.flowError {
                    VStack(spacing: 18) {
                        Text(error)
                            .font(theme.id == .privateCinema
                                  ? JoePCType.outfit(26) : .system(size: 26))
                            .foregroundStyle(theme.text)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 1100)
                        Button {
                            identity.beginDeviceCodeFlow()
                        } label: {
                            JoeSecondaryLabel(title: "Thử lại")
                        }
                        .joeCardButton()
                        .focused($retryFocused)
                    }
                } else {
                    ProgressView()
                        .tint(theme.text)
                    Text("Đang lấy mã kích hoạt…")
                        .font(theme.id == .privateCinema
                              ? JoePCType.outfit(25) : .system(size: 25))
                        .foregroundStyle(theme.meta)
                }
                // FL-353 sweep (2.0.45, leg 6): both
                // WAITING branches (the ~40 s code display
                // and the spinner) had no focusable element
                // at all — .defaultFocus pointed at the
                // error branch's button, which does not
                // exist here — so Menu fell through to the
                // system exactly as on the SVIP slate. The
                // Huỷ button below is the waiting branches'
                // own exit; it shares retryFocused because
                // the branches are mutually exclusive (only
                // one button exists at a time). Its action
                // is the .onExitCommand body, verbatim.
                if identity.flowError == nil {
                    Button {
                        DiagLog.write("YT-ROUTE", "slate device-code — về detail (trigger=nút)")
                        identity.cancelDeviceCodeFlow()
                        nav.ytPlayer = nil
                    } label: {
                        JoeSecondaryLabel(title: "Huỷ")
                    }
                    .joeCardButton()
                    .focused($retryFocused)
                }
                Text("\(request.seriesTitle) · Tập \(request.startIndex + 1)")
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(23) : .system(size: 23))
                    .foregroundStyle(theme.meta)
            }
            .padding(.horizontal, 80)
        }
        .onExitCommand {
            DiagLog.write("YT-ROUTE", "slate device-code — về detail (trigger=menu)")
            identity.cancelDeviceCodeFlow()
            nav.ytPlayer = nil
        }
        .defaultFocus($retryFocused, true)
    }
}
