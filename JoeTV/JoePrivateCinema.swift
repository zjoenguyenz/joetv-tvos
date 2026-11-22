import SwiftUI
import UIKit

// MARK: - Private Cinema shared pieces (v2.1.0 (Private Cinema))
//
// The shared building blocks of the Private Cinema theme
// (v2.1.0 (Private Cinema)) that live OUTSIDE any one
// screen: the shell's live clock and the trailer-preview
// chain for surfaces that are not JoeMovieDetail (the
// actor filmography page). (The PC detail compositions'
// text-line credits blocks live with their compositions:
// JoeActorNameLabel in JoeMovieDetail.swift and
// JoeTorNameLabel in JoeTorrent.swift.) Everything here
// follows the house
// rules: one render owner per control (the shared
// JoeCardButtonStyle via .joeCardButton()), value-only
// focus changes (no view structure conditional on
// @FocusState), and nothing recomputed in body on the
// focus path.

// MARK: - Live clock (shell top bar)

/// The Private Cinema top bar's live clock (v2.1.0
/// (Private Cinema)): "HH:mm", refreshed on a 30 s
/// periodic timeline so the minute flips without any
/// polling loop of the app's own. JoeTVApp's topBar
/// renders this under the PC theme only.
struct PCClockLabel: View {
    @Environment(\.joeTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(context.date, format: PCClockLabel.clockStyle)
                .font(.system(size: 25))
                .foregroundStyle(theme.meta)
        }
    }

    static let clockStyle = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
}

// MARK: - Trailer chain for non-detail surfaces

/// The trailer attempt for surfaces outside
/// JoeMovieDetail (v2.1.0 (Private Cinema)): a verbatim
/// mirror of JoeMovieDetail.startTrailerPreview /
/// attemptTrailerKey (JoeMovieDetail.swift, the v2.0.49
/// trailer-only contract) so the actor filmography page
/// runs the IDENTICAL chain — TMDB's trailer key first,
/// the title's own source trailer (mined from the
/// source trailer URL) as fallback, each key resolved
/// through JoeYtResolver (the player's own route), the
/// ≥720p known-height gates, the HLS assembly session
/// via JoeYtHlsServer with the tv_samsung user agent,
/// the muxed/direct fallbacks, the hand-over at
/// startFraction 0, and one abort with the last key's
/// reason only when every key failed. Every decision
/// writes the same PREVIEW DiagLog lines the detail
/// writes, so a device log proves this chain the same
/// way it proves the detail's.
enum JoeCinemaTrailer {

    /// Sentinel reason returned by attemptTrailerKey when
    /// the attempt was superseded (Task cancelled) after an
    /// uninterruptible await. Distinct from every real
    /// failure reason: run() treats it as an immediate,
    /// silent exit and must NOT abort the attempt (see
    /// run()'s doc comment for the cross-film leak race).
    private static let cancelledReason = "trailer-cancelled"

    /// The runPreview gates that do not depend on a
    /// surface (v2.1.0 (Private Cinema)): the Settings
    /// preview toggle and Reduce Motion, with the same
    /// skip log lines JoeMovieDetail.runPreview writes.
    /// The surface gate is the CALLER's (the filmography
    /// page exists only under the PC composition, which
    /// has a backdrop layer by construction). Returns
    /// true when a trailer attempt may proceed.
    @MainActor
    static func allowedByRules() -> Bool {
        guard JoePreviewSettings.enabled else {
            DiagLog.write("PREVIEW", "preview skipped rule=settings-off")
            return false
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            DiagLog.write("PREVIEW", "preview skipped rule=reduce-motion")
            return false
        }
        return true
    }

    /// Run one trailer attempt into `preview` for the
    /// title identified by (tmdbId, tmdbType), with
    /// `sourceTrailerUrl` as the fallback trailer source
    /// (the provider payload's trailer URL; "" when the
    /// record carries none — TVB snapshot titles carry
    /// no source trailer, so their chain is TMDB-only).
    ///
    /// Cross-film leak race (F-B1): the resolver/HLS
    /// awaits are uninterruptible, so a superseded film's
    /// chain can resume after the page has moved on to
    /// the next film. Because this chain runs on
    /// @MainActor, a Task.isCancelled check placed
    /// immediately after the last await before each
    /// preview.play(...) is airtight (no suspension
    /// between check and play). attemptTrailerKey
    /// performs those checks and returns cancelledReason
    /// on cancellation; run() then returns IMMEDIATELY
    /// and SILENTLY — it must NOT call
    /// preview.abortAttempt, because the attempt slot may
    /// already belong to the next film (the page's
    /// stop() already tore down this film's own attempt).
    /// The same discipline applies between keys and at
    /// loop end: a cancelled run never aborts.
    @MainActor
    static func run(tmdbId: String, tmdbType: String,
                    sourceTrailerUrl: String,
                    into preview: JoePreviewController) async {
        var keys: [String] = []
        if !tmdbId.isEmpty, tmdbId != "0",
           let tmdbKey = await TMDBClient.fetchTrailerKey(
               tmdbId: tmdbId, type: tmdbType),
           !tmdbKey.isEmpty {
            keys.append(tmdbKey)
        }
        // Mirror of the detail's F-B1 guard: the key
        // fetch above runs BEFORE beginAttempt, so a
        // dismissal during the fetch must not let this
        // orphaned task go on to begin an attempt on a
        // dead view.
        guard !Task.isCancelled else { return }
        if let sourceKey = youtubeVideoId(
               fromTrailerURL: sourceTrailerUrl),
           !keys.contains(sourceKey) {
            keys.append(sourceKey)
        }
        guard !keys.isEmpty else {
            DiagLog.write("PREVIEW", "preview skipped rule=no-trailer")
            return
        }
        guard preview.beginAttempt(kind: "trailer") else { return }
        var lastReason = "trailer-unresolved"
        for key in keys {
            guard !Task.isCancelled else { return }
            if let reason = await attemptTrailerKey(key, into: preview) {
                // Superseded: exit silently — never abort,
                // the attempt slot may be the next film's.
                if reason == cancelledReason { return }
                lastReason = reason
                continue
            }
            return
        }
        guard !Task.isCancelled else { return }
        preview.abortAttempt(reason: lastReason)
    }

    /// One trailer key's resolve + hand-over. Returns
    /// nil when the playable was handed to the preview
    /// player (the attempt is under way); otherwise the
    /// abort reason for this key — the caller decides
    /// whether another key remains before aborting.
    /// Verbatim mirror of JoeMovieDetail.attemptTrailerKey.
    ///
    /// F-B1 cure: after each uninterruptible await (the
    /// resolver, then the HLS session) and immediately
    /// before every preview.play(...) — all three play
    /// sites — guard !Task.isCancelled and return
    /// cancelledReason on cancellation. On @MainActor
    /// there is no suspension between the final check
    /// and play(), so a superseded film's late play()
    /// can never land in the next film's attempt.
    @MainActor
    private static func attemptTrailerKey(
        _ videoKey: String,
        into preview: JoePreviewController
    ) async -> String? {
        let result = await JoeYtResolver.shared.resolve(videoId: videoKey)
        guard !Task.isCancelled else { return cancelledReason }
        switch result {
        case .playable(let playable, _):
            switch playable.kind {
            case .assembly:
                // QUALITY GATE (17:50 ruling): the
                // resolver already KNOWS this variant's
                // height — a known sub-720 height
                // suppresses HERE, before any hand-over.
                // An unknown height (0) proceeds; the
                // controller's item-level gates still
                // apply.
                if playable.height > 0, playable.height < 720 {
                    return "trailer-low-quality-\(playable.height)p"
                }
                if let session = await JoeYtHlsServer.shared.makeSession(
                    playable: playable,
                    userAgent: JoeYtClientSpec.tvSamsung.userAgent) {
                    guard !Task.isCancelled else { return cancelledReason }
                    DiagLog.write("PREVIEW", "preview resolve kind=trailer-assembly")
                    preview.play(url: session.url, headers: [:],
                                 startFraction: 0)
                    return nil
                }
                if let direct = playable.fallbackDirectURL {
                    // The muxed fallback's OWN known
                    // height gates it the same way.
                    if playable.fallbackHeight > 0, playable.fallbackHeight < 720 {
                        return "trailer-low-quality-muxed-\(playable.fallbackHeight)p"
                    }
                    guard !Task.isCancelled else { return cancelledReason }
                    DiagLog.write("PREVIEW", "preview resolve kind=trailer-muxed-fallback")
                    preview.play(url: direct, headers: [:],
                                 startFraction: 0)
                    return nil
                }
                return "trailer-assembly-failed"
            case .muxed, .hlsManifest:
                // Known-height gate, same as the assembly
                // branch.
                if playable.height > 0, playable.height < 720 {
                    return "trailer-low-quality-\(playable.height)p"
                }
                if let direct = playable.directURL {
                    guard !Task.isCancelled else { return cancelledReason }
                    DiagLog.write("PREVIEW", "preview resolve kind=trailer-direct")
                    preview.play(url: direct, headers: [:],
                                 startFraction: 0)
                    return nil
                }
                return "trailer-no-direct-url"
            }
            // Unreachable — every kind path above returns;
            // present so the compiler sees the case return.
            return "trailer-unresolved"
        case .needsIdentity:
            return "trailer-needs-identity"
        case .membersRequired(let reason):
            return "trailer-members-required \(reason)"
        case .unplayable(let status, let reason):
            return "trailer-unplayable \(status) \(reason)"
        case .httpFailure(let status):
            return "trailer-http-\(status)"
        case .transportFailure(let message):
            return "trailer-transport \(message)"
        case .solverFailed(let step, let message):
            return "trailer-solver \(step) \(message)"
        }
    }

    /// Mine a YouTube video id out of a source trailer
    /// URL: a local copy of JoeMovieDetail's
    /// youtubeVideoId(fromTrailerURL:) (v2.0.49) — the
    /// shapes the provider payloads carry — watch?v=…,
    /// youtu.be/…, /embed/…, /shorts/… The id is the run
    /// of id characters right after the marker; anything
    /// else (a non-YouTube URL, an empty field) yields
    /// nil and the caller treats it as "no source
    /// trailer". The URL itself is never logged — only
    /// the extracted key is used.
    static func youtubeVideoId(fromTrailerURL raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let markers = ["youtu.be/", "watch?v=", "/embed/", "/shorts/"]
        for marker in markers {
            guard let r = s.range(of: marker) else { continue }
            let tail = s[r.upperBound...]
            let id = tail.prefix {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
            }
            if !id.isEmpty { return String(id) }
        }
        return nil
    }
}
