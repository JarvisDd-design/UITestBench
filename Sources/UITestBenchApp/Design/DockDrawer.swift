import SwiftUI
import UITestBenchCore

/// 坞胶囊与卡片共用的尺寸。
enum DockMetrics {
    static let railWidth: CGFloat = 68
    static let drawerWidth: CGFloat = 292
    static let cardMaxHeight: CGFloat = 560
}

/// 头部与内容的实测高度，用来让卡片贴合内容、超过上限再滚动。
private struct HeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct DockDrawer: View {
    let module: DockModule
    @ObservedObject var app: AppModel

    @Environment(\.benchPalette) private var palette

    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: HeaderHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )

            Divider().overlay(palette.separator)

            ScrollView {
                content
                    .padding(16)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ContentHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            // 换抽屉时回到顶部，别把上一个抽屉的滚动位置带过来。
            .id(module)
            .frame(height: scrollViewportHeight)
        }
        .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(width: DockMetrics.drawerWidth)
        // 先垫不透明卡面（更靠近内容），再让材质在最底层提供毛玻璃。
        // 反过来的话材质会去采样窗口背后的桌面，深色卡压白底时正文会消失。
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.surfaceOpaque.opacity(0.9))
        )
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(palette.separator.opacity(0.55), lineWidth: 0.5)
        )
        .shadow(color: palette.shadowNear, radius: 22, y: 9)
        .onHover { app.dock.drawerHover($0) }
    }

    /// 卡片总高 = 头部 + 1pt 分隔线 + 滚动区；滚动区最多拿到上限剩下的高度。
    private var scrollViewportHeight: CGFloat {
        let available = DockMetrics.cardMaxHeight - headerHeight - 1
        guard available > 0 else { return 0 }
        return min(max(contentHeight, 0), available)
    }

    private var header: some View {
        HStack {
            Text(module.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Spacer()
            Button { app.dock.dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(palette.textPrimary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("收起\(module.title)")
            .accessibilityLabel("收起\(module.title)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch module {
        case .material:
            APKPanelView(model: app.apk, scanner: app.scanner)
        case .device:
            DeviceDrawer(
                device: app.device,
                profileIndex: $app.profileIndex,
                customWidth: $app.customWidth,
                customHeight: $app.customHeight,
                customDensity: $app.customDensity,
                showsCustomResolution: $app.showsCustomResolution,
                actionError: $app.actionError,
                onToggleDevice: { app.toggleDevice() },
                onSwitchPreset: { app.switchToPreset($0) },
                onApplyCustomResolution: { app.applyCustomResolution() }
            )
        case .app:
            AppDrawer(
                device: app.device,
                run: app.run,
                session: app.session,
                apk: app.apk.acquired
            )
        case .diagnostics:
            DiagnosticsDrawer(paths: app.paths, device: app.device)
        case .settings:
            SettingsDrawer(theme: app.theme, window: app.window)
        }
    }
}
