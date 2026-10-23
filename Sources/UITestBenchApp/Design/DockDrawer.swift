import SwiftUI
import UITestBenchCore

/// 坞的尺寸关系：轨道 72 + 抽屉槽 300（左边距 8 + 抽屉 292）= 坞列 372。
enum DockMetrics {
    static let railWidth: CGFloat = 72
    static let drawerInset: CGFloat = 8
    static let drawerWidth: CGFloat = 292
    static let drawerSlotWidth: CGFloat = 300   // drawerInset + drawerWidth
    static let columnWidth: CGFloat = 372       // railWidth + drawerSlotWidth
    static let drawerTopInset: CGFloat = 48
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
    @ObservedObject var dock: DockModel

    let paths: AppPaths
    @ObservedObject var device: EmulatorController
    @ObservedObject var apk: APKPanelModel
    @ObservedObject var scanner: ScreenScannerModel
    @ObservedObject var run: RunModel
    @ObservedObject var session: SessionModel
    @ObservedObject var theme: ThemeStore
    @ObservedObject var window: BenchWindowController

    @Binding var profileIndex: Int
    @Binding var customWidth: String
    @Binding var customHeight: String
    @Binding var customDensity: String
    @Binding var showsCustomResolution: Bool
    @Binding var actionError: String?

    let onToggleDevice: () -> Void
    let onSwitchPreset: (Int) -> Void
    let onApplyCustomResolution: () -> Void

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
        .shadow(color: palette.shadowNear, radius: 18, y: 8)
        .onHover { dock.drawerHover($0) }
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
            Button { dock.dismiss() } label: {
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
            APKPanelView(model: apk, scanner: scanner)
        case .device:
            DeviceDrawer(
                device: device,
                profileIndex: $profileIndex,
                customWidth: $customWidth,
                customHeight: $customHeight,
                customDensity: $customDensity,
                showsCustomResolution: $showsCustomResolution,
                actionError: $actionError,
                onToggleDevice: onToggleDevice,
                onSwitchPreset: onSwitchPreset,
                onApplyCustomResolution: onApplyCustomResolution
            )
        case .app:
            AppDrawer(device: device, run: run, session: session, apk: apk.acquired)
        case .diagnostics:
            DiagnosticsDrawer(paths: paths, device: device)
        case .settings:
            SettingsDrawer(theme: theme, window: window)
        }
    }
}

struct DockColumn: View {
    let paths: AppPaths
    @ObservedObject var device: EmulatorController
    @ObservedObject var apk: APKPanelModel
    @ObservedObject var scanner: ScreenScannerModel
    @ObservedObject var run: RunModel
    @ObservedObject var session: SessionModel
    @ObservedObject var theme: ThemeStore
    @ObservedObject var window: BenchWindowController
    @ObservedObject var dock: DockModel

    @Binding var profileIndex: Int
    @Binding var customWidth: String
    @Binding var customHeight: String
    @Binding var customDensity: String
    @Binding var showsCustomResolution: Bool
    @Binding var actionError: String?

    let onToggleDevice: () -> Void
    let onSwitchPreset: (Int) -> Void
    let onApplyCustomResolution: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            DockRail(dock: dock, theme: theme, window: window)
                .frame(width: DockMetrics.railWidth)

            ZStack(alignment: .topLeading) {
                if let module = dock.presented {
                    DockDrawer(
                        module: module,
                        dock: dock,
                        paths: paths,
                        device: device,
                        apk: apk,
                        scanner: scanner,
                        run: run,
                        session: session,
                        theme: theme,
                        window: window,
                        profileIndex: $profileIndex,
                        customWidth: $customWidth,
                        customHeight: $customHeight,
                        customDensity: $customDensity,
                        showsCustomResolution: $showsCustomResolution,
                        actionError: $actionError,
                        onToggleDevice: onToggleDevice,
                        onSwitchPreset: onSwitchPreset,
                        onApplyCustomResolution: onApplyCustomResolution
                    )
                    .padding(.leading, DockMetrics.drawerInset)
                    .padding(.top, DockMetrics.drawerTopInset)
                    .transition(.opacity.combined(with: .offset(x: -10)))
                }
            }
            .frame(width: DockMetrics.drawerSlotWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: DockMetrics.columnWidth)
        .frame(maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: dock.presented)
    }
}
