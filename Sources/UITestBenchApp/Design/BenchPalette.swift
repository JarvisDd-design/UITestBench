import SwiftUI
import UITestBenchCore

fileprivate extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// 语义色。组件里只引用这些名字，不写十六进制。
struct BenchPalette {
    let isDark: Bool
    let canvas: Color
    /// 半透明表面，叠在材质上使用。
    let surface: Color
    /// 不透明表面：抽屉、卡片需要遮挡底下的内容时用。
    let surfaceOpaque: Color
    let textPrimary: Color
    let textSecondary: Color
    /// 弱化文字；只用于 11pt 以上的说明性文字。
    /// 抽屉卡面实测约 4.3–5.0:1，会随窗口背后的壁纸轻微浮动；要硬过 AA 见计划 Task 18 的取舍记录。
    let textTertiary: Color
    let separator: Color
    /// 自绘交通灯；两种主题下保持一致。
    let trafficClose: Color
    let trafficMinimize: Color
    let trafficZoom: Color
    /// 交通灯悬停时圆点上的小图标。
    let trafficSymbol: Color
    let lime: Color
    let onLime: Color
    /// 浅色下黄绿不能直接做文字，改用深橄榄；深色下可以直接用黄绿。
    let limeInk: Color
    let error: Color
    let warning: Color
    let phoneBezel: Color
    let phoneRim: Color
    /// 近层阴影，和 shadowFar 叠加成柔和投影。
    let shadowNear: Color
    /// 远层阴影，负责扩散范围。
    let shadowFar: Color

    static let light = BenchPalette(
        isDark: false,
        canvas: Color(hex: 0xF2F2F7),
        surface: Color.white.opacity(0.55),
        surfaceOpaque: Color(hex: 0xFFFFFF),
        textPrimary: Color(hex: 0x1C1C1E),
        textSecondary: Color(hex: 0x5F5F64),
        textTertiary: Color(hex: 0x6E6E73),
        separator: Color(hex: 0xD1D1D6),
        trafficClose: Color(hex: 0xFF5F57),
        trafficMinimize: Color(hex: 0xFEBC2E),
        trafficZoom: Color(hex: 0x28C840),
        trafficSymbol: Color.black.opacity(0.6),
        lime: Color(hex: 0xC6F24E),
        onLime: Color(hex: 0x14210A),
        limeInk: Color(hex: 0x3F6212),
        error: Color(hex: 0xD70015),
        warning: Color(hex: 0xC93400),
        phoneBezel: Color(hex: 0x141416),
        phoneRim: Color.white.opacity(0.08),
        shadowNear: Color.black.opacity(0.10),
        shadowFar: Color.black.opacity(0.14)
    )

    static let dark = BenchPalette(
        isDark: true,
        canvas: Color(hex: 0x0B0B0C),
        surface: Color.white.opacity(0.08),
        surfaceOpaque: Color(hex: 0x1C1C1E),
        textPrimary: Color(hex: 0xF2F2F7),
        textSecondary: Color(hex: 0xA1A1A6),
        textTertiary: Color(hex: 0x8E8E93),
        separator: Color(hex: 0x38383A),
        trafficClose: Color(hex: 0xFF5F57),
        trafficMinimize: Color(hex: 0xFEBC2E),
        trafficZoom: Color(hex: 0x28C840),
        trafficSymbol: Color.black.opacity(0.6),
        lime: Color(hex: 0xC6F24E),
        onLime: Color(hex: 0x14210A),
        limeInk: Color(hex: 0xC6F24E),
        error: Color(hex: 0xFF453A),
        warning: Color(hex: 0xFF9F0A),
        phoneBezel: Color(hex: 0x2C2C2E),
        phoneRim: Color.white.opacity(0.12),
        shadowNear: Color.black.opacity(0.20),
        shadowFar: Color.black.opacity(0.32)
    )
}

private struct BenchPaletteKey: EnvironmentKey {
    static let defaultValue = BenchPalette.light
}

extension EnvironmentValues {
    var benchPalette: BenchPalette {
        get { self[BenchPaletteKey.self] }
        set { self[BenchPaletteKey.self] = newValue }
    }
}

private struct BenchThemeModifier: ViewModifier {
    let mode: ThemeMode

    func body(content: Content) -> some View {
        let palette: BenchPalette = mode == .dark ? .dark : .light
        return content
            .environment(\.benchPalette, palette)
            .preferredColorScheme(palette.isDark ? .dark : .light)
            .tint(palette.limeInk)
    }
}

extension View {
    func benchTheme(_ mode: ThemeMode) -> some View {
        modifier(BenchThemeModifier(mode: mode))
    }
}
