import AVFoundation
import AVKit
import SwiftUI

/// Full-screen native tvOS player with the Android app's same-fixture
/// fallback: the sources are every channel carrying the SAME match
/// (tapped one first); when a stream fails, the next source is tried
/// automatically, and only when all of them fail does the view settle
/// on a "no signal" slate. AVPlayerViewController brings the standard
/// remote transport controls (play/pause, scrub, Menu to exit).
struct TVPlayerView: View {
    let sources: [Channel]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var exhausted = false
    @State private var switching = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if exhausted {
                noSignal
            } else if sources.indices.contains(index), sources[index].streamURL != nil {
                PlayerController(channel: sources[index], onFail: advance, onReady: { switching = false })
                    .id(index)
                    .ignoresSafeArea()
                if switching {
                    VStack {
                        Spacer()
                        HStack {
                            Text(index == 0 ? "Đang tải…" : "Đang chuyển nguồn khác…")
                                .font(.callout)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                            Spacer()
                        }
                        .padding(.leading, 48)
                        .padding(.bottom, 36)
                    }
                    .ignoresSafeArea()
                }
            } else {
                // An unparseable URL counts as a failed source.
                Color.clear.onAppear { advance() }
            }
        }
        .onExitCommand { dismiss() }
    }

    private func advance() {
        if index + 1 < sources.count {
            index += 1
            switching = true
        } else {
            exhausted = true
        }
    }

    private var noSignal: some View {
        ZStack {
            Color(red: 0.05, green: 0.07, blue: 0.08).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("MẤT TÍN HIỆU")
                    .font(.system(size: 54, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(.white)
                Text("Tất cả các nguồn của trận này đều không phát được. Bấm Menu để quay lại.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }
}

private struct PlayerController: UIViewControllerRepresentable {
    let channel: Channel
    let onFail: () -> Void
    let onReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFail: onFail, onReady: onReady)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let item = AVPlayerItem(asset: Self.asset(for: channel))
        let player = AVPlayer(playerItem: item)
        controller.player = player
        context.coordinator.observe(item)
        player.play()
        return controller
    }

    /// The asset carries exactly the headers the entry itself
    /// declared (#EXTVLCOPT) — nothing invented, nothing blanket.
    static func asset(for channel: Channel) -> AVURLAsset {
        let url = channel.streamURL ?? URL(fileURLWithPath: "/dev/null")
        var headers: [String: String] = [:]
        if !channel.userAgent.isEmpty { headers["User-Agent"] = channel.userAgent }
        if !channel.referrer.isEmpty { headers["Referer"] = channel.referrer }
        if headers.isEmpty { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.invalidate()
        controller.player?.pause()
        controller.player = nil
    }

    /// Watches the item: ready → tell the view to drop its "loading"
    /// label; failed (status or end-of-playback error) → advance to
    /// the fixture's next source, at most once per item.
    ///
    /// MainActor-isolated (Swift 6): the observation callbacks arrive
    /// from non-isolated contexts — the KVO handler runs on whatever
    /// thread changed the item's status, and the NotificationCenter
    /// block carries no isolation of its own — while everything the
    /// coordinator touches (its tokens, its `fired` flag, the view's
    /// callbacks) is main-actor state. Isolating the class makes the
    /// once-only flag race-free by construction (the old code set it
    /// directly on the KVO thread). The KVO path reads the status
    /// VALUE inside the handler and hops to the main actor carrying
    /// only that Sendable value, never the item; the notification is
    /// delivered on the main queue (queue: .main), so touching the
    /// isolated state synchronously via assumeIsolated is sound
    /// there. Both callbacks still reach the view on the main actor,
    /// exactly as the old DispatchQueue.main hops delivered them.
    @MainActor
    final class Coordinator {
        private var statusToken: NSKeyValueObservation?
        private var failToken: NSObjectProtocol?
        private let onFail: () -> Void
        private let onReady: () -> Void
        private var fired = false

        init(onFail: @escaping () -> Void, onReady: @escaping () -> Void) {
            self.onFail = onFail
            self.onReady = onReady
        }

        func observe(_ item: AVPlayerItem) {
            statusToken = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                // Read the status VALUE here and hop: the KVO handler
                // is a non-isolated context, the coordinator's state
                // is main-actor state (Swift 6).
                let status = item.status
                guard let self else { return }
                Task { @MainActor in
                    self.handleStatus(status)
                }
            }
            failToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                // Delivered on the main queue (queue: .main), so the
                // coordinator's main-actor state may be touched
                // synchronously via assumeIsolated.
                MainActor.assumeIsolated {
                    self?.fireOnce()
                }
            }
        }

        private func handleStatus(_ status: AVPlayerItem.Status) {
            switch status {
            case .readyToPlay:
                onReady()
            case .failed:
                fireOnce()
            default:
                break
            }
        }

        private func fireOnce() {
            guard !fired else { return }
            fired = true
            onFail()
        }

        func invalidate() {
            statusToken?.invalidate()
            statusToken = nil
            if let failToken {
                NotificationCenter.default.removeObserver(failToken)
                self.failToken = nil
            }
        }
    }
}
