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
    /// FIX-7 (2.1.1, owner decision 2026-11-22 02:40 CST):
    /// this screen NO LONGER carries a trailer preview or
    /// the device-code prompt it used to surface. TVB
    /// trailers on YouTube are ~all 480p and died at the
    /// <720p quality gate, so the owner replaced them with
    /// the title's highest-quality STILL as the backdrop
    /// ("khỏi trailer cho tvb lấy hình tĩnh chất lượng cao
    /// nhất"). With no trailer attempt, the preview's
    /// .needsIdentity surfacing (DIAG-2050 §1c) can never
    /// fire here, so its prompt state is removed with it —
    /// playback identity is NOT touched: an episode tap
    /// still goes through the router, which opens the
    /// device-code surface itself when playback needs it
    /// (see tapEpisode / the §4.1 note below).
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
    /// FIX-213 (Fault 1, DIAG-20261122): the Menu exit's
    /// second-press arm — Menu #1 jumps to the top and
    /// arms this, Menu #2 closes, independent of whether
    /// the jump's programmatic chipFocus write landed
    /// (the chain detail's exitArmed, same construction).
    /// Cleared by any focus change (the chipFocus /
    /// epFocus stages in body below).
    @State private var exitArmed = false
    /// Super VIP press feedback: the honest above-tier
    /// message, promoted from a quiet line to the accented
    /// notice when an episode is actually pressed.

    @FocusState private var epFocus: Int?
    @FocusState private var chipFocus: String?
    /// FIX-10b / F13: the PC back row's focus binding —
    /// its own, so the row never touches the episode /
    /// chip focus the composition's default focus and
    /// the exit handler are built on.
    @FocusState private var backFocus: Bool

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
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(29) : .system(size: 29))
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
        // FIX-7 (2.1.1): the v2.0.49 preview kill hooks
        // that used to stage between the exit hook and
        // the task (focus-input reports, the player /
        // scene-phase kills, the onDisappear stop) are
        // GONE with the preview itself — no preview ever
        // starts on this TVB screen, so there is nothing
        // for a kill-on-input discipline to engage.
        let exitStage = rootContent
            .onExitCommand { handleExitCommand() }
        // FIX-213 (Fault 1): any focus change on this
        // screen disarms the Menu exit (see exitArmed) —
        // two more stepwise stages in the FL-390 shape.
        let chipFocusStage = exitStage
            .onChange(of: chipFocus) { _, _ in exitArmed = false }
        let epFocusStage = chipFocusStage
            .onChange(of: epFocus) { _, _ in exitArmed = false }
        let taskStage = epFocusStage
            .task {
                ytStore.ensureLoaded()
                await session.refresh()
            }
        return AnyView(taskStage)
    }

    /// Menu / exit (v2.0.49 — owner order 2026-11-21
    /// 22:32 CST: "nút back trên tvos sẽ nhảy thẳng về
    /// đầu trang"). Focus already resting on the
    /// "src:auto" source chip means the press closes
    /// the detail as before; anywhere else, the press
    /// jumps straight back to the top (scroll signal +
    /// focus to the chip) and the exit is swallowed.
    /// (FIX-10b / F13: under Private Cinema the back row
    /// now leads the composition, but this handler is
    /// unchanged — exactly as on the chain detail, whose
    /// Menu-close keys on Play, not on its back row; the
    /// back row's own press dismisses directly.)
    /// (FIX-213: the handler now also carries the
    /// exitArmed second-press close — see exitArmed.)
    /// (FIX-7: the per-branch preview kills this handler
    /// used to perform are removed — no preview exists
    /// on this screen.)
    private func handleExitCommand() {
        if chipFocus == "src:auto" {
            nav.ytDetail = nil
        } else if exitArmed {
            // FIX-213 (Fault 1): the previous Menu already
            // jumped to the top and armed the exit; this
            // press closes even if the chipFocus write
            // never landed.
            nav.ytDetail = nil
        } else {
            topScrollSignal += 1
            chipFocus = "src:auto"
            exitArmed = true
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
                        // 2.1.1: under Private Cinema the
                        // header and source row take the
                        // chain-detail family composition
                        // (cinemaHeader / cinemaSourceRow);
                        // every other theme keeps the
                        // existing constructions byte-for-byte.
                        if theme.id == .privateCinema {
                            pcBackRow
                            cinemaHeader(series)
                            cinemaSourceRow(series)
                        } else {
                            header(series)
                            sourceRow(series)
                        }
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
        // FIX-7 (2.1.1): the v2.0.49 preview dwell task
        // that used to hang here is DELETED — this TVB
        // screen makes no trailer attempt at all, so no
        // dwell, no resolve and no preview start can
        // occur. The still backdrop (backdrop(series)
        // below) is the whole visual.
    }

    // MARK: Backdrop (v2.0.49)

    /// The full-screen backdrop stack: the chain
    /// detail's Ultra stack (JoeMovieDetail) mirrored in
    /// miniature — same layer order, same two scrims.
    ///
    /// FIX-7 (2.1.1, owner decision 2026-11-22 02:40
    /// CST): NO trailer preview layer exists here any
    /// more — the backdrop IS the title's highest-quality
    /// STILL, full-bleed and sharp, in this best-variant
    /// ladder (bottom → top; the topmost loaded leg is
    /// what shows, every leg at the detail backdrop
    /// bucket — JoeBandImage targetPixels 1920 through
    /// JoeImagePipeline):
    ///   1. (bottom) the resolved poster's art, ONLY when
    ///      it is a real poster (JoeYtResolvedPoster
    ///      .isPortraitPoster: the TMDB w500 poster by
    ///      tmdbId, the chain-catalogue poster, or the
    ///      TMDB search poster) — rendered .slice, the
    ///      WS-D sharp-poster path (2.1.1 DIAG-2050 §3:
    ///      the old .blurField smear is gone), now the
    ///      PRIMARY fallback when no backdrop exists.
    ///   2. the matched chain title's OWN TMDB backdrop
    ///      (TVBTitle.cinemaBackdropURL — the snapshot's
    ///      backdropPath at w1280), when a §1.4 match
    ///      exists.
    ///   3. (top) the series' own TMDB backdrop at w1280
    ///      (loadBackdrop — TMDBClient.fetchInfo by the
    ///      series' tmdbId as "tv"): the highest-quality
    ///      still the data carries for this title.
    /// NO thumbnail-grade source feeds this backdrop:
    /// the episode-1 YouTube thumbnail (JoeYtSeries
    /// .posterURL — hqdefault, 480×360 — and the resolver's
    /// .youtubeThumbnail result, which is that same URL)
    /// is deliberately NOT a leg; when every still leg
    /// misses, the scrims paint over the bare theme
    /// background rather than a thumbnail blowing up
    /// full-screen. The thumbnail still serves the small
    /// header/card slots elsewhere, untouched.
    private func backdrop(_ series: JoeYtSeries) -> some View {
        return ZStack {
            if let resolvedPoster, resolvedPoster.isPortraitPoster,
               let poster = resolvedPoster.url {
                JoeBandImage(url: poster, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .slice)
            }
            if let backdropURL = matchedTitle?.cinemaBackdropURL {
                JoeBandImage(url: backdropURL, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .slice)
            }
            if !tmdbBackdropURLString.isEmpty,
               let u = URL(string: tmdbBackdropURLString) {
                JoeBandImage(url: u, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .slice)
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

    // MARK: - Backdrop preview — REMOVED (FIX-7, 2.1.1)

    /// The v2.0.49 TMDB-trailer preview driver that used
    /// to live here (runPreview) is DELETED, not gated:
    /// this screen is TVB by definition, and the owner
    /// ruled TVB gets NO trailer (2026-11-22 02:40 CST)
    /// — its YouTube trailers are ~all 480p and died at
    /// the <720p quality gate. The shared preview
    /// machinery itself (JoePreview.swift) is untouched:
    /// the chain detail and torrent/Phim surfaces that
    /// still preview keep using it. With the attempt
    /// gone, its .needsIdentity ending can never occur
    /// here, so the DIAG-2050 §1c device-code prompt it
    /// surfaced is deleted below as well (it had no
    /// other caller; playback's own identity need is
    /// served by the router at tap time, unchanged).

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

    /// The AGGREGATED source chips (design §1.6), shared
    /// by the standard source row and the Private Cinema
    /// source row: Tự động · YouTube · one chip per chain
    /// source that GENUINELY carries this series (the
    /// matched title's providers, in the chain's own
    /// priority order — a chip exists only when that
    /// provider's record carries a slug, and tapping it
    /// opens the real chain detail via openChain) · the
    /// user addon's backup when it matched this series.
    /// No Torrent chip: this file's data carries no
    /// torrent identity for the series (JoeYtSeries has
    /// a TMDB id only — no IMDb id, no TorMeta), so a
    /// Torrent entry here would be a fabricated route.
    private func sourceChips(_ series: JoeYtSeries) -> some View {
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
    }

    /// The mode explanation line under the chips (shared
    /// by both source-row arms).
    private var modeNote: some View {
        Text(mode == .auto
             ? "Tự động: ưu tiên YouTube; nếu YouTube không phát được mà phim có ở nguồn khác, app tự chuyển nguồn."
             : "YouTube: chỉ phát qua YouTube, không tự chuyển nguồn.")
            .font(theme.id == .privateCinema
                  ? JoePCType.outfit(23) : .system(size: 23))
            .foregroundStyle(theme.meta)
            .frame(maxWidth: 1250, alignment: .leading)
    }

    private func sourceRow(_ series: JoeYtSeries) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nguồn phát")
                .font(.system(size: 29, weight: .bold))
                .foregroundStyle(theme.text)
            sourceChips(series)
            modeNote
        }
    }

    /// FIX-10b / F13: the chain-detail family's leading
    /// "← Quay lại" row (pcBackRow in JoeMovieDetail,
    /// mirrored): a plain button in its own focus
    /// section at the head of the PC composition. Its
    /// press runs this view's real dismiss — the same
    /// `nav.ytDetail = nil` the exit handler's closing
    /// branch performs. The declared default focus is
    /// untouched (the content's .defaultFocus still
    /// lands on the episode list), so entry focus stays
    /// on the primary content, never on this row.
    private var pcBackRow: some View {
        HStack(spacing: 0) {
            Button {
                nav.ytDetail = nil
            } label: {
                JoeYtPCBackLabel()
            }
            .joeCardButton()
            .focused($backFocus)
            Spacer(minLength: 0)
        }
        .focusSection()
    }

    // MARK: Private Cinema composition (2.1.1)

    /// Private Cinema header: the chain-detail family
    /// composition (privateCinemaDetail in JoeMovieDetail)
    /// carried to this screen — NO poster card, the title
    /// block sits over the full-bleed backdrop: a
    /// letterspaced eyebrow, a serif typeset title, and
    /// the meta lines (channel · episode count · views ·
    /// the measured quality badge) in the hero-meta
    /// colour. Every value is the series' own real field.
    private func cinemaHeader(_ series: JoeYtSeries) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TVB / YOUTUBE")
                .font(JoePCType.outfit(15, weight: .medium))
                .tracking(3.6)
                .foregroundStyle(theme.heroMeta)
                .lineLimit(1)
                .padding(.top, 30)
            Text(series.title)
                .font(JoePCType.display(100))
                .tracking(-3)
                .foregroundStyle(theme.text)
                .lineLimit(3)
                .padding(.top, 16)
            HStack(spacing: 12) {
                JoeChipLabel(title: series.tierLabel,
                             selected: series.isMembersTier)
                JoeChipLabel(title: "YouTube", selected: false)
            }
            .padding(.top, 16)
            Text("\(series.channelDisplay) · \(series.eps.count) tập")
                .font(JoePCType.outfit(25))
                .foregroundStyle(theme.heroMeta)
                .padding(.top, 12)
            if let views = series.views {
                Text("\(views.formatted()) lượt xem trên YouTube")
                    .font(JoePCType.outfit(25))
                    .foregroundStyle(theme.heroMeta)
                    .padding(.top, 6)
            }
            if let badge = JoeYtQualityMap.badgeText(pid: series.pid) {
                Text("Chất lượng cao nhất đã đo trên máy này: \(badge)")
                    .font(JoePCType.outfit(25))
                    .foregroundStyle(theme.heroMeta)
                    .padding(.top, 6)
            }
        }
    }

    /// Private Cinema source block: the design's "Chọn
    /// nguồn phát" heading over the SAME aggregated chips
    /// the standard row carries (sourceChips) — Tự động ·
    /// YouTube · the chain sources that carry this title ·
    /// the addon backup. No numbered server cards exist
    /// here: this screen's sources are modes and hand-offs,
    /// not server entries, so the chips ARE the honest
    /// aggregation unit (the chain detail's numbered cards
    /// dress ITS server list, a different data shape).
    private func cinemaSourceRow(_ series: JoeYtSeries) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Chọn nguồn phát")
                .font(JoePCType.display(34))
                .foregroundStyle(theme.text)
                .padding(.top, 8)
            sourceChips(series)
            modeNote
        }
    }

    // MARK: Sign-in prompt — REMOVED (FIX-7, 2.1.1)

    /// The DIAG-2050 §1c device-code prompt that used to
    /// live here existed ONLY for the trailer preview's
    /// .needsIdentity ending. FIX-7 deletes the trailer
    /// attempt on this TVB screen, so the prompt's one
    /// trigger is gone and the prompt is deleted with
    /// it — no dead prompt path is left wired to
    /// nothing. Playback is unaffected: when PLAYBACK
    /// itself needs identity, the router opens the
    /// device-code surface at tap time (tapEpisode's
    /// §4.1 contract below), exactly as before.

    private func sourceChip(id: String, title: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        // FIX-7 (2.1.1): the v2.0.49 armed preview kill
        // this press used to perform is gone — no preview
        // ever starts on this TVB screen.
        Button {
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
            .font(theme.id == .privateCinema
                  ? JoePCType.outfit(25) : .system(size: 25))
            .foregroundStyle(theme.meta)
            .frame(maxWidth: 1250, alignment: .leading)
    }

    // MARK: Episodes

    private func episodes(_ series: JoeYtSeries) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Danh sách tập")
                .font(theme.id == .privateCinema
                      ? JoePCType.outfit(29, weight: .bold)
                      : .system(size: 29, weight: .bold))
                .foregroundStyle(theme.text)
            // FL-352 (2.0.45, leg 5): the saved-position
            // label — the row's own epLabel ("Đang xem:
            // Tập N"), shown only when the row names an
            // episode this series actually carries.
            if let row = resumeRow, let ri = resumeIndex,
               ri < series.eps.count {
                Text(row.epLabel)
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(25, weight: .semibold)
                          : .system(size: 25, weight: .semibold))
                    .foregroundStyle(JoeTheme.okGreen)
            }
            // Lazy by requirement (design §1.5): a 444-episode
            // series scrolls as cheaply as a 20-episode one.
            // 2.1.1: COMPACT EPISODE CHIPS in a wrapping grid
            // — the owner ordered the Sony chain detail's
            // compact-chip shape on tvOS too (2026-11-22
            // 01:20–01:32 CST), replacing the long full-width
            // bars his 01:31 photo showed. This episode list
            // is ONE shared construction for every theme in
            // this file (no per-theme branch exists to scope
            // it to Private Cinema alone), so the chips are
            // the construction for ALL themes here — a
            // deliberate all-theme change, flagged in the
            // WS-D report for the gate.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)],
                      alignment: .leading, spacing: 14) {
                ForEach(Array(series.eps.enumerated()), id: \.offset) { pair in
                    Button {
                        tapEpisode(pair.offset, series: series)
                    } label: {
                        JoeYtEpisodeChipLabel(
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
        // FIX-7 (2.1.1): the v2.0.49 armed preview kill
        // this tap used to perform is gone — no preview
        // ever starts on this TVB screen.
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

// MARK: - Episode chip label

/// One compact episode chip (2.1.1): the episode number
/// over the episode's own title from the playlist, in a
/// small wrapping-grid cell — the Sony chain detail's
/// compact-chip shape the owner ordered for tvOS too.
/// Painted with the theme tokens in the chip family's
/// construction (resting stroke, focus ring inside).
private struct JoeYtEpisodeChipLabel: View {
    let index: Int
    let title: String
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tập \(index + 1)")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Text(title.isEmpty ? "Tập \(index + 1)" : title)
                .font(.system(size: 21))
                .foregroundStyle(theme.meta)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.surface2))
        // Fault 11 fix round: the resting hairline is its
        // own always-installed overlay and the focus ring is
        // the chip family's (JoeChipRing) — under Private
        // Cinema the ivory outset outline (2 px, offset
        // 4 px); under every other theme the house
        // JoeFocusRing over the hairline, which the 4 px
        // inside band covers exactly as the single-overlay
        // expression did.
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
            theme.stroke, lineWidth: 1.5))
        .overlay(JoeChipRing(shape: RoundedRectangle(cornerRadius: 14)))
    }
}

// MARK: - PC back label

/// The PC back row's label (FIX-10b / F13): the chain
/// detail's PCDetailBackLabel dressing mirrored for
/// this file (that struct is private to JoeMovieDetail)
/// — arrow glyph + "Quay lại", focus recolours the text
/// to theme.focus, value-only: no plate, no ring of its
/// own, no scale; the button's native kit treatment is
/// the focus rendering.
private struct JoeYtPCBackLabel: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left")
                .font(.system(size: 24, weight: .medium))
            Text("Quay lại")
                .font(JoePCType.outfit(26))
        }
        .foregroundStyle(isFocused ? theme.focus : theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
