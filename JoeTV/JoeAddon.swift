import SwiftUI

// MARK: - User addon (Stremio) — v2.0.45, leg 3
//
// The owner's OWN Stremio addon (re TV is the first) as a
// first-class library source, per the design's §5:
//
// - Its link resolves exactly like MediaFusion's
//   (TorrentSettings.effectiveUserAddonURL — stored wins,
//   the bundled RETV_URL secret is the fallback) and is
//   NEVER logged: it carries his personal account token
//   in its path (FL-073). DiagLog (tag ADDON) records
//   presence, the addon's own name and catalogue counts
//   only.
// - The full library comes in as a Home section (one
//   rail per non-search catalogue, manifest order,
//   paged by skip=), EXCEPT titles that match a title
//   the app already carries — those get NO duplicate
//   Home poster (the owner's final duplicate rule,
//   2026-11-20 22:57 CST); their streams join as backup
//   links instead (movies via the pooled/per-title
//   stream fetch, TVB via JoeYtDetail's backup row).
//   Matching, strongest key first: IMDb id → TMDB id
//   (when the meta carries one — catalog metas here do
//   not) → normalised name + year → TVB by name.
//   Fail-open: an unmatched or ambiguous title stands
//   as a new item; content is never dropped over a
//   failed match.
// - NAMED LIMITATION (§5.4, stated, not hidden):
//   addon-only titles get NO Continue Watching row in
//   2.0.45 — no progress key family was designed for
//   them. JoeAddonDetail's play sessions therefore mint
//   a WatchStore template the store can never persist
//   or fold (see JoeAddonDetail.play). Matched titles
//   are unaffected: they play through their main
//   title's detail and progress follows its path.

/// The addon detail's route (the TorRoute idiom): the
/// serving base rides along so the detail resolves its
/// meta and streams from the same addon that listed it.
struct JoeAddonRoute: Hashable, Sendable, Identifiable {
    var base: String
    var type: String
    var metaId: String
    var name: String
    var poster: String
    var year: String
    var addonName: String
    var id: String { base + "|" + type + "|" + metaId }
}

// MARK: - Client

/// The Stremio protocol surface for ONE user addon.
/// TorrentClient is already the app's Stremio client
/// for the configured gateways; this sibling covers the
/// user addon's own shapes the gateway client does not
/// carry (tolerant manifest parse with extras, skip=
/// paging on an arbitrary base, and the stream fields
/// the §5.5 routing table reads — externalUrl / ytId /
/// proxyHeaders). All responses are Sendable values;
/// failures throw to a named layer (FL-076).
enum JoeUserAddon {

    struct Catalog: Sendable, Identifiable {
        var type: String
        var id: String
        var name: String
        /// True when the catalogue declares a REQUIRED
        /// search extra — a search-only catalogue (it
        /// cannot be listed plainly, so it gets no rail;
        /// it feeds the search group instead).
        var searchRequired: Bool
    }

    struct Manifest: Sendable {
        var name: String
        var catalogs: [Catalog]
        var types: [String]
    }

    /// One stream row, with the routing fields §5.5
    /// reads. (TorrentClient's TorStream covers the
    /// gateway pool; the addon detail's routing table
    /// also needs externalUrl / ytId, which TorStream
    /// never parses.)
    struct Stream: Sendable, Identifiable {
        var id = UUID()
        var name: String = ""
        var title: String = ""
        var url: String = ""
        var infoHash: String = ""
        var fileIdx: Int = -1
        var proxyHeaders: [String: String] = [:]
        var externalUrl: String = ""
        var ytId: String = ""

        /// The §5.5 classification of this row: a direct
        /// URL (with the engine its container/headers
        /// demand), a bare hash for the torrent
        /// machinery, or a shape this round does not
        /// play (externalUrl / ytId only).
        enum Route {
            case avPlayer(URL)
            case ksPlayer(URL)
            case torrent
            case unsupported
        }

        var route: Route {
            if !url.isEmpty, let url = URL(string: url) {
                if !proxyHeaders.isEmpty { return .ksPlayer(url) }
                let ext = url.pathExtension.lowercased()
                if ext == "m3u8" || TorStream.avPlayerContainers.contains(ext) {
                    return .avPlayer(url)
                }
                // No decisive extension: the shared
                // container rule decides from the URL +
                // release text (a known-bad container →
                // KSPlayer; anything else AVPlayer opens).
                var probe = TorStream()
                probe.url = self.url
                probe.name = name
                probe.title = title
                return probe.containerPlayable ? .avPlayer(url) : .ksPlayer(url)
            }
            if !infoHash.isEmpty { return .torrent }
            return .unsupported
        }

        /// This row in the torrent pool's own model, for
        /// the shared candidate conversion (hash rows).
        var asTorStream: TorStream {
            var s = TorStream()
            s.name = name
            s.title = title
            s.url = url
            s.infoHash = infoHash
            s.fileIdx = fileIdx
            s.proxyHeaders = proxyHeaders
            return s
        }
    }

    /// The meta detail's header fields (the episode
    /// list itself comes from TorrentClient.fetchVideos,
    /// the house meta parse).
    struct MetaHead: Sendable {
        var name: String = ""
        var poster: String = ""
        var background: String = ""
        var desc: String = ""
        var year: String = ""
    }

    static func loadManifest(base: String) async throws -> Manifest {
        let root = try await JoeHTTP.getJSON(base + "/manifest.json", timeout: 12)
        var manifest = Manifest(name: JSON.str(root, "name"), catalogs: [], types: [])
        for c in JSON.arr(root, "catalogs") ?? [] {
            let type = JSON.str(c, "type")
            let id = JSON.str(c, "id")
            guard !id.isEmpty, type == "movie" || type == "series" else { continue }
            var catalog = Catalog(type: type, id: id,
                                  name: JSON.str(c, "name", id),
                                  searchRequired: false)
            for extra in JSON.arr(c, "extra") ?? [] {
                if JSON.str(extra, "name") == "search",
                   (extra["isRequired"] as? Bool) == true {
                    catalog.searchRequired = true
                }
            }
            manifest.catalogs.append(catalog)
            if !manifest.types.contains(type) { manifest.types.append(type) }
        }
        return manifest
    }

    /// One catalogue page. Page 1 is the plain catalogue
    /// URL; later pages carry the Stremio skip= extra
    /// (the shape TorrentClient.fetchSportsCatalog
    /// already uses).
    static func catalogPage(base: String, catalog: Catalog, skip: Int) async throws -> [TorMeta] {
        let url = skip > 0
            ? base + "/catalog/\(catalog.type)/\(catalog.id)/skip=\(skip).json"
            : base + "/catalog/\(catalog.type)/\(catalog.id).json"
        let root = try await JoeHTTP.getJSON(url, timeout: 12)
        return parseMetas(JSON.arr(root, "metas"))
    }

    /// One search catalogue's answer for a keyword, as
    /// typed (the TorrentClient.search shape, on the
    /// user addon's base).
    static func search(base: String, catalog: Catalog, keyword: String) async throws -> [TorMeta] {
        let q = JoeHTTP.qenc(keyword)
        let root = try await JoeHTTP.getJSON(
            base + "/catalog/\(catalog.type)/\(catalog.id)/search=\(q).json",
            timeout: 12)
        return parseMetas(JSON.arr(root, "metas"))
    }

    static func metaHead(base: String, type: String, id: String) async throws -> MetaHead {
        let root = try await JoeHTTP.getJSON(base + "/meta/\(type)/\(id).json", timeout: 12)
        guard let meta = JSON.obj(root, "meta") else { return MetaHead() }
        var head = MetaHead()
        head.name = JSON.str(meta, "name")
        head.poster = JSON.str(meta, "poster")
        head.background = JSON.str(meta, "background")
        head.desc = JSON.str(meta, "description")
        head.year = JSON.str(meta, "year")
        if head.year.isEmpty || head.year.lowercased() == "null" {
            let ri = JSON.str(meta, "releaseInfo")
            head.year = ri.count >= 4 ? String(ri.prefix(4)) : ""
        }
        return head
    }

    static func streams(base: String, type: String, id: String) async throws -> [Stream] {
        let root = try await JoeHTTP.getJSON(base + "/stream/\(type)/\(id).json", timeout: 15)
        return (JSON.arr(root, "streams") ?? []).map { o in
            var s = Stream()
            s.name = JSON.str(o, "name")
            s.title = JSON.str(o, "title")
            if s.title.isEmpty { s.title = JSON.str(o, "description") }
            s.url = JSON.str(o, "url")
            s.infoHash = JSON.str(o, "infoHash")
            s.fileIdx = JSON.int(o, "fileIdx", -1)
            s.externalUrl = JSON.str(o, "externalUrl")
            s.ytId = JSON.str(o, "ytId")
            if let bh = JSON.obj(o, "behaviorHints"),
               let ph = JSON.obj(bh, "proxyHeaders"),
               let req = JSON.obj(ph, "request") {
                for (k, v) in req where v is String {
                    s.proxyHeaders[k] = v as? String ?? ""
                }
            }
            return s
        }
    }

    /// TorrentClient.parseMetas' shape, kept beside the
    /// client that needs it for arbitrary catalogues
    /// (TorrentClient's own parse serves its TorCatalog
    /// fetches and is not shared).
    private static func parseMetas(_ arr: [[String: Any]]?) -> [TorMeta] {
        (arr ?? []).compactMap { o in
            var m = TorMeta()
            m.id = JSON.str(o, "id")
            m.type = JSON.str(o, "type", "movie")
            m.name = JSON.str(o, "name")
            m.poster = JSON.str(o, "poster")
            m.background = JSON.str(o, "background")
            m.year = JSON.str(o, "year")
            if m.year.isEmpty || m.year.lowercased() == "null" {
                let ri = JSON.str(o, "releaseInfo")
                m.year = ri.count >= 4 ? String(ri.prefix(4)) : ""
            }
            m.desc = JSON.str(o, "description")
            // §5.6 key 1's second form: an IMDb id carried
            // as the meta's own field (either spelling).
            m.imdbId = JSON.str(o, "imdbId")
            if m.imdbId.isEmpty { m.imdbId = JSON.str(o, "imdb_id") }
            return (m.id.isEmpty || m.name.isEmpty) ? nil : m
        }
    }
}

// MARK: - Store

/// The addon library's state: manifest, rails (already
/// match-filtered), paging cursors, and the TVB backup
/// match map. Loaded once from the Home surfaces;
/// fail-soft throughout — an addon that is down or
/// unconfigured simply has no section.
@MainActor
final class JoeAddonStore: ObservableObject {
    static let shared = JoeAddonStore()

    struct Rail: Identifiable {
        var catalog: JoeUserAddon.Catalog
        var metas: [TorMeta] = []
        var exhausted = false
        var id: String { catalog.type + "|" + catalog.id }
    }

    @Published private(set) var addonName: String = ""
    @Published private(set) var rails: [Rail] = []
    @Published private(set) var loaded = false

    private var loadedBase: String?
    private var catalogs: [JoeUserAddon.Catalog] = []
    private var manifestLoaded = false
    /// Gate round 6 (C6-2): the base the latched
    /// manifest belongs to — a manifest latched for
    /// another base is no latch at all.
    private var manifestBase: String?
    private var loading = false
    private var nextSkip: [String: Int] = [:]
    /// TVB backup matches: normalised series name →
    /// the addon meta that carries that series (for
    /// JoeYtDetail's "Nguồn phụ" row).
    private var tvbMatches: [String: (type: String, id: String)] = [:]
    /// The catalogues the last full load matched
    /// against — the search path reuses the same
    /// snapshot (matching runs at library load and per
    /// search result, per the design).
    private var matchMovies: [Movie] = []
    private var matchSeries: [JoeYtSeries] = []

    private func log(_ message: String) {
        DiagLog.write("ADDON", message)
    }

    var hasAddon: Bool { TorrentSettings.userAddonBase != nil }

    /// The serving base for detail routes (nil = the
    /// addon is not in force).
    var servingBase: String? { loadedBase ?? TorrentSettings.userAddonBase }

    /// Gate round 5 (C5-1): the latch is keyed to the
    /// base it was built from. The Settings field saves
    /// on EVERY edit, so the effective base can change
    /// (or be cleared) mid-process — and every latched
    /// piece (manifest, rails, matches, cursors) belongs
    /// to the OLD addon. When the live base differs from
    /// the latched one, all of it goes before anything
    /// loads or searches again; a cleared link empties
    /// the section entirely. Returns the live base.
    private func syncBase() -> String? {
        let live = TorrentSettings.userAddonBase
        if live != loadedBase {
            loadedBase = live
            loaded = false
            manifestLoaded = false
            manifestBase = nil
            addonName = ""
            catalogs = []
            rails = []
            tvbMatches = [:]
            nextSkip = [:]
            matchMovies = []
            matchSeries = []
        }
        return live
    }

    // MARK: Load

    /// Load the manifest + every rail's first page.
    /// Called by the Home surfaces with the app
    /// catalogues the matcher runs against. A call that
    /// finds the movie catalogue still empty does NOT
    /// latch — the next call retries (the launch gate
    /// may still be filling the store on the first
    /// appearance).
    func ensureLoaded(phim: PhimStore, tvbSeries: [JoeYtSeries]) {
        guard !loading else { return }
        // syncBase FIRST (C5-1): a base change under a
        // latched `loaded` resets the latch here, and
        // only then does the loaded guard mean anything.
        guard let base = syncBase() else { return }
        guard !loaded else { return }
        let movies = Self.appMovies(phim)
        guard !movies.isEmpty else { return }
        loading = true
        Task { [weak self] in
            guard let self else { return }
            await self.load(base: base, movies: movies, tvbSeries: tvbSeries)
            self.loading = false
        }
    }

    /// The Phim store's visible library, assembled the
    /// way JoeSearch.storeMovies assembles its pool.
    private static func appMovies(_ phim: PhimStore) -> [Movie] {
        var all: [Movie] = []
        all += phim.merged
        all += phim.kkSeries + phim.kkMovies + phim.kkAnime
        all += phim.f4kNew + phim.f4kMovies
        all += phim.vsNew + phim.vsSeries
        all += phim.tpNew + phim.tpMovies + phim.tpSeries
        all += phim.chieuRap + phim.vietnamAll
        for list in phim.genreLists.values { all += list }
        for list in phim.countryLists.values { all += list }
        return all
    }

    private func load(base: String, movies: [Movie], tvbSeries: [JoeYtSeries]) async {
        if let source = TorrentSettings.userAddonSource {
            log("addon: hiệu lực — có link (\(source))")
        }
        self.loadedBase = base
        matchMovies = movies
        matchSeries = tvbSeries
        guard await ensureManifest(base: base) else { return }
        // Gate round 6 (C6-2): the rails, their cursors
        // and the TVB matches are built into LOCALS and
        // committed only at the latch point below, under
        // the base guard — a load the owner has already
        // superseded (a search-triggered sync can reset
        // the store mid-load) commits NOTHING at all.
        var built: [Rail] = []
        var skips: [String: Int] = [:]
        var matches: [String: (type: String, id: String)] = [:]
        for catalog in catalogs where !catalog.searchRequired {
            var rail = Rail(catalog: catalog)
            let page = (try? await JoeUserAddon.catalogPage(
                base: base, catalog: catalog, skip: 0)) ?? []
            log("addon: catalogue \(catalog.id) trang skip=0 → \(page.count) mục")
            rail.metas = page.filter { keepUnmatched($0, tvbSink: &matches) }
            rail.exhausted = page.isEmpty
            skips[rail.id] = page.count
            built.append(rail)
        }
        // C5-1: a base change mid-load abandons the
        // latch — these rails belong to an addon the
        // owner has already replaced; the next offer
        // reloads against the live base.
        guard base == TorrentSettings.userAddonBase else { return }
        rails = built
        nextSkip = skips
        tvbMatches = matches
        loaded = true
    }

    private func ensureManifest(base: String) async -> Bool {
        // Keyed to its base (gate round 6, C6-2): a
        // manifest latched for ANOTHER base is treated
        // as no latch — every consumer refetches rather
        // than inheriting a previous addon's catalogue
        // set, so a stale in-flight write can never
        // contaminate durably.
        if manifestLoaded && manifestBase == base { return true }
        do {
            let manifest = try await JoeUserAddon.loadManifest(base: base)
            addonName = manifest.name
            catalogs = manifest.catalogs
            manifestLoaded = true
            manifestBase = base
            log("addon: manifest OK — name=\(manifest.name) catalogs=\(manifest.catalogs.count) types=\(manifest.types.joined(separator: ","))")
            return true
        } catch {
            log("addon: manifest lỗi — \(error.localizedDescription) (section ẩn)")
            return false
        }
    }

    /// Page the next slice of one rail in (the Home
    /// rail calls this when its last card appears).
    func loadMore(railID: String) {
        // Base discipline (gate round 6, A6-3): sync
        // FIRST — if the owner edited the link since the
        // rails latched, the reset here flips loaded off
        // and this paging call dies with it, instead of
        // paging the OLD addon into rails that are about
        // to be replaced; the completion below ALSO
        // re-verifies the latched base before writing
        // back (C6-3).
        _ = syncBase()
        guard loaded, let base = loadedBase,
              let idx = rails.firstIndex(where: { $0.id == railID }),
              !rails[idx].exhausted else { return }
        let catalog = rails[idx].catalog
        let skip = nextSkip[railID] ?? 0
        // Gate round 6 (C6-3): the completion must
        // revalidate the latch it was spawned under — a
        // sync+reload in the meantime (a link change)
        // makes this page stale even when a rail with
        // the same id exists again.
        let latchedBase = loadedBase
        // Mark exhausted optimistically against a
        // double-fire while the page is in flight; the
        // completion re-opens it unless the page was a
        // genuine end-of-catalogue.
        rails[idx].exhausted = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await JoeUserAddon.catalogPage(
                    base: base, catalog: catalog, skip: skip)
                guard self.loadedBase == latchedBase else { return }
                self.log("addon: catalogue \(catalog.id) trang skip=\(skip) → \(page.count) mục")
                guard let i = self.rails.firstIndex(where: { $0.id == railID })
                else { return }
                self.nextSkip[railID] = skip + page.count
                var matches = self.tvbMatches
                self.rails[i].metas += page.filter {
                    self.keepUnmatched($0, tvbSink: &matches)
                }
                self.tvbMatches = matches
                self.rails[i].exhausted = page.isEmpty
            } catch {
                // A FAILED page is not an EMPTY page
                // (gate round 1, C-3): re-open the rail
                // so a later appearance retries the same
                // skip — one network flap must not
                // truncate the rail for the process's
                // life. The cursor never advanced, so
                // nothing is skipped or duplicated.
                guard self.loadedBase == latchedBase else { return }
                if let i = self.rails.firstIndex(where: { $0.id == railID }) {
                    self.rails[i].exhausted = false
                }
            }
        }
    }

    // MARK: Search

    /// The search group's fetch: every search-required
    /// catalogue, queried as typed, match-filtered the
    /// same way the rails are. (name, metas) — an empty
    /// name means no addon group this round. The caller
    /// offers its current app pools so the match
    /// snapshot is never the empty pre-load one (gate
    /// round 3, Lens C observation): whenever a
    /// non-empty pool is offered it replaces the
    /// snapshot the filter runs against.
    func search(keyword: String, movies: [Movie],
                tvbSeries: [JoeYtSeries]) async -> (name: String, metas: [TorMeta]) {
        // C5-1: search syncs the latch too — it must
        // never query the live base with a PREVIOUS
        // addon's catalogue set. The sync runs FIRST
        // (gate round 6, C6-1): its reset clears the
        // match pools, so the caller's offered pools are
        // installed only after it, or the first search
        // after a link change would filter against the
        // empty pools the reset just made.
        guard let base = syncBase() else { return ("", []) }
        if !movies.isEmpty {
            matchMovies = movies
            matchSeries = tvbSeries
        }
        if !manifestLoaded || manifestBase != base {
            guard await ensureManifest(base: base) else { return ("", []) }
        }
        var out: [TorMeta] = []
        var matches = tvbMatches
        for catalog in catalogs where catalog.searchRequired {
            let found = (try? await JoeUserAddon.search(
                base: base, catalog: catalog, keyword: keyword)) ?? []
            out += found.filter { keepUnmatched($0, tvbSink: &matches) }
        }
        tvbMatches = matches
        return (addonName, out)
    }

    // MARK: TVB backup lookup

    /// The addon meta carrying this TVB series, when the
    /// library load matched one by name (JoeYtDetail's
    /// backup row reads this).
    func tvbBackup(forSeriesTitle title: String) -> (type: String, id: String)? {
        tvbMatches[Providers.normalizeTitle(title)]
    }

    // MARK: Matching (the §5.6 duplicate rule)

    /// Decide one addon meta's fate: true = it stands as
    /// a NEW item (kept); false = it matched an existing
    /// title and stays OUT (its streams join as backup
    /// links instead). Every decision is logged with its
    /// key or its reason — fail-open throughout. A TVB
    /// match is recorded into the caller's sink (gate
    /// round 6, C6-2): the library load passes a LOCAL
    /// sink it commits only at its latch point, so a
    /// superseded load records nothing; paging/search
    /// pass a copy of the live map and write it back.
    private func keepUnmatched(
        _ meta: TorMeta,
        tvbSink: inout [String: (type: String, id: String)]
    ) -> Bool {
        // 1. IMDb id — the meta's own id in tt form, or
        //    its imdb field when it carries one (§5.6's
        //    "hoặc trường imdb của meta"), against the
        //    app catalogue's imdbId (the first key
        //    WatchStore.sameFilm uses).
        let imdbKey = meta.id.hasPrefix("tt") ? meta.id
            : (meta.imdbId.hasPrefix("tt") ? meta.imdbId : "")
        if !imdbKey.isEmpty {
            let hits = matchMovies.filter { $0.imdbId == imdbKey }
            if hits.count == 1 {
                log("addon: link phụ — \"\(meta.name)\" khớp imdb → nhảy vào tựa sẵn có")
                return false
            }
            if hits.count > 1 {
                log("addon: không khớp — \"\(meta.name)\" đứng mục mới (mơ hồ — \(hits.count) ứng viên imdb)")
                return true
            }
        }
        // 2. TMDB id — catalog metas in this protocol
        //    shape carry no TMDB field (TorMeta has
        //    none), so this key cannot run here; it is
        //    named so the order stays the design's.
        // 3. Normalised name + year (sameFilm
        //    discipline: exact normalised title, years
        //    equal / either empty / ±1).
        let nameHits = matchMovies.filter {
            Providers.sameFilm($0, name: meta.name, origin: "", year: meta.year)
        }
        if nameHits.count == 1 {
            log("addon: link phụ — \"\(meta.name)\" khớp tên+năm → nhảy vào tựa sẵn có")
            return false
        }
        if nameHits.count > 1 {
            log("addon: không khớp — \"\(meta.name)\" đứng mục mới (mơ hồ — \(nameHits.count) ứng viên tên+năm)")
            return true
        }
        // 4. TVB by name — the normalised name against
        //    the TVB catalogue's series names. SERIES
        //    metas only (gate round 1, C-2): the backup
        //    this key feeds is a series row in
        //    JoeYtDetail, so a same-named MOVIE meta must
        //    not be stolen into it — it stands as its own
        //    item instead (fail-open, §5.6's intent over
        //    its letter). The design's "kèm năm khi có"
        //    cannot run: JoeYtSeries carries no year.
        let key = Providers.normalizeTitle(meta.name)
        let tvbHits = meta.type == "series" ? matchSeries.filter {
            Providers.normalizeTitle($0.title) == key && !key.isEmpty
        } : []
        if tvbHits.count == 1 {
            tvbSink[key] = (type: meta.type, id: meta.id)
            log("addon: link phụ — \"\(meta.name)\" khớp tvb-tên → nhảy vào tựa sẵn có")
            return false
        }
        if tvbHits.count > 1 {
            log("addon: không khớp — \"\(meta.name)\" đứng mục mới (mơ hồ — \(tvbHits.count) ứng viên tvb-tên)")
            return true
        }
        log("addon: không khớp — \"\(meta.name)\" đứng mục mới (không có ứng viên)")
        return true
    }
}
