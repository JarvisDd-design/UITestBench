# 屏幕取景框扫码获取 APK（1.2.0）

## Context

用户反馈：计划里写过 APK 获取不止「拖入文件」，还有二维码识别；实测只能拖入 APK，上传带二维码的截图读不出来。

排查确认是三个问题叠加：

1. **入口缺失**：只能「拖入有图片扩展名的文件」或「选择文件」；剪贴板截图不会被读（全仓库 `NSPasteboard` 只写不读），从浏览器/飞书直接拖图片数据会被 [APKPanelView.swift:56-65](../../Sources/UITestBenchApp/APKPanelView.swift#L56-L65) 静默丢弃（只取 `UTType.fileURL`，其它类型直接 return）。
2. **解码器能力不足**：[QRCodeDecoder.swift](../../Sources/UITestBenchCore/QRCodeDecoder.swift) 只收整份文件 `Data`，走 `CIDetectorTypeQRCode`，未处理图片方向、无裁剪/缩放；测试样本是放大 10 倍的干净 PNG。
3. **错误合并**：「图打不开 / 图里没码 / 码里不是链接」全部报同一句「这张图里没有找到下载地址」。

原计划写着「后续再加屏幕框选扫码」（`~/.claude/plans/encapsulated-swimming-boole.md` 第 25 行），一直未实现。本次补齐，并把扫码提升为 APK 获取的**主入口**；拖入/粘贴/选文件保留为兜底。

## 已确认的需求

| # | 决策 |
|---|---|
| 1 | 扫码形态：始终置顶、可拖动的**玻璃卡片**，中央是 **320×320 完全透明的取景区**；毛玻璃只铺在四条边框上，不覆盖取景区。出现后先给 2 秒准备期，再开始判定 |
| 2 | 取景框出现时主窗口自动最小化；命中或取消（Esc/关闭）后恢复 |
| 3 | **实时连续识别**，不是截一帧；只捕获取景框覆盖的屏幕区域 |
| 4 | 多码时取离取景框中心最近的；最近的码不是链接时不下载，只提示 |
| 5 | 命中后立即停扫、取景区显示成功对勾并停留 **0.5 秒**，再恢复主窗口、显示确认条（域名/文件名）→ 点「下载」才开始下载 |
| 6 | 确认按钮**只下载并解析**；安装/启动仍由现有「运行应用」负责 |
| 7 | 任意 http(s) 链接都允许试下载，**不设体积上限**，可随时取消；下载后由 `ApkInspector` 判定，失败即删临时文件（绝不碰本地原始 APK） |
| 8 | 非链接内容：框内提示「识别到内容，但不是下载链接」，继续扫描 |
| 9 | 首次点击扫描检测并请求屏幕录制授权；被拒给中文说明 + 直达系统设置；保留「改用截图…」兜底 |
| 10 | 接受 ad-hoc 签名导致重打包后可能需重新授权 |
| 11 | 部署目标 macOS **12.3**，只用 ScreenCaptureKit；版本 **1.2.0** |
| 12 | 取景框每次出现在**鼠标所在屏幕中央**（不记忆位置） |
| 13 | 主要验收：**飞书聊天窗（最重要）**、浏览器、微信；小码、Retina、暗色、视频中的码 |
| 14 | 文档同步 README、docs/architecture.md、CLAUDE.md、计划文件 |

## 总体设计

- **App 层**（新目录 `Sources/UITestBenchApp/Scanner/`）：屏幕捕获、透明取景框面板、权限流程、与主窗口/`APKPanelModel` 的编排。
- **Core 层**（新文件放 `Sources/UITestBenchCore/`）：链接校验、候选排序、命中门限、区域坐标换算、Vision 识别。全部可单测，不依赖 SwiftUI/AppKit。
- 保持现有依赖方向 `App → Core`；不引入第三方依赖。

## 文件清单

### 新增（Core）

| 文件 | 职责 / 关键签名 |
|---|---|
| `DownloadLink.swift` | `struct DownloadLink: Equatable, Sendable { let url: URL; let host: String; let fileName: String }`；`enum DownloadLinkParser { static func parse(_ text: String) -> DownloadLink? }`。只接受 http/https 且有 host；`fileName` 取 `lastPathComponent`，空则 `download.apk` |
| `ScanImage.swift` | `enum ScanImage { case pixelBuffer(CVPixelBuffer); case cgImage(CGImage) }` |
| `BarcodeDetector.swift` | `struct BarcodeCandidate { let payload: String; let boundingBox: CGRect }`；`protocol BarcodeDetecting { func detect(in: ScanImage) throws -> [BarcodeCandidate] }` |
| `VisionBarcodeDetector.swift` | Vision `VNDetectBarcodesRequest`，`symbologies = [.qr]`，用**系统默认 revision**（12.3 上不手动钉 revision）；识别不到时按节流做反色重试 |
| `ScanCandidateSelector.swift` | `enum ScanCandidateSelector { static func choose(from: [BarcodeCandidate]) -> BarcodeCandidate? }`：按到 (0.5, 0.5) 的距离最小；平局依次比 `minY`、`minX` |
| `ScanHitGate.swift` | 同一 URL 连续 2 帧、间隔 ≤ 0.35 s 才命中；命中后同一 URL 不再触发；非链接提示 1.5 s 节流 |
| `ScanSession.swift` | `final class ScanSession { init(detector: BarcodeDetecting, gate: ScanHitGate); func process(_ image: ScanImage, at: TimeInterval) -> ScanOutcome; func reset() }`；`enum ScanOutcome { case none, notALink(String), hit(DownloadLink) }` |
| `CaptureRegionCalculator.swift` | `struct CaptureRegion { let sourceRect: CGRect /* 显示器本地、左上原点、点 */; let pixelWidth: Int; let pixelHeight: Int }`；`static func region(panelFrame: CGRect, screenFrame: CGRect, backingScale: CGFloat) -> CaptureRegion`。负责 AppKit 全局坐标（左下原点）→ 显示器本地 Quartz 坐标的翻转，以及 Retina 像素尺寸 |
| `OrientedImage.swift` | `static func cgImage(from data: Data, maxPixel: CGFloat = 4096) -> CGImage?`：`CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceCreateThumbnailWithTransform`，一次完成 EXIF 方向归一化 |

### 新增（App）

| 文件 | 职责 |
|---|---|
| `Scanner/ScreenRegionCapture.swift` | 封装 `SCShareableContent` / `SCContentFilter` / `SCStream`；`@available(macOS 12.3, *)`；只暴露 `start(region:onFrame:onFailure:)`、`updateRegion(_:)`、`pause()`、`stop()` |
| `Scanner/ScannerPanel.swift` | `NSPanel` 子类 + `NSView` 内容：368×452 玻璃卡片、中央 320×320 镂空取景区、可拖、Esc/关闭、标题与底部提示、浅蓝扫描光带、成功对勾、四角准星 |
| `Scanner/ScreenScannerModel.swift` | `@MainActor ObservableObject`：权限状态机、面板展示、主窗口最小化/恢复、捕获编排、把 `ScanSession` 的命中回调出去 |
| `Scanner/ScreenCapturePermission.swift` | `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` 封装；打开系统设置；中文状态描述 |

### 修改

- `Sources/UITestBenchCore/APKSource.swift`：拆分错误；新增图片 `Data` 入口。
- `Sources/UITestBenchCore/QRCodeDecoder.swift`：改为调用 Vision 检测器；保留 `downloadURL(from: Data)` 兼容旧调用。
- `Sources/UITestBenchCore/FileDownloader.swift`：**不加上限**，保持现有下载/取消/续传行为不变。
- `Sources/UITestBenchCore/APKAcquirer.swift`：新增 `APKAcquisitionPolicy { removesRemoteOnFailure }` 与 `acquire(_:policy:progress:)`；默认策略保持现有行为，扫码用 `.scanned`（取消或检查失败都删除远程临时文件及其 `.part`）。
- `Sources/UITestBenchApp/APKPanelView.swift`：主按钮「扫描屏幕二维码」；确认条；剪贴板粘贴；拖入 `.image` 支持；`chooseFile` 增加 `.avif`。
- `Sources/UITestBenchApp/UITestBenchApp.swift`：持有 `ScreenScannerModel`，把命中回调接到 `APKPanelModel`；退出时停止捕获。
- `project.yml`：部署目标 12.3；版本 1.2.0 / build 8；`NSScreenCaptureUsageDescription`。
- `Package.swift`：**保持 `.macOS(.v12)`**。SwiftPM 的 `MacOSVersion` 只有 `.v12`/`.v13`（已确认），不能写 12.3；发布下限由 `project.yml` 决定，所有 SCK 代码用 `@available(macOS 12.3, *)` 包住，`swift build` 仍可编译。
- `Scripts/package.sh`：默认版本 1.2.0；「使用说明」里的 APK 来源、macOS 版本（12.3）与录屏权限说明同步。

## 关键实现细节

### 1. 屏幕捕获（ScreenCaptureKit，仅 SCStream）

`SCScreenshotManager` 是 macOS 14 才有，12.3 只能用 `SCStream`。

- 用 `SCShareableContent.current` 找到取景框所在 `NSScreen` 对应的 `SCDisplay`，以及本应用的 `SCRunningApplication`。
- `SCContentFilter(display:excludingApplications: [ownApp], exceptingWindows: [])`，确保取景框自身不进入画面；面板同时设 `sharingType = .none` 双保险。
- `SCStreamConfiguration`：`sourceRect` 用 `CaptureRegionCalculator` 的结果（玻璃卡片中央的 320×320 取景区，不是整张卡片）；`width/height = 点 × pointPixelScale`（Retina 下 320 点 → 640 像素）；`minimumFrameInterval = CMTime(value: 1, timescale: 10)`；`pixelFormat = ._32BGRA`；`showsCursor = false`；`queueDepth = 2`。
- 样本回调在串行队列上直接跑 Vision；用 `NSLock` 保护的 `isBusy` 做背压，忙时丢帧（SCK 的 `queueDepth` 也会丢）。
- 只处理 `SCFrameStatus.complete` / 第一帧的 `.idle`；`.blank` / `.suspended` / `.stopped` 跳过；每帧 `autoreleasepool`。
- 拖动期间丢弃帧；拖动结束 150 ms 防抖后：同屏 `updateConfiguration` 改 `sourceRect`，跨屏则 stop 后重建 filter + stream。
- 命中时先在样本队列同步 `pause()`，再异步 `stopCapture()`；启动 2 秒内无有效帧 → `.grantedButNoFrames`。
- `willTerminate` 与扫描取消都必须 `stop`，保证屏幕录制指示灯熄灭。

### 2. 二维码识别

- 实时帧走 Vision（直接吃 `CVPixelBuffer`），静态图片走同一检测器（转 `CGImage`），旧的 `downloadURL(from: Data)` 保留为薄封装。
- 热路径不做预处理；本帧无结果时按节流重试：反色（`CIColorInvert`，每 3 帧最多一次）、低对比灰度（`CIColorControls`），静态图片短边 < 600 px 时 2× 放大后再试一次。
- 多码严格取离中心最近者；最近的不是链接 → `.notALink`，继续扫描，**不**去取更远处可能存在的链接。
- 命中确认：同一 URL 连续 2 帧（≤ 0.35 s），10 fps 下约 100–200 ms，视觉上仍是「立即」。
- 静态截图路径保持旧语义：取最近的**有效链接**（截图里常同时有 Wi-Fi 码和下载码）。

### 3. 取景框与主窗口

- `ScannerPanel`：`styleMask = [.borderless, .nonactivatingPanel]`；`level = .floating`；`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`；`isOpaque = false`；`backgroundColor = .clear`；`hasShadow = false`；`hidesOnDeactivate = false`；`canBecomeKey = true`、`canBecomeMain = false`。
- 初始位置：`NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }` 的 `visibleFrame` 居中（每次打开都重新计算）。
- 拖动：内容视图 `mouseDown` 判断关闭按钮区域，其余 `performDrag(with:)`。
- 取消：内容视图与 panel 均实现 `cancelOperation(_:)`；`keyDown` 里 `keyCode == 53` 兜底。
- 主窗口：显示面板 → `mainWindow.miniaturize(nil)`；恢复 → `deminiaturize(nil)` + `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront(nil)`。**不要用 `NSApp.hide`**，会把面板一起藏掉。
- 命中反馈：白色覆盖层 0.85 → 0，0.18 s；随后收起面板并恢复主窗口。

### 4. 权限状态机

| 状态 | 判定 | 界面 |
|---|---|---|
| 未请求 | `CGPreflightScreenCaptureAccess() == false` 且未请求过 | 点击扫描时先弹说明页再请求 |
| 已拒绝/待重启 | 请求后 preflight 仍 false | APK 区卡片：中文说明 + 「打开系统设置」+「重新检查」+「改用截图…」 |
| 已授权 | preflight true | 正常进入取景框 |
| 授权但无画面 | 2 s 内无有效帧 | 卡片：提示退出重开 / 取消再勾选屏幕录制 |
| 捕获中断 | `SCStreamDelegate` 报 `-3801` | 回到「已拒绝/待重启」 |
| 其他错误 | 其他 `SCStreamError` | 卡片显示中文原因 + 重试 |

- `project.yml` 增加 `NSScreenCaptureUsageDescription`：「需要读取屏幕上的取景框画面来识别二维码。画面只在本机内存中分析，不会保存或上传。」
- 无 App Sandbox，不需要 entitlements。
- 系统设置直达：`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`。
- ad-hoc 重签提示写进说明页与 README：升级后若异常，先在系统设置里用「−」移除「UI验收台」再重新授权；终端兜底 `tccutil reset ScreenCapture com.uitestbench.app`。

### 5. APK 面板集成

- 空状态：**「扫描屏幕二维码」为主按钮**（醒目、整行），下方才是拖放区、「粘贴链接」和「选择本地文件…」。拖放区注册 `.fileURL` + `.image`，图片数据走 `loadDataRepresentation`。
- 新增「从剪贴板粘贴」：读 `NSPasteboard.general`，有 PNG/TIFF 就解码，有文本就按链接处理；快捷键在 APK 区聚焦时 ⌘V。
- 新增 `APKPanelModel` 状态（与现有四态正交）：

```swift
struct ScanNotice: Equatable {
    enum Stage: Equatable { case pending, downloading(received: Int64, total: Int64?), failed }
    let link: DownloadLink
    var stage: Stage
}
@Published private(set) var scanNotice: ScanNotice?
```

- 命中 → `state = .empty`、`scanNotice = .pending(link)`、恢复主窗口；确认条显示「识别到 example.com / app-release.apk」+「下载」+「取消」。
- 点「下载」→ 现有 `load` 流程，`source = .remote(link.url)`，`policy = .scanned`。`state` 进入 `.loading` 时确认条显示进度；`.failed` 时确认条只显示「下载失败，见下方说明」。
- 手动拖入/粘贴/选文件时清空 `scanNotice`。
- 命中**不会**自动下载，必须点确认按钮。

### 6. 错误与文案

`APKSourceError` 拆成：`unsupportedFile` / `unreadableImage` / `noQRCodeInImage` / `qrCodeIsNotLink` / `invalidLink`，并新增「四条图片/链接错误文案互不相同」的断言。

| 场景 | 文案 |
|---|---|
| 打不开图片 | 打不开这张图片。文件可能已损坏，或不是 PNG、JPG、HEIC 等常见格式。请换一张截图试试。 |
| 图里没码 | 这张图里没有找到二维码。请换一张二维码完整、清晰的截图。 |
| 码里不是链接 | 找到了二维码，但里面不是下载链接。二维码内容要以 http:// 或 https:// 开头。 |
| 实时扫到非链接 | 识别到内容，但不是下载链接（框内提示，1.5 s 节流） |
| 下载到一半取消 | 已取消下载，临时文件已删除。 |
| 下载到的不是 APK | 下载完成了，但这个文件不是 APK。二维码里可能是一个网页或普通文件。 |
| 权限被拒 | 还没有屏幕录制权限。macOS 需要它来读取取景框里的画面。请在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选「UI验收台」，然后重启应用。 |
| 授权但无画面 | 已经获得屏幕录制权限，但没有拿到画面。可能是授权在本次启动后才生效。请退出并重新打开 UI验收台；仍不行就取消勾选再重新勾选。 |

## 测试（严格 TDD，先 RED）

| 顺序 | 测试文件 | 首批用例 |
|---|---|---|
| 1 | `DownloadLinkTests.swift` | 接受 http/https、去空白、拒非 http、拒无 host、保留 query、推导 host/fileName、空文件名兜底 |
| 2 | `ScanCandidateSelectorTests.swift` | 取离中心最近、最近的码非链接时胜出、多链接取最近、空输入、平局确定性 |
| 3 | `ScanHitGateTests.swift` | 需连续 2 帧、payload 变化重置、超时重置、同一 URL 只发一次、非链接提示节流 |
| 4 | `ScanSessionTests.swift` | 最近链接命中、非链接继续扫、无效载荷不命中、reset 后可重扫、注入假 detector |
| 5 | `CaptureRegionTests.swift` | Retina 2× 像素、1x 点像素、主屏、副屏在右/在上、坐标翻转、钳制到可见区域 |
| 6 | `VisionBarcodeDetectorTests.swift` | 单码、多码、小码、反色、纯白图无码 |
| 7 | `QRCodeDecoderTests.swift`（改） | EXIF 方向、区分「打不开/没码/非链接」、JPEG 压缩、多码取最近有效链接 |
| 8 | `APKSourceResolverTests.swift`（改） | 四种错误分别映射、剪贴板图片 Data 入口 |
| 9 | `APKAcquirerTests.swift`（改） | `.scanned` 策略取消/检查失败都删远程临时文件与 `.part`、不删用户本地文件；默认策略仍保留 `.part` |

Fixture：

- 扩展 `Support/QRCodeFixture.swift`：JPEG、EXIF 方向、反色、极小尺寸、多码合成图、`CVPixelBuffer` 转换。
- 新增 `Support/ScanFixture.swift`：直接构造候选；合成「聊天气泡 + 二维码」截图（亮/暗、60/100/160 px、JPEG 压缩、轻微模糊），全部现场生成，不提交外部图片。
- 新增 `RealScreenScanAcceptanceTests.swift`：默认 skip，`UITESTBENCH_SCAN_SAMPLES` 指向本机私有截图目录时运行。**公司聊天截图只放本机，不进仓库、DMG、日志或诊断。**
- App 层的捕获/面板/权限不新增测试 target；编排逻辑通过 `BarcodeDetecting` / 捕获协议注入，Core 测试覆盖决策，其余手工验收。

## 里程碑

| 里程碑 | 内容 | 验证 |
|---|---|---|
| M1 | `DownloadLink` + 错误拆分 + `APKSourceResolver` 改造 | 对应单测 RED → GREEN |
| M2 | `OrientedImage`、`VisionBarcodeDetector`、`QRCodeDecoder` 重构、fixture | 单测 |
| M3 | `ScanCandidateSelector`、`ScanHitGate`、`ScanSession` | 单测 |
| M4 | `CaptureRegionCalculator` | 单测 |
| M5 | 取消/失败清理、非 APK 文案 | 单测 |
| M6 | 权限封装、`ScreenRegionCapture`、`ScannerPanel`、`ScreenScannerModel` | 运行 App 手工验证 |
| M7 | APK 面板：扫描主按钮、确认条、剪贴板、图片拖入 | 端到端 |
| M8 | 版本 1.2.0、文档、`xcodegen generate`、打包、真机验收 | 全量 |

## 验证

```bash
cd "/Users/jarvis/Desktop/桌面测试工具/1.0.0"
xcodegen generate
swift build
swift test
Scripts/package.sh 1.2.0
```

手工验收：

1. 首次点「扫描屏幕二维码」弹中文授权说明；拒绝后主窗口不最小化，卡片可直达系统设置。
2. 授权并重启后扫描：玻璃卡片出现、主窗口最小化、中央 320×320 取景区完全透明、出现在鼠标所在屏幕中央；出现后 2 秒内光带不动、不识别，2 秒后光带开始扫。
3. 浏览器 / Preview 里的二维码在准备期结束后 1–2 秒命中；命中后停扫、显示对勾 0.5 秒、恢复主窗口、确认条显示域名与文件名。
4. **飞书**：聊天窗里的二维码图片预览、未放大的小图都能扫到；微信同样。
5. 多码：框中心靠近 A 取 A，移近 B 取 B。
6. 非链接码：底部提示且继续扫描，不退出。
7. 暗色 + 反色码、Retina 内置屏、外接 1x 屏、视频播放中的码。
8. Esc / 关闭：停扫、恢复主窗口、屏幕录制指示灯熄灭。
9. 确认条点「下载」后才开始下载；包信息与兼容性正常；「运行应用」流程不变。
10. 非 APK 链接下载后提示「不是 APK」，远程临时文件被删除；大文件下载可随时取消且无残留；本地原始 APK 不受影响。
11. 多显示器、全屏 Safari、Space 切换：取景框始终置顶，坐标正确。
12. 扫描 30 秒观察 CPU 与发热；停止后流释放、CPU 回落。
13. 重新打包 ad-hoc 新版本后按文档处理 TCC 重新授权。

本地测试物料（不联网）：

```bash
mkdir -p /tmp/uitestbench-scan
# 放入 sample.apk、page.html、large.bin（>50MB）
python3 -m http.server 8000 --directory /tmp/uitestbench-scan
# 生成二维码：http://127.0.0.1:8000/sample.apk / page.html / large.bin / 纯文本 hello
```

## 文档与版本

- `project.yml`：`deploymentTarget.macOS: "12.3"`、`CFBundleShortVersionString: "1.2.0"`、`CFBundleVersion: "8"`、`NSScreenCaptureUsageDescription`；改完 `xcodegen generate`。
- `Scripts/package.sh`：默认版本改 1.2.0；使用说明补扫码用法、12.3 要求、录屏权限与重授权提示。
- `README.md`：删掉「零屏幕录制权限」，改为「扫码时才申请屏幕录制，只读取景框区域，不落盘」；APK 来源写清四条路径。
- `docs/architecture.md`：更新抓屏取舍与 APK 来源数据流。
- `CLAUDE.md`：安全红线补「屏幕捕获内容只在内存中用于识别，不写盘、不进日志/诊断/报告」；关键模块表加扫描相关文件；部署目标改为 12.3。
- 计划文件 `~/.claude/plans/encapsulated-swimming-boole.md`：第 25 行状态改为已实现，补一条决策「可拖拽透明取景框 + 连续识别，捕获仅限框内区域且不落盘」。

## 主要风险

- **12.3 的 SCK `sourceRect` 行为**：坐标换算单测覆盖；拖动结束用 `updateConfiguration`，失败则 stop/restart；必须在真实 macOS 12.3 机器上验收（CLAUDE.md 既有要求）。
- **TCC 与 ad-hoc 重签**：授权后需重启、升级后可能重置；说明页、README、`tccutil` 兜底三处都写清。
- **飞书/微信渲染**：SCK 通常能捕获；若出现黑帧，提示改用「截图后拖入」，并在验收中优先验证。
- **取景框挡住鼠标操作**：不做点击穿透，避免误触；需要操作下方应用时先拖开。
- **CPU/发热**：只捕获 800×800、10 fps、只识别 QR、拖动暂停、命中即停；检测耗时 > 60 ms 时降到 5 fps。
- **误扫到超大链接**：不设体积上限，依靠确认条（必须先点「下载」）与下载中的取消按钮兜底；取消后立即删除临时文件。
- **`Package.swift` 无法表达 12.3**：保持 `.v12` + `@available`，发布下限以 `project.yml` 为准。
