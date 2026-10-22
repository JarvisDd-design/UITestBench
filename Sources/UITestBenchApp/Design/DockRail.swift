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
            .padding(.bottom, 14)
        }
        .frame(width: 72)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .background(palette.surface.opacity(0.35))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(palette.separator.opacity(0.45))
                .frame(width: 0.5)
        }
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
        .overlay(alignment: .leading) {
            if isPresented {
                Capsule()
                    .fill(palette.lime)
                    .frame(width: 3, height: 22)
                    .offset(x: -6)
            }
        }
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
