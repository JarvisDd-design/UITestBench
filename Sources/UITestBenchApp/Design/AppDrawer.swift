import AppKit
import SwiftUI
import UITestBenchCore

struct AppDrawer: View {
    @ObservedObject var device: EmulatorController
    @ObservedObject var run: RunModel
    @ObservedObject var session: SessionModel
    let apk: AcquiredAPK?

    @Environment(\.benchPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("运行状态")
            runStatus

            if let identity = run.identity {
                Divider().overlay(palette.separator)
                identitySection(identity)
            } else if let apk {
                Divider().overlay(palette.separator)
                HStack(spacing: 6) {
                    Text("设备 ID").font(.caption).foregroundStyle(palette.textSecondary)
                    Text("应用还没读取").font(.caption).foregroundStyle(palette.textSecondary)
                    Button("刷新") { run.refreshIdentity(packageName: apk.info.packageName) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if let notice = session.recoveryNotice {
                Label(notice, systemImage: "arrow.counterclockwise.circle")
                    .font(.caption)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("运行和重开在手机下方的胶囊里操作。")
                .font(.caption2)
                .foregroundStyle(palette.textTertiary)
        }
    }

    @ViewBuilder
    private var runStatus: some View {
        if run.isBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(run.statusText ?? "正在运行…")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
        } else if run.isRunning {
            Label("应用已启动", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(palette.limeInk)
        } else if let failure = run.failureText {
            Text(failure)
                .font(.caption)
                .foregroundStyle(palette.error)
                .fixedSize(horizontal: false, vertical: true)
        } else if apk != nil {
            Text(device.isRunning ? "还没运行，点手机下方的「运行应用」。" : "先启动设备。")
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
        } else {
            Text("先从「素材」获取一个 APK。")
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    /// 开发加白名单要的是应用自己看到的 Android ID，不是设备种子。
    private func identitySection(_ identity: DeviceIdentity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let androidID = identity.androidID {
                HStack(spacing: 6) {
                    Text("设备 ID")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                    Text(androidID)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("复制") { copyToPasteboard(androidID) }
                        .buttonStyle(.link)
                        .font(.caption)
                }

                HStack(spacing: 6) {
                    Text("MD5")
                        .font(.caption2)
                        .foregroundStyle(palette.textSecondary)
                    Text(DeviceFingerprint.md5(of: androidID))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("复制 MD5") {
                        copyToPasteboard(DeviceFingerprint.md5(of: androidID))
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                    .help("反馈后台显示 32 位设备 ID 时，发这个")
                }
            } else {
                Text("设备 ID 还没读到")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }

            if device.teamKeyActive {
                Label(
                    "团队设备 ID 已启用：全团队、所有同一套证书的包共用这个 ID。",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.caption2)
                .foregroundStyle(palette.limeInk)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(identityExplanation)
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(identity.model) · 序列号 \(identity.serial)")
                .font(.caption2)
                .foregroundStyle(palette.textTertiary)
                .textSelection(.enabled)
        }
    }

    private var identityExplanation: String {
        if device.teamKeyActive {
            return "发给开发加测试白名单，配一次即可。全团队、所有同一套签名证书的包共用这一个 ID；"
                + "反复运行、清数据、重装、换电脑都不会变。"
        }
        return "发给开发加测试白名单，配一次即可。同一个包反复运行、清数据、重装都不会变；"
            + "同一套签名证书签的包共用这个 ID。"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.textSecondary)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
