import SwiftUI

// MARK: - YouTube detail routes

struct JoeYtRoute: Hashable, Sendable, Identifiable {
    let pid: String
    var id: String { pid }
}

/// The detail's source-row modes (design §1.6). Chain chips
/// are actions, not modes: tapping one hands off to the
/// existing MovieRoute flow immediately.
enum JoeYtSourceMode: String, Sendable {
    case auto
    case youtube
}

struct JoeYtPlayRequest: Identifiable, Sendable {
    let id = UUID()
    let pid: String
    /// The series' full ordered episode video-ID list
    /// (playlist order = episode order) — the player carries
    /// it so next-episode and auto-next never re-read the
    /// catalogue mid-play.
    let videoIds: [String]
    let startIndex: Int
    let mode: JoeYtSourceMode
    let tier: String
    let seriesTitle: String
    /// The matched title's TMDB id (0 = YouTube-only or
    /// the match never passed the in-app check). Carried
    /// so the native player's WatchStore rows stamp the
    /// stable title identity (design §3.4 / FL-058) —
    /// never used to gate or route playback.
    let tmdbId: Int
    /// The matched 803 title's primary chain route, minted by
    /// the detail at tap time; consumed ONLY by Auto's
    /// fall-through when every YouTube surface fails
    /// (design §1.6). Nil for YouTube-only series.
    let chainRoute: MovieRoute?
    /// The unified-detail hand-back (the owner's shared-grid
    /// ruling, 2026-11-19): when the player was launched
    /// from INSIDE the existing chain detail (JoeMovieDetail)
    /// in Auto mode, a total YouTube failure hands THIS
    /// episode back to that same detail, which plays it via
    /// the chain — the app substitutes a working source
    /// itself, in the same screen. Nil outside that flow
    /// (and always nil for a manual YouTube pick).
    let chainPlay: JoeYtChainPlay?
}

/// One chain-play hand-back token: the detail route it
/// belongs to, the chain episode name to play, and a nonce
/// so repeated hand-backs for the same episode still
/// register as changes.
struct JoeYtChainPlay: Equatable, Sendable {
    let route: MovieRoute
    let epName: String
    let nonce: UUID
}

// MARK: - Our detail screen for a YouTube series (design §1.5)
//
// Serves the YouTube-ONLY series (no chain entry): reached
// from a YouTube rail card or from search when the series
// has no §1.4 match. A MATCHED series never lands here —
// every entry point opens the existing chain detail
// (JoeMovieDetail) instead, where the YouTube source row
// and the ONE shared episode grid live (the owner's
// shared-grid ruling, 2026-11-19: episode buttons "phải ăn
// chung" — Auto takes YouTube per-episode, the chain covers
// the episodes YouTube lacks; a parallel YouTube-only grid
// for a matched title strands the chain's episodes, the
// exact fault he ruled against on the Sony build). Built
// from the existing detail construction — same chips, same
// labels, no new visual language (the design freeze holds).

struct JoeYtDetail: View {
    let route: JoeYtRoute
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var watch: WatchStore
    @Environment(\.joeTheme) private var theme
    @ObservedObject private var ytStore = JoeYtStore.shared
    @ObservedObject private var session = JoeYtSession.shared
    /// v2.0.45 (leg 3): the user addon store — read for
    /// this series' backup-source match (sourceRow).
    @ObservedObject private var addonStore = JoeAddonStore.shared
    @State private var mode: JoeYtSourceMode = .auto
    /// 2.0.47: this series' resolved poster (JoeYtPoster
    /// Resolver: TMDB by tmdbId → chain-catalogue poster by
    /// normalised title → episode-1 thumbnail). Nil until
    /// the content's resolve task lands; the header paints
    /// its placeholder meanwhile, never the thumbnail first.
    @State private var resolvedPoster: JoeYtResolvedPoster?
    /// v2.0.49: the backdrop preview's controller — this
    /// screen gains the trailer preview the chain detail
    /// has (TMDB trailer only; see runPreview below).
    @StateObject private var preview = JoePreviewController()
    /// v2.0.49: the series' own TMDB backdrop URL
    /// (backdrop leg 1), resolved alongside the poster.
    /// Empty until / unless it lands; the backdrop then
    /// falls to the next leg.
    @State private var tmdbBackdropURLString = ""
    /// v2.0.49 (owner order 2026-11-21 22:32 CST): the
    /// Back-to-top signal — the exit handler bumps it
    /// and the ScrollViewReader scrolls the content's
    /// top id back into view.
    @State private var topScrollSignal = 0
    /// v2.0.49: scene phase, for the preview kill hook
    /// (mirrors JoeMovieDetail's wiring).
    @Environment(\.scenePhase) private var scenePhase
    /// Super VIP press feedback: the honest above-tier
    /// message, promoted from a quiet line to the accented
    /// notice when an episode is actually pressed.

    @FocusState private var epFocus: Int?
    @FocusState private var chipFocus: String?

    private var series: JoeYtSeries? {
        ytStore.snapshot?.byPid[route.pid]
    }

    private var matchedTitle: TVBTitle? {
        guard let snapshot = ytStore.snapshot,
              let series else { return nil }
        return snapshot.matchedTitleByPid[series.pid]
    }

    /// FL-352 (2.0.45, leg 5): the saved progress row for
    /// this series (the detail never read the store
    /// before this leg). One row per series — its latest
    /// episode — so the row's episode is the preselect
    /// target; the player itself resumes the position
    /// when that episode is played.
    private var resumeRow: WatchStore.Entry? {
        watch.progressFor(key: WatchStore.ytProgressKey(pid: route.pid))
    }

    /// The 0-based index resumeRow names, or nil when
    /// there is no row (or the row names no episode).
    private var resumeIndex: Int? {
        guard let row = resumeRow else { return nil }
        let n = WatchStore.episodeNumber(of: row)
        return n >= 1 ? n - 1 : nil
    }

    /// FL-390 cure (CI run #36): the content expression,
    /// erased to AnyView so the root hook chain below
    /// composes against a concrete base — the first half
    /// of the construction that cured JoeMovieDetail's
    /// migrating timeouts in 2.0.48 (runs #30–#35).
    private var rootContent: AnyView {
        AnyView(Group {
            if let series {
                content(series)
            } else {
                ProgressView("Đang tải danh sách TVB…")
                    .font(.system(size: 29))
                    .foregroundStyle(theme.text)
                    .tint(theme.text)
            }
        })
    }

    var body: some View {
        // FL-390 cure (CI run #36): the seven root hooks
        // are composed STEPWISE — one modifier per let
        // binding, each statement priced on its own —
        // instead of one chain on the Group, whose single
        // expression timed the type-checker out at the
        // closing .task (run #36, JoeYtDetail.swift:180).
        // Modifier order, closures and conditions are
        // identical to the chained form this replaces.
        // Own-root Menu handler (the 1.9.2 construction),
        // extended v2.0.49 by the owner's Back-to-top
        // order — see handleExitCommand.
        let exitStage = rootContent
            .onExitCommand { handleExitCommand() }
        // v2.0.49: the preview kill hooks, wired exactly
        // as JoeMovieDetail wires them — every focus
        // binding reports through focusInput (the value
        // shape rule: an optional binding landing is
        // unset → set), the player presentation and the
        // scene phase kill explicitly, and disappearing
        // stops the preview outright.
        let epFocusStage = exitStage
            .onChange(of: epFocus) { old, new in
                preview.focusInput(landingShaped: old == nil && new != nil)
            }
        let chipFocusStage = epFocusStage
            .onChange(of: chipFocus) { old, new in
                preview.focusInput(landingShaped: old == nil && new != nil)
            }
        let playerStage = chipFocusStage
            .onChange(of: nav.ytPlayer?.id) { handleYtPlayerPresentation() }
        let sceneStage = playerStage
            .onChange(of: scenePhase) { handleScenePhaseChange() }
        let disappearStage = sceneStage
            .onDisappear { preview.stop() }
        let taskStage = disappearStage
            .task {
                ytStore.ensureLoaded()
                await session.refresh()
            }
        return AnyView(taskStage)
    }

    /// The YouTube player's presentation kills the
    /// preview (v2.0.49; mirrors JoeMovieDetail's hook —
    /// an episode tap with focus already resting on the
    /// row changes no focus binding, so this hook is
    /// the one that catches it).
    private func handleYtPlayerPresentation() {
        if nav.ytPlayer != nil { preview.kill(reason: "play") }
    }

    /// The scene leaving the foreground kills the
    /// preview (v2.0.49; mirrors JoeMovieDetail).
    private func handleScenePhaseChange() {
        if scenePhase != .active { preview.kill(reason: "inactive") }
    }

    /// Menu / exit (v2.0.49 — owner order 2026-11-21
    /// 22:32 CST: "nút back trên tvos sẽ nhảy thẳng về
    /// đầu trang"). The press kills the preview per
    /// branch (unconditional on close, armed on the
    /// jump — see the body). Then: focus
    /// already resting on the page's first focusable
    /// element — the "src:auto" source chip at the top
    /// of the page — means the press closes the detail
    /// as before; anywhere else, the press jumps
    /// straight back to the top (scroll signal + focus
    /// to the chip) and the exit is swallowed.
    private func handleExitCommand() {
        // Gate R1 (lens C): as in the chain detail — the
        // close branch kills unconditionally; the
        // jump-to-top branch keeps the visit alive, so it
        // may only kill an attempt in flight, never latch.
        if chipFocus == "src:auto" {
            preview.kill(reason: "menu")
            nav.ytDetail = nil
        } else {
            preview.killIfAttempting(reason: "menu")
            topScrollSignal += 1
            chipFocus = "src:auto"
        }
    }

    // MARK: Content

    private func content(_ series: JoeYtSeries) -> some View {
        // v2.0.49: the content now sits OVER a full-screen
        // backdrop stack (backdrop(series) below) — this
        // screen previously painted straight onto the
        // bare theme background.
        ZStack {
            backdrop(series)
            // v2.0.49 Back-to-top: the reader owns the
            // scroll view; the exit handler's signal
            // scrolls the content VStack's top id back
            // into view (see handleExitCommand).
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        header(series)
                        sourceRow(series)
                        if series.isSuperVIP {
                            vipNotice
                        }
                        episodes(series)
                    }
                    .id("joeYtDetailTop")
                    .padding(.horizontal, 80)
                    .padding(.vertical, 60)
                }
                .onChange(of: topScrollSignal) {
                    proxy.scrollTo("joeYtDetailTop", anchor: .top)
                }
            }
        }
        // FL-352 (2.0.45, leg 5): entry focus lands on
        // the saved episode when one exists (clamped to
        // the loaded episode list), else the first
        // episode, exactly as before.
        .defaultFocus($epFocus, resumeIndex.map {
            min($0, series.eps.count - 1)
        } ?? 0)
        // 2.0.47: resolve this series' real poster (cached
        // per pid in the resolver, so a re-entry is a
        // cache read, not a new TMDB call). v2.0.49: the
        // backdrop's TMDB leg resolves in the same task.
        .task(id: series.pid) {
            resolvedPoster = await JoeYtPosterResolver.resolve(series)
            await loadBackdrop(series)
        }
        // v2.0.49: the preview dwell — keyed on the pid
        // ONLY, never on focus: a focus move is an input
        // that kills an in-flight attempt (through the
        // hooks above); it must never restart this task
        // into a fresh attempt.
        .task(id: "preview|" + series.pid) {
            await runPreview(series)
        }
    }

    // MARK: Backdrop (v2.0.49)

    /// The full-screen backdrop stack: the chain
    /// detail's Ultra stack (JoeMovieDetail) mirrored in
    /// miniature — same layer order, same two scrims.
    /// The art is the series' OWN, aspect-FILLED
    /// edge-to-edge, in priority order: (1) the TMDB
    /// backdrop by the series' tmdbId, (2) the resolved
    /// poster's art, (3) the episode-1 thumbnail. The
    /// trailer preview layer sits over the art and
    /// under both scrims. When no trailer plays, this
    /// backdrop is what shows — never the bare theme
    /// background.
    private func backdrop(_ series: JoeYtSeries) -> some View {
        let previewOpacity: Double = preview.visible && !preview.fadingOut
            ? 1 : 0
        let previewFadeDuration: Double = preview.visible ? 0.8 : 0.15
        let posterMode: JoeBandImage.PortraitMode =
            (resolvedPoster?.isPortraitPoster ?? false) ? .blurField : .slice
        return ZStack {
            if let thumb = series.posterURL {
                JoeBandImage(url: thumb, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .slice)
            }
            if let poster = resolvedPoster?.url {
                JoeBandImage(url: poster, targetPixels: 1920,
                             anchor: 0.16, portraitMode: posterMode)
            }
            if !tmdbBackdropURLString.isEmpty,
               let u = URL(string: tmdbBackdropURLString) {
                JoeBandImage(url: u, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .slice)
            }
            // The trailer preview's video layer — above
            // the backdrop images, below BOTH scrims,
            // exactly as in the chain detail's stack.
            // Present only while a preview player exists;
            // opacity carries the crossfades (see
            // JoePreview.swift).
            if preview.player != nil {
                JoePreviewLayerView(controller: preview)
                    .opacity(previewOpacity)
                    .animation(.easeInOut(duration: previewFadeDuration),
                               value: preview.visible)
                    .animation(.easeInOut(duration: 0.8),
                               value: preview.fadingOut)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            LinearGradient(stops: [
                .init(color: .black.opacity(0.85), location: 0),
                .init(color: .black.opacity(0.40), location: 0.5),
                .init(color: .black.opacity(0.05), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.30), location: 0),
                .init(color: .clear, location: 0.35),
                .init(color: theme.bg.opacity(0.88), location: 0.85),
                .init(color: theme.bg, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Background layers ignore the safe area,
        // content respects it — the platform's own
        // idiom, as in the chain detail (v2.0.22 there).
        .ignoresSafeArea()
    }

    /// Backdrop leg 1 (v2.0.49): the series' OWN TMDB
    /// backdrop, fetched by its tmdbId as "tv" — the
    /// same identity pin the chain detail's enrichment
    /// uses. Fail-soft: no id / no backdrop / a failed
    /// call leaves the string empty and the backdrop
    /// falls to the poster leg.
    private func loadBackdrop(_ series: JoeYtSeries) async {
        tmdbBackdropURLString = ""
        guard series.tmdbId > 0 else { return }
        let info = await TMDBClient.fetchInfo(
            tmdbId: String(series.tmdbId), type: "tv")
        guard !Task.isCancelled else { return }
        tmdbBackdropURLString = info?.backdropURL ?? ""
    }

    // MARK: - Backdrop preview (v2.0.49: TMDB trailer only)

    /// The trailer attempt: after the 1.5 s dwell, the
    /// series' TMDB trailer — resolved through
    /// JoeYtResolver (the player's own route) and handed
    /// to the preview player at startFraction 0 (a
    /// trailer plays from its own start). Gates mirror
    /// JoeMovieDetail's runPreview (Settings toggle,
    /// Reduce Motion). No TMDB id or no trailer → ONE
    /// PREVIEW log line and no attempt; the full
    /// backdrop above simply stays. NO episode resolve
    /// ever happens for a preview (v2.0.49 trailer
    /// redesign — the episode legs are deleted).
    private func runPreview(_ series: JoeYtSeries) async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled else { return }
        guard JoePreviewSettings.enabled else {
            DiagLog.write("PREVIEW", "preview skipped rule=settings-off")
            return
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            DiagLog.write("PREVIEW", "preview skipped rule=reduce-motion")
            return
        }
        guard series.tmdbId > 0,
              let key = await TMDBClient.fetchTrailerKey(
                  tmdbId: String(series.tmdbId), type: "tv"),
              !key.isEmpty else {
            DiagLog.write("PREVIEW", "preview skipped rule=no-trailer")
            return
        }
        // v2.0.49 fix round (Lens B F-B1): the key fetch
        // above runs BEFORE beginAttempt, so a dismissal
        // during the fetch must not let this orphaned
        // task go on to begin an attempt on a dead view.
        guard !Task.isCancelled else { return }
        guard preview.beginAttempt(kind: "trailer") else { return }
        let result = await JoeYtResolver.shared.resolve(videoId: key)
        switch result {
        case .playable(let playable, _):
            // The playable handling mirrors the chain
            // detail's trailer leg exactly (assembly
            // through the HLS server, muxed fallback,
            // direct forms; trailer-prefixed reasons).
            switch playable.kind {
            case .assembly:
                // QUALITY GATE (17:50 ruling): a known
                // sub-720 height suppresses before any
                // hand-over; unknown (0) proceeds to the
                // controller's item-level gates.
                if playable.height > 0, playable.height < 720 {
                    preview.abortAttempt(reason: "trailer-low-quality-\(playable.height)p")
                    return
                }
                if let session = await JoeYtHlsServer.shared.makeSession(
                    playable: playable,
                    userAgent: JoeYtClientSpec.tvSamsung.userAgent) {
                    DiagLog.write("PREVIEW", "preview resolve kind=trailer-assembly")
                    preview.play(url: session.url, headers: [:],
                                 startFraction: 0)
                    return
                }
                if let direct = playable.fallbackDirectURL {
                    if playable.fallbackHeight > 0, playable.fallbackHeight < 720 {
                        preview.abortAttempt(reason: "trailer-low-quality-muxed-\(playable.fallbackHeight)p")
                        return
                    }
                    DiagLog.write("PREVIEW", "preview resolve kind=trailer-muxed-fallback")
                    preview.play(url: direct, headers: [:],
                                 startFraction: 0)
                    return
                }
                preview.abortAttempt(reason: "trailer-assembly-failed")
            case .muxed, .hlsManifest:
                if playable.height > 0, playable.height < 720 {
                    preview.abortAttempt(reason: "trailer-low-quality-\(playable.height)p")
                    return
                }
                if let direct = playable.directURL {
                    DiagLog.write("PREVIEW", "preview resolve kind=trailer-direct")
                    preview.play(url: direct, headers: [:],
                                 startFraction: 0)
                    return
                }
                preview.abortAttempt(reason: "trailer-no-direct-url")
            }
        case .needsIdentity:
            preview.abortAttempt(reason: "trailer-needs-identity")
        case .membersRequired(let reason):
            preview.abortAttempt(reason: "trailer-members-required \(reason)")
        case .unplayable(let status, let reason):
            preview.abortAttempt(reason: "trailer-unplayable \(status) \(reason)")
        case .httpFailure(let status):
            preview.abortAttempt(reason: "trailer-http-\(status)")
        case .transportFailure(let message):
            preview.abortAttempt(reason: "trailer-transport \(message)")
        case .solverFailed(let step, let message):
            preview.abortAttempt(reason: "trailer-solver \(step) \(message)")
        }
    }

    private func header(_ series: JoeYtSeries) -> some View {
        HStack(alignment: .top, spacing: 34) {
            // 2.0.47: the resolved poster, not the raw
            // thumbnail. A real poster (TMDB / chain legs)
            // is FIT whole into the header frame and gated
            // .portrait — never cropped, never letterboxed
            // INTO the art; the thumbnail leg keeps the
            // old fill behaviour in the .any slot.
            JoeRemoteImage(url: resolvedPoster?.url, targetPixels: 720,
                           fit: resolvedPoster?.isPortraitPoster ?? false,
                           slotClass: (resolvedPoster?.isPortraitPoster ?? false)
                               ? .portrait : .any) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.surface2)
            }
            .frame(width: 440, height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 14) {
                Text(series.title)
                    .font(.system(size: 46, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(3)
                HStack(spacing: 12) {
                    JoeChipLabel(title: series.tierLabel,
                                 selected: series.isMembersTier)
                    JoeChipLabel(title: "YouTube", selected: false)
                }
                Text("\(series.channelDisplay) · \(series.eps.count) tập")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
                if let views = series.views {
                    Text("\(views.formatted()) lượt xem trên YouTube")
                        .font(.system(size: 25))
                        .foregroundStyle(theme.meta)
                }
                // 2.0.48 (Approach C): the honest quality
                // badge — this series' measured ceiling on
                // THIS install (JoeYtQualityMap, fed by the
                // player's real resolves), shown only when
                // a measurement exists. Unmeasured = no
                // line at all, never an assumed figure.
                if let badge = JoeYtQualityMap.badgeText(pid: series.pid) {
                    Text("Chất lượng cao nhất đã đo trên máy này: \(badge)")
                        .font(.system(size: 25))
                        .foregroundStyle(theme.meta)
                }
            }
            Spacer()
        }
    }

    // MARK: Source row (design §1.6)

    private func sourceRow(_ series: JoeYtSeries) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nguồn phát")
                .font(.system(size: 29, weight: .bold))
                .foregroundStyle(theme.text)
            HStack(spacing: 14) {
                sourceChip(id: "src:auto", title: "Tự động",
                           selected: mode == .auto) {
                    mode = .auto
                }
                sourceChip(id: "src:yt", title: "YouTube",
                           selected: mode == .youtube) {
                    mode = .youtube
                }
                if let title = matchedTitle {
                    ForEach(TVBTitle.priorityKeys, id: \.self) { key in
                        if let record = title.providers[key],
                           let slug = record.slugs.first, !slug.isEmpty {
                            sourceChip(
                                id: "src:" + key,
                                title: Providers.displayName(
                                    TVBTitle.appProviderCode(key)),
                                selected: false) {
                                openChain(title, key: key, slug: slug)
                            }
                        }
                    }
                }
                // v2.0.45 (leg 3): the user addon's backup
                // row — shown only when the addon library
                // matched this series by name (§5.6's TVB
                // key). The chip hands off to the addon's
                // own detail for the series, exactly the
                // chain chips' shape; its episodes' streams
                // route per §5.5 there.
                if let backup = addonStore.tvbBackup(forSeriesTitle: series.title),
                   let base = addonStore.servingBase {
                    sourceChip(
                        id: "src:addon",
                        title: "Nguồn phụ — \(addonStore.addonName)",
                        selected: false) {
                        nav.addonDetail = JoeAddonRoute(
                            base: base, type: backup.type,
                            metaId: backup.id, name: series.title,
                            poster: resolvedPoster?.url?.absoluteString ?? series.posterURLString,
                            year: "", addonName: addonStore.addonName)
                    }
                }
            }
            .focusSection()
            Text(mode == .auto
                 ? "Tự động: ưu tiên YouTube; nếu YouTube không phát được mà phim có ở nguồn khác, app tự chuyển nguồn."
                 : "YouTube: chỉ phát qua YouTube, không tự chuyển nguồn.")
                .font(.system(size: 23))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1250, alignment: .leading)
        }
    }

    private func sourceChip(id: String, title: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        // v2.0.49: every chip press kills an in-flight
        // preview first — a press with focus already
        // resting on the chip changes no focus binding,
        // so the focus hooks alone would miss it. Gate
        // R1 (lens C): the press keeps the user on this
        // detail, so it is the ARMED kill — pre-attempt
        // presses never latch the visit.
        Button {
            preview.killIfAttempting(reason: "input")
            action()
        } label: {
            JoeChipLabel(title: title, selected: selected)
        }
        .joeCardButton()
        .focused($chipFocus, equals: id)
    }

    // MARK: Super VIP notice

    // The 2.0.41 Gold gate row (a standing "sign into
    // the web door" button for signed-out members
    // series) is GONE: under the single-route design
    // (§4.1) identity is the device-code flow, opened
    // by the router at tap time — the door survives
    // only as the router's degraded fallback (§4.6),
    // never as a detail-level sign-in prompt.

    /// Super VIP sits ABOVE the owner's Level-2 Gold:
    /// the notice states the tier FACT only. Whether an
    /// episode plays is decided at tap time by the live
    /// /player signal through the router (§4.1's
    /// live-signal law) — this label-driven verdict
    /// ("chưa xem được") and the tap flash that used to
    /// accompany it were the 2.0.41 law and are removed.
    private var vipNotice: some View {
        Text("Mục Super VIP — hạng cao nhất của TVB trên YouTube.")
            .font(.system(size: 25))
            .foregroundStyle(theme.meta)
            .frame(maxWidth: 1250, alignment: .leading)
    }

    // MARK: Episodes

    private func episodes(_ series: JoeYtSeries) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Danh sách tập")
                .font(.system(size: 29, weight: .bold))
                .foregroundStyle(theme.text)
            // FL-352 (2.0.45, leg 5): the saved-position
            // label — the row's own epLabel ("Đang xem:
            // Tập N"), shown only when the row names an
            // episode this series actually carries.
            if let row = resumeRow, let ri = resumeIndex,
               ri < series.eps.count {
                Text(row.epLabel)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(JoeTheme.okGreen)
            }
            // Lazy by requirement (design §1.5): a 444-episode
            // series scrolls as cheaply as a 20-episode one.
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(series.eps.enumerated()), id: \.offset) { pair in
                    Button {
                        tapEpisode(pair.offset, series: series)
                    } label: {
                        JoeYtEpisodeLabel(
                            index: pair.offset,
                            title: series.epTitle(at: pair.offset))
                    }
                    .joeCardButton()
                    .focused($epFocus, equals: pair.offset)
                }
            }
            .focusSection()
        }
    }

    // MARK: Actions

    private func tapEpisode(_ index: Int, series: JoeYtSeries) {
        // v2.0.49: the tap kills an in-flight preview
        // first (the ARMED kill — gate R1, lens C); the
        // ytPlayer presentation hook then kills with
        // reason "play" when the request actually lands,
        // which is the visit-ending latch.
        preview.killIfAttempting(reason: "input")
        // EVERY tier mints the request (design §4.1 —
        // the single-route ruling superseded the 2.0.41
        // label gates that used to live here): the
        // ROUTER decides from the live signal — no
        // identity → the device-code surface; a tier
        // above the account → the honest slate from
        // /player's own UNPLAYABLE reason; playable →
        // the native player. Nothing is blocked or
        // diverted by the catalogue label at tap time,
        // and a members tap with no identity opens the
        // activation flow through the router — never a
        // quiet chain fallback, never a dead player
        // (the owner's Q2 discipline, kept; the surface
        // that serves it changed).
        nav.ytPlayer = JoeYtPlayRequest(
            pid: series.pid,
            videoIds: series.eps,
            startIndex: index,
            mode: mode,
            tier: series.tier,
            seriesTitle: series.title,
            tmdbId: matchedTitle != nil ? series.tmdbId : 0,
            chainRoute: primaryChainRoute(),
            chainPlay: nil)
    }

    /// Auto's fall-through target: the matched title's
    /// primary holder route, minted exactly as the TVB tab
    /// mints it (JoeTVBView.open).
    private func primaryChainRoute() -> MovieRoute? {
        guard let title = matchedTitle,
              let target = title.routeTarget else { return nil }
        return MovieRoute(provider: target.provider, slug: target.slug,
                          name: title.titleVi, poster: title.posterURLString,
                          year: title.yearString, tvb: title.routeContext)
    }

    /// A chain chip hands off to the existing chain detail
    /// for that holder — the chain itself is not
    /// re-implemented (design §1.6).
    private func openChain(_ title: TVBTitle, key: String, slug: String) {
        nav.movie = MovieRoute(
            provider: TVBTitle.appProviderCode(key), slug: slug,
            name: title.titleVi, poster: title.posterURLString,
            year: title.yearString, tvb: title.routeContext)
    }
}

// MARK: - Episode row label

/// One episode row: number + the episode's own title from
/// the playlist. Painted with the theme tokens in the chip
/// family's construction (resting stroke, focus ring inside).
private struct JoeYtEpisodeLabel: View {
    let index: Int
    let title: String
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        HStack(spacing: 18) {
            Text("Tập \(index + 1)")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(theme.text)
            Text(title.isEmpty ? "Tập \(index + 1)" : title)
                .font(.system(size: 24))
                .foregroundStyle(theme.meta)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
            isFocused ? theme.focus : theme.stroke,
            lineWidth: isFocused ? theme.ringWidth : 1.5))
    }
}
