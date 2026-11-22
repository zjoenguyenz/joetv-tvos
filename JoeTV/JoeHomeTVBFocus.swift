import SwiftUI

/// HomeTVBFocus hero (RECALC-SPEC §3.2 / R7): the TVB form of
/// the Private Cinema home hero, extracted VERBATIM from
/// JoePhimHome's cinemaHeroText TVB branch (episode row,
/// episode-first actions, mark button, TVB eyebrow) into its
/// own standalone view — HomeTVBFocus is its own screen form
/// in the design set, not a mode of the movie hero. The hero
/// title in this form is Bricolage 78/500, tracking -4
/// (RECALC-SPEC §2.3 / R2, completion spec §"TVB Home").
/// Handlers and values are the moved code's own: actions open
/// the resolved target through the core's
/// cinemaOpenHeroTarget (passed in as `openTarget`), the
/// episode row reads the same YouTube catalogue store, and
/// the mark button uses the same WatchStore / FollowStore
/// mechanisms, via the same stores the core used.
struct JoeHomeTVBFocusHero: View {
    let resolved: JoePhimHomeCore.CinemaHeroResolved
    /// The per-title TVB eyebrow line (RECALC-SPEC §3.2:
    /// "TVB · <the title's own genre line>"), computed by
    /// the core — which owns the catalogue map — from the
    /// target's own category data (GATE-213 R2 Lens 3 F3);
    /// the core passes the §3.5 static line only when a
    /// target carries no category at all.
    let eyebrowLine: String
    var heroPlayFocused: FocusState<Bool>.Binding
    var heroInfoFocused: FocusState<Bool>.Binding
    let openTarget: (JoePhimHomeCore.CinemaHeroTarget) -> Void
    @EnvironmentObject private var watch: WatchStore
    @ObservedObject private var followStore = FollowStore.shared
    @ObservedObject private var ytStore = JoeYtStore.shared
    @Environment(\.joeTheme) private var theme

    var body: some View {
        let item = resolved.item
        return VStack(alignment: .leading, spacing: 0) {
            Text(eyebrowLine)
                .font(JoePCType.outfit(15, weight: .medium))
                .tracking(3.6)
                .foregroundStyle(theme.heroMeta)
                .lineLimit(1)
            Text(item.title)
                .font(JoePCType.display(78))
                .tracking(-4)
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .padding(.top, 12)
            cinemaHeroMetaRow(resolved)
            if case .tvbEntry(let entry) = resolved.target {
                cinemaHeroEpisodeRow(entry)
            }
            cinemaHeroActions(resolved)
            .padding(.top, 16)
        }
        .padding(.leading, 94)
        .padding(.vertical, 36)
        .frame(maxWidth: 900, alignment: .leading)
    }

    /// The hero's action set (HomeTVBFocus form): the
    /// drawing's EPISODE-FIRST set, moved verbatim from
    /// the TVB branch of the core's cinemaHeroActions.
    @ViewBuilder
    private func cinemaHeroActions(_ resolved: JoePhimHomeCore.CinemaHeroResolved) -> some View {
        HStack(spacing: 16) {
            Button {
                openTarget(resolved.target)
            } label: {
                JoePrimaryLabel(title: "Chọn tập", systemImage: "play.fill")
            }
            .joeCardButton()
            .focused(heroPlayFocused)
            Button {
                openTarget(resolved.target)
            } label: {
                JoeSecondaryLabel(title: "Tựa đang trỏ",
                                  systemImage: "info.circle")
            }
            .joeCardButton()
            .focused(heroInfoFocused)
            cinemaHeroMarkButton(resolved.target)
        }
    }

    /// The HomeTVBFocus episode row (FIX-213, Fault
    /// 13; completion spec §"TVB Home": row margin-top
    /// 15, gap 16, text 17/400, meter 126×4 r2): "Tập
    /// N / M" from the entry's own episode number and
    /// the series' real episode count in the YouTube
    /// catalogue; the meter and "mm:ss / mm:ss · pct%"
    /// from the entry's stored position / duration;
    /// the drawing's note line under it. Any part the
    /// data cannot know is omitted, never invented
    /// (the filmography precedent): no duration → no
    /// meter or time; no catalogue match → no total.
    @ViewBuilder
    private func cinemaHeroEpisodeRow(_ entry: WatchStore.Entry) -> some View {
        let epNum = WatchStore.episodeNumber(of: entry)
        let total = ytStore.snapshot?.byPid[entry.slug]?.eps.count ?? 0
        if epNum > 0 || !entry.epLabel.isEmpty || entry.dur > 0 {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    if epNum > 0 {
                        Text(total > 0 ? "Tập \(epNum) / \(total)" : "Tập \(epNum)")
                    } else if !entry.epLabel.isEmpty {
                        Text(entry.epLabel)
                    }
                    if entry.dur > 0 {
                        let frac = min(1, max(0, Double(entry.pos) / Double(entry.dur)))
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(theme.text.opacity(0.25))
                                .frame(width: 126, height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(theme.accent2)
                                .frame(width: 126 * frac, height: 4)
                        }
                        Text("\(heroClockText(entry.pos)) / \(heroClockText(entry.dur)) · \(heroPercentText(frac))")
                    }
                }
                .font(JoePCType.outfit(17))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                Text("Chọn tập trước khi chọn nguồn")
                    .font(JoePCType.outfit(15))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
                    .padding(.top, 10)
            }
            .padding(.top, 15)
        }
    }

    /// "20:22" — minutes:seconds for the episode row.
    private func heroClockText(_ seconds: Int64) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "46,3%" — the drawing's percent, VN decimal
    /// comma, one decimal.
    private func heroPercentText(_ frac: Double) -> String {
        String(format: "%.1f", frac * 100)
            .replacingOccurrences(of: ".", with: ",") + "%"
    }

    /// "Đánh dấu tựa" (HomeTVBFocus): the mark toggle
    /// for a TVB hero target, bound to the mechanism
    /// the title actually has — a continue-watching
    /// entry is favourited in the WatchStore (the
    /// player's own favourite mechanism); a catalogue
    /// title is followed via its chain route (the
    /// FollowStore identity the chain detail's follow
    /// button uses, its real episode count as the
    /// baseline). A title with neither renders no
    /// third action — never a dead button.
    @ViewBuilder
    private func cinemaHeroMarkButton(_ target: JoePhimHomeCore.CinemaHeroTarget) -> some View {
        switch target {
        case .tvbEntry(let entry):
            Button {
                _ = watch.toggleFavorite(entry)
            } label: {
                JoeSecondaryLabel(
                    title: watch.isFavorite(key: entry.key) ? "Đã đánh dấu" : "Đánh dấu tựa",
                    systemImage: "checkmark")
            }
            .joeCardButton()
        case .tvb(let title):
            if let route = title.routeTarget {
                Button {
                    _ = followStore.toggle(
                        provider: route.provider, slug: route.slug,
                        title: title.titleVi, poster: title.posterURLString,
                        currentEpisodes: title.episodeTotalTmdb)
                } label: {
                    JoeSecondaryLabel(
                        title: followStore.isFollowing(provider: route.provider,
                                                       slug: route.slug)
                            ? "Đã đánh dấu" : "Đánh dấu tựa",
                        systemImage: "checkmark")
                }
                .joeCardButton()
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func cinemaHeroMetaRow(_ resolved: JoePhimHomeCore.CinemaHeroResolved) -> some View {
        // v2.1.1 (WS-I): the meta line is the resolved
        // item's own (year · ★ · runtime for a chain
        // title via cinemaHeroMetaLine, the strip's meta
        // for the other surfaces); the quality chip rides
        // only a chain title that carries a quality value.
        let quality: String = {
            switch resolved.target {
            case .movie(let movie, _), .fileTrending(let movie):
                return movie.quality
            default:
                return ""
            }
        }()
        if !resolved.item.meta.isEmpty || !quality.isEmpty {
            HStack(alignment: .center, spacing: 14) {
                if !resolved.item.meta.isEmpty {
                    Text(resolved.item.meta)
                        // FIX-4 / C6: design meta 20/400.
                        .font(JoePCType.outfit(20))
                        .foregroundStyle(theme.heroMeta)
                        .lineLimit(1)
                }
                if !quality.isEmpty {
                    Text(quality)
                        // FIX-4 / C6: design badges 14/400.
                        .font(JoePCType.outfit(14))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(theme.stroke, lineWidth: 1))
                }
            }
            .padding(.top, 12)
        }
    }

}
