# CLAUDE.md

给在这个仓库里工作的 AI 的项目约定。面向人的说明在 [README.md](README.md) 与 [docs/](docs/)。

## 项目

UI验收台是公司内部的 macOS SwiftUI 工具：本地 Android 模拟器 + 内嵌 scrcpy 画面 + 鼠标输入 + 截图标注 + 屏幕取景框扫码。当前 1.4.2。基础计划在维护者的 `~/.claude/plans/encapsulated-swimming-boole.md`（18 条决策 + M0a–M9）；主窗口改版（手机 + 三个吸附悬浮面板）的计划与实测在 [docs/superpowers/plans/2026-10-22-ui-1-3-0-redesign.md](docs/superpowers/plans/2026-10-22-ui-1-3-0-redesign.md)。计划外的「团队统一设备 ID」记录在 [docs/device-id.md](docs/device-id.md)。

## 常用命令

```bash
xcodegen generate                 # 改了 project.yml 后必须重跑
swift build
swift test                        # 真实模拟器用例默认 skip
Scripts/package.sh 1.4.2          # 出 dist/UI验收台-1.4.2.dmg

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

- Swift 5.9，部署目标 **macOS 12.3**。`Package.swift` 只能写 `.v12`（SwiftPM 没有 12.3），所以 ScreenCaptureKit 代码一律用 `@available(macOS 12.3, *)` 包住；发布下限以 `project.yml` 为准。不要用 `@Observable`、`NavigationSplitView`、`ContentUnavailableView`；用 `ObservableObject` + `@Published`。1.4.0 起界面上没有传统的应用窗口：手机是无边框 `PhoneWindow`，坞胶囊、底胶囊、抽屉卡片是 `BenchPanel` 子窗口，由 `FloatingPanelsController` 吸附定位。改布局前先读 [docs/architecture.md](docs/architecture.md)。
- 面板窗口的 `shadowPadding` 是 40pt，给 SwiftUI 卡片的阴影留空间；改小会在窗口边缘切出直边。坞/胶囊的拖动用 `BenchWindowController` 的 60Hz 定时器按鼠标屏幕坐标移动，不要换回按手势增量逐帧移动（会卡顿）。`PanelWakeObserver` 在应用激活或窗口成为 key 时整组 `orderFront`；删掉它会出现「只点哪块面板，哪块才浮上来」。
- AVD 的 `hw.mainKeys` 保持 `yes`，系统才不会在屏幕底部画三键导航条；`AVDStore.hideNavigationBar` 负责原地迁移旧设备，只有真的改了文件才用 `-no-snapshot-load` 冷启动一次，之后恢复快照启动。显示分辨率不变，手机外框比例仍由 `DeviceProfile` 决定；应用启动时 `EmulatorController.adoptExistingProfile` 负责把磁盘上的实际分辨率同步回界面（机型选择本身不落盘）。
- 双轨工程：`Package.swift`（SwiftPM）与 `project.yml`（XcodeGen）共用 `Sources/`。改了 `project.yml` 必须 `xcodegen generate`；`Project/UITestBenchApp-Info.plist` 是生成物。
- 零第三方 Swift 依赖。唯一随包资源是 `Sources/UITestBenchApp/Resources/scrcpy-server.jar`；jar 与控制消息布局必须成对，不能单独升级。
- `UITestBenchCore` 放纯逻辑，不依赖 SwiftUI；`UITestBenchApp` 只放界面与 Model。
- 面向用户的文案一律中文，错误要说人话，不把 `INSTALL_FAILED_*` 原样甩给设计同事。
- 严格 TDD：先写失败测试、确认 RED 原因正确，再写最小实现。行为变更必须有测试。
- 版本号改 `project.yml` 的 `CFBundleShortVersionString` / `CFBundleVersion`，再改 `Scripts/package.sh` 的默认版本和说明文字，然后 `xcodegen generate`、`Scripts/package.sh <版本>`。

## 关键模块

| 领域 | 文件 |
|---|---|
| 主窗口与吸附面板 | `AppModel`、`PhoneWindowView`、`PhoneFrame`、`BenchWindowController`（`PhoneWindow`）、`BenchPanel`、`FloatingPanelsController`、`WindowDragArea`、`DockPanelView`、`CapsulePanelView`、`DrawerPanelView`、`BenchPalette`、`ThemeStore` |
| 坞与抽屉 | `DockModel`、`DockRail`、`DockDrawer`、`ActionCapsule`、`FloatingPanelLayoutCalculator`、`PhoneLayoutCalculator`、`DockDrawerState`、`DockEscapePolicy` |
| SDK 自举 | `SdkBootstrap`、`SdkRepository`、`SdkInstallPlan`、`SdkInstaller`、`FileDownloader`、`Checksum`、`ZipArchive` |
| 路径与清理 | `AppPaths`、`SessionCleaner`、`SessionShutdown`、`Diagnostics` |
| APK | `APKSource`、`APKAcquirer`、`DownloadedContent`、`APKPageLink`、`APKPageDetail`、`ZipReader`、`AXmlParser`、`AndroidManifest`、`ApkInspector`、`CompatibilityChecker` |
| 二维码与扫码 | `DownloadLink`、`OrientedImage`、`BarcodeDetector`、`VisionBarcodeDetector`、`ScanCandidateSelector`、`ScanHitGate`、`ScanSession`、`QRCodeDecoder`、`CaptureRegionCalculator`；App 层 `Scanner/`（`ScreenRegionCapture`、`ScannerPanel`、`ScreenScannerModel`、`ScreenCapturePermission`） |
| 设备 | `AVDConfiguration`、`AVDStore`、`DeviceProfile`、`EmulatorController`、`TeamDeviceKeyProvisioner` |
| 运行应用 | `AppLifecycle`、`AppRunner`、`DeviceIdentity`、`ScreenshotCapturer` |
| scrcpy | `ScrcpyServerJar`、`ScrcpyServerCommand`、`ScrcpySession`、`ScrcpyProtocol`、`ScrcpyVideoReader`、`H264Decoder`、`VideoSampleBuffer`、`ScrcpyFramePump`、`MirrorEngine`、`ScrcpyMirrorSource` |
| 输入 | `MirrorInputController`、`CoordinateMapper`、`ScrollNotchAccumulator`、`ScrcpyInputSink`、`DragScrollSink`、`KeyboardInput` |
| 截图与标注 | `Annotation`、`AnnotationRenderer`、界面里的 `AnnotationEditorModel` |

滚轮**不发** `INJECT_SCROLL_EVENT`，由 `DragScrollSink` 合成短拖动（按下 → 6 步 → 停顿 → 抬起）。这是 AOSP 14 模拟器上实测的结果，别改回滚动消息；细节见代码注释与 [docs/architecture.md](docs/architecture.md)。

坞、抽屉、底胶囊都是 `BenchPanel` 子窗口，`becomesKeyOnlyIfNeeded`；hover 打开的抽屉不是 key，所以 Esc 不能挂在视图的 `onExitCommand` 上，统一走 `DockModel.startEventMonitors` 的键盘监视器 + `DockEscapePolicy`（输入框里第一次 Esc 只结束编辑）。无边框手机窗口的 `miniaturize` 无效，隐藏/恢复一律走 `BenchWindowController.minimize()` / `showPhone()`，扫码收起主窗口也用它。

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
- 屏幕捕获只用于在内存里识别取景框内的二维码：不写盘、不进日志 / 诊断 / 报告，也不上传。公司聊天截图只留在本机，不进仓库、DMG 或测试样例。
- macOS 12.3 必须在真实的 macOS 12.3（或更高）机器上由用户验证；不要用「代码只用了 12.3 的 API」代替实测。
