import SwiftUI

// MARK: - User-addon meta detail — v2.0.45, leg 3
//
// The addon's own detail screen (design §5.4): built
// from the existing meta-driven detail constructions —
// header from the meta (poster / title / year / desc),
// episode rows from meta.videos[] for a series, a stream
// list per video in the torrent detail's row shape — no
// new visual language. A stream tap routes by the §5.5
// table (JoeUserAddon.Stream.route): AVPlayer-friendly
// files to the AVPlayer engine, Matroska / header-bound
// files to the KSPlayer engine (both behind
// JoePlayerView — PlayCandidate.engine is the switch,
// exactly as the torrent path routes), bare hashes
// through the existing debrid machinery, and
// externalUrl / ytId rows to the honest slate.
//
// WatchStore (§5.4's named limitation): addon-only
// titles have NO Continue Watching row this round — no
// progress key family was designed for them. The play
// session's template therefore carries an EMPTY
// progress key (WatchStore.saveProgress's own guard
// turns the write away) and metaType "tv" (the store's
// canonical-eligibility rule excludes it, so the
// template can never fold into — or remove — another
// title's row). Two independent guards, both the
// store's own rules; no Continue Watching write of any
// kind can land from here. (The player chrome's
// favourite toggle is the one store write an addon
// session CAN make — a favourites row under
// tor|<metaId>|tv, a key shape no real torrent
// favourite uses; gate round 1, C-6.)

struct JoeAddonDetail: View {
    let route: JoeAddonRoute
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var watch: WatchStore
    @Environment(\.joeTheme) private var theme

    @State private var head = JoeUserAddon.MetaHead()
    @State private var videos: [TorVideo] = []
    @State private var selectedVideoId: String?
    @State private var streams: [JoeUserAddon.Stream] = []
    @State private var loadingStreams = false
    @State private var notice: String?
    @State private var playerHolder: JoeMovieDetail.DirectorHolder?
    /// Gate round 1 (A-1): monotonic tokens for the two
    /// unstructured flows — a superseded stream fetch or
    /// playback build never lands its state writes.
    @State private var streamsToken = 0
    @State private var playToken = 0
    /// Gate round 5 (C5-2): the fallback exit's focus —
    /// see backFallback in the body.
    @FocusState private var backFocused: Bool
    @FocusState private var focusedRow: String?
    /// v2.0.49 (item 7, fix round): bumped by the
    /// detail's Menu handler to make the body's
    /// ScrollViewReader jump to the top of the page
    /// (owner order 2026-11-21).
    @State private var topScrollSignal = 0

    private var isSeries: Bool { route.type == "series" }

    /// v2.0.49 (item 7, fix round): the focus identity of
    /// this page's first row — the first episode row for
    /// a series, else the first stream row; nil while
    /// neither list carries a row (the fallback exit
    /// button is the page's only focusable then).
    private var firstRowFocusID: String? {
        if let first = videos.first { return "ep|" + first.id }
        if let first = streams.first { return "st|" + first.id.uuidString }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            // v2.0.49 (item 7, fix round): the ScrollView
            // sits inside a ScrollViewReader so Menu can
            // jump straight to the top of the page (see
            // .onExitCommand below).
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 32) {
                header
                if isSeries {
                    episodesBlock
                }
                streamsBlock
                if let notice {
                    Text(notice)
                        .font(theme.id == .privateCinema
                              ? JoePCType.outfit(25, weight: .semibold)
                              : .system(size: 25, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                // FL-353 discipline (gate round 5, C5-2):
                // while neither the episode list nor the
                // stream list carries a row — the initial
                // load, a failed/empty stream fetch, a
                // series with no videos — the screen would
                // hold NO focusable element and its
                // own-root Menu handler could never fire
                // (the §8.1 mechanism), so Menu would exit
                // the app. This standing fallback exit
                // (failureSlate's construction) owns those
                // states; it leaves the tree the moment a
                // real row exists.
                if videos.isEmpty && streams.isEmpty {
                    Button {
                        DiagLog.write("ADDON", "addon: detail — quay lại (trigger=nút)")
                        nav.addonDetail = nil
                    } label: {
                        JoeSecondaryLabel(title: "Quay lại")
                    }
                    .joeCardButton()
                    .focused($backFocused)
                    .defaultFocus($backFocused, true)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .id("joeAddonDetailTop")
            }
            // v2.0.49 (item 7, fix round): the Menu-to-top
            // jump's scroll hook, inside the reader.
            .onChange(of: topScrollSignal) { _, _ in
                proxy.scrollTo("joeAddonDetailTop", anchor: .top)
            }
            }
        .task { await load() }
        .fullScreenCover(item: $playerHolder) { holder in
            JoePlayerView(director: holder.director,
                          filmTitle: holder.title,
                          filmEpisode: holder.episode,
                          sourceLine: holder.sourceLine)
        }
        // Own-root Menu handler (the house construction):
        // one press closes exactly this layer.
        .onExitCommand {
            // v2.0.49 (item 7, fix round — owner order
            // 2026-11-21 22:32): Menu jumps straight to
            // the top of the page first. Focus on the
            // first row (or on the fallback exit button,
            // the page's only focusable while no row
            // exists) keeps the existing close; anywhere
            // else, Menu scrolls to the top and lands
            // focus on the first row, swallowing the
            // exit.
            if backFocused || focusedRow == firstRowFocusID {
                nav.addonDetail = nil
            } else {
                topScrollSignal += 1
                focusedRow = firstRowFocusID
            }
        }
        }
    }

    // MARK: Backdrop (FL-362)

    /// The detail's backdrop layer: the meta's BACKGROUND
    /// image in its own role — a full-screen JoeBandImage
    /// (the chain detail's construction: top-anchored slice
    /// under the same scrims as JoeMovieDetail.ultraBackdrop
    /// / JoeTorrent.ultraTorBackdrop) behind the unchanged
    /// content. Pre-fix this screen never read
    /// head.background at all, so the fetched backdrop was
    /// discarded and the page opened on the bare theme
    /// background. Poster art is NEVER substituted into
    /// this slot: a meta with no background leaves the
    /// layer empty and the page exactly as it was.
    @ViewBuilder
    private var backdrop: some View {
        if !head.background.isEmpty, let url = URL(string: head.background) {
            ZStack {
                JoeBandImage(url: url, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .slice)
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
            .ignoresSafeArea()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 34) {
            // FL-362: the poster slot in its own role — an
            // exact 2:3 portrait frame (the height is the
            // pre-fix 330; the pre-fix 440 width made it a
            // 4:3 landscape frame), FIT so the whole poster
            // paints, and the portrait aspect gate so a
            // wrong-shape bitmap is rejected to the
            // placeholder instead of being fill-cropped
            // into the frame (the pre-fix default fill cut
            // the character's head off). The same
            // construction as JoeMovieDetail.posterArt and
            // the JoeTorrent hero.
            JoeRemoteImage(url: URL(string: head.poster.isEmpty ? route.poster : head.poster),
                           targetPixels: 720, fit: true,
                           slotClass: .portrait) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.surface2)
            }
            .frame(width: 220, height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 14) {
                Text(head.name.isEmpty ? route.name : head.name)
                    .font(theme.id == .privateCinema ? JoePCType.display(46, weight: .semibold) : .system(size: 46, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(3)
                HStack(spacing: 12) {
                    JoeChipLabel(title: route.addonName, selected: true)
                    if !(head.year.isEmpty ? route.year : head.year).isEmpty {
                        JoeChipLabel(title: head.year.isEmpty ? route.year : head.year,
                                     selected: false)
                    }
                }
                if !head.desc.isEmpty {
                    Text(head.desc)
                        .font(theme.id == .privateCinema ? JoePCType.outfit(24) : .system(size: 24))
                        .foregroundStyle(theme.meta)
                        .lineLimit(6)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
            }
            Spacer()
        }
    }

    // MARK: Episodes (series)

    private var episodesBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Danh sách tập")
                .font(theme.id == .privateCinema ? JoePCType.outfit(29, weight: .bold) : .system(size: 29, weight: .bold))
                .foregroundStyle(theme.text)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(videos) { video in
                    Button {
                        select(video.id)
                    } label: {
                        HStack(spacing: 16) {
                            Text(selectedVideoId == video.id ? "▶" : "·")
                                .font(theme.id == .privateCinema ? JoePCType.outfit(25, weight: .bold) : .system(size: 25, weight: .bold))
                                .foregroundStyle(theme.text)
                            Text(video.label)
                                .font(theme.id == .privateCinema ? JoePCType.outfit(26, weight: .semibold) : .system(size: 26, weight: .semibold))
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(theme.surface2))
                    }
                    .joeCardButton()
                    .focused($focusedRow, equals: "ep|" + video.id)
                }
            }
            .focusSection()
        }
    }

    // MARK: Streams

    @ViewBuilder
    private var streamsBlock: some View {
        if loadingStreams {
            ProgressView("Đang tải nguồn…")
                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.text)
                .tint(theme.text)
        } else if !streams.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Nguồn phát — \(route.addonName)")
                    .font(theme.id == .privateCinema ? JoePCType.outfit(29, weight: .bold) : .system(size: 29, weight: .bold))
                    .foregroundStyle(theme.text)
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(streams) { stream in
                        streamRow(stream)
                    }
                }
                .focusSection()
            }
        }
    }

    private func streamRow(_ stream: JoeUserAddon.Stream) -> some View {
        Button {
            play(stream)
        } label: {
            HStack(spacing: 16) {
                Text(route.addonName)
                    .font(theme.id == .privateCinema ? JoePCType.outfit(23, weight: .bold)
                              : .system(size: 23, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(JoeTheme.okGreen.opacity(0.35)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.name.isEmpty ? stream.title : stream.name)
                        .font(theme.id == .privateCinema ? JoePCType.outfit(29, weight: .semibold) : .system(size: 29, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    if !stream.title.isEmpty && stream.title != stream.name {
                        Text(stream.title)
                            .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                            .foregroundStyle(theme.meta)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Fault 11 fix round: the shared source-row
            // construction — under Private Cinema the
            // design's source-row state (celadon outset
            // outline + #304039DF focused face); under every
            // other theme the surface2 face and the house
            // JoeFocusRing, value-for-value.
            .background(JoeSourceRowFace(
                shape: RoundedRectangle(cornerRadius: theme.rField),
                restFill: theme.surface2))
            .overlay(JoeDesignRing(shape: RoundedRectangle(cornerRadius: theme.rField)))
        }
        .joeCardButton()
        .focused($focusedRow, equals: "st|" + stream.id.uuidString)
    }

    // MARK: Load

    private func load() async {
        if let fetched = try? await JoeUserAddon.metaHead(
            base: route.base, type: route.type, id: route.metaId) {
            head = fetched
        }
        if isSeries {
            videos = (try? await TorrentClient.fetchVideos(
                addonBase: route.base, type: route.type, id: route.metaId)) ?? []
            if let first = videos.first { select(first.id) }
        } else {
            selectedVideoId = route.metaId
            streamsToken += 1
            await loadStreams(videoId: route.metaId, token: streamsToken)
        }
    }

    private func select(_ videoId: String) {
        selectedVideoId = videoId
        notice = nil
        streamsToken += 1
        let token = streamsToken
        Task { await loadStreams(videoId: videoId, token: token) }
    }

    private func loadStreams(videoId: String, token: Int) async {
        loadingStreams = true
        let fetched = (try? await JoeUserAddon.streams(
            base: route.base, type: route.type, id: videoId)) ?? []
        // A superseded fetch never lands (gate round 1,
        // A-1): the newer selection owns the state —
        // including the loading flag this fetch would
        // otherwise clear early.
        guard token == streamsToken else { return }
        loadingStreams = false
        streams = fetched
        if streams.isEmpty {
            notice = "Addon chưa trả nguồn nào cho mục này."
        }
    }

    // MARK: Play (§5.5 routing)

    private func play(_ tapped: JoeUserAddon.Stream) {
        let videoId = selectedVideoId ?? route.metaId
        if case .unsupported = tapped.route {
            // §5.5's out-of-scope shape: the row stays
            // visible, the tap answers honestly — never
            // silent, never a browser.
            notice = "Dạng luồng này chưa hỗ trợ trong JoeTV"
            DiagLog.write("ADDON", "addon: dạng luồng chưa hỗ trợ — externalUrl/ytId")
            return
        }
        notice = nil
        let engineWord: String
        switch tapped.route {
        case .avPlayer(_): engineWord = "avplayer"
        case .ksPlayer(_): engineWord = "ksplayer"
        case .torrent: engineWord = "torrent"
        case .unsupported: engineWord = "" // unreachable — returned above
        }
        DiagLog.write("ADDON", "addon: stream \(route.type)/\(videoId) → \(streams.count) luồng, phát qua \(engineWord)")
        playToken += 1
        let token = playToken
        Task { await startPlayback(tapped: tapped, videoId: videoId, token: token) }
    }

    private func startPlayback(tapped: JoeUserAddon.Stream, videoId: String,
                               token: Int) async {
        var candidates: [PlayCandidate] = []
        // A tapped DIRECT stream leads its own ladder; a
        // tapped HASH stream leads inside the torrent
        // conversion below (its `preferred:`), after the
        // other rows' direct candidates (gate round 1,
        // C-4 — the order is stated, not implied).
        if let lead = Self.directCandidate(for: tapped,
                                           addonName: route.addonName) {
            candidates.append(lead)
        }
        for stream in streams where stream.id != tapped.id {
            if let candidate = Self.directCandidate(for: stream,
                                                    addonName: route.addonName) {
                candidates.append(candidate)
            }
        }
        // Hash rows ride the shared torrent conversion
        // (the tapped hash, when it is one, earns the
        // one debrid resolution there).
        let hashStreams = streams.filter {
            $0.url.isEmpty && !$0.infoHash.isEmpty
        }
        if !hashStreams.isEmpty {
            let preferred = hashStreams.first { $0.id == tapped.id }
            candidates += await TorrentClient.playCandidates(
                streams: hashStreams.map { $0.asTorStream },
                preferred: preferred?.asTorStream,
                labelPrefix: route.addonName)
        }
        // A superseded build never presents (gate round
        // 1, A-1): the latest tap owns the player.
        guard token == playToken else { return }
        guard !candidates.isEmpty else {
            notice = "Không dựng được nguồn phát từ addon."
            return
        }
        let videoLabel = videos.first { $0.id == videoId }?.label ?? ""
        var entry = WatchStore.Entry()
        entry.kind = WatchStore.kindTor
        // §5.4's named limitation, enforced by the
        // store's own rules (see the header note): an
        // empty progress key is never persisted, and
        // metaType "tv" is canonically ineligible, so
        // this session can neither create a row nor
        // touch another title's.
        entry.key = ""
        entry.metaType = "tv"
        entry.metaId = route.metaId
        entry.title = head.name.isEmpty ? route.name : head.name
        entry.ep = videoLabel
        entry.epLabel = videoLabel
        entry.poster = head.poster.isEmpty ? route.poster : head.poster
        entry.year = head.year.isEmpty ? route.year : head.year
        let director = PlayDirector(
            store: watch,
            identity: PlayIdentity(entry: entry),
            resumeMs: 0,
            resolveLadder: { _ in candidates },
            hopIdentity: nil)
        playerHolder = JoeMovieDetail.DirectorHolder(
            director: director,
            title: entry.title,
            episode: videoLabel,
            sourceLine: "Nguồn: \(route.addonName)")
    }

    /// One direct-URL stream as a candidate, its engine
    /// from the §5.5 route (nil for hash / unsupported
    /// rows — the hash conversion handles those).
    private static func directCandidate(for stream: JoeUserAddon.Stream,
                                        addonName: String) -> PlayCandidate? {
        let label = "\(addonName) · \(stream.name.isEmpty ? stream.title : stream.name)"
        switch stream.route {
        case .avPlayer(let url):
            return PlayCandidate(url: url, headers: stream.proxyHeaders,
                                 label: label, engine: .avPlayer)
        case .ksPlayer(let url):
            return PlayCandidate(url: url, headers: stream.proxyHeaders,
                                 label: label, engine: .ffmpeg)
        case .torrent, .unsupported:
            return nil
        }
    }
}
