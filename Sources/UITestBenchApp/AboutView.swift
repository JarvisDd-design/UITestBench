import SwiftUI
import UITestBenchCore

/// 「关于」。分发的是未公证的内部包，用户手上没有任何随附文档，
/// 所以许可声明必须能在应用里看到。
struct AboutView: View {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.benchPalette) private var palette
    @State private var showsLicense = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.and.hand.point.up.left")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(palette.limeInk)

            VStack(spacing: 4) {
                Text("UI验收台")
                    .font(.title2.weight(.semibold))
                Text("版本 \(Self.appVersion)")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }

            Text("把 Android 安装包放进本地模拟器里，用鼠标直接看界面、截图、标注。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)

            VStack(spacing: 8) {
                Text("本工具包含 scrcpy 的服务端程序 scrcpy-server.jar，版权归 Genymobile 所有，按 Apache License 2.0 发布。")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)

                Button("查看完整许可证") { showsLicense = true }
                    .buttonStyle(.link)
            }

            Button("关闭") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 440)
        .background(palette.canvas)
        .sheet(isPresented: $showsLicense) {
            LicenseView()
        }
    }
}

private struct LicenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.benchPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(licenseText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 480)
        .background(palette.canvas)
    }

    private var licenseText: String {
        guard let url = AppResources.scrcpyLicenseURL,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "许可证文本未能找到，请向维护者索取 scrcpy 的 Apache License 2.0 全文。"
        }
        return text
    }
}
