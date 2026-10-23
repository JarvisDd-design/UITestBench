import SwiftUI
import UITestBenchCore

extension DockModule {
    var title: String {
        switch self {
        case .material: return "素材"
        case .device: return "设备"
        case .app: return "应用"
        case .diagnostics: return "诊断"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .material: return "shippingbox"
        case .device: return "iphone"
        case .app: return "play.square"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }
}

/// 坞胶囊：宽度固定 68，高度贴合内容，悬浮在手机左侧。
struct DockRail: View {
    @ObservedObject var dock: DockModel
    @ObservedObject var theme: ThemeStore
    @ObservedObject var window: BenchWindowController

    @Environment(\.benchPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            TrafficLights(window: window)
                .frame(height: 40)

            VStack(spacing: 6) {
                // 用 Button 而不是 onTapGesture：这样 VoiceOver 能念出按钮，
                // 全键盘访问时也能聚焦、回车展开。
                ForEach(DockModule.allCases, id: \.self) { module in
                    Button {
                        dock.togglePin(module)
                    } label: {
                        DockRailItem(
                            module: module,
                            isPresented: dock.presented == module,
                            isPinned: dock.pinned == module
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(module.title)
                    .accessibilityValue(dock.pinned == module ? "已固定" : "")
                    .onHover { dock.hover(module, inside: $0) }
                }
            }
            .padding(.top, 8)

            Spacer(minLength: 12)

            VStack(spacing: 6) {
                utilityButton(
                    systemImage: theme.mode == .light ? "moon" : "sun.max",
                    label: theme.mode == .light ? "切换到深色" : "切换到浅色",
                    action: .theme
                )
                utilityButton(
                    systemImage: window.isAlwaysOnTop ? "pin.fill" : "pin",
                    label: window.isAlwaysOnTop ? "取消置顶" : "窗口置顶",
                    action: .alwaysOnTop
                )
            }
            .padding(.bottom, 12)
        }
        .frame(width: DockMetrics.railWidth)
        // 内容有多高胶囊就多高；不再拉满整个窗口高度。
        .padding(.vertical, 2)
        // 与卡片、底胶囊同一套垫高：不透明底靠近内容，材质放最底层。
        // 只有材质时，深色主题的浅灰字会跟着亮桌面一起被抬亮。
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(palette.surfaceOpaque.opacity(0.92))
        )
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(palette.separator.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: palette.shadowNear, radius: 18, y: 7)
    }

    private enum UtilityAction {
        case theme
        case alwaysOnTop
    }

    private func utilityButton(
        systemImage: String,
        label: String,
        action: UtilityAction
    ) -> some View {
        Button {
            // 传 @MainActor 方法值会丢隔离并产生警告，这里统一在按钮里分派。
            switch action {
            case .theme: theme.toggle()
            case .alwaysOnTop: window.toggleAlwaysOnTop()
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(palette.textPrimary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct DockRailItem: View {
    let module: DockModule
    let isPresented: Bool
    let isPinned: Bool

    @Environment(\.benchPalette) private var palette
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: module.systemImage)
                .font(.system(size: 20, weight: .regular))
            Text(module.title)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(isPresented ? palette.limeInk : palette.textSecondary)
        .frame(width: 56, height: 52)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(backgroundFill)
        )
        .onHover { isHovering = $0 }
        .help(module.title)
    }

    private var backgroundFill: Color {
        // 钉住比 hover 预告更「实」，用户一眼能看出这个抽屉不会自己收起。
        if isPinned {
            return palette.lime.opacity(0.24)
        }
        if isPresented {
            return palette.lime.opacity(0.16)
        }
        if isHovering {
            return palette.textPrimary.opacity(0.06)
        }
        return .clear
    }
}
