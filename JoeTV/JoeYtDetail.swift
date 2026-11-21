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

    var body: some View {
        Group {
            if let series {
                content(series)
            } else {
                ProgressView("Đang tải danh sách TVB…")
                    .font(.system(size: 29))
                    .foregroundStyle(theme.text)
                    .tint(theme.text)
            }
        }
        // Own-root Menu handler (the 1.9.2 construction):
        // one press closes exactly this layer.
        .onExitCommand { nav.ytDetail = nil }
        .task {
            ytStore.ensureLoaded()
            await session.refresh()
        }
    }

    // MARK: Content

    private func content(_ series: JoeYtSeries) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                header(series)
                sourceRow(series)
                if series.isSuperVIP {
                    vipNotice
                }
                episodes(series)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
        }
        // FL-352 (2.0.45, leg 5): entry focus lands on
        // the saved episode when one exists (clamped to
        // the loaded episode list), else the first
        // episode, exactly as before.
        .defaultFocus($epFocus, resumeIndex.map {
            min($0, series.eps.count - 1)
        } ?? 0)
    }

    private func header(_ series: JoeYtSeries) -> some View {
        HStack(alignment: .top, spacing: 34) {
            JoeRemoteImage(url: series.posterURL, targetPixels: 720) {
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
                            poster: series.posterURL?.absoluteString ?? "",
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
        Button(action: action) {
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
