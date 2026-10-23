# 架构

面向第一次接手这个仓库的开发者。目标是在 5 分钟内知道：代码分几层、一次「运行」经过哪些模块、哪些设计是踩过坑后定下来的。

## 分层

```
UITestBenchApp (SwiftUI)
  UITestBenchApp.swift     主窗口装配、手机舞台
  Design/                  配色 token、坞、手机画布、窗口外壳（BenchWindowController）
  SetupModel / RunModel / SessionModel / MirrorModel /
  ScreenshotModel / AnnotationEditorModel
  Scanner/                 透明取景框、ScreenCaptureKit、权限状态机
        │  只订阅状态、转发用户动作
        ▼
UITestBenchCore (纯逻辑，无 SwiftUI)
  SDK · AVD · 进程 · scrcpy · APK · 二维码识别 · 设备 ID · 清理
        │
        ▼
adb / emulator / scrcpy-server.jar / VideoToolbox / 文件系统
```

`UITestBenchCore` 用协议把外部世界挡在外面（`CommandRunning`、`ProcessLaunching`、`SocketConnecting`、`MirrorFrameSource`、`MirrorInputSink`、`DeviceProvisioning`），所以绝大多数逻辑可以在没有模拟器的情况下做单测。真实环境的用例集中在 `Tests/UITestBenchCoreTests/Real*AcceptanceTests.swift`，默认跳过。

App 层的主窗口是「左侧悬浮坞 + 手机屏画布」：坞是 72pt 轨道 + 300pt 抽屉槽（`DockRail` / `DockDrawer`），手机在画布上的位置固定（`PhoneStage` / `PhoneFrame`）。这一版也调整了部分输入语义（`KeyboardInput` 里删除/Esc 改为 `.ignored`，不再映射成设备按键）；镜像链路与坐标映射未改。

## 一次「运行」的数据流

1. **准备环境**（只在第一次或换镜像源时）
   `SetupModel` → `SdkRepository` 解析 Google 清单 → `SdkInstallPlan` 选出 platform-tools / emulator / `system-images;android-34;default;arm64-v8a` → `FileDownloader` 下载 → `Checksum` 校验 → `ZipArchive` 解压到临时目录 → 原子换入 `~/Library/Application Support/UI验收台/sdk/`。
   离线导入走同一条安装路径，只是归档来自用户选择的文件夹；安装器不会删除这些归档。

2. **准备 APK**
   `APKSource` 表示本地文件 / 远程链接。四条入口最终都收敛到它：拖入 / 选择文件、剪贴板图片、屏幕取景框扫码、粘贴链接。

   屏幕扫码走 `/Scanner`：`ScreenScannerModel` 在主窗口最小化后弹出 `ScannerPanel`——一张可拖动的玻璃卡片，中央是 320×320 的透明取景区，毛玻璃只铺在四条边框上，绝不覆盖取景区域。面板出现后先有 2 秒准备期：捕获照常启动（把 `SCStream` 的启动时间藏进准备期），但 `ScanSession` 的 `startAt` 让这段时间不判定，光带也停在原地。准备期结束后光带开始扫，`CaptureRegionCalculator` 把取景区的 AppKit 坐标换成 ScreenCaptureKit 的显示器本地坐标，`ScreenRegionCapture` 只捕获取景区（10 fps）。帧在后台串行队列交给 `ScanSession`：`VisionBarcodeDetector` 识别 QR → `ScanCandidateSelector` 取离框中心最近的码 → `ScanHitGate` 要求同一链接连续 2 帧才算命中。命中后停扫、显示对勾 1 秒，再恢复主窗口，只把 `DownloadLink` 交给 APK 面板弹确认条；用户点「下载」才调用 `APKAcquirer`。

   `APKAcquirer` 负责下载本地化，得到文件。远程下载的文件落在 `tmp/apk/`，随会话清理；用户选中的原始 APK 不复制、不删除。扫码来源使用 `.scanned` 策略：取消或解析失败时删掉这次下载的临时文件与 `.part`。
   `ZipReader` 读 ZIP 中央目录 → `AXmlParser` 解析二进制 `AndroidManifest.xml` → `AndroidManifest` / `ApkInspector` 得到包名、版本、启动 Activity、ABI → `CompatibilityChecker` 给出阻断或放行。

3. **启动设备**
   `AVDStore` 直接在 `avd/` 下写 `uitestbench.ini` 与 `uitestbench.avd/config.ini`（不依赖需要 JDK 的 `avdmanager`），通过 `ANDROID_AVD_HOME` 把 AVD 收在自己的目录里。
   `EmulatorController` 以 `-no-window -no-audio -no-boot-anim -gpu host` 启动 emulator，轮询 adb 直到开机；停止时先 `adb emu kill`，等模拟器把快照写完再允许下一次启动（`stopping` 状态就是为这个存在的）。
   开机完成后、交出画面之前，`TeamDeviceKeyProvisioner` 检查并写入团队 `userkey`；失败只显示橙色警告，不阻断设备使用。

4. **安装与启动应用**
   `AppLifecycle` 执行 `adb install -r -t`、`am start`（失败回退 `monkey`）、`pm clear`、`uninstall`。安装失败按 `INSTALL_FAILED_*` 翻译成中文原因。
   `AppRunner` 把「清数据重开 / 保留数据重开 / 完全重装」编排成固定顺序。

5. **画面**
   `ScrcpySession` 推 jar、开端口转发、拉起服务端并完成握手；`ScrcpyVideoReader` 解析视频头与逐帧包；`ScrcpyFramePump` 调 `ScrcpyDecoder`（内部是 `H264Decoder` / VideoToolbox）把包解码成 `DecodedFrame`；`MirrorEngine` 在后台队列上循环「取一帧已解码画面 → 用 `VideoSampleBuffer` 包成 `CMSampleBuffer` → 上屏」，断流时通过 `MirrorRecoveringFrameSource.restart()` 重建会话，最多重试 3 次。
   `ScrcpyMirrorSource` 把 scrcpy 会话接到这个通用接口上；界面只认 `MirrorFrameSource`，所以降级到别的画面来源时上层不用改。

6. **输入**
   视图坐标经 `CoordinateMapper` 换成设备坐标，`MirrorInputController` 分派给 `MirrorInputSink`。`ScrcpyInputSink` 按锁定的 scrcpy 版本写控制消息；`DragScrollSink` 把滚轮翻译成合成短拖动；`KeyboardInput` 只支持 ASCII。

7. **截图与标注**
   `ScreenshotCapturer` 用 `exec-out screencap -p` 拿 PNG，界面立即冻结画面；`Annotation` 是文档模型，`AnnotationRenderer` 负责把矩形 / 箭头 / 文字 / 画笔画到图上。导出必须由用户显式保存或复制。

8. **结束**
   `SessionShutdown` 先清数据并卸载被测包，再删 `tmp/`；如果设备已经不在、包没卸掉，就保留 `SessionCleaner` 的会话记录，下次启动补卸。`SessionCleaner` 负责启动自检与残留清理。

## 关键设计取舍

| 取舍 | 原因 |
|---|---|
| 只用 scrcpy 服务端，不用它的窗口 | scrcpy 窗口无法嵌进 SwiftUI；抓屏要屏幕录制权限，且新版就失效。自己实现协议换来真内嵌、零权限、点击 10–20 ms。 |
| jar 与控制消息布局成对锁死 | 协议字段随 scrcpy 版本变化，不一致时表现为乱点或崩溃；启动时校验版本，不静默降级。 |
| 手写 AVD 配置，不用 `avdmanager` | `avdmanager` 需要 JDK，同事机器上没有；目录收在应用支持目录，不污染 `~/.android`。 |
| `-gpu host`，不用 `auto` | `auto` 在 Apple 芯片上会退到 SwiftShader，帧率和输入延迟都明显变差。 |
| 滚轮合成短拖动 | AOSP 14 镜像上 `INJECT_SCROLL_EVENT` 应用层不响应；合成拖动是唯一稳定的路径。 |
| 改 SSAID 前先停系统框架 | SettingsProvider 内存里有旧表，不停框架直接改文件会被覆盖回去。 |
| 团队统一 `userkey` | SSAID = HMAC(userkey, 签名证书)。固定 userkey，所有电脑对同一套证书得到同一个 ID，开发只配一次白名单。 |
| 扫码只捕获取景框，不截全屏 | 飞书/浏览器里常同时有多个码；框内捕获既符合「对准哪个扫哪个」的直觉，也把 CPU 和隐私面压到最小。 |
| 屏幕画面只在内存里识别 | 捕获帧不写盘、不进日志/诊断/报告。用户桌面和公司聊天内容不应该因为扫码被留存。 |
| Vision 失败再试反色与 CIDetector | 暗色模式、反色码在飞书里很常见；静态截图还要兼容旧路径。原始帧不做预处理，避免每帧都付图像变换的代价。 |
| 扫码下载不设体积上限、失败即删 | 二维码背后的 APK 大小不可预知；确认条 + 下载中的取消按钮负责兜底。临时文件只属于工具，失败就清掉。 |
| 退出即清业务数据 | 设计核对不应把公司包和登录态留在同事机器上；原始 APK 与导出截图除外。 |

## 状态与磁盘

工具只写 `~/Library/Application Support/UI验收台/`：

```
sdk/     platform-tools、emulator、system-images
avd/     uitestbench.ini、uitestbench.avd/
tmp/     会话临时目录（下载的 APK 等）
logs/    emulator.log 等
```

`AppPaths` 是这些路径的唯一来源。清理逻辑只允许删 `tmp/`、工具创建的 AVD、设备上的被测包；用户原始 APK、原始设计图和离线归档不在清理范围。

## 测试结构

- 纯逻辑单测：`Tests/UITestBenchCoreTests/*Tests.swift`，用假 runner / 假 socket / 假进程，不碰真实环境。扫码的决策链（链接校验、候选排序、命中门限、坐标换算、Vision 识别）都在 Core，用现场生成的二维码图片测试，不提交外部截图。
- App 层的捕获与取景框不建测试 target：决策链已由 Core 覆盖；`ScreenScannerModel` 直接装配 `ScreenRegionCapture` 与 `VisionBarcodeDetector`（二者分别有 `ScreenCapturing` / `BarcodeDetecting` 协议），编排、权限与多屏行为靠手工验收。
- 真实环境验收：`Real*AcceptanceTests.swift`，默认 skip，靠 `UITESTBENCH_REAL_SETUP=1` 打开；需要真实 SDK、模拟器和样本 APK。运行方式见 [acceptance-testing.md](acceptance-testing.md)。
- 设备 ID 的算法与映射见 [device-id.md](device-id.md)。
