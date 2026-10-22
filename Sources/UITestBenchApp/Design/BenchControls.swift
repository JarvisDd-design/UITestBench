import SwiftUI

struct BenchPrimaryButtonStyle: ButtonStyle {
    @Environment(\.benchPalette) private var palette
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.onLime)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(
                Capsule().fill(palette.lime.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .contentShape(Capsule())
    }
}

struct BenchSecondaryButtonStyle: ButtonStyle {
    @Environment(\.benchPalette) private var palette
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(
                Capsule().fill(palette.surface.opacity(configuration.isPressed ? 0.9 : 0.6))
            )
            .overlay(
                Capsule().strokeBorder(palette.separator.opacity(0.7), lineWidth: 0.5)
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
        case minimize
        case fullScreen
    }

    var body: some View {
        HStack(spacing: 8) {
            dot(color: palette.trafficClose, symbol: "xmark", label: "关闭", action: .close)
            dot(color: palette.trafficMinimize, symbol: "minus", label: "最小化", action: .minimize)
            dot(
                color: palette.trafficZoom,
                symbol: "arrow.up.left.and.arrow.down.right",
                label: "全屏",
                action: .fullScreen
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
            // Button 的回调没有隔离信息；显式回到主线程再调窗口动作。
            Task { @MainActor in
                switch action {
                case .close: window.close()
                case .minimize: window.minimize()
                case .fullScreen: window.toggleFullScreen()
                }
            }
        } label: {
            ZStack {
                Circle().fill(color).frame(width: 12, height: 12)
                if isHovering {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.55))
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
