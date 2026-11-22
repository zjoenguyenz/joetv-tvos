import Foundation

// MARK: - Trending data file (v2.0.49)
//
// v2.0.49 (owner redirect, 2026-11-21 22:46 CST): the
// torrent home's trending rails come from a self-pulled
// DATA FILE, never from a direct TMDB trending call in
// the app. The file is generated outside the app and
// hosted on the owner's public data repo, beside the TVB
// catalogue — the same self-pull pattern as tvb-yt.json:
// fetch at use, keep the last-good copy cached on device
// (the JoeYtStore cache discipline: the shared Caches
// home, JoeStorage — FIX-214; atomic write, a failed
// fetch falls back to the cache), and fail OPEN — no
// cache, a failed fetch or a malformed file yields no
// rails at all and the home renders exactly as it did
// before this file existed.
//
// File schema (built against exactly; every field is
// read tolerantly — a missing optional field becomes
// empty/0, never a crash):
//
//   { "generated_at": ...,
//     "rails": [ { "id": "movie-day",
//                  "title": "Phim đang thịnh hành hôm nay",
//                  "items": [ { "tmdb_id": n,
//                               "imdb_id": "tt…",
//                               "media_type": "movie|tv",
//                               "title": "…",
//                               "original_title": "…",
//                               "year": n,
//                               "poster": "https://image.tmdb.org/…",
//                               "backdrop": "https://image.tmdb.org/…",
//                               "overview": "…" } ] } ] }
//
// Items are converted to TorMeta keyed by their IMDb id
// (the torrent detail resolves by IMDb id), so an item
// with an empty imdb_id is SKIPPED — it could never open.
// The file's rail order and item order are preserved.
// A title appears once across ALL of the file's rails
// (deduped here, at parse time, by imdb_id AND by
// tmdb_id — the first rail wins), because TorMeta carries
// no tmdb id for the home store to dedupe by later.

/// One rail of the trending file, already converted to
/// the metas the torrent home publishes.
struct JoeTrendingRail: Sendable {
    var id = ""
    var title = ""
    var metas: [TorMeta] = []
}

enum JoeTrendingFile {

    static let hostedURL = URL(
        string: "https://raw.githubusercontent.com/zjoenguyenz/dabanh-playlist/main/trending.json")!

    // MARK: Cache (the JoeYtStore idiom)

    /// FIX-214 (Fault 10 / FL-421): the cache lives in
    /// the shared Caches home (JoeStorage) — the old
    /// Application Support path could never be created
    /// by the tvOS sandbox, so the last-good copy
    /// silently never landed on a fresh install.
    private static var cacheURL: URL {
        JoeStorage.fileURL("trending_cache.json")
    }

    // MARK: Single-flight + last-good (FIX-214, lag package)
    //
    // DESIGN-PASS-214 §3.2: through 2.1.3 this loader
    // was network-first with NO coalescing and a dead
    // disk fallback, called by THREE consumers
    // (TorrentStore, PhimStore, the Top Shelf writer) —
    // concurrent section enters ran concurrent full
    // fetches, and one load's failure path could
    // publish EMPTY rails over rails an earlier load
    // had landed (DiagLog 17: launch read 96 items,
    // the 14:51:59 re-read returned rails=0 inside the
    // worst stall cluster). Now: concurrent callers
    // join ONE in-flight fetch; a fetch that comes
    // back empty-handed NEVER replaces the in-process
    // last-good rails; and every resolution logs its
    // source + generation so the next log shows which
    // path fed the homes.

    /// One load's resolution: the rails the caller
    /// publishes, where they came from ("fetched" /
    /// "stillCurrent" / "none") and the loader's
    /// generation after the resolution.
    fileprivate struct Outcome: Sendable {
        var rails: [JoeTrendingRail]
        var source: String
        var generation: Int
    }

    private actor Flight {
        private(set) var lastGood: [JoeTrendingRail] = []
        private(set) var generation = 0
        private var inFlight: Task<Outcome, Never>?

        /// Vend the shared fetch task: the first caller
        /// creates it, concurrent callers join the SAME
        /// task (and therefore the same Outcome).
        func begin(_ make: @Sendable () -> Task<Outcome, Never>)
            -> Task<Outcome, Never> {
            if let inFlight { return inFlight }
            let task = make()
            inFlight = task
            return task
        }

        /// Close out the in-flight fetch — called ONLY
        /// from inside that task's own body, exactly
        /// once per fetch. A fresh non-empty result
        /// becomes the last-good copy and bumps the
        /// generation; a disk-cache result is adopted
        /// as the in-process last-good when none exists;
        /// an empty-handed fetch changes nothing, so a
        /// superseded or failed generation can never
        /// replace good rails with empty ones. The one
        /// [TOR] resolution line per fetch is written
        /// here so joined callers do not duplicate it.
        func finish(_ fetched: [JoeTrendingRail], fresh: Bool) -> Outcome {
            inFlight = nil
            let outcome: Outcome
            if fresh, !fetched.isEmpty {
                lastGood = fetched
                generation += 1
                outcome = Outcome(rails: fetched, source: "fetched",
                                  generation: generation)
            } else if !fetched.isEmpty {
                if lastGood.isEmpty { lastGood = fetched }
                outcome = Outcome(rails: lastGood, source: "stillCurrent",
                                  generation: generation)
            } else if !lastGood.isEmpty {
                outcome = Outcome(rails: lastGood, source: "stillCurrent",
                                  generation: generation)
            } else {
                outcome = Outcome(rails: [], source: "none",
                                  generation: generation)
            }
            DiagLog.write("TOR", "trending file source=\(outcome.source) rails=\(outcome.rails.count) items=\(outcome.rails.reduce(0) { $0 + $1.metas.count }) gen=\(outcome.generation)")
            return outcome
        }
    }

    private static let flight = Flight()

    // MARK: Load

    /// Fetch the hosted file (single-flight — see the
    /// Flight note above); on success the raw bytes
    /// become the new last-good cache. On any failure
    /// the cached copy is tried instead, and behind
    /// that the in-process last-good rails. Returns an
    /// empty array only when no source has ever
    /// produced rails (fail-open).
    static func loadRails() async -> [JoeTrendingRail] {
        let task = await flight.begin {
            Task {
                let (rails, fresh) = await Self.fetchRails()
                return await Self.flight.finish(rails, fresh: fresh)
            }
        }
        return await task.value.rails
    }

    /// The raw fetch: network first (a parsed result is
    /// "fresh" and its bytes become the new disk
    /// cache), then the disk cache. An empty array with
    /// fresh == false means neither source produced
    /// rails.
    private static func fetchRails() async
        -> (rails: [JoeTrendingRail], fresh: Bool) {
        var request = URLRequest(url: hostedURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, _) = try? await URLSession.shared.data(for: request),
           let rails = parse(data) {
            // Cache the last-good copy for the next launch
            // (atomic, like JoeYtStore's refresh write). A
            // failed write is not a load failure — the
            // freshly parsed rails still publish. The
            // directory is JoeStorage's, created by its
            // resolver before this URL could exist.
            try? data.write(to: cacheURL, options: .atomic)
            return (rails, true)
        }
        if let cached = try? Data(contentsOf: cacheURL),
           let rails = parse(cached) {
            return (rails, false)
        }
        return ([], false)
    }

    // MARK: Parse

    /// Tolerant parse: nil ONLY when the file is not the
    /// expected shape at all (not a JSON object, or no
    /// "rails" array) — a well-formed file with empty or
    /// partially-populated rails parses to whatever usable
    /// rails it carries.
    static func parse(_ data: Data) -> [JoeTrendingRail]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              let railDicts = JSON.arr(root, "rails") else {
            return nil
        }
        var seenImdb = Set<String>()
        var seenTmdb = Set<Int>()
        var rails: [JoeTrendingRail] = []
        for railDict in railDicts {
            var rail = JoeTrendingRail()
            rail.id = JSON.str(railDict, "id")
            rail.title = JSON.str(railDict, "title")
            for item in JSON.arr(railDict, "items") ?? [] {
                let imdbId = JSON.str(item, "imdb_id")
                    .trimmingCharacters(in: .whitespaces)
                // No IMDb id ⇒ the torrent detail cannot
                // resolve this title — skip it (see header).
                guard !imdbId.isEmpty else { continue }
                let tmdbId = JSON.int(item, "tmdb_id")
                // First rail wins, across the whole file:
                // a title already seen by either id is not
                // repeated in a later rail. v2.0.49 fix
                // round (Lens A MINOR-1 / Lens C MINOR-2):
                // both ids are CHECKED before either is
                // claimed — an item rejected by the tmdb
                // guard must not claim its imdb id and
                // suppress a later legitimate item; only
                // accepted items claim ids.
                if seenImdb.contains(imdbId) { continue }
                if tmdbId > 0, seenTmdb.contains(tmdbId) { continue }
                seenImdb.insert(imdbId)
                if tmdbId > 0 {
                    seenTmdb.insert(tmdbId)
                }
                var meta = TorMeta()
                meta.id = imdbId
                meta.type = JSON.str(item, "media_type") == "tv"
                    ? "series" : "movie"
                meta.name = JSON.str(item, "title")
                meta.poster = JSON.str(item, "poster")
                meta.background = JSON.str(item, "backdrop")
                let year = JSON.int(item, "year")
                meta.year = year > 0 ? String(year) : ""
                meta.desc = JSON.str(item, "overview")
                meta.imdbId = imdbId
                rail.metas.append(meta)
            }
            rails.append(rail)
        }
        return rails
    }
}
