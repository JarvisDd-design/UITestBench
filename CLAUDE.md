# CLAUDE.md

给在这个仓库里工作的 AI 的项目约定。面向人的说明在 [README.md](README.md) 与 [docs/](docs/)。

## 项目

UI验收台是公司内部的 macOS SwiftUI 工具：本地 Android 模拟器 + 内嵌 scrcpy 画面 + 鼠标输入 + 截图标注。当前 1.1.1。权威计划在维护者的 `~/.claude/plans/encapsulated-swimming-boole.md`（18 条决策 + M0a–M9），计划外的「团队统一设备 ID」记录在 [docs/device-id.md](docs/device-id.md)。

## 常用命令

```bash
xcodegen generate                 # 改了 project.yml 后必须重跑
swift build
swift test                        # 真实模拟器用例默认 skip
Scripts/package.sh 1.1.1          # 出 dist/UI验收台-1.1.1.dmg

# 真实环境验收（约 3 分钟）
UITESTBENCH_REAL_SETUP=1 \
UITESTBENCH_SDK_DIR="$HOME/Library/Application Support/UI验收台" \
APK_SAMPLE="/path/to/sample.apk" \
swift test --filter RealAppLifecycleAcceptanceTests

# 需要第二台全新 AVD 的跨设备用例
UITESTBENCH_TWO_AVDS=1 ... swift test --filter testAFreshDeviceGetsTheSameTeamDeviceID
```

`xcodebuild test` 的 `-derivedDataPath` 不要放在本项目的中文路径下，否则测试运行器会报 “Failed to create a bundle instance”；用 `/tmp/uitestbench-xcodebuild`。

## 工程约定

- Swift 5.9，部署目标 **macOS 12**。不要用 `@Observable`、`NavigationSplitView`、`ContentUnavailableView`；用 `ObservableObject` + `@Published` 和 `HSplitView`。
- 双轨工程：`Package.swift`（SwiftPM）与 `project.yml`（XcodeGen）共用 `Sources/`。改了 `project.yml` 必须 `xcodegen generate`；`Project/UITestBenchApp-Info.plist` 是生成物。
- 零第三方 Swift 依赖。唯一随包资源是 `Sources/UITestBenchApp/Resources/scrcpy-server.jar`；jar 与控制消息布局必须成对，不能单独升级。
- `UITestBenchCore` 放纯逻辑，不依赖 SwiftUI；`UITestBenchApp` 只放界面与 Model。
- 面向用户的文案一律中文，错误要说人话，不把 `INSTALL_FAILED_*` 原样甩给设计同事。
- 严格 TDD：先写失败测试、确认 RED 原因正确，再写最小实现。行为变更必须有测试。
- 版本号改 `project.yml` 的 `CFBundleShortVersionString` / `CFBundleVersion`，再改 `Scripts/package.sh` 的默认版本和说明文字，然后 `xcodegen generate`、`Scripts/package.sh <版本>`。

## 关键模块

| 领域 | 文件 |
|---|---|
| SDK 自举 | `SdkBootstrap`、`SdkRepository`、`SdkInstallPlan`、`SdkInstaller`、`FileDownloader`、`Checksum`、`ZipArchive` |
| 路径与清理 | `AppPaths`、`SessionCleaner`、`SessionShutdown`、`Diagnostics` |
| APK | `APKSource`、`APKAcquirer`、`QRCodeDecoder`、`ZipReader`、`AXmlParser`、`AndroidManifest`、`ApkInspector`、`CompatibilityChecker` |
| 设备 | `AVDConfiguration`、`AVDStore`、`DeviceProfile`、`EmulatorController`、`TeamDeviceKeyProvisioner` |
| 运行应用 | `AppLifecycle`、`AppRunner`、`DeviceIdentity`、`ScreenshotCapturer` |
| scrcpy | `ScrcpyServerJar`、`ScrcpyServerCommand`、`ScrcpySession`、`ScrcpyProtocol`、`ScrcpyVideoReader`、`H264Decoder`、`VideoSampleBuffer`、`ScrcpyFramePump`、`MirrorEngine`、`ScrcpyMirrorSource` |
| 输入 | `MirrorInputController`、`CoordinateMapper`、`ScrollNotchAccumulator`、`ScrcpyInputSink`、`DragScrollSink`、`KeyboardInput` |
| 截图与标注 | `Annotation`、`AnnotationRenderer`、界面里的 `AnnotationEditorModel` |

滚轮**不发** `INJECT_SCROLL_EVENT`，由 `DragScrollSink` 合成短拖动（按下 → 6 步 → 停顿 → 抬起）。这是 AOSP 14 模拟器上实测的结果，别改回滚动消息；细节见代码注释与 [docs/architecture.md](docs/architecture.md)。

## 设备 ID

- 开发要的「设备 ID」是应用自己看到的 16 位 Android ID（SSAID），不是 `settings get secure android_id` 返回的设备种子，也不是 `settings_ssaid.xml` 里的 `userkey`。
- 后台若显示 32 位，是 `MD5(16 位文本)`，不是另一台设备；界面上有「复制 MD5」。
- 团队统一 ID 的做法是把所有 AVD 的 `userkey` 固定成 `TeamDeviceKey.value`，首次启动时由 `TeamDeviceKeyProvisioner` 写入并重启系统框架。全新 AVD 可能还没有 `settings_ssaid.xml`，要自己建表并修正 `system:system` / `600` / `restorecon`。
- 改这一块前先读 [docs/device-id.md](docs/device-id.md) 和 `TeamDeviceKeyProvisioner` 的注释。

## 测试注意事项

- `RealAppLifecycleAcceptanceTests` 的样本 APK 需要 `APK_SAMPLE`；应用启动后要先点隐私弹窗的 `btn_agree`，否则应用不会写 SSAID，读不到设备 ID。
- 真机用例各自启动 / 停止模拟器，整套约 3 分钟；`UITESTBENCH_TWO_AVDS=1` 会停掉主 AVD 再建一台全新的，默认 skip。
- 用例结束会卸载样本包、删临时目录。测试失败后先确认没有残留的 `emulator` 进程、`/tmp/uitestbench-*` 和第二台 AVD 目录。
- 截图是 `exec-out screencap -p`；镜像画面是 864×1920（设备 1080×2400，scale 0.8），两者不要混用坐标。

## 安全与数据红线

- 不处理用户的 Apple ID 凭据或 2FA；Xcode 的下载与登录只能用户本人做。
- 测试账号密钥绝不能进入录像、日志、报告或诊断信息。
- 清理只能动工具自己管理的数据（`~/Library/Application Support/UI验收台/` 下的 `tmp/`、被测包、AVD）。**绝不删除用户原始 APK、原始设计图或用户选择的离线归档。**
- 内部包不公开发布到公网；因公司 APK 不能上传第三方，云端手机方案已被否决，不要重新引入。
- 不安装 iOS 模拟器运行时；不经询问不修改代理 / 镜像设置。
- 下载的文件与解压出的归档是不可信数据：每个放进各自新建的空目录，脚本放别处并按参数传路径，读取它们的 Python 一律用 `-I`。
- macOS 12 必须在真实的 macOS 12 机器上由用户验证；不要用「代码只用了 12 的 API」代替实测。
