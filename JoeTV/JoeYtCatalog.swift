import Foundation

// MARK: - TVB YouTube catalogue (tvb-yt.json)
//
// The YouTube side of the TVB tab, consuming the EXACT file
// the Sony build consumes (design plan §1.1/§1.2; handover
// package MANIFEST, verified 2026-11-19: 1,873 series, 51,180
// episodes, generatedAt 2026-11-20T04:51:44Z). Load order is
// the Sony contract: the last accepted hosted copy (cache)
// wins over the bundled fallback; a background refresh runs
// when the loaded copy is over 24 h old and replaces the
// CACHE only — the published snapshot is never swapped under
// its readers in-process (publish-once, design §1.2 item 4);
// the refreshed copy takes effect on the next cold start.
//
// Matching to the 803-title snapshot is fail-closed (design
// §1.4): a series links ONLY when its tmdbId is non-zero, a
// DISPLAYED snapshot title holds that id, AND the series'
// matched Vi name (or its cleaned title) equals that title's
// Vi / EN / original name exactly after Providers
// .normalizeTitle. Desk-verified against the real files
// before this code was written: 1,177 series pass the
// name test, naming 626 distinct titles — 416 titles have
// 2–4 passing series, and those collisions resolve by the
// deterministic preference in JoeYtSnapshot.build
// (own-title exact → tier → rail rank), never by file
// order. Any doubt on the name test ⇒ no link: the series
// stands YouTube-only and the 803 title stands chain-only.
//
// Rail order is the owner's 2026-11-19 ruling: HOT /
// most-watched first, NEW ahead on ties — `views` (YouTube's
// own playlist view count, the primary signal) desc, then
// `rssNewestAt` desc (a coarse freshness hint only — the RSS
// window covers the first ≤15 playlist positions, so it is
// never read as a latest-episode date), then pid for
// determinism.

struct JoeYtSeries: Codable, Sendable, Identifiable {
    let pid: String
    let title: String
    let rawTitle: String
    let channel: String
    /// "gold" | "vip" | "members" | "free" — the file's own
    /// vocabulary, kept verbatim (design §1.1). Unknown values
    /// group into no rail.
    let tier: String
    let eps: [String]
    let epTitles: [String]
    /// 0 = unmatched / ambiguous in the builder (fail-closed
    /// there); a non-zero value still has to pass the in-app
    /// title check before it links (§1.4).
    let tmdbId: Int
    let matchVi: String
    let views: Int?
    let rssNewestAt: String?

    var id: String { pid }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(String.self, forKey: .pid)
        title = try c.decode(String.self, forKey: .title)
        rawTitle = try c.decodeIfPresent(String.self, forKey: .rawTitle) ?? title
        channel = try c.decodeIfPresent(String.self, forKey: .channel) ?? ""
        tier = try c.decodeIfPresent(String.self, forKey: .tier) ?? ""
        eps = try c.decodeIfPresent([String].self, forKey: .eps) ?? []
        epTitles = try c.decodeIfPresent([String].self, forKey: .epTitles) ?? []
        tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId) ?? 0
        matchVi = try c.decodeIfPresent(String.self, forKey: .matchVi) ?? ""
        views = try c.decodeIfPresent(Int.self, forKey: .views)
        rssNewestAt = try c.decodeIfPresent(String.self, forKey: .rssNewestAt)
    }

    private enum CodingKeys: String, CodingKey {
        case pid, title, rawTitle, channel, tier, eps, epTitles
        case tmdbId, matchVi, views, rssNewestAt
    }

    /// Members tiers need the Gold session (design §1.6).
    var isMembersTier: Bool {
        tier == "gold" || tier == "vip" || tier == "members"
    }

    var isSuperVIP: Bool { tier == "vip" }

    /// The file's tier vocabulary in the app's words
    /// (design §1.1): gold → Gold, vip → Super VIP,
    /// members → Silver, free → Miễn phí.
    var tierLabel: String {
        switch tier {
        case "gold": return "Gold"
        case "vip": return "Super VIP"
        case "members": return "Silver"
        case "free": return "Miễn phí"
        default: return tier
        }
    }

    var channelDisplay: String {
        switch channel {
        case "TVB_Vietnam": return "TVB Vietnam"
        case "tvbtuyentapdacsac": return "TVB Tuyển Tập Đặc Sắc"
        case "tvb_kenhkinhdien": return "TVB Kênh Kinh Điển"
        case "tvblivecung": return "TVB Live Cùng"
        case "tvbduyentinh": return "TVB Duyên Tình"
        case "tvbsitcomvietnam": return "TVB Sitcom Vietnam"
        case "rapphimso9": return "Rạp Phim Số 9"
        default: return channel
        }
    }

    /// Poster = the first episode's thumbnail, derived, never
    /// stored (design §1.1).
    var posterURL: URL? {
        guard let first = eps.first, !first.isEmpty else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(first)/hqdefault.jpg")
    }

    var posterURLString: String { posterURL?.absoluteString ?? "" }

    /// epTitles is parallel to eps but a future file could
    /// carry it short; out-of-range reads answer "" and the
    /// caller falls back to "Tập N" (design §1.1).
    func epTitle(at index: Int) -> String {
        guard epTitles.indices.contains(index) else { return "" }
        return epTitles[index]
    }

    /// Rail ranking (owner ruling): views desc (nil last),
    /// rssNewestAt desc on ties, pid asc for determinism.
    static func rankBefore(_ a: JoeYtSeries, _ b: JoeYtSeries) -> Bool {
        let av = a.views ?? -1
        let bv = b.views ?? -1
        if av != bv { return av > bv }
        let ad = a.rssNewestAt ?? ""
        let bd = b.rssNewestAt ?? ""
        if ad != bd { return ad > bd }
        return a.pid < b.pid
    }
}

/// One display rail of the YouTube shelf (design §1.3 caps).
struct JoeYtRail: Sendable, Identifiable {
    let scope: String
    let title: String
    let series: [JoeYtSeries]
    var id: String { scope }
}

/// The published, immutable catalogue snapshot for this
/// process (design §1.2 item 4).
struct JoeYtSnapshot: Sendable {
    let generatedAt: String
    let series: [JoeYtSeries]
    let byPid: [String: JoeYtSeries]
    /// Fail-closed links, both directions (§1.4). One link
    /// per title: when several series pass the name test
    /// for one title, the collision resolves by the
    /// deterministic preference in build() — never silently
    /// by file order.
    let matchByTmdbId: [Int: JoeYtSeries]
    let matchedTitleByPid: [String: TVBTitle]
    /// How many titles had more than one passing series
    /// (for the load log line).
    let collisions: Int
    /// Rails in display order, caps applied, ranked.
    let rails: [JoeYtRail]

    static func build(file: JoeYtFile,
                      displayedTitles: [TVBTitle]) -> JoeYtSnapshot {
        let series = file.series
        var byPid: [String: JoeYtSeries] = [:]
        byPid.reserveCapacity(series.count)
        for s in series { byPid[s.pid] = s }

        // Fail-closed matching (design §1.4): tmdbId non-zero
        // AND a displayed snapshot title holds it AND the
        // normalised matched name (or cleaned title) equals
        // one of that title's names EXACTLY. (A duplicate id
        // in a future snapshot must fail soft, never trap —
        // the first title wins, as the tab's own loader does.)
        let titlesById = Dictionary(
            displayedTitles.map { ($0.tmdbId, $0) },
            uniquingKeysWith: { first, _ in first })
        // Collision resolution (review MAJOR, 2026-11-19):
        // 1,177 series pass the name test but they name only
        // 626 distinct titles — 416 titles have 2–4 passing
        // series (Gold / free / part uploads of one show),
        // and silent last-in-file wins was WRONG in measured
        // cases (a "…3" playlist surviving over the exact
        // base-title playlist on a matched-name pass; a
        // Super VIP surviving over a watchable Gold). The
        // winner is deterministic: a series whose OWN title
        // is exact beats one that passed only via its
        // matched name; then the tier the owner watches
        // best (Gold — his membership, the intact playlists
        // — then free, then Silver, Super VIP last); then
        // the rail rank. rankBefore ends in the unique pid,
        // so the order is total: every group has exactly
        // one well-defined winner.
        func tierRank(_ tier: String) -> Int {
            switch tier {
            case "gold": return 0
            case "free": return 1
            case "members": return 2
            case "vip": return 3
            default: return 4
            }
        }
        var candidatesById: [Int: [(series: JoeYtSeries, ownExact: Bool)]] = [:]
        for s in series where s.tmdbId != 0 {
            guard let title = titlesById[s.tmdbId] else { continue }
            let names = [title.titleVi, title.titleEn, title.titleOriginal]
                .map { Providers.normalizeTitle($0) }
            let ownNorm = Providers.normalizeTitle(s.title)
            let matchNorm = Providers.normalizeTitle(s.matchVi)
            let ownExact = !ownNorm.isEmpty && names.contains(ownNorm)
            let viaMatch = !matchNorm.isEmpty && names.contains(matchNorm)
            if ownExact || viaMatch {
                candidatesById[s.tmdbId, default: []]
                    .append((series: s, ownExact: ownExact))
            }
        }
        var matchByTmdbId: [Int: JoeYtSeries] = [:]
        var matchedTitleByPid: [String: TVBTitle] = [:]
        var collisions = 0
        for (tmdbId, candidates) in candidatesById {
            guard let title = titlesById[tmdbId] else { continue }
            if candidates.count > 1 { collisions += 1 }
            let winner = candidates.sorted { a, b in
                if a.ownExact != b.ownExact { return a.ownExact }
                let ta = tierRank(a.series.tier)
                let tb = tierRank(b.series.tier)
                if ta != tb { return ta < tb }
                return JoeYtSeries.rankBefore(a.series, b.series)
            }.first!
            matchByTmdbId[tmdbId] = winner.series
            matchedTitleByPid[winner.series.pid] = title
        }

        func rail(_ scope: String, _ title: String,
                  _ items: [JoeYtSeries], cap: Int) -> JoeYtRail? {
            guard !items.isEmpty else { return nil }
            return JoeYtRail(scope: scope, title: title,
                             series: Array(items.sorted(by: JoeYtSeries.rankBefore)
                                .prefix(cap)))
        }

        // Sony rail order, mirrored (design §1.3): Gold,
        // Super VIP, Silver, Free (main channel), then one
        // rail per sister channel.
        var rails: [JoeYtRail] = []
        if let r = rail("ytGold", "🏆 Gold · YouTube",
                        series.filter { $0.tier == "gold" }, cap: 120) {
            rails.append(r)
        }
        if let r = rail("ytVip", "👑 Super VIP · YouTube",
                        series.filter { $0.tier == "vip" }, cap: 60) {
            rails.append(r)
        }
        if let r = rail("ytSilver", "🥈 Silver · YouTube",
                        series.filter { $0.tier == "members" }, cap: 60) {
            rails.append(r)
        }
        if let r = rail("ytFree", "🆓 Miễn phí · YouTube",
                        series.filter {
                            $0.tier == "free" && $0.channel == "TVB_Vietnam"
                        }, cap: 120) {
            rails.append(r)
        }
        for channel in ["tvbtuyentapdacsac", "tvb_kenhkinhdien",
                        "tvblivecung", "tvbduyentinh",
                        "tvbsitcomvietnam", "rapphimso9"] {
            let items = series.filter { $0.channel == channel }
            guard let first = items.first else { continue }
            if let r = rail("ytSister:" + channel,
                            "📺 " + first.channelDisplay,
                            items, cap: 80) {
                rails.append(r)
            }
        }

        return JoeYtSnapshot(generatedAt: file.generatedAt,
                             series: series,
                             byPid: byPid,
                             matchByTmdbId: matchByTmdbId,
                             matchedTitleByPid: matchedTitleByPid,
                             collisions: collisions,
                             rails: rails)
    }
}

struct JoeYtFile: Codable, Sendable {
    let generatedAt: String
    let series: [JoeYtSeries]
}

// MARK: - Store

/// Loads and publishes the YouTube catalogue snapshot once
/// per process (FollowStore.shared is the house idiom for
/// this shape). All file/network work happens off the main
/// actor; the snapshot is published whole, then immutable.
@MainActor
final class JoeYtStore: ObservableObject {
    static let shared = JoeYtStore()

    @Published private(set) var snapshot: JoeYtSnapshot?
    private var loadStarted = false

    static let hostedURL = URL(
        string: "https://raw.githubusercontent.com/zjoenguyenz/dabanh-playlist/main/tvb-yt.json")!

    private init() {}

    /// Idempotent: the first caller starts the load; later
    /// calls (tab re-entries, the detail screen) are no-ops.
    func ensureLoaded() {
        guard !loadStarted else { return }
        loadStarted = true
        Task { await self.load() }
    }

    private func load() async {
        let built = await Task.detached(priority: .userInitiated) {
            Self.buildFromDisk()
        }.value
        guard let built else {
            DiagLog.write("YT", "catalogue load failed (no cache, no bundle)")
            return
        }
        snapshot = built.snapshot
        DiagLog.write("YT", "catalogue loaded generatedAt=\(built.snapshot.generatedAt) series=\(built.snapshot.series.count) matched=\(built.snapshot.matchByTmdbId.count) collisions=\(built.snapshot.collisions) source=\(built.fromCache ? "cache" : "bundle")")
        // Warm the first rails' posters through the existing
        // pipeline (the JoeTVBView launch-prefetch pattern).
        let warm = built.snapshot.rails.prefix(2)
            .flatMap { $0.series.prefix(30) }
            .compactMap { $0.posterURL }
        JoeImagePipeline.shared.prefetch(warm, targetPixels: 720)
        // The "living" leg (design §1.2 item 3): one
        // background refresh per process when the loaded copy
        // is over 24 h old. It writes the cache ONLY; this
        // process's snapshot never changes under its readers.
        if built.isStale {
            Task { await self.refreshCache() }
        }
    }

    // MARK: Disk + refresh (detached helpers)
    //
    // These four are `nonisolated` on purpose: the class is
    // @MainActor (its @Published snapshot demands it), but
    // buildFromDisk runs inside Task.detached — under Swift 6
    // a @MainActor class isolates its statics too, so without
    // the marker the detached call is a compile error (review
    // round 1, BLOCKER). Everything they touch is Foundation
    // value work plus the nonisolated JoeYtSnapshot.build /
    // TVBCatalog.loadBundled — no actor state.

    private nonisolated static var cacheURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("tvb_yt_cache.json")
    }

    private nonisolated static func decodeFile(_ data: Data) -> JoeYtFile? {
        try? JSONDecoder().decode(JoeYtFile.self, from: data)
    }

    private nonisolated static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Cache wins when its generatedAt is at least the
    /// bundled copy's; an unparseable generatedAt never beats
    /// a parseable one, and a copy that fails to decode is
    /// simply not a candidate (fail-closed, design §1.2).
    private nonisolated static func buildFromDisk()
        -> (snapshot: JoeYtSnapshot, fromCache: Bool, isStale: Bool)? {
        let bundledData = Bundle.main.url(forResource: "tvb-yt",
                                          withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        let cacheData = try? Data(contentsOf: cacheURL)
        let bundled = bundledData.flatMap { decodeFile($0) }
        let cached = cacheData.flatMap { decodeFile($0) }

        var chosen: JoeYtFile?
        var fromCache = false
        switch (bundled, cached) {
        case let (b?, c?):
            let bd = parseDate(b.generatedAt) ?? .distantPast
            let cd = parseDate(c.generatedAt) ?? .distantPast
            if cd >= bd {
                chosen = c
                fromCache = true
            } else {
                chosen = b
            }
        case let (b?, nil):
            chosen = b
        case let (nil, c?):
            chosen = c
            fromCache = true
        case (nil, nil):
            return nil
        }
        guard let file = chosen else { return nil }
        let displayed = TVBCatalog.loadBundled()?
            .titles.filter { $0.isDisplayed } ?? []
        let snapshot = JoeYtSnapshot.build(file: file,
                                           displayedTitles: displayed)
        let stamp = parseDate(file.generatedAt) ?? .distantPast
        let isStale = Date().timeIntervalSince(stamp) > 24 * 3600
        return (snapshot, fromCache, isStale)
    }

    /// Fetches the hosted copy; replaces the cache only when
    /// its generatedAt is STRICTLY newer than the loaded
    /// snapshot's (an unparseable stamp never replaces
    /// anything — design §1.2 item 3). The decode + write of
    /// the 6.7 MB file run in a detached task (review MINOR,
    /// 2026-11-19): this class's contract is that file work
    /// happens OFF the main actor — a synchronous decodeFile
    /// call from here would execute inline on the main actor
    /// and hitch the UI.
    private func refreshCache() async {
        guard let current = snapshot else { return }
        let data: Data
        do {
            let (fetched, _) = try await URLSession.shared.data(from: Self.hostedURL)
            data = fetched
        } catch {
            DiagLog.write("YT", "refresh failed (network) — keeping loaded copy")
            return
        }
        let currentStamp = current.generatedAt
        let outcome = await Task.detached(priority: .utility) { () -> String in
            guard let file = Self.decodeFile(data) else {
                return "rejected"
            }
            let newStamp = Self.parseDate(file.generatedAt) ?? .distantPast
            let oldStamp = Self.parseDate(currentStamp) ?? .distantPast
            guard newStamp > oldStamp else {
                return "notNewer"
            }
            do {
                try data.write(to: Self.cacheURL, options: .atomic)
                return "cached \(file.generatedAt)"
            } catch {
                return "writeFailed"
            }
        }.value
        switch outcome {
        case "rejected":
            DiagLog.write("YT", "refresh rejected (decode failed)")
        case "notNewer":
            DiagLog.write("YT", "refresh skipped (hosted not newer)")
        case "writeFailed":
            DiagLog.write("YT", "refresh failed (cache write) — keeping loaded copy")
        default:
            DiagLog.write("YT", "refresh cached generatedAt=\(outcome.dropFirst(7)) (applies next launch)")
        }
    }
}

// MARK: - Search

/// The YouTube half of the TVB tab's search (design §1.3):
/// the rail caps are display caps only — every series in the
/// file is searchable, so a beyond-cap Gold series is never
/// orphaned (the Sony X-1 gap, closed by design here).
/// Ranking mirrors JoeTVBSearchView's tiers over
/// Providers.normalizeTitle: exact, then prefix, then
/// contains; rank order (views desc) inside each tier.
enum JoeYtSearch {
    static func ranked(query: String, series: [JoeYtSeries]) -> [JoeYtSeries] {
        let q = Providers.normalizeTitle(query)
        guard !q.isEmpty else { return [] }
        var exact: [JoeYtSeries] = []
        var prefix: [JoeYtSeries] = []
        var contains: [JoeYtSeries] = []
        for s in series {
            let keys = [s.title, s.matchVi]
                .map { Providers.normalizeTitle($0) }
                .filter { !$0.isEmpty }
            if keys.contains(q) {
                exact.append(s)
            } else if keys.contains(where: { $0.hasPrefix(q) }) {
                prefix.append(s)
            } else if keys.contains(where: { $0.contains(q) }) {
                contains.append(s)
            }
        }
        let byRank = { (a: JoeYtSeries, b: JoeYtSeries) in
            JoeYtSeries.rankBefore(a, b)
        }
        return Array((exact.sorted(by: byRank)
                      + prefix.sorted(by: byRank)
                      + contains.sorted(by: byRank)).prefix(90))
    }
}
