import SwiftUI

/// Trang chủ — its own screen (owner ruling 2026-11-22
/// 11:41 CST: "Trang home của app ko phải của tvb" /
/// "Không phải trang home của bất kỳ tab nào";
/// RECALC-SPEC §3.1). Trang chủ is a screen designed for
/// itself (the Home drawing, 11 rails), not the Phim
/// screen relabelled and not any other tab's home: this
/// type fixes the screen identity at construction
/// (JoeCinemaScreen.trangChu) and the shared core below
/// it never reads the live navigation section to decide
/// its composition (RECALC-SPEC §4 R7).
enum JoeCinemaScreen {
    case trangChu
    case phim
}

/// The Trang chủ screen: the shared Private Cinema home
/// core with its identity fixed to Trang chủ.
struct JoeHomeScreen: View {
    var body: some View {
        JoePhimHomeCore(screen: .trangChu)
    }
}
