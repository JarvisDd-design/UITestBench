import SwiftUI
import UITestBenchCore

struct SettingsDrawer: View {
    @ObservedObject var theme: ThemeStore
    @ObservedObject var window: BenchWindowController

    @Environment(\.benchPalette) private var palette
    @State private var showsAbout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("外观")
                Picker(
                    "主题",
                    selection: Binding(
                        get: { theme.mode },
                        set: { theme.set($0) }
                    )
                ) {
                    Text("浅色").tag(ThemeMode.light)
                    Text("深色").tag(ThemeMode.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle(
                "窗口置顶",
                isOn: Binding(
                    get: { window.isAlwaysOnTop },
                    set: { newValue in
                        if newValue != window.isAlwaysOnTop {
                            window.toggleAlwaysOnTop()
                        }
                    }
                )
            )
            .toggleStyle(.switch)
            .font(.caption)

            Divider().overlay(palette.separator)

            Button("关于 UI验收台") { showsAbout = true }
                .buttonStyle(BenchSecondaryButtonStyle(height: 30))

            Text("版本 \(AboutView.appVersion)")
                .font(.caption)
                .foregroundStyle(palette.textTertiary)
        }
        .sheet(isPresented: $showsAbout) {
            AboutView()
                .benchTheme(theme.mode)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.textSecondary)
    }
}
