import SwiftUI

// MARK: - YT PROBE shell
//
// A bare-bones research shell (PROBE-SPEC 2026-11-24):
// the YouTube sign-in state (JoeYtIdentity's device-code
// flow, surfaced exactly as JoeTV surfaces it), one
// "Run matrix" button, a scrolling log view, and the
// DiagLog LAN+QR export block copied from JoeTV's
// Settings pattern (the app-lifetime DiagLogServer is
// started at launch; this screen only displays its
// state). Nothing else lives in this app — no catalogue,
// no player, no JoeTV target sources.

@main
struct YTProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeRootView()
                .task {
                    DiagLog.logLaunchPresence()
                    DiagLogServer.shared.start()
                }
        }
    }
}

struct ProbeRootView: View {
    @ObservedObject private var identity = JoeYtIdentity.shared
    @StateObject private var runner = ProbeRunViewModel()
    /// The app-lifetime export server's state, displayed
    /// exactly as JoeTV's LogExportView displays it.
    @State private var serverState: DiagLogServer.State = .starting
    private var server: DiagLogServer { DiagLogServer.shared }

    var body: some View {
        HStack(alignment: .top, spacing: 56) {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("YT Probe")
                        .font(.system(size: 54, weight: .bold))
                    Text("YT-403 variant matrix — v1 (variants 1, 2, 3, 3b, 5)")
                        .font(.system(size: 25))
                        .foregroundStyle(.secondary)
                }
                signInBlock
                Button {
                    runner.startMatrix()
                } label: {
                    Text(runner.running ? "Đang chạy matrix…" : "Run matrix")
                        .font(.system(size: 30, weight: .semibold))
                }
                .disabled(runner.running)
                exportBlock
            }
            .frame(width: 780, alignment: .leading)

            logView
        }
        .padding(48)
        .onAppear {
            server.onStateChange = { state in
                serverState = state
            }
            // A state re-report when already serving
            // (the normal case — started at launch),
            // never a second bind (FL-378 pattern).
            server.start()
        }
        .onDisappear {
            server.onStateChange = nil
        }
    }

    // MARK: Sign-in (JoeYtIdentity's device-code surface)

    @ViewBuilder
    private var signInBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            if identity.hasToken {
                Text("Đã đăng nhập YouTube ✓")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.green)
                Button("Đăng xuất") {
                    JoeYtOAuthStore.clearTokens()
                    identity.noteTokensCleared()
                }
            } else if let code = identity.userCode {
                Text("Trên iPhone, mở \(identity.verificationURL) rồi nhập mã:")
                    .font(.system(size: 26))
                Text(code)
                    .font(.system(size: 64, weight: .bold))
                Text("Đang chờ duyệt…")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Button("Huỷ đăng nhập") {
                    identity.cancelDeviceCodeFlow()
                }
            } else {
                Button("Đăng nhập YouTube") {
                    identity.beginDeviceCodeFlow()
                }
                .font(.system(size: 28, weight: .semibold))
                if let error = identity.flowError {
                    Text(error)
                        .font(.system(size: 23))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Log export (JoeTV's pattern: URL + PIN + QR)

    @ViewBuilder
    private var exportBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gửi log chẩn đoán")
                .font(.system(size: 30, weight: .bold))
            switch serverState {
            case .starting:
                Text("Đang mở kênh gửi log…")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            case .serving(let url):
                Text(url)
                    .font(.system(size: 27, weight: .semibold))
                    .lineLimit(1)
                if !server.pin.isEmpty {
                    Text("Mã PIN một lần: \(server.pin)")
                        .font(.system(size: 24))
                }
                if let qr = Self.qrImage(for: url) {
                    // White card = the QR's quiet zone,
                    // a functional element (JoeTV's note).
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 240, height: 240)
                        .padding(18)
                        .background(RoundedRectangle(cornerRadius: 20)
                            .fill(Color.white))
                }
                Text("Trên iPhone, mở Safari tới địa chỉ trên (đã gồm PIN) hoặc quét QR — file log tải về, gửi vào chat.")
                    .font(.system(size: 21))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 720, alignment: .leading)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 23))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 720, alignment: .leading)
            }
        }
    }

    // MARK: Scrolling log

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if runner.lines.isEmpty {
                        Text("Chưa có dòng log nào — bấm Run matrix.")
                            .font(.system(size: 21))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(runner.lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 20, design: .monospaced))
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: runner.lines.count) { _, count in
                if count > 0 {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }

    /// QR code for the serving URL — JoeTV's exact
    /// construction (CIQRCodeGenerator, ×12 transform,
    /// CIContext render; the Image draws it with
    /// interpolation off so the modules stay hard-edged).
    private static func qrImage(for string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled,
                                                  from: scaled.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
