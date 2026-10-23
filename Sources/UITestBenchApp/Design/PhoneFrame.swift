import SwiftUI
import UITestBenchCore

/// 只负责手机外壳与屏幕裁剪；屏幕里放什么由调用方决定。
struct PhoneFrame<Content: View>: View {
    let layout: PhoneLayout
    @ViewBuilder let content: () -> Content

    @Environment(\.benchPalette) private var palette

    var body: some View {
        let outerRadius = layout.cornerRadius + layout.bezel

        content()
            .frame(width: layout.screenSize.width, height: layout.screenSize.height)
            .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous))
            .padding(layout.bezel)
            .background(
                RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                    .fill(palette.phoneBezel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                    .strokeBorder(palette.phoneRim, lineWidth: 1)
            )
            // 外层大阴影由窗口自身的 hasShadow 负责，这里只留贴边的近影。
            .shadow(color: palette.shadowNear, radius: 6, x: 0, y: 2)
    }
}
