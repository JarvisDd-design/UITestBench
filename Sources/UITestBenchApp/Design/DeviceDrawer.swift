import SwiftUI
import UITestBenchCore

struct DeviceDrawer: View {
    @ObservedObject var device: EmulatorController
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
    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("机型")

                Picker("机型", selection: $profileIndex) {
                    ForEach(Array(DeviceProfile.presets.enumerated()), id: \.offset) { index, profile in
                        Text(profile.name).tag(index)
                    }
                    Text("自定义").tag(-1)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: profileIndex) { newValue in
                    if newValue < 0 {
                        // 选中「自定义」时直接把输入框露出来，少一次点击。
                        showsCustomResolution = true
                    } else {
                        onSwitchPreset(newValue)
                    }
                }

                Text(profileSummary)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }

            DisclosureGroup("自定义分辨率", isExpanded: $showsCustomResolution) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        TextField("宽", text: $customWidth)
                        TextField("高", text: $customHeight)
                        TextField("DPI", text: $customDensity)
                    }
                    .textFieldStyle(.roundedBorder)

                    Button("应用") { onApplyCustomResolution() }
                        .buttonStyle(BenchSecondaryButtonStyle(height: 28))
                        .disabled(customProfile == nil)
                }
                .padding(.top, 6)
            }
            .font(.caption)

            Button(action: onToggleDevice) {
                Text(deviceButtonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BenchPrimaryButtonStyle(height: 38))
            .disabled(isBusy)

            if let message = statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let warning = device.provisioningWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if device.teamKeyActive {
                Label("团队设备 ID 已启用", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(palette.limeInk)
            }

            Divider().overlay(palette.separator)

            DisclosureGroup("高级", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前序列号：\(device.isRunning ? device.serial : "设备未启动")")
                    Text("机型比例会直接决定手机框的宽高。")
                }
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
                .padding(.top, 6)
            }
            .font(.caption)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.textSecondary)
    }

    private var profileSummary: String {
        if profileIndex >= 0, DeviceProfile.presets.indices.contains(profileIndex) {
            let profile = DeviceProfile.presets[profileIndex]
            return "\(profile.width) × \(profile.height) · \(profile.density) dpi"
        }
        if let custom = customProfile {
            return "\(custom.width) × \(custom.height) · \(custom.density) dpi"
        }
        return "宽高和 DPI 都要填正整数"
    }

    private var customProfile: DeviceProfile? {
        guard let width = Int(customWidth),
              let height = Int(customHeight),
              let density = Int(customDensity),
              width > 0, height > 0, density > 0
        else { return nil }
        return DeviceProfile(name: "自定义", width: width, height: height, density: density)
    }

    private var deviceButtonTitle: String {
        switch device.state {
        case .stopped: return "启动设备"
        case .starting: return "正在启动…"
        case .stopping: return "正在停止…"
        case .running: return "停止设备"
        case .failed: return "重试启动"
        }
    }

    private var isBusy: Bool {
        switch device.state {
        case .starting, .stopping: return true
        case .stopped, .running, .failed: return false
        }
    }

    private var statusMessage: String? {
        if let actionError { return actionError }
        if case let .failed(message) = device.state { return message }
        return nil
    }
}
