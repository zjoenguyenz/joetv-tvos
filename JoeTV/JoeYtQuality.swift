import Foundation

// MARK: - Per-series measured quality ceiling (2.0.48)
// Feature #1 / Approach C — the standing product answer
// to FL-351 (owner-approved 2026-11-21 12:51 CST).
//
// FL-351 proved the quality ceiling is PER-SERIES: YouTube
// gates some TVB series at 480p by title while others
// reach 1080p, so any quality the app PRINTS for a series
// it has not measured is a guess dressed as a fact. This
// store is the honest alternative: the app records the
// best variant height it ACTUALLY obtained for a series
// (the native player's built items and the backdrop
// preview's resolves are the measuring instruments —
// JoeYtPlayable.height is the height of the variant the
// resolve really produced), keyed by the series' pid, and
// the detail screen + series cards badge ONLY from this
// map. A series never measured on this install shows NO
// badge — never an assumed or aspirational figure.
//
// Measure-only by design: no seed ships in 2.0.48 (the
// FL-351 evidence was gathered per episode video, and
// mapping it onto series pids could not be done without
// guessing at identities — when in doubt, no seed).
//
// Storage: one JSON object {pid: height} in UserDefaults.
// A series count is bounded by the catalogue (~1,873), so
// the blob stays a few tens of KB at the outside. The
// lock + load-once cache follow the JoeYtPosterResolver
// idiom; record() persists only when the ceiling RISES,
// so the write rate is a handful per series per install.
enum JoeYtQualityMap {

    private static let lock = NSLock()
    private static let defaultsKey = "ytSeriesCeilingV1"
    // Swift 6: nonisolated(unsafe) — every access is
    // serialized by lock (the JoeYtPosterResolver idiom).
    private nonisolated(unsafe) static var loaded: [String: Int]?

    private static func loadLocked() -> [String: Int] {
        if let loaded { return loaded }
        var map: [String: Int] = [:]
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(
               [String: Int].self, from: data) {
            map = decoded
        }
        loaded = map
        return map
    }

    /// Record one measurement: a variant of `height` was
    /// really obtained for this series on this install.
    /// Only a RISE is kept — the map is a ceiling, not a
    /// last-sample — and only a rise touches disk.
    static func record(pid: String, height: Int) {
        guard !pid.isEmpty, height > 0 else { return }
        var rose = false
        lock.lock()
        var map = loadLocked()
        if height > (map[pid] ?? 0) {
            map[pid] = height
            loaded = map
            if let data = try? JSONEncoder().encode(map) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
            rose = true
        }
        lock.unlock()
        if rose {
            DiagLog.write("YT-QUAL",
                          "ceiling pid=\(pid) height=\(height)p (đo thật trên máy này)")
        }
    }

    /// The measured ceiling for one series, or nil when
    /// this install has never measured it — nil is the
    /// honest "unknown", and callers badge nothing.
    static func ceiling(pid: String) -> Int? {
        guard !pid.isEmpty else { return nil }
        lock.lock()
        let value = loadLocked()[pid]
        lock.unlock()
        return value
    }

    /// The badge text ("1080p") for one series, or nil
    /// when unmeasured. Same spoken form as the player's
    /// own quality label (JoeYtNativePlayerModel
    /// .qualityText): "\(height)p".
    static func badgeText(pid: String) -> String? {
        guard let height = ceiling(pid: pid), height > 0
        else { return nil }
        return "\(height)p"
    }
}
