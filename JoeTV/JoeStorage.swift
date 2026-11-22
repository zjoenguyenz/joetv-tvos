import Foundation

/// FIX-214 (Fault 10 / FL-421, root cause convicted by
/// DESIGN-PASS-214 §3.1): the ONE writable home for the
/// app's small data files.
///
/// THE CONVICTION: tvOS's sandbox refuses to CREATE the
/// `Library/Application Support` directory — the
/// createDirectory call itself fails with NSCocoaError
/// 513 ("You don't have permission to save the file
/// "Application Support" in the folder "Library"",
/// DiagLog 17 line 185), on a directory every affected
/// writer obtained from `urls(for:
/// .applicationSupportDirectory)` (which returns the URL
/// without creating it). The 2.1.3 fix created the
/// directory explicitly before writing — it aimed at
/// precisely the operation the sandbox denies, so all
/// three writers stayed broken: the TVB-YouTube
/// catalogue cache (JoeYtStore), the trending cache
/// (JoeTrendingFile) and the YouTube session cookie
/// mirror (JoeYtSession — which had therefore NEVER
/// persisted). The tree already carries the proof of
/// the working home: WatchStore was moved to Caches in
/// v2.0.17 for this exact failure (WatchStore.swift,
/// fileDirectory), and DiagLog survives only through
/// its Caches fallback.
///
/// THE FIX: every app data file resolves through here,
/// ONCE, into `Caches/joetv-files/`. Caches is
/// system-purgeable under storage pressure; that is
/// acceptable for all three consumers by design — the
/// catalogue and the trending file re-fetch from their
/// hosted copies, and the cookie mirror deliberately
/// does NOT live here at all (leader decision,
/// 2026-11-22: it moved to UserDefaults, which a cache
/// purge cannot reach — a purge must never sign the
/// owner out).
///
/// The launch probe below is the conviction-grade
/// evidence the next diagnostic log carries: what
/// Application Support answered, whether Caches took a
/// real write test, and the directory every writer now
/// uses. It logs PATHS and OUTCOMES only — never a file
/// content, never a credential (DiagLog discipline).
enum JoeStorage {

    /// The shared directory: Caches/joetv-files/,
    /// created at first use. Resolved ONCE — `static
    /// let` initialisation is thread-safe by the
    /// runtime's own guarantee (the DiagLog storage
    /// idiom), so no caller ever races the creation or
    /// the probe.
    static let directory: URL = {
        let fm = FileManager.default

        // Probe 1 — Application Support: attempt the
        // sanctioned create and record the outcome.
        // The result is EVIDENCE for the next log, not
        // a candidate home: the active directory is
        // Caches regardless (design decision above).
        var appSupportLine = "appsupport url=none create=false result=unavailable"
        if let appSupport = fm.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first {
            do {
                _ = try fm.url(for: .applicationSupportDirectory,
                               in: .userDomainMask,
                               appropriateFor: nil, create: true)
                appSupportLine = "appsupport url=\(appSupport.path) create=true result=ok"
            } catch {
                appSupportLine = "appsupport url=\(appSupport.path) create=true result=fail \(error.localizedDescription)"
            }
        }

        // Probe 2 — Caches: create the shared directory
        // and prove it with a real write + remove of a
        // scratch file (a directory that exists but
        // cannot be written is not a home).
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = caches.appendingPathComponent("joetv-files",
                                                isDirectory: true)
        var cachesResult = "ok"
        do {
            try fm.createDirectory(at: dir,
                                   withIntermediateDirectories: true)
            let probe = dir.appendingPathComponent(".writetest")
            try Data([0x4A]).write(to: probe, options: .atomic)
            try? fm.removeItem(at: probe)
        } catch {
            cachesResult = "fail \(error.localizedDescription)"
        }

        DiagLog.write("storage", appSupportLine)
        DiagLog.write("storage", "caches url=\(caches.path) writetest=\(cachesResult)")
        DiagLog.write("storage", "active dir=\(dir.path)")
        return dir
    }()

    /// One consumer's file inside the shared directory.
    static func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}
