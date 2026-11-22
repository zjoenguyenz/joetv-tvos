import AVFoundation
import SwiftUI
import UIKit

// MARK: - Actor page (Ideas 1 + 20)
//
// ONE shared page for an actor, reached from two places:
//   - the TVB tab's "🎭 Diễn viên" rail (Idea 1) — .tvb
//     mode: the filmography is the bundled snapshot's
//     displayed titles whose `cast` carries the name;
//   - a movie detail's TMDB cast row (Idea 20) — .tmdb
//     mode: the person's TMDB credits, each matched to a
//     PLAYABLE title before it may render as a card.
//
// Playable matches open through the navigator's normal
// movie route, minted exactly as the presenting surface
// mints it (a PhimStore Movie's own provider/slug, or a
// TVB title's routeTarget — the JoeTVBView.open mirror).
// Credits with no playable match are NEVER dead focusable
// cards: they list as plain rows under "Chưa có nguồn
// phát", honestly labelled as having no source yet.

enum JoeActorRoute: Identifiable {
    case tmdb(personId: Int, name: String, photoURL: String)
    case tvb(name: String)

    var id: String {
        switch self {
        case .tmdb(let personId, _, _): return "tmdb|\(personId)"
        case .tvb(let name): return "tvb|\(name)"
        }
    }

    var name: String {
        switch self {
        case .tmdb(_, let name, _): return name
        case .tvb(let name): return name
        }
    }

    var photoURL: String {
        switch self {
        case .tmdb(_, _, let photoURL): return photoURL
        case .tvb: return ""
        }
    }
}

struct JoeActorPage: View {
    let route: JoeActorRoute
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var phim: PhimStore
    @Environment(\.joeTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    /// .tvb mode: the snapshot filmography (popularity desc).
    @State private var tvbTitles: [TVBTitle] = []
    /// .tmdb mode: the person's credits, split by the match.
    @State private var credits: [TMDBCreditTitle] = []
    @State private var matchedMovies: [MovieMatch] = []
    @State private var matchedTVB: [TVBMatch] = []
    @State private var unmatched: [TMDBCreditTitle] = []
    /// v2.0.31 (L8): the route a film tap chose, held until
    /// this page's cover has actually lifted (see open()).
    @State private var pendingRoute: MovieRoute?
    @FocusState private var cardFocus: String?
    @FocusState private var backFocused: Bool
    // v2.1.0 (Private Cinema): the PC filmography's own
    // preview controller + dwell task + the focused
    // item's info/backdrop record. Idle under every
    // other theme (the controller builds no player
    // until a PC trailer attempt runs).
    @StateObject private var cinemaPreview = JoePreviewController()
    @State private var cinemaFocusTask: Task<Void, Never>?
    @State private var cinemaFocusedItem: CinemaItem?
    /// v2.1.2 (filmography spec §4/§8): the TMDB person
    /// record (.tmdb mode) — h632 profile + biography for
    /// the cinema header. nil until the fetch lands, and
    /// nil for good in .tvb mode (the snapshot carries no
    /// person record; the header then runs on the route's
    /// own name with the spec's portrait fallback).
    @State private var person: TMDBPerson?
    /// v2.1.2 (filmography spec §5): the cinema grid's
    /// unified card list, built once at load from the
    /// SAME records the standard page splits into
    /// matched/unmatched — every credit (or snapshot
    /// title) whose art ladder is non-empty, newest
    /// first. The standard page never reads it.
    @State private var cinemaCards: [CinemaCard] = []
    /// v2.1.2 (filmography spec §7/§11): the trailer
    /// frame's status note — "Không có trailer" once a
    /// focus attempt has concluded with no player;
    /// "" while an attempt is pending or playing (the
    /// playing state has its own drawn text).
    @State private var cinemaTrailerNote = ""
    /// v2.1.2 (filmography spec §4): the header's
    /// tagline, computed ONCE at load (the biography's
    /// first sentence, truncated at a word boundary to
    /// its drawn 604 slot) — body never measures text.
    @State private var cinemaTagline = ""
    /// v2.1.2 (filmography spec §4, adaptation A6): the
    /// known-for titles that FIT the meta line's drawn
    /// slot, fitted once at load by the greedy rule.
    @State private var cinemaKnownFor: [String] = []
    /// v2.1.2 (filmography spec §11): the credits load
    /// FAILED (the client now returns nil for failure,
    /// distinct from a genuinely empty filmography) —
    /// the grid title slot renders the failure line
    /// instead of the no-data line. .tmdb mode only.
    @State private var creditsLoadFailed = false

    private struct MovieMatch: Identifiable {
        let credit: TMDBCreditTitle
        let movie: Movie
        var id: String { movie.id }
    }

    private struct TVBMatch: Identifiable {
        let credit: TMDBCreditTitle
        let title: TVBTitle
        var id: Int { title.tmdbId }
    }

    /// v2.1.2 (filmography spec §6/§7): the focused
    /// card's record for the cinema composition — the
    /// trailer frame's static ladder, the info line
    /// under the frame and the fixed bottom bar's role
    /// line. Built from the CREDIT's own fields wherever
    /// a credit exists (v2.1.2: TMDBCreditTitle now
    /// carries the vote, the overview and the character,
    /// so a matched film's info no longer degrades to
    /// its playable record's thinner fields); a snapshot
    /// title contributes its vote and leaves character /
    /// synopsis empty. Absent fields stay absent (rating
    /// 0 / empty strings render nothing), never invented.
    /// Index/total are stamped at resolve time so the
    /// counter is a plain read in body — nothing is
    /// recomputed on the focus path.
    private struct CinemaItem {
        let title: String
        let year: String
        let rating: Double
        let synopsis: String
        let backdropURL: URL?
        let posterURL: URL?
        let character: String
        let index: Int
        let total: Int
    }

    /// v2.1.2 (filmography spec §5): one card of the
    /// cinema grid. The target is the page's existing
    /// plumbing, unchanged: a matched PhimStore Movie, a
    /// matched (or snapshot) TVBTitle, or an unmatched
    /// credit whose press runs the page's resolve-by-
    /// TMDB-id discipline (resolveAndOpen). The display
    /// fields ride the credit (or the snapshot title in
    /// .tvb mode); date/popularity are the spec's sort
    /// keys, kept so the grid order is a load-time
    /// decision, never a body computation.
    private struct CinemaCard: Identifiable {
        enum Target {
            case movie(Movie)
            case tvb(TVBTitle)
            case credit(TMDBCreditTitle)
        }
        let focusID: String
        let target: Target
        let title: String
        let year: String
        let character: String
        let rating: Double
        let overview: String
        let posterURL: URL?
        let backdropURL: URL?
        let tmdbId: String
        let tmdbType: String
        let trailerUrl: String
        let date: String
        let popularity: Double
        var id: String { focusID }
    }

    var body: some View {
        Group {
            // v2.1.0 (Private Cinema): under PC the page
            // renders the cinema filmography; every other
            // theme keeps the standard page byte-for-byte.
            // The root modifiers below apply ONCE on the
            // Group, so both compositions share the exit,
            // disappear and load behaviour exactly.
            if theme.id == .privateCinema {
                cinemaBody
            } else {
                standardBody
            }
        }
        // Menu closes THIS page (the detail's own-root
        // handler placement): one press, one layer.
        .onExitCommand { dismiss() }
        // v2.0.31 (L8): a film tap's route swap runs HERE,
        // once the cover is gone (see open()).
        // v2.1.0 (Private Cinema): the PC preview dies
        // with the page (stop() on an idle controller is
        // a no-op teardown, so the standard themes are
        // unaffected).
        .onDisappear {
            performPendingOpen()
            cinemaFocusTask?.cancel()
            cinemaPreview.stop()
        }
        .task { await load() }
    }

    private var standardBody: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 40) {
                    header
                    content
                }
            }
        }
    }

    // MARK: - Header (the detail-header visual language)

    private var header: some View {
        HStack(alignment: .center, spacing: 28) {
            if !route.photoURL.isEmpty, let url = URL(string: route.photoURL) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.10))
                    JoeRemoteImage(url: url, targetPixels: 240) {
                        Text(String(route.name.prefix(1)))
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 110, height: 110)
                .clipShape(Circle())
                .overlay(Circle()
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1.2))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(route.name)
                    .font(theme.id == .privateCinema
                          ? JoePCType.display(44, weight: .semibold)
                          : .system(size: 44, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                JoeSecondaryLabel(title: "⟵ Quay lại")
            }
            .joeCardButton()
            .focused($backFocused)
        }
        // v2.0.29 (cluster A, item 1c): the header is its own
        // declared focus region — it stood in no section
        // while the film grid below declares one, so the
        // page's focus graph had an unsectioned head over a
        // sectioned body (every other page in the app
        // sections its header: the detail heads, the TVB
        // header, the shell's top bar).
        .focusSection()
    }

    private var subtitle: String {
        switch route {
        case .tvb(_):
            return loaded ? "\(tvbTitles.count) phim trong mục TVB"
                          : "Đang tải danh sách…"
        case .tmdb(_, _, _):
            return "Các phim có diễn viên này"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView("Đang tải…")
                .font(.system(size: 29))
                .foregroundStyle(theme.text)
                .tint(theme.text)
                .padding(.top, 30)
        } else {
            switch route {
            case .tvb(_): tvbContent
            case .tmdb(_, _, _): tmdbContent
            }
        }
    }

    @ViewBuilder
    private var tvbContent: some View {
        if tvbTitles.isEmpty {
            Text("Chưa có phim nào của diễn viên này trong danh sách TVB.")
                .font(.system(size: 29))
                .foregroundStyle(theme.meta)
        } else {
            cardGrid {
                ForEach(tvbTitles) { title in
                    tvbCard(title)
                }
            }
        }
    }

    @ViewBuilder
    private var tmdbContent: some View {
        if credits.isEmpty {
            // No credits loaded at all (no key / no network /
            // no filmography on record): say so plainly
            // instead of painting an empty page.
            Text("Chưa tải được danh sách phim của diễn viên này.")
                .font(.system(size: 29))
                .foregroundStyle(theme.meta)
        } else {
            if !matchedMovies.isEmpty || !matchedTVB.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle("Có nguồn phát")
                    cardGrid {
                        ForEach(matchedMovies) { match in
                            movieCard(match.movie)
                        }
                        ForEach(matchedTVB) { match in
                            tvbCard(match.title)
                        }
                    }
                }
            }
            if !unmatched.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle("Chưa có nguồn phát")
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(unmatched.enumerated()),
                                id: \.offset) { _, credit in
                            unmatchedRow(credit)
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: theme.id == .posterWall ? 40 : 34,
                          weight: theme.id == .posterWall ? .heavy : .bold))
            .foregroundStyle(theme.text)
    }

    /// The JoeBrowseView / TVB genre-grid construction:
    /// six columns, the wall card form under design D.
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: theme.railGap), count: 6)
    }

    private func cardGrid<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 40) {
            content()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, theme.id == .posterWall ? 8 : 4)
        .focusSection()
    }

    // MARK: - Cards + rows

    /// A playable PhimStore title: the existing PosterCard
    /// over the Movie's own fields, badge from its provider.
    private func movieCard(_ movie: Movie) -> some View {
        Button { openMovie(movie) } label: {
            PosterCard(
                title: movie.name,
                posterURL: movie.posterURL,
                tmdbId: movie.tmdbId,
                tmdbType: movie.tmdbType,
                meta: movie.cardMeta,
                badge: Providers.badge(movie.provider))
        }
        .joeCardButton()
        .focused($cardFocus, equals: "movie|" + movie.id)
    }

    /// A playable TVB snapshot title: the TVB side's card
    /// construction (JoeTVBView.card / the search grid's
    /// card, same PosterCard fields), opening through the
    /// routeTarget mirror in openTVB below.
    private func tvbCard(_ title: TVBTitle) -> some View {
        Button { openTVB(title) } label: {
            PosterCard(
                title: title.titleVi,
                posterURL: title.posterURL,
                tmdbId: "\(title.tmdbId)",
                tmdbType: "tv",
                meta: title.cardMeta,
                badge: title.routeTarget.map { Providers.badge($0.provider) })
        }
        .joeCardButton()
        .focused($cardFocus, equals: "tvb|" + "\(title.tmdbId)")
    }

    /// An unmatched credit: poster + title + year (+ the
    /// character, when TMDB carries one). v2.0.29 (cluster
    /// A, item 1c): this row is a BUTTON now. It used to be
    /// a plain, non-focusable row — deliberately, so it
    /// could never read as a playable card — but on device
    /// the owner's actor page showed its film list as
    /// exactly these rows with no way to focus or open any
    /// of them ("không có nút bấm vào"): a credit lands
    /// here whenever the at-load catalogue match missed it,
    /// even when a provider does carry the title. The press
    /// now runs the franchise strip's resolution discipline
    /// (JoeMovieDetail.loadFranchise): search the providers
    /// by the credit's title and accept ONLY a result whose
    /// TMDB id equals the credit's own id (type must agree
    /// when both records state one) — a title lookalike is
    /// never opened. No ID match: the press does nothing
    /// and the row keeps its honest "Chưa có nguồn phát"
    /// place. Focus paints the row-family ring around the
    /// row (JoeDesignRing — the house JoeFocusRing off the
    /// PC path, the design's celadon outset outline under
    /// Private Cinema; clear at rest either way — the
    /// resting row is pixel-identical to the pre-fix
    /// plain row).
    private func unmatchedRow(_ credit: TMDBCreditTitle) -> some View {
        Button {
            Task { await resolveAndOpen(credit) }
        } label: {
            unmatchedRowLabel(credit)
        }
        .joeCardButton()
        .focused($cardFocus, equals: "unmatched|" + credit.id)
    }

    private func unmatchedRowLabel(_ credit: TMDBCreditTitle) -> some View {
        HStack(alignment: .center, spacing: 22) {
            ZStack {
                Color.white.opacity(0.08)
                if !credit.posterURL.isEmpty,
                   let url = URL(string: credit.posterURL) {
                    JoeRemoteImage(url: url, targetPixels: 240) {
                        Text(String(credit.title.prefix(1)))
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else {
                    Text(String(credit.title.prefix(1)))
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 80, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(credit.title)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                let yearText = "\(credit.year)"
                let meta = [yearText == "0" ? "" : yearText, credit.character]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 23))
                        .foregroundStyle(theme.meta)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        // Fault 11 fix round: JoeDesignRing — under Private
        // Cinema (this page's designed composition) the
        // row-family celadon outset outline; under every
        // other theme the house JoeFocusRing, value-for-value.
        .overlay(JoeDesignRing(shape: RoundedRectangle(cornerRadius: 12)))
    }

    /// The unmatched row's press resolution (item 1c):
    /// the credit's OWN (type, tmdbId) identity is the only
    /// acceptance key — see unmatchedRow. Bounded exactly
    /// like loadFranchise: one search pass per provider, in
    /// Providers.priority order, first ID match wins.
    private func resolveAndOpen(_ credit: TMDBCreditTitle) async {
        guard !credit.tmdbId.isEmpty, credit.tmdbId != "0" else { return }
        for code in Providers.priority {
            guard let results = try? await Providers.search(
                code, keyword: credit.title)
            else { continue }
            if let hit = results.first(where: {
                $0.tmdbId == credit.tmdbId && !$0.slug.isEmpty
                    && ($0.tmdbType.isEmpty || credit.type.isEmpty
                        || $0.tmdbType == credit.type)
            }) {
                openMovie(hit)
                return
            }
        }
    }

    // MARK: - Opening titles

    private func openMovie(_ movie: Movie) {
        open(MovieRoute(provider: movie.provider, slug: movie.slug,
                        name: movie.name, poster: movie.poster,
                        year: movie.year))
    }

    /// The JoeTVBView.open mirror, verbatim in shape: the
    /// title's routeTarget (primary provider's first slug,
    /// TP → KK → VS fallback) mints the MovieRoute.
    private func openTVB(_ title: TVBTitle) {
        guard let target = title.routeTarget else { return }
        open(MovieRoute(provider: target.provider, slug: target.slug,
                        name: title.titleVi, poster: title.posterURLString,
                        year: title.yearString,
                        tvb: title.routeContext))
    }

    /// Present the route through the navigator — SEQUENCED
    /// (v2.0.31, L8). This page is a fullScreenCover: over
    /// a movie detail in .tmdb mode, over the TVB tab in
    /// .tvb mode. The pre-fix open() dismissed the cover
    /// and rewrote nav.movie in the SAME turn — clearing
    /// the detail that PRESENTS this cover while its
    /// dismissal was still in flight, and (in .tvb mode)
    /// inserting the new detail layer under a cover that
    /// had not finished lifting. On device the swap was
    /// swallowed whole: the tap visibly did nothing, on
    /// every film, in both modes — the owner's 2.0.29
    /// retest, after FIX5 had only repaired the page's
    /// focus landing and row buttons, never this sequence.
    /// The tap now only records the route and dismisses;
    /// the swap itself runs from the page's onDisappear,
    /// when the cover is gone and the tree is stable.
    /// A plain Menu / Quay lại dismissal carries no
    /// pending route and stays a plain dismissal.
    ///
    /// v2.0.33 (item 7): the L8 enumeration above named
    /// only TWO presenters — it missed the third. This
    /// page is also presented by JoeTorrentDetail (a film
    /// opened as a torrent detail, its cast row inside
    /// the "Chọn Server" panel), and that presenter lives
    /// in the OTHER navigator slot: the parent film is in
    /// nav.tor, not nav.movie. The rule is therefore:
    /// opening a film from this page replaces the WHOLE
    /// detail stack — performPendingOpen() must clear any
    /// lingering nav.tor layer as part of the swap. Left
    /// standing, that layer would otherwise stay on top
    /// of the new detail (JoeRootView renders the torrent
    /// detail at zIndex 3 ABOVE the movie detail at
    /// zIndex 2) and hide it — exactly the owner's
    /// Odyssey symptom: the tapped film's detail existed
    /// invisibly underneath, and one Menu press (the
    /// torrent layer's own exit handler clearing nav.tor)
    /// was needed to reveal it.
    private func open(_ movieRoute: MovieRoute) {
        pendingRoute = movieRoute
        dismiss()
    }

    /// The deferred half of open(): swap the navigator's
    /// movie route now that this page is off screen. When
    /// a detail is already open underneath (the .tmdb
    /// entry point), that detail's @State was built from
    /// ITS route, so the route is cleared and re-minted on
    /// the next turn — the fresh detail then builds from
    /// the new route exactly as a home/rail tap does.
    ///
    /// v2.0.33 (item 7): both branches also clear nav.tor
    /// as part of the swap (see open() for the three-
    /// presenter rule). The ordering avoids flashing the
    /// home shell between layers: the new movie detail is
    /// assigned FIRST and the torrent layer lifted SECOND,
    /// in the same task / same turn, so by the time the
    /// zIndex 3 layer goes the zIndex 2 detail is already
    /// there underneath it. This clearing runs ONLY on
    /// the pending-route path — a plain Menu / Quay lại
    /// dismissal never reaches here, leaves nav.tor alone,
    /// and stays owned by the torrent detail's own exit
    /// handling, exactly as before.
    private func performPendingOpen() {
        guard let movieRoute = pendingRoute else { return }
        pendingRoute = nil
        if nav.movie != nil {
            nav.movie = nil
            Task { @MainActor in
                nav.movie = movieRoute
                nav.tor = nil
            }
        } else {
            nav.movie = movieRoute
            nav.tor = nil
        }
    }

    // MARK: - Private Cinema filmography (v2.1.0 (Private Cinema))

    /// The PC composition (v2.1.2 — rebuilt to
    /// FILMOGRAPHY-DESIGN-SPEC.md, the design expert's
    /// spec measured off the Replit ActorFilmography
    /// drawing; this closes flag F3 of the 2.1.1 closure
    /// table). Flat Ink ground — NO full-screen backdrop:
    /// the left zone (x 94–740) carries the actor header,
    /// the 2-column poster grid in its hard-clipped
    /// scroll viewport and the FIXED bottom bar; the
    /// right zone (x 930–1826) carries the focused film's
    /// trailer in its drawn 896×504 frame with the info
    /// line under it. Every slot is fixed-geometry: data
    /// changes contents, never positions. The cards are
    /// new local builders (the spec's fixed title/year
    /// slots), bound to the SAME cardFocus, and a tap
    /// still opens through the untouched open() /
    /// performPendingOpen() path (a matched title) or
    /// the resolve-by-id discipline (an unmatched one).
    private var cinemaBody: some View {
        ZStack(alignment: .topLeading) {
            theme.bg.ignoresSafeArea()
            cinemaSpecHeader
            if loaded {
                cinemaActorHeader
                cinemaGridTitleRow
                cinemaGridViewport
                if !cinemaCards.isEmpty {
                    cinemaBottomBar
                    cinemaTrailerRegion
                }
            } else {
                cinemaSkeleton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .onChange(of: cardFocus) { _, newValue in
            cinemaFocusChanged(newValue)
        }
    }

    // MARK: Cinema spec header (spec §3)

    /// The drawing's own header for this screen: the
    /// back affordance at (94, 56), the centre nav
    /// labels painted as drawn (plain text — the cover
    /// presents this page over the shell, whose own bar
    /// carries the working navigation; the labels are
    /// the drawing's furniture, never fake buttons), and
    /// the live clock at the right inset. Only the back
    /// button takes focus.
    private var cinemaSpecHeader: some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Text("←")
                    Text("Quay lại")
                }
                .font(JoePCType.outfit(24))
                .foregroundStyle(backFocused
                    ? theme.text : theme.text.opacity(0.75))
            }
            .joeCardButton()
            .focused($backFocused)
            Spacer()
            HStack(spacing: 64) {
                Text("Home")
                Text("Movies")
                Text("Series")
                Text("TVB")
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                    Text("Search")
                }
            }
            .font(JoePCType.outfit(24))
            .foregroundStyle(theme.text)
            Spacer()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(context.date, format: PCClockLabel.clockStyle)
                    .font(JoePCType.outfit(24))
                    .foregroundStyle(theme.text)
            }
        }
        .padding(.horizontal, 94)
        .frame(maxWidth: .infinity)
        .offset(y: 42)
        .focusSection()
    }

    // MARK: Cinema actor header (spec §4)

    /// The actor header: portrait 186×262 r3 at (94, 168)
    /// (cover-crop, face anchor 0.18; no photo on record
    /// → the Panel block + the name's initial in serif
    /// 44, spec §8), then the text column at x 296 —
    /// eyebrow y 180, the name in serif light 104 at
    /// y 202 (shrinking toward 60 to hold its 548 slot,
    /// never wrapping), the tagline slot at y 316 (the
    /// biography's first sentence, A3 — pre-truncated at
    /// load to its 604 slot at a word boundary; empty
    /// when TMDB carries no biography), and the
    /// "Được biết đến qua" meta line at y 360, fitted at
    /// load under the A6 rule.
    private var cinemaActorHeader: some View {
        ZStack(alignment: .topLeading) {
            cinemaPortrait
                .offset(x: 94, y: 168)
            HStack(spacing: 8) {
                Text("DIỄN VIÊN")
                    .foregroundStyle(theme.accent2)
                Text("/")
                    .foregroundStyle(theme.meta)
                Text("PHIM ĐÃ THAM GIA")
                    .foregroundStyle(theme.accent2)
            }
            .font(JoePCType.outfit(15, weight: .semibold))
            .tracking(5)
            .offset(x: 296, y: 180)
            Text(cinemaDisplayName)
                .font(JoePCType.editorial(104))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(60.0 / 104.0)
                .frame(width: 548, alignment: .leading)
                .offset(x: 296, y: 202)
            Text(cinemaTagline)
                .font(JoePCType.editorial(27, italic: true))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .frame(width: 604, height: 34, alignment: .leading)
                .offset(x: 296, y: 316)
            cinemaMetaLine
                .offset(x: 296, y: 360)
        }
    }

    private var cinemaPortrait: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.surface2)
            if let url = cinemaPortraitURL {
                JoeBandImage(url: url, targetPixels: 632,
                             anchor: 0.18, portraitMode: .slice)
            } else {
                Text(String(cinemaDisplayName.prefix(1)))
                    .font(JoePCType.editorial(44))
                    .foregroundStyle(theme.text)
            }
        }
        .frame(width: 186, height: 262)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    /// The person record's h632 profile when the fetch
    /// carried one; the route's own photo behind it (the
    /// cast row's w185 — a lesser size of the same art);
    /// nil when neither exists (the Panel + initial
    /// fallback then paints).
    private var cinemaPortraitURL: URL? {
        if let profile = person?.profileURL, !profile.isEmpty {
            return URL(string: profile)
        }
        return route.photoURL.isEmpty ? nil : URL(string: route.photoURL)
    }

    private var cinemaDisplayName: String {
        if let name = person?.name, !name.isEmpty { return name }
        return route.name
    }

    /// The meta line's segments (spec §4): the Muted
    /// label, the fitted known-for titles in Ivory, the
    /// Muted slash, the Muted count — gaps of 18. With
    /// no titles at all the label and slash go too and
    /// the count stands alone.
    private var cinemaMetaLine: some View {
        HStack(spacing: 18) {
            if !cinemaKnownFor.isEmpty {
                Text("Được biết đến qua")
                    .foregroundStyle(theme.meta)
                Text(cinemaKnownFor.joined(separator: ", "))
                    .foregroundStyle(theme.text)
                Text("/")
                    .foregroundStyle(theme.meta)
            }
            Text("\(cinemaCards.count) phim trong tuyển tập")
                .foregroundStyle(theme.meta)
        }
        .font(JoePCType.outfit(20))
        .lineLimit(1)
    }

    // MARK: Cinema grid (spec §5)

    /// The grid's title row at y 430 (x 94–740): the
    /// grid title at 27/500, the focus counter right-
    /// aligned at x 740 (15/400 Muted, zero-padded). The
    /// title slot also carries the §11 states: the
    /// load-failure line and the no-data line, both
    /// 27/500 Muted in this same slot.
    private var cinemaGridTitleRow: some View {
        HStack(alignment: .center, spacing: 16) {
            if case .tmdb(_, _, _) = route, creditsLoadFailed {
                Text("Không tải được danh sách phim")
                    .font(JoePCType.outfit(27, weight: .medium))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
            } else if cinemaCards.isEmpty {
                Text("Chưa có dữ liệu phim")
                    .font(JoePCType.outfit(27, weight: .medium))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
            } else {
                Text("Phim có \(cinemaDisplayName)")
                    .font(JoePCType.outfit(27, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%02d / %02d",
                            (cinemaFocusedItem?.index ?? 0) + 1,
                            cinemaCards.count))
                    .font(JoePCType.outfit(15))
                    .foregroundStyle(theme.meta)
            }
        }
        .frame(width: 646, alignment: .leading)
        .offset(x: 94, y: 430)
    }

    /// The scroll viewport (spec §5): x 94–740,
    /// y 470–930 — a HARD clip at y 930, so the second
    /// row shows only its posters' tops and the cut
    /// row's titles never paint. Focus scrolls inside
    /// this viewport only; the header, the bottom bar
    /// and the trailer zone stand outside it, fixed.
    /// Columns at x 94 / 334 (205 cards, 35 gap); row
    /// pitch 377 (a 324 cell + 53 spacing); the first
    /// row's posters start at y 483.
    private var cinemaGridViewport: some View {
        Group {
            if !cinemaCards.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: [
                            GridItem(.fixed(205), spacing: 35),
                            GridItem(.fixed(205), spacing: 35),
                        ],
                        alignment: .leading, spacing: 53
                    ) {
                        ForEach(cinemaCards) { card in
                            Button {
                                cinemaCardTapped(card)
                            } label: {
                                CinemaPosterCard(
                                    title: cinemaCardTitle(card),
                                    year: card.year,
                                    posterURL: card.posterURL,
                                    backdropURL: card.backdropURL,
                                    tmdbId: card.tmdbId,
                                    tmdbType: card.tmdbType)
                            }
                            .joeCardButton()
                            .focused($cardFocus, equals: card.focusID)
                        }
                    }
                    .padding(.top, 13)
                    .focusSection()
                }
            }
        }
        .frame(width: 646, height: 460)
        .clipped()
        .offset(x: 94, y: 470)
    }

    // MARK: Cinema bottom bar (spec §6)

    /// The FIXED bottom bar of the left zone: the hint
    /// line at y 941 (13/400 Muted), the 1 pt divider
    /// at y 964 (Muted at 24%), and the role line at
    /// y 984 — "Vai diễn" / the focused film's character
    /// (Ivory 600) · its year; a credit with no character
    /// on record leaves the line with the year alone
    /// (spec §8). Nothing here scrolls with the grid.
    private var cinemaBottomBar: some View {
        ZStack(alignment: .topLeading) {
            Text("Mới nhất trước · ↑↓ Duyệt thêm · Giữ tiêu điểm để xem trailer")
                .font(JoePCType.outfit(13))
                .foregroundStyle(theme.meta)
                .lineLimit(1)
                .offset(x: 94, y: 941)
            Rectangle()
                .fill(theme.meta.opacity(0.24))
                .frame(width: 646, height: 1)
                .offset(x: 94, y: 964)
            cinemaRoleLine
                .offset(x: 94, y: 984)
        }
    }

    @ViewBuilder
    private var cinemaRoleLine: some View {
        if let item = cinemaFocusedItem {
            if !item.character.isEmpty {
                HStack(spacing: 8) {
                    Text("Vai diễn")
                        .foregroundStyle(theme.meta)
                    Text("/")
                        .foregroundStyle(theme.meta)
                    Text(item.character)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.text)
                    if !item.year.isEmpty {
                        Text("·")
                            .foregroundStyle(theme.meta)
                        Text(item.year)
                            .foregroundStyle(theme.text)
                    }
                }
                .font(JoePCType.outfit(20))
                .lineLimit(1)
            } else if !item.year.isEmpty {
                // Spec §8: a credit with no character on
                // record leaves the line with the year
                // alone — no label, no separator.
                Text(item.year)
                    .font(JoePCType.outfit(20))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Cinema trailer region (spec §7)

    /// The right zone: the eyebrow row at y 364 (the
    /// Muted eyebrow left; the sound state as a NON-
    /// focusable indicator at the right — A2: the
    /// drawing's transport-looking labels are status
    /// indicators here, never extra focus points), the
    /// 896×504 trailer frame at (930, 388), the info
    /// line at y 912 and the one-line synopsis at y 954.
    /// The frame's stack: the Panel ground, the focused
    /// film's static art (the §7 fallback chain —
    /// backdrop w1280, else the poster cover-cropped
    /// into the frame, else the Panel + the film's title
    /// centred), and the preview layer letterboxed over
    /// it while a trailer runs. The static art follows
    /// focus immediately; the trailer crossfades in over
    /// it when its first frames flow, and its natural
    /// end crossfades back to the same static art (the
    /// shared controller's own contract — the frame
    /// never freezes on a last frame, never flashes
    /// black, never changes size).
    private var cinemaTrailerRegion: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 16) {
                Text("TRAILER THEO TIÊU ĐIỂM")
                    .font(JoePCType.outfit(15, weight: .semibold))
                    .tracking(5)
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
                Spacer()
                Text("Tắt tiếng")
                    .font(JoePCType.outfit(15))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
            }
            .frame(width: 896)
            .offset(x: 930, y: 364)
            cinemaTrailerFrame
                .offset(x: 930, y: 388)
            cinemaInfoLine
                .offset(x: 930, y: 912)
            if let item = cinemaFocusedItem, !item.synopsis.isEmpty {
                Text(item.synopsis)
                    .font(JoePCType.outfit(18))
                    .foregroundStyle(theme.text.opacity(0.92))
                    .lineLimit(1)
                    .frame(width: 896, alignment: .leading)
                    .offset(x: 930, y: 954)
            }
        }
    }

    private var cinemaTrailerFrame: some View {
        let previewOpacity: Double =
            cinemaPreview.visible && !cinemaPreview.fadingOut ? 1 : 0
        let previewFadeDuration: Double =
            cinemaPreview.visible ? 0.8 : 0.15
        return ZStack {
            theme.surface2
            if let item = cinemaFocusedItem {
                if let url = item.backdropURL {
                    JoeBandImage(url: url, targetPixels: 1280,
                                 anchor: 0.5, portraitMode: .slice)
                } else if let url = item.posterURL {
                    JoeBandImage(url: url, targetPixels: 1280,
                                 anchor: 0.35, portraitMode: .slice)
                } else {
                    Text(item.title)
                        .font(JoePCType.outfit(20))
                        .foregroundStyle(theme.meta)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            if cinemaPreview.player != nil {
                CinemaTrailerHostView(controller: cinemaPreview)
                    .opacity(previewOpacity)
                    .animation(.easeInOut(duration: previewFadeDuration),
                               value: cinemaPreview.visible)
                    .animation(.easeInOut(duration: 0.8),
                               value: cinemaPreview.fadingOut)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 896, height: 504)
        .clipped()
    }

    /// The info line under the frame (spec §7): the
    /// focused film's title at 26/500 Ivory, its year
    /// (20/400 Muted) and — only when the record carries
    /// a real vote — the Celadon ★ + the vote in VN
    /// decimal form + "· điểm TMDB"; right-aligned, the
    /// playback status ("Đang phát · Tắt tiếng" while a
    /// trailer shows; "Không có trailer" once an attempt
    /// concluded with nothing to play).
    private var cinemaInfoLine: some View {
        HStack(alignment: .center, spacing: 16) {
            if let item = cinemaFocusedItem {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.title)
                        .font(JoePCType.outfit(26, weight: .medium))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    if !item.year.isEmpty {
                        Text(item.year)
                            .font(JoePCType.outfit(20))
                            .foregroundStyle(theme.meta)
                            .lineLimit(1)
                    }
                    if item.rating > 0 {
                        (Text("★ ").foregroundStyle(theme.accent2)
                            + Text(cinemaVoteText(item.rating))
                                .foregroundStyle(theme.text)
                            + Text(" · điểm TMDB")
                                .foregroundStyle(theme.meta))
                            .font(JoePCType.outfit(20))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
            }
            Spacer()
            Text(cinemaPreview.visible
                    ? "Đang phát · Tắt tiếng" : cinemaTrailerNote)
                .font(JoePCType.outfit(15))
                .foregroundStyle(theme.meta)
                .lineLimit(1)
        }
        .frame(width: 896)
    }

    /// The vote in the spec's VN decimal form: one
    /// decimal place, a comma for the point ("8,1").
    private func cinemaVoteText(_ vote: Double) -> String {
        String(format: "%.1f", vote)
            .replacingOccurrences(of: ".", with: ",")
    }

    // MARK: Cinema skeleton (spec §11)

    /// The loading surface: Panel blocks at the REAL
    /// geometry (portrait 186×262, four grid cards, the
    /// 896×504 frame) — no text, no centred spinner.
    /// The spec header above it is live furniture (the
    /// back button works while the page loads).
    private var cinemaSkeleton: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.surface2)
                .frame(width: 186, height: 262)
                .offset(x: 94, y: 168)
            // Row pitch matches the real grid exactly:
            // the second row's posters start at
            // 483 + 377 = 860 (263 art + 114 of the
            // pitch), and the stack is hard-clipped at
            // the viewport's y 930 line (447 from 483),
            // like the loaded grid.
            HStack(alignment: .top, spacing: 35) {
                ForEach(0..<2, id: \.self) { _ in
                    VStack(spacing: 114) {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.surface2)
                                .frame(width: 205, height: 263)
                        }
                    }
                }
            }
            .frame(height: 447, alignment: .top)
            .clipped()
            .offset(x: 94, y: 483)
            theme.surface2
                .frame(width: 896, height: 504)
                .offset(x: 930, y: 388)
        }
    }

    // MARK: - Cinema focus + card data (v2.1.2)

    /// A PC card tap routes through the page's existing
    /// plumbing: a matched title opens exactly as its
    /// standard-page card does; an unmatched credit runs
    /// the resolve-by-exact-TMDB-id discipline.
    private func cinemaCardTapped(_ card: CinemaCard) {
        switch card.target {
        case .movie(let movie):
            openMovie(movie)
        case .tvb(let title):
            openTVB(title)
        case .credit(let credit):
            Task { await resolveAndOpen(credit) }
        }
    }

    /// The PC focus handler — the page's own discipline
    /// since v2.1.0, retargeted at the spec's trailer
    /// frame: a focus move ends the CURRENT film's
    /// attempt with stop() (full teardown, NO latch),
    /// never killIfAttempting — the kill latch is
    /// per-VISIT semantics from the detail page (one
    /// title per visit), while this page's design is
    /// per-FOCUS trailers; latching would silence every
    /// later film's trailer for the rest of the visit.
    /// The focused card's record resolves at once (the
    /// info line, the role line and the frame's static
    /// art follow focus immediately, the previous film's
    /// art never lingering); the dwell task then runs
    /// the preview contract — 1.2 s, cancellable, gated
    /// by the Settings toggle + Reduce Motion
    /// (JoeCinemaTrailer.allowedByRules, checked before
    /// the task is even formed). An attempt that
    /// concludes with no player stamps the frame's
    /// status note; a rules-blocked attempt leaves the
    /// note empty (the film may well have a trailer —
    /// previews are simply off).
    private func cinemaFocusChanged(_ focus: String?) {
        cinemaFocusTask?.cancel()
        cinemaFocusTask = nil
        cinemaPreview.stop()
        cinemaTrailerNote = ""
        guard let focus,
              let index = cinemaCards.firstIndex(
                  where: { $0.focusID == focus }) else {
            cinemaFocusedItem = nil
            return
        }
        let card = cinemaCards[index]
        cinemaFocusedItem = resolveCinemaItem(card, index: index)
        guard JoeCinemaTrailer.allowedByRules() else { return }
        let tmdbId = card.tmdbId
        let tmdbType = card.tmdbType
        let trailerUrl = card.trailerUrl
        cinemaFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await JoeCinemaTrailer.run(
                tmdbId: tmdbId, tmdbType: tmdbType,
                sourceTrailerUrl: trailerUrl,
                into: cinemaPreview)
            guard !Task.isCancelled else { return }
            if cinemaPreview.player == nil {
                cinemaTrailerNote = "Không có trailer"
            }
        }
    }

    /// The card title as the grid paints it (spec §5):
    /// shaped ONCE per card at build time — word-boundary
    /// truncation with the ellipsis at the drawn 205
    /// width, 18 pt — so the card's Text never cuts a
    /// word in two. The one edge the rule cannot serve
    /// (a single word longer than the whole slot) falls
    /// back to the raw title rather than no title at all.
    private func cinemaCardTitle(_ card: CinemaCard) -> String {
        let shaped = truncatedToFit(
            card.title, maxWidth: 205,
            font: UIFont.systemFont(ofSize: 18))
        return shaped.isEmpty ? card.title : shaped
    }

    /// Resolve the focused card into the record the
    /// composition paints. The synopsis is pre-shaped
    /// here (first sentence, word-boundary truncation to
    /// the drawn 896 line at 18 pt) so body stays a plain
    /// read on the focus path.
    private func resolveCinemaItem(
        _ card: CinemaCard, index: Int
    ) -> CinemaItem {
        CinemaItem(
            title: card.title,
            year: card.year,
            rating: card.rating,
            synopsis: truncatedToFit(
                firstSentence(of: card.overview),
                maxWidth: 896, font: UIFont.systemFont(ofSize: 18)),
            backdropURL: card.backdropURL,
            posterURL: card.posterURL,
            character: card.character,
            index: index,
            total: cinemaCards.count)
    }

    /// Build the cinema card list (spec §5/§7) from the
    /// records load() just produced. A credit (or a
    /// snapshot title) becomes a card only when its art
    /// ladder is non-empty — poster first, backdrop
    /// behind it (A7: ONE 205×263 frame for every card).
    /// A matched credit's art prefers the CREDIT's own
    /// TMDB art (its poster is the right person's film);
    /// the playable record's art fills only the rungs
    /// the credit lacks. Sort: release date descending,
    /// popularity descending as the tie-break (credits
    /// without a date ride last). The .tvb list keeps
    /// the snapshot's own popularity order.
    private func buildCinemaCards() {
        switch route {
        case .tvb:
            cinemaCards = tvbTitles.compactMap { title in
                guard title.posterURL != nil
                        || title.cinemaBackdropURL != nil
                else { return nil }
                return CinemaCard(
                    focusID: "tvb|" + "\(title.tmdbId)",
                    target: .tvb(title),
                    title: title.titleVi,
                    year: title.yearString,
                    character: "",
                    rating: title.voteAverage,
                    overview: "",
                    posterURL: title.posterURL,
                    backdropURL: title.cinemaBackdropURL,
                    tmdbId: "\(title.tmdbId)",
                    tmdbType: "tv",
                    trailerUrl: "",
                    date: "",
                    popularity: title.popularity)
            }
        case .tmdb:
            let movieByCredit = Dictionary(
                matchedMovies.map { ($0.credit.id, $0.movie) },
                uniquingKeysWith: { first, _ in first })
            let tvbByCredit = Dictionary(
                matchedTVB.map { ($0.credit.id, $0.title) },
                uniquingKeysWith: { first, _ in first })
            var cards: [CinemaCard] = []
            for credit in credits {
                var poster = credit.posterURL.isEmpty
                    ? nil : URL(string: credit.posterURL)
                var backdrop = credit.backdropURL.isEmpty
                    ? nil : URL(string: credit.backdropURL)
                let focusID: String
                let target: CinemaCard.Target
                var trailerUrl = ""
                if let movie = movieByCredit[credit.id] {
                    focusID = "movie|" + movie.id
                    target = .movie(movie)
                    trailerUrl = movie.trailerUrl
                    if poster == nil { poster = movie.posterURL }
                    if backdrop == nil {
                        backdrop = movie.thumbURL ?? movie.posterURL
                    }
                } else if let title = tvbByCredit[credit.id] {
                    focusID = "tvb|" + "\(title.tmdbId)"
                    target = .tvb(title)
                    if poster == nil { poster = title.posterURL }
                    if backdrop == nil {
                        backdrop = title.cinemaBackdropURL
                    }
                } else {
                    focusID = "unmatched|" + credit.id
                    target = .credit(credit)
                }
                guard poster != nil || backdrop != nil else {
                    continue
                }
                cards.append(CinemaCard(
                    focusID: focusID,
                    target: target,
                    title: credit.title,
                    year: credit.year == "0" ? "" : credit.year,
                    character: credit.character,
                    rating: credit.voteAverage,
                    overview: credit.overview,
                    posterURL: poster,
                    backdropURL: backdrop,
                    tmdbId: credit.tmdbId,
                    tmdbType: credit.type,
                    trailerUrl: trailerUrl,
                    date: credit.date,
                    popularity: credit.popularity))
            }
            cards.sort { a, b in
                if a.date != b.date { return a.date > b.date }
                return a.popularity > b.popularity
            }
            cinemaCards = cards
        }
    }

    /// The header's derived texts, computed once per
    /// load: the tagline (spec §4/A3 — the biography's
    /// first sentence in the language TMDB returned,
    /// truncated at a word boundary to its 604 slot;
    /// empty when there is no biography) and the
    /// known-for fit (spec §4/A6 — titles in popularity
    /// order, added only while the composed line still
    /// ends inside its slot; at least one title whenever
    /// any exist).
    private func computeCinemaHeaderTexts() {
        cinemaTagline = truncatedToFit(
            firstSentence(of: person?.biography ?? ""),
            maxWidth: 604, font: cinemaSerifFont(size: 27, italic: true))
        let popularityOrdered: [String]
        switch route {
        case .tvb:
            popularityOrdered = tvbTitles.map(\.titleVi)
        case .tmdb:
            popularityOrdered = cinemaCards
                .sorted { $0.popularity > $1.popularity }
                .map(\.title)
        }
        // Spec §8: the slot's source is the FIRST THREE
        // titles by popularity in the displayed list;
        // the A6 fit below may only trim that set further.
        let candidates = Array(popularityOrdered.prefix(3))
        let font = UIFont.systemFont(ofSize: 20)
        let countText = "\(cinemaCards.count) phim trong tuyển tập"
        func composedWidth(_ titles: [String]) -> CGFloat {
            var width = textWidth(countText, font: font)
            if !titles.isEmpty {
                width += textWidth("Được biết đến qua", font: font)
                width += 18
                width += textWidth(
                    titles.joined(separator: ", "), font: font)
                width += 18
                width += textWidth("/", font: font)
                width += 18
            }
            return width
        }
        var chosen: [String] = []
        for title in candidates {
            if chosen.isEmpty
                || composedWidth(chosen + [title]) <= 604 {
                chosen.append(title)
            } else {
                break
            }
        }
        cinemaKnownFor = chosen
    }

    // MARK: - Text shaping helpers

    /// The first sentence of a text: everything up to
    /// and including the first sentence terminator
    /// ('.', '!', '?', '…'); the whole text when it
    /// carries none. Whitespace-trimmed; empty stays
    /// empty (never invented content — A3).
    private func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let index = trimmed.firstIndex(where: {
            $0 == "." || $0 == "!" || $0 == "?" || $0 == "…"
        }) {
            return String(trimmed[...index])
        }
        return trimmed
    }

    /// Truncate to fit a width at a word boundary,
    /// appending the ellipsis when text was cut; a text
    /// that already fits passes through unchanged.
    private func truncatedToFit(
        _ text: String, maxWidth: CGFloat, font: UIFont
    ) -> String {
        guard !text.isEmpty,
              textWidth(text, font: font) > maxWidth else {
            return text
        }
        var candidate = text
        while let cut = candidate.lastIndex(of: " ") {
            candidate = String(candidate[..<cut])
            if textWidth(candidate + "…", font: font) <= maxWidth {
                return candidate + "…"
            }
        }
        return ""
    }

    private func textWidth(_ text: String, font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// The serif face the spec's tagline slot draws
    /// (serif italic 27), for measuring that slot.
    private func cinemaSerifFont(size: CGFloat, italic: Bool) -> UIFont {
        var descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
        if let serif = descriptor.withDesign(.serif) {
            descriptor = serif
        }
        if italic,
           let traits = descriptor.withSymbolicTraits(.traitItalic) {
            descriptor = traits
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    // MARK: - Load + matching

    private func load() async {
        switch route {
        case .tvb(let name):
            // The snapshot decode rides a detached task (the
            // TVB tab's own load pattern); the filmography
            // is the DISPLAYED titles whose cast carries the
            // name exactly, popularity desc.
            let titles = await Task.detached(priority: .userInitiated) {
                (TVBCatalog.loadBundled()?.titles ?? [])
                    .filter { $0.isDisplayed && $0.cast.contains(name) }
                    .sorted { $0.popularity > $1.popularity }
            }.value
            tvbTitles = titles
            buildCinemaCards()
            computeCinemaHeaderTexts()
            loaded = true
            landInitialFocus()
        case .tmdb(let personId, _, _):
            async let creditsFetch =
                TMDBClient.fetchPersonCredits(personId: personId)
            // v2.1.2: the person record rides the same
            // window (the cinema header's h632 portrait +
            // biography); fail-soft — a nil person leaves
            // the header on the route's own name/photo.
            async let personFetch =
                TMDBClient.fetchPerson(personId: personId)
            let snapshot = await Task.detached(priority: .userInitiated) {
                TVBCatalog.loadBundled()
            }.value
            let fetched = await creditsFetch
            creditsLoadFailed = fetched == nil
            credits = fetched ?? []
            person = await personFetch
            // tmdbId → Movie over every list the PhimStore
            // holds (the trending matcher's catalogue map,
            // JoePhimHome.catalogueByTmdbId, mirrored).
            let byTmdbId = catalogueByTmdbId()
            var tvbById: [Int: TVBTitle] = [:]
            for title in snapshot?.titles ?? [] where title.isDisplayed {
                if tvbById[title.tmdbId] == nil {
                    tvbById[title.tmdbId] = title
                }
            }
            var movies: [MovieMatch] = []
            var tvbs: [TVBMatch] = []
            var rest: [TMDBCreditTitle] = []
            for credit in credits {
                // The credit's tmdbId is matched in its
                // string form (the Movie map's key form);
                // the same text reads back as the TVB map's
                // Int key. v2.0.29 (cluster A, item 7 half):
                // the Movie map is keyed by the (type, id)
                // pair for typed records — TMDB's numeric
                // ids are per-type namespaces, so a bare-id
                // map could bind a credit to a same-numbered
                // title of the OTHER kind (and a typed
                // record could shadow the untyped one under
                // the bare key). The typed key is tried
                // first; the bare key behind it holds ONLY
                // records whose payload stated no type.
                let key = String(describing: credit.tmdbId)
                let type = credit.type
                if let movie = byTmdbId[type + "|" + key] ?? byTmdbId[key] {
                    movies.append(MovieMatch(credit: credit, movie: movie))
                } else if type.isEmpty || type == "tv",
                          let tvbKey = Int(key), let title = tvbById[tvbKey] {
                    tvbs.append(TVBMatch(credit: credit, title: title))
                } else {
                    rest.append(credit)
                }
            }
            matchedMovies = movies
            matchedTVB = tvbs
            unmatched = rest
            buildCinemaCards()
            computeCinemaHeaderTexts()
            loaded = true
            landInitialFocus()
        }
    }

    /// v2.0.29 (cluster A, item 1c): write the page's
    /// initial focus once the filmography lands. The page
    /// declared NO landing at all (no .defaultFocus, no
    /// write): while `loaded` was false the only focusable
    /// element was the header's Quay lại button, and when
    /// the grid inserted beneath it nothing ever steered
    /// focus to a film — the owner found the list present
    /// but unreachable. The write lands on the first
    /// playable card (the .tmdb sections' order: PhimStore
    /// matches, then TVB matches; .tvb mode: the first
    /// snapshot card), falling back to the first unmatched
    /// row, and to Quay lại only when the page carries no
    /// film row at all. Same mechanism as the detail's
    /// focusedRetry write in JoeMovieDetail.load().
    private func landInitialFocus() {
        // v2.1.2 (filmography spec §10): under Private
        // Cinema the initial focus is the cinema grid's
        // first card — that grid is the cinema card list,
        // not the standard page's matched sections. With
        // NO cinema cards (the §11 no-data state) the PC
        // tree's only focusable is the header back
        // button: land there, never on a standard-page
        // card ID the PC tree does not contain.
        if theme.id == .privateCinema {
            if let first = cinemaCards.first {
                cardFocus = first.focusID
            } else {
                backFocused = true
            }
            return
        }
        if let first = matchedMovies.first {
            cardFocus = "movie|" + first.movie.id
        } else if let first = matchedTVB.first {
            cardFocus = "tvb|" + "\(first.title.tmdbId)"
        } else if let first = tvbTitles.first {
            cardFocus = "tvb|" + "\(first.tmdbId)"
        } else if let first = unmatched.first {
            cardFocus = "unmatched|" + first.id
        } else {
            backFocused = true
        }
    }

    /// (type, tmdbId) → Movie over every list the
    /// PhimStore holds. First carrier wins per key (lists
    /// are visited in rail/priority order, merged first);
    /// vietnamAll covers the store's derived
    /// vietnamSeries / vietnamSingle views. v2.0.29
    /// (cluster A, item 7 half): a record whose payload
    /// states a TMDB type is keyed "type|tmdbId"; only a
    /// record with NO stated type rides the bare tmdbId
    /// key — TMDB's numeric ids are per-type namespaces,
    /// so keying every record by the bare id (the pre-fix
    /// form, mirrored from JoePhimHome) let one kind's
    /// record answer for the other kind's credit whenever
    /// the numbers collided.
    private func catalogueByTmdbId() -> [String: Movie] {
        var map: [String: Movie] = [:]
        func add(_ movies: [Movie]) {
            for m in movies where !m.tmdbId.isEmpty {
                let key = m.tmdbType.isEmpty
                    ? m.tmdbId : m.tmdbType + "|" + m.tmdbId
                if map[key] == nil {
                    map[key] = m
                }
            }
        }
        add(phim.merged)
        add(phim.kkNew)
        add(phim.f4kNew)
        add(phim.vsNew)
        add(phim.tpNew)
        add(phim.chieuRap)
        add(phim.vietnamAll)
        add(phim.kkSeries)
        add(phim.kkMovies)
        add(phim.kkAnime)
        add(phim.f4kMovies)
        add(phim.vsSeries)
        add(phim.tpMovies)
        add(phim.tpSeries)
        for spec in PhimStore.genreSpec {
            add(phim.genreLists[spec.slug] ?? [])
        }
        for spec in PhimStore.countrySpec {
            add(phim.countryLists[spec.slug] ?? [])
        }
        return map
    }
}

/// v2.1.2 (filmography spec §5): one card of the cinema
/// grid — a FIXED 324 pt cell: the 205×263 art frame
/// (r6 art / r7 button), the title at +276 (18/400
/// Ivory, ONE line — it arrives pre-shaped by the page
/// at a word boundary with the ellipsis at the 205
/// width, never a mid-word cut), the year at +307
/// (14/400 Muted). Every card
/// carries the same frame (A7): the poster when the
/// record has one, else its backdrop cover-cropped
/// into the same 205×263. The focus treatment is the
/// design's tile treatment (A1 as rebuilt by the
/// Fault 11 fix round): the system platter is stripped
/// by the caller's .joeCardButton() and the art wears
/// the ivory OUTSET outline + 1.045 scale — the same
/// treatment PosterCard's cinema body paints — so
/// focus reads as the design's pale outline without
/// a second geometry fighting the OS. The quality chip
/// of the drawing is NOT painted: no per-title measured
/// quality exists at this surface (A4 — a chip only
/// with a real measurement).
private struct CinemaPosterCard: View {
    @Environment(\.joeTheme) private var theme
    @Environment(\.isFocused) private var isFocused

    let title: String
    let year: String
    let posterURL: URL?
    let backdropURL: URL?
    let tmdbId: String
    let tmdbType: String

    /// PosterCard's own fallback leg, mirrored: when the
    /// primary bitmap fails to load (or fails its aspect
    /// gate), the pipeline's TMDB poster for this title
    /// is tried before the placeholder paints — the same
    /// recovery every other poster card in the app gets.
    private var tmdbFallback: (() async -> URL?)? {
        guard !tmdbId.isEmpty, tmdbId != "0" else { return nil }
        let id = tmdbId, type = tmdbType
        return {
            await JoeImagePipeline.shared.tmdbPosterURL(
                tmdbId: id, type: type)
        }
    }

    /// The placeholder PosterCard itself paints under
    /// every non-Ultra theme (JoeTheme.swift): the film
    /// glyph at 64 pt in the meta colour at 55%.
    private var placeholderArt: some View {
        Image(systemName: "film")
            .font(.system(size: 64))
            .foregroundStyle(theme.meta.opacity(0.55))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                theme.surface2
                if let posterURL {
                    JoeRemoteImage(
                        url: posterURL, targetPixels: 480,
                        fit: true, slotClass: .portrait,
                        fallbackProvider: tmdbFallback
                    ) {
                        placeholderArt
                    }
                    .frame(width: 205, height: 263)
                    .clipped()
                } else if let backdropURL {
                    JoeRemoteImage(
                        url: backdropURL, targetPixels: 480,
                        fit: false, slotClass: .any,
                        fallbackProvider: tmdbFallback
                    ) {
                        placeholderArt
                    }
                    .frame(width: 205, height: 263)
                    .clipped()
                } else {
                    placeholderArt
                        .frame(width: 205, height: 263)
                }
            }
            .frame(width: 205, height: 263)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Fault 11 fix round: the focus is the design's
            // tile treatment, exactly as PosterCard's cinema
            // body now paints it — the ivory OUTSET outline
            // (3 pt, offset 5) plus the 1.045 focus scale on
            // the art; the focus-conditional inset ring that
            // stood here was the legacy construction (and its
            // structure changed with focus). The card root
            // below carries the rest-state opacity (.83).
            .overlay(JoeOutsetRing(
                shape: RoundedRectangle(cornerRadius: 7),
                color: JoeCinemaFocus.ivory, lineWidth: 3, offset: 5))
            .scaleEffect(isFocused ? 1.045 : 1)
            .animation(JoeCinemaFocus.tileCurve, value: isFocused)
            Text(title)
                .font(JoePCType.outfit(18))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 13)
            Text(year)
                .font(JoePCType.outfit(14))
                .foregroundStyle(theme.meta)
                .lineLimit(1)
                .padding(.top, 9)
        }
        .frame(width: 205, height: 324, alignment: .top)
        // Fault 11 fix round: the completion
        // specification's rest state for poster tiles
        // (opacity .83 at rest, 1 focused).
        .joeCinemaCardFocus()
    }
}

/// v2.1.2 (filmography spec §7): the trailer frame's
/// video surface — a LOCAL host for the shared preview
/// controller's player layer. JoePreviewLayerView (in
/// the protected JoePreview.swift) sets its layer to
/// resizeAspectFill for the detail page's full-bleed
/// backdrop; the spec's bounded 896×504 frame letter-
/// boxes instead, so this host mirrors that view's
/// structure with resizeAspect. The controller, its
/// playback and its end-of-clip behaviour are the
/// shared ones, untouched — only the gravity differs.
private struct CinemaTrailerHostView: View {
    @ObservedObject var controller: JoePreviewController

    var body: some View {
        CinemaTrailerHostUIView(player: controller.player)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CinemaTrailerHostUIView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> CinemaTrailerHostPlatformView {
        CinemaTrailerHostPlatformView()
    }

    func updateUIView(_ view: CinemaTrailerHostPlatformView,
                      context: Context) {
        view.playerLayer.player = player
    }
}

private final class CinemaTrailerHostPlatformView: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
