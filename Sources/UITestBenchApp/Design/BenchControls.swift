import SwiftUI

struct BenchPrimaryButtonStyle: ButtonStyle {
    @Environment(\.benchPalette) private var palette
    /// 自定义 ButtonStyle 不会自动变灰，禁用态要自己画。
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        let fill = isEnabled
            ? palette.lime.opacity(configuration.isPressed ? 0.75 : 1)
            : palette.lime.opacity(0.35)
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.onLime.opacity(isEnabled ? 1 : 0.55))
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
    }
}

struct BenchSecondaryButtonStyle: ButtonStyle {
    @Environment(\.benchPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        // 用不透明底色，别指望半透明 surface：最终窗口是透明的，
        // 0.6 的 surface 叠在桌面上，浅色主题压黑背景只有约 2.25:1。
        let fill = isEnabled
            ? palette.surfaceOpaque.opacity(configuration.isPressed ? 0.95 : 0.78)
            : palette.surfaceOpaque.opacity(0.35)
        return configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.textPrimary.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(Capsule().fill(fill))
            .overlay(
                Capsule().strokeBorder(
                    palette.separator.opacity(isEnabled ? 0.7 : 0.3),
                    lineWidth: 0.5
                )
            )
            .contentShape(Capsule())
    }
}

/// 坞顶的三枚圆点，行为对齐 macOS 交通灯。
struct TrafficLights: View {
    @ObservedObject var window: BenchWindowController
    @Environment(\.benchPalette) private var palette
    @State private var isHovering = false

    private enum Action {
        case close
        case hide
        case fit
    }

    var body: some View {
        // 12 + 3×16 + 2×4 = 68pt，正好放进 68pt 胶囊；间距对齐 macOS 的 20pt 圆心。
        HStack(spacing: 4) {
            dot(color: palette.trafficClose, symbol: "xmark", label: "退出", action: .close)
            dot(color: palette.trafficMinimize, symbol: "minus", label: "隐藏窗口", action: .hide)
            dot(
                color: palette.trafficZoom,
                symbol: "arrow.up.left.and.arrow.down.right",
                label: window.isFittedToScreen ? "恢复原来大小" : "适应屏幕",
                action: .fit
            )
        }
        .padding(.leading, 12)
        .onHover { isHovering = $0 }
    }

    private func dot(
        color: Color,
        symbol: String,
        label: String,
        action: Action
    ) -> some View {
        Button {
            // Button 的回调本来就在主线程，直接调即可；包 Task 反而多排队一轮。
            switch action {
            case .close: window.close()
            case .hide: window.minimize()
            case .fit: window.toggleFitToScreen()
            }
        } label: {
            ZStack {
                Circle().fill(color).frame(width: 12, height: 12)
                if isHovering {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(palette.trafficSymbol)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
