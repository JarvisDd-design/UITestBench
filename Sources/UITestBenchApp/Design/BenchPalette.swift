import SwiftUI
import UITestBenchCore

extension Color {
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
    let surface: Color
    let surfaceOpaque: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let separator: Color
    let lime: Color
    let onLime: Color
    /// 浅色下黄绿不能直接做文字，改用深橄榄；深色下可以直接用黄绿。
    let limeInk: Color
    let error: Color
    let warning: Color
    let phoneBezel: Color
    let phoneRim: Color
    let shadowNear: Color
    let shadowFar: Color

    static let light = BenchPalette(
        isDark: false,
        canvas: Color(hex: 0xF2F2F7),
        surface: Color.white.opacity(0.55),
        surfaceOpaque: Color(hex: 0xFFFFFF),
        textPrimary: Color(hex: 0x1C1C1E),
        textSecondary: Color(hex: 0x6C6C70),
        textTertiary: Color(hex: 0x8E8E93),
        separator: Color(hex: 0xD1D1D6),
        lime: Color(hex: 0xC6F24E),
        onLime: Color(hex: 0x14210A),
        limeInk: Color(hex: 0x3F6212),
        error: Color(hex: 0xD70015),
        warning: Color(hex: 0xC93400),
        phoneBezel: Color(hex: 0x141416),
        phoneRim: Color.white.opacity(0.08),
        shadowNear: Color.black.opacity(0.18),
        shadowFar: Color.black.opacity(0.22)
    )

    static let dark = BenchPalette(
        isDark: true,
        canvas: Color(hex: 0x0B0B0C),
        surface: Color.white.opacity(0.08),
        surfaceOpaque: Color(hex: 0x1C1C1E),
        textPrimary: Color(hex: 0xF2F2F7),
        textSecondary: Color(hex: 0xA1A1A6),
        textTertiary: Color(hex: 0x6C6C70),
        separator: Color(hex: 0x38383A),
        lime: Color(hex: 0xC6F24E),
        onLime: Color(hex: 0x14210A),
        limeInk: Color(hex: 0xC6F24E),
        error: Color(hex: 0xFF453A),
        warning: Color(hex: 0xFF9F0A),
        phoneBezel: Color(hex: 0x2C2C2E),
        phoneRim: Color.white.opacity(0.12),
        shadowNear: Color.black.opacity(0.35),
        shadowFar: Color.black.opacity(0.55)
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
        content
            .environment(\.benchPalette, mode == .dark ? .dark : .light)
            .preferredColorScheme(mode == .dark ? .dark : .light)
            .tint(mode == .dark ? Color(hex: 0xC6F24E) : Color(hex: 0x3F6212))
    }
}

extension View {
    func benchTheme(_ mode: ThemeMode) -> some View {
        modifier(BenchThemeModifier(mode: mode))
    }
}
