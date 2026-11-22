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
// (the JoeYtStore cache discipline: Application Support,
// atomic write, a failed fetch falls back to the cache),
// and fail OPEN — no cache, a failed fetch or a malformed
// file yields no rails at all and the home renders
// exactly as it did before this file existed.
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

    private static var cacheURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("trending_cache.json")
    }

    // MARK: Load

    /// Fetch the hosted file; on success the raw bytes
    /// become the new last-good cache. On any failure the
    /// cached copy is tried instead. Returns an empty
    /// array when neither source parses (fail-open).
    static func loadRails() async -> [JoeTrendingRail] {
        var request = URLRequest(url: hostedURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, _) = try? await URLSession.shared.data(for: request),
           let rails = parse(data) {
            // Cache the last-good copy for the next launch
            // (atomic, like JoeYtStore's refresh write). A
            // failed write is not a load failure — the
            // freshly parsed rails still publish.
            try? data.write(to: cacheURL, options: .atomic)
            return rails
        }
        if let cached = try? Data(contentsOf: cacheURL),
           let rails = parse(cached) {
            return rails
        }
        return []
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
