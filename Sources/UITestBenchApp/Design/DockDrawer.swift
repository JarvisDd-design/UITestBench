import SwiftUI
import UITestBenchCore

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                .accessibilityLabel("收起\(module.title)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().overlay(palette.separator)

            ScrollView {
                content
                    .padding(16)
            }
        }
        .frame(width: 292)
        .frame(maxHeight: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.surface.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(palette.separator.opacity(0.55), lineWidth: 0.5)
        )
        .shadow(color: palette.shadowNear, radius: 18, y: 8)
        .onHover { dock.drawerHover($0) }
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
                .frame(width: 72)

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
                    .padding(.leading, 8)
                    .padding(.top, 48)
                    .transition(.opacity.combined(with: .offset(x: -10)))
                }
            }
            .frame(width: 300, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 372)
        .frame(maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: dock.presented)
    }
}
