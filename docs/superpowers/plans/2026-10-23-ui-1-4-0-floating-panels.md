# UI验收台 1.4.0 主窗口重构：手机 + 三个吸附悬浮面板

> **状态（2026-10-23）**：M0–M6 已实现，最终以 1.4.2 / build 13 发布；执行结果与实际偏差见文末「执行记录」。当前架构以 [docs/architecture.md](../../architecture.md) 为准，本文是设计依据与 M0 实测记录。

## Context

1.3.0 的主窗口目前是「透明大窗口 + 左侧常驻轨道 + 300pt 抽屉槽 + 手机画布」：

- `DockColumn` 固定 372pt（72pt 轨道 + 300pt 抽屉槽），抽屉永远向**右**展开，窗口默认 1120×780，手机只在剩余空间里居中，左侧留下大片透明/灰色空画布。见 [DockDrawer.swift](../../../Sources/UITestBenchApp/Design/DockDrawer.swift#L164-L228) 与 [UITestBenchApp.swift](../../../Sources/UITestBenchApp/UITestBenchApp.swift#L64-L107)。
- 深色模式下坞的图标/文字几乎看不见：`DockRail` 只有 `.ultraThinMaterial` + 8% 白，透明窗口的材质采样到亮桌面后被抬亮，而图标仍是深色主题的浅灰。抽屉和底胶囊都用「不透明卡面靠近内容、材质垫底」规避了，唯独轨道漏了（[DockRail.swift:75-83](../../../Sources/UITestBenchApp/Design/DockRail.swift#L75-L83)）。

用户已确认的目标：

1. 视觉上**没有窗口形态**：只有手机机身、左侧坞胶囊、下方操作胶囊；抽屉卡片悬停时从坞的**左侧**弹出。
2. 真·多面板：手机是唯一真实窗口（无边框、只剩机身）；坞、底胶囊、抽屉都是跟随手机的独立 `NSPanel` 子面板。拖动任意一块 = 整套一起移动，坞/胶囊始终吸附手机。
3. 坞改成贴合内容高度的胶囊，悬浮在手机左侧，和底胶囊同一套视觉语言。
4. 悬浮件保留毛玻璃，但必须垫不透明实底，深色/浅色在任何桌面壁纸上都能看清。
5. 手机仍可拖窗口边缘等比缩放；坞、胶囊、卡片自动重新定位。

目标形态（示意）：

```
                    ┌─────────────────┐
  悬停时             │  抽屉卡片 292pt  │
  ┌──────────────┐  │  （垂直居中于坞）│
  │ 设备          │  └─────────────────┘
  │ 机型 [主流 ▾] │        ╭────╮
  │ 1080×2400    │        │ ●● │ ← 坞胶囊 68pt，顶部对齐手机
  │ [启动设备]    │        │素材│
  │ ...          │        │设备│
  └──────────────┘        │应用│   ╭──────────────╮
                          │诊断│   │              │
                          │设置│   │   手机画面    │
                          │────│   │              │
                          │☾ 📌│   │              │
                          ╰────╯   ╰──────────────╯
                                   [  操作胶囊 48pt  ]
```

## 架构决定

### 窗口拆分

| 部件 | 载体 | 说明 |
|---|---|---|
| 手机 | 主 `NSWindow`（borderless + resizable；优先由 `WindowGroup` 的窗口改 styleMask，M0 验证 key 行为，不行就在 AppDelegate 手工建 `PhoneWindow: NSWindow` 子类） | content = `PhoneFrame`（屏幕 + 7pt 边框），窗口尺寸就是手机外框尺寸 |
| 坞 | `NSPanel` 子面板 | 内容高度自适应的胶囊；顶部放自绘交通灯 |
| 底胶囊 | `NSPanel` 子面板 | 宽 = 手机外框宽，吸附在手机下方 12pt |
| 抽屉卡片 | `NSPanel` 子面板 | 坞左侧 12pt，垂直居中于坞；面板尺寸随卡片内容变化 |

- 三个面板都用 `phoneWindow.addChildWindow(panel, ordered: .above)` 挂到手机窗口：主窗口移动时子窗口自动跟随；缩放/换屏时由控制器重排。
- 面板统一：`NSPanel`、`styleMask: [.borderless]`、透明背景、`hasShadow = false`（阴影由 SwiftUI 卡片画）、`level = .normal`（子窗口天然在主窗口之上；不要用 `.floating`，否则 App 不在前台时也浮在别的应用上）、`collectionBehavior = [.ignoresCycle]`、`becomesKeyOnlyIfNeeded = true`（点按钮不抢手机窗口的键盘焦点，点文本框时才成为 key）、`canBecomeMain = false`、`hidesOnDeactivate = false`。**不加 `.nonactivatingPanel`**：坞是常驻控件，App 未激活时点它应该激活 App；[ScannerPanel.swift](../../../Sources/UITestBenchApp/Scanner/ScannerPanel.swift#L78-L120) 用它是因为扫码浮层不该抢激活，场景不同。M0 对比两种面板在「未激活点按」和「文本框输入」上的差别，确认后再定稿。置顶打开时把手机窗口与所有面板一起切到 `.floating`。
- 手机窗口：`styleMask = [.borderless, .resizable]`，`backgroundColor = .clear`、`isOpaque = false`、`hasShadow = true`、`contentAspectRatio` 锁手机外框比例。拖边缘缩放时控制器重排三个面板。
- 绿色交通灯不再进 macOS 全屏（透明无边框窗口全屏会得到一块黑底），改成「适应屏幕」：在「上次大小」和「按可见屏幕高度能放下的最大尺寸」之间切换。

### 状态共享（必须做）

抽屉、坞、胶囊在三个独立的 `NSHostingView` 里，无法再靠 `ContentView` 里的 `@StateObject` 和 `@Binding` 传递。把现有模型与状态上提成 App 层唯一的 `AppModel`（`@MainActor ObservableObject`），由 `UITestBenchApp` 持有，注入手机窗口内容与三个面板的 hosting view。

`AppModel` 负责：
- 现有全部 `@StateObject`：`setup/theme/window/dock/device/mirror/apk/scanner/run/screenshot/session`。
- 现有 `@State`：`profileIndex/customWidth/customHeight/customDensity/showsCustomResolution/actionError` 改成 `@Published`，原来传 `$binding` 的地方改传模型。
- 现有 `ContentView` 里的动作：`toggleDevice`、`switchToPreset`、`applyCustomResolution`、`currentProfile`。
- 生命周期编排（设备 state → mirror/run/screenshot/session、apk → run.reset、run.isRunning → session.recordLaunch、theme → scanner）**保留在手机窗口的视图里**（手机窗口始终存在），不搬进模型，降低改动面。

### 几何下沉 Core（TDD）

新增 `Sources/UITestBenchCore/FloatingPanelLayout.swift`：

```swift
public struct FloatingPanelMetrics {
    public var dockGap: CGFloat = 12
    public var capsuleGap: CGFloat = 12
    public var drawerGap: CGFloat = 12
    public var screenInset: CGFloat = 8
    public static let standard = FloatingPanelMetrics()
}

public struct FloatingPanelFrames: Equatable {
    public let dock: CGRect       // AppKit 屏幕坐标，左下原点
    public let capsule: CGRect
    public let drawer: CGRect?
}

public enum FloatingPanelLayoutCalculator {
    public static func frames(
        phoneFrame: CGRect,        // 手机外框在屏幕上的矩形
        dockSize: CGSize,
        capsuleHeight: CGFloat,
        drawerSize: CGSize?,
        visibleScreen: CGRect,
        metrics: FloatingPanelMetrics = .standard
    ) -> FloatingPanelFrames
}
```

定位规则（全部写进测试）：

- 坞：右边缘 = `phoneFrame.minX - dockGap`，顶边 = `phoneFrame.maxY`（顶部对齐），尺寸取内容实测。
- 底胶囊：宽 = `phoneFrame.width`，`x = phoneFrame.minX`，`y = phoneFrame.minY - capsuleGap - capsuleHeight`。
- 抽屉：右边缘 = 坞的 `minX - drawerGap`，垂直中心 = 坞的 `midY`；再夹到 `visibleScreen` 内（上下各留 8pt）。左侧空间不足时夹到屏幕左边，允许极端情况下压住坞，不翻到右边。
- `drawerSize == nil` 时 `drawer = nil`。
- Core 返回的是**可见胶囊/卡片**的矩形；面板控制器在四周统一加 `shadowPadding`（给 SwiftUI 阴影留位置）再 `setFrame`，两套尺寸不要混用。计划里的 18pt 是估算值，实现取 **40pt**，以 `FloatingPanelsController.shadowPadding` 为准。

`PhoneLayout` 增加：

```swift
public static func layout(frameSize: CGSize, profile: DeviceProfile) -> PhoneLayout
public static func frameSize(forScreenWidth: CGFloat, profile: DeviceProfile) -> CGSize
public static func maximumScreenWidth(visibleSize: CGSize, profile: DeviceProfile) -> CGFloat
```

- 窗口 content = 手机外框，屏幕 = content - 2×7pt 边框。
- 默认屏幕宽 300pt；最小 240pt（再小镜像内容没法点）；最大 440pt，且不超过可见屏幕高度能容纳的值（扣掉胶囊 48 + 间距 12 + 上下留白）。窗口 min/max contentSize 与这两个边界保持同一来源，不要在手写常量里各写一份。
- 旧的 `layout(available:)`（按“扣除胶囊后的剩余空间”算）随 `PhoneStage`/`SetupStage` 一起删除，`PhoneLayoutTests` 改成围绕新 API 重写，不再保留死代码。

`DockDrawerState` 增加跨窗口的收起判定（替换现在按 `x > 372` 判断的方式）：

```swift
public enum DockClickTarget: Equatable, Sendable {
    case dock, drawer, phone, auxiliary, sheet, modal
}
public func shouldDismissOnClick(target: DockClickTarget) -> Bool
```

- `.dock` / `.drawer` / `.auxiliary` / `.sheet` / `.modal` → 不收起；`.phone` → 收起。
- 扫码 `ScannerPanel`、底胶囊面板都归为 `.auxiliary`，避免扫到一半或点截图时抽屉消失。

## 文件改动

### 新增 Core

| 文件 | 职责 |
|---|---|
| `Sources/UITestBenchCore/FloatingPanelLayout.swift` | 上面三个面板的屏幕坐标计算 |
| `Tests/UITestBenchCoreTests/FloatingPanelLayoutTests.swift` | 坞/胶囊/抽屉定位、夹边、无抽屉、负空间 |
| `Tests/UITestBenchCoreTests/PhoneLayoutTests.swift`（改） | 新增按外框算布局、最大尺寸、默认尺寸 |
| `Sources/UITestBenchCore/PhoneLayout.swift`（改） | `layout(frameSize:)` / `frameSize(forScreenWidth:)` / `maximumScreenWidth` |
| `Sources/UITestBenchCore/DockDrawerState.swift`（改） | `DockClickTarget` 与新的收起判定 |
| `Tests/UITestBenchCoreTests/DockDrawerStateTests.swift`（改） | 新判定；旧的 372pt 用例替换 |

### 新增 App

| 文件 | 职责 |
|---|---|
| `Sources/UITestBenchApp/AppModel.swift` | 全应用唯一的 ObservableObject：模型、状态、动作 |
| `Sources/UITestBenchApp/Design/PhoneWindowView.swift` | 手机窗口内容：`PhoneFrame` + 画面/待机屏/安装向导，承载现有生命周期 `.onChange` |
| `Sources/UITestBenchApp/Design/BenchPanel.swift` | `NSPanel` 子类 + `NSHostingView` 宿主 + 尺寸回报 |
| `Sources/UITestBenchApp/Design/FloatingPanelsController.swift` | 创建/挂载三个面板、定位、跟随缩放、显隐、主题、外点收起 |
| `Sources/UITestBenchApp/Design/WindowDragArea.swift` | `NSViewRepresentable`：在面板空白处按下后，按屏幕坐标增量移动手机窗口（不要用跨窗口的 `performDrag`，它在面板自己的窗口上启动拖动） |
| `Sources/UITestBenchApp/Design/DockPanelView.swift` | 坞面板根视图（胶囊 + 交通灯 + 模块 + 主题/置顶） |
| `Sources/UITestBenchApp/Design/DrawerPanelView.swift` | 抽屉面板根视图（`DockDrawer` + 尺寸回报 + hover 桥接） |
| `Sources/UITestBenchApp/Design/CapsulePanelView.swift` | 底胶囊面板根视图（`ActionCapsule` + 显隐回报） |

### 修改

| 文件 | 改动 |
|---|---|
| `Sources/UITestBenchApp/UITestBenchApp.swift` | 持有 `AppModel`；`WindowGroup` 内容改 `PhoneWindowView`；去掉 `minWidth 1000/minHeight 700`；⌘W 直接走退出流程 |
| `Sources/UITestBenchApp/Design/BenchWindow.swift` | 手机窗口 borderless + 缩放比例锁定 + 尺寸持久化（新 autosave 名）；持有 `FloatingPanelsController`；最小化/适应屏幕/置顶同时作用于面板 |
| `Sources/UITestBenchApp/Design/DockRail.swift` | 改为胶囊：宽度 68、高度自适应、`surfaceOpaque 0.92` + 材质；去掉左侧选中竖条；保留交通灯与底部工具键 |
| `Sources/UITestBenchApp/Design/DockDrawer.swift` | 删除 `DockColumn`；`DockMetrics` 改为新尺寸；卡片宽度 292、最大高 560、内容高度回报；卡片位置由面板控制器负责 |
| `Sources/UITestBenchApp/Design/BenchControls.swift` | 绿点行为改为「适应屏幕」；文案/help 同步 |
| `Sources/UITestBenchApp/Design/DockModel.swift` | 外点监视改成按窗口身份判定；外部点击回调由面板控制器注入 |
| `Sources/UITestBenchApp/Scanner/ScreenScannerModel.swift` | `start(from:)` 明确传手机窗口；`resolveMainWindow` 跳过 `BenchPanel` |
| `Sources/UITestBenchApp/Setup/SetupStage.swift`（删） | 安装向导并入手机窗口内容 |
| `Sources/UITestBenchApp/Design/PhoneStage.swift`（删） | 拆分逻辑进 `PhoneWindowView` / 胶囊面板 |
| `README.md`、`CLAUDE.md`、`docs/architecture.md` | 主窗口描述、文件表、版本 |
| `project.yml`、`Scripts/package.sh` | 版本号（建议 1.4.0，主窗口形态变更） |

### 删除

- `DockColumn`、`PhoneStage`、`SetupStage`（`SetupScreen` 保留，装进手机屏）。
- `DockMetrics.columnWidth/drawerSlotWidth/drawerTopInset`。

## 里程碑

### M0 — 技术验证（不写产品代码）

**实测结论（2026-10-23，/tmp/uitestbench-m0）：**

- 无边框窗口 `canBecomeKey/canBecomeMain` 默认 **false**；`NSWindow` 子类覆盖后正常。
- 无边框 + `.resizable` 从边缘拖动缩放 **可用**；`contentAspectRatio` 生效（右边缘拖动会同时改变 `origin.y`）。
- 无边框窗口 `miniaturize` **无效**（有标题栏的对照窗口有效）。
- `addChildWindow` 的子面板随主窗移动（位移完全一致）；父窗 `orderOut` 时子面板一起隐藏。
- `NSPanel` 子类覆盖 `canBecomeKey` 后能成为 key；TextField 能拿到 field editor。
- 合成鼠标事件需要把拖动事件先 `NSApp.postEvent` 再送 `mouseDown`，否则原生缩放循环会阻塞。

因此 **主窗改为 AppDelegate 手工创建的 `PhoneWindow: NSWindow`**（borderless、resizable、override `canBecomeKey/Main`）+ `NSHostingView`；SwiftUI `App` 只保留 `Settings` 场景与 commands。`applicationShouldTerminateAfterLastWindowClosed` 改为 false，关闭统一走显式 `NSApp.terminate`（否则「隐藏窗口」会被当成最后一个窗口关闭而退出）。

原验证项保留作记录：

1. borderless + resizable 的窗口能否从边缘缩放、能否 `miniaturize`，以及**能否成为 key window**（`canBecomeKey` 对无标题栏窗口默认可能为 false）。若 `WindowGroup` 的窗口改 styleMask 后收不到键盘，M3 改为 AppDelegate 手工创建 `PhoneWindow: NSWindow` 子类（override `canBecomeKey`/`canBecomeMain`）+ `NSHostingView`，`WindowGroup` 只保留 commands。
2. `addChildWindow` 的子面板是否随主窗口移动；主窗口最小化/恢复时子面板是否跟着；父窗关闭时子面板会不会残留。
3. 普通 borderless `NSPanel` 与 `.nonactivatingPanel` 两种写法里，SwiftUI `TextField` 点击后能否输入、`becomesKeyOnlyIfNeeded = true` 时普通按钮是否不抢焦点、App 未激活时点坞是否激活 App。
4. 子面板上的 `.onHover` 在鼠标跨窗口移动时是否正常触发（坞 → 抽屉的 250ms 桥接）。

任何一条不成立，先改方案（例如最小化改用隐藏窗口 + 菜单栏恢复），不要带着风险往下做。

### M1 — Core 几何与收起判定（严格 TDD）

1. 先写 `FloatingPanelLayoutTests` / `PhoneLayoutTests` 新用例 / `DockDrawerStateTests` 新用例，确认 RED 原因正确。
2. 实现 `FloatingPanelLayout.swift`、`PhoneLayout` 新函数、`DockDrawerState` 新判定。
3. `swift test --filter FloatingPanelLayoutTests`、`--filter PhoneLayoutTests`、`--filter DockDrawerStateTests` 全绿。

### M2 — AppModel 上提（不改视觉）

1. 新建 `AppModel`，把 `ContentView` 的 `@StateObject` 与 `@State` 搬进去；`ContentView` 改名 `PhoneWindowView` 并改成 `@ObservedObject var app: AppModel`。
2. 所有抽屉/胶囊改用 `app.xxx`，`$binding` 换成 `app.$xxx`。
3. `swift build` + 现有 `swift test` 全绿；手工确认功能与 1.3.0 一致。

### M3 — 手机主窗口 + 坞/胶囊面板

1. `BenchWindow` 改成 borderless 手机窗口：content = `PhoneFrame`，比例锁定，最小/最大尺寸，新的尺寸持久化。
2. `PhoneWindowView` 只渲染手机（画面 / 待机屏 / 安装向导）。
3. `BenchPanel` + `FloatingPanelsController`：创建坞与胶囊面板，`addChildWindow`，按 `FloatingPanelLayoutCalculator` 定位；监听手机窗口的 `didMove` / `didResize` / `didChangeScreen`、`didMiniaturize` / `didDeminiaturize` 和 `NSApplication.didChangeScreenParametersNotification` 重排（移动时子窗口会自动跟，重排只需要在尺寸/屏幕变化时做）。
4. `WindowDragArea`：坞面板空白处、手机边框可拖动整套；面板自身不移动。
5. 手工验收：拖动任意一块整体移动；拖边缘等比缩放手机，坞与胶囊重新吸附；最小化/恢复。

### M4 — 抽屉面板移到左侧

1. `DrawerPanelView`：卡片宽度 292、高度按内容、最大 560；面板尺寸随内容回报更新。首次弹出时先用该模块上次测到的高度（没有就用 300）定位，测量回调到达后再无动画地修正，避免高度从 0 跳一下。
2. 位置由 Core 计算：坞左侧 12pt、垂直居中于坞、夹边。换模块导致高度变化时同样不做位移动画，只让卡片内容淡入。
3. hover 桥接：坞项进入 150ms 展开；坞 ↔ 抽屉之间的 250ms 收起沿用 `DockModel`。
4. 钉住、Esc、点手机/其他面板收起：改用 `DockClickTarget` 判定；扫码面板与 sheet 排除。
5. 面板显隐用 `alphaValue` 过渡：`presented` 变 nil 时先 0.12s 淡出再 `orderOut`；hosting view 由控制器持有的「最后一个模块」驱动，不在视图里直接读 `dock.presented`，否则淡出期间内容会先消失。
6. 手工验收：从坞划到卡片不会闪；点卡片内按钮/输入框正常；Esc 收起；钉住后点手机收起。

### M5 — 视觉与深色对比

1. `DockRail` 改胶囊：宽 68、内容自适应高度、圆角胶囊、`surfaceOpaque.opacity(0.92)` + 材质 + 描边 + 阴影；交通灯顶部 40pt；模块项 56×52；底部主题/置顶圆形键。
2. 去掉选中项左侧 3pt 竖条，只保留 lime 底 + `limeInk` 文字（沿用现配色；`limeInk` 在浅色下是深橄榄、深色下是亮黄绿）。
3. 面板 `appearance` 跟随主题；确认深色模式下坞、卡片、胶囊的字/图标在任何壁纸下都可读（浅灰 #A1A1A6 对 #1C1C1E 实底）。
4. 绿点改「适应屏幕」：当前尺寸 ↔ 最大适配尺寸切换。
5. 手工在浅色/深色、亮/暗桌面上各过一遍。

### M6 — 收尾

1. 更新 `README.md`、`CLAUDE.md`、`docs/architecture.md` 的主窗口描述与文件表。
2. `project.yml` 版本 1.4.0 / build 递增；`Scripts/package.sh` 默认版本。
3. `xcodegen generate`、`swift test`、`Scripts/package.sh 1.4.0`。
4. macOS 12.3+ 实机验收（这是硬性要求，不能用“只用了 12.3 API”代替）。

## 关键细节与已知坑

- **子面板焦点**：坞/胶囊面板 `becomesKeyOnlyIfNeeded = true`，点模块按钮不抢手机窗口的 key；抽屉面板同理，点文本框时才成为 key。镜像键盘输入依赖 `MirrorDisplayView` 是 key window 的 first responder（[MirrorModel.swift:157-225](../../../Sources/UITestBenchApp/MirrorModel.swift#L157-L225)），输入框聚焦期间收不到键盘是预期行为，点手机即恢复。
- **外部点击**：`addLocalMonitorForEvents` 只看得到本 App 的事件；点击桌面本来就不会收起（沿用现状）。判定只看 `event.window` 是不是坞/抽屉/扫码面板/sheet，彻底丢掉 372pt 坐标假设。
- **扫码窗口**：`resolveMainWindow` 现在会拿 `NSApp.keyWindow`；抽屉成为 key 后会选错窗口。改为显式传手机窗口，并跳过 `BenchPanel`。
- **面板尺寸反馈**：卡片高度由头部 + 内容实测决定。用一个 `PanelSizeReporter`（GeometryReader + 变化回调）回报，尺寸差 < 0.5pt 不更新，避免 setContentSize ↔ 布局的循环。
- **抽屉夹边**：屏幕左侧空间不足时按 Core 规则夹到 `visibleFrame.minX + 8`，允许压住坞；不翻到右侧（用户明确要左侧）。
- **最小化**：borderless 窗口没有最小化按钮，`miniaturize` 很可能无效。M0 验证；不可用则黄点改为「隐藏窗口」，并在 `applicationShouldHandleReopen` 里恢复手机窗口与三个面板（点 Dock 图标回来），不引入全屏。
- **窗口阴影**：手机窗口仍设 `hasShadow = true`（系统会按内容 alpha 生成形状阴影）；M0 检查圆角处有没有出现方形底影。若出现，改成 `hasShadow = false` + 在 `PhoneFrame` 外用 SwiftUI 画阴影，并相应调整窗口内容与布局的尺寸关系。
- **退出**：面板是独立窗口且只 `orderOut` 不 `close`，`applicationShouldTerminateAfterLastWindowClosed` 可能不再触发。手机窗口的 `windowShouldClose` 与 ⌘W、红点统一走 `NSApp.terminate(nil)`，先由 `ShutdownCoordinator` 清理再退出；不要依赖「最后一个窗口关闭」的推断。
- **窗格身份**：`DockClickTarget` 需要一个从 `event.window` 到 `dock/drawer/phone/auxiliary` 的映射，由 `FloatingPanelsController` 注入（持有三个 `BenchPanel` 引用 + 手机窗口弱引用）；`DockModel` 不再知道任何坐标。
- **绿点语义变更**：原来绿点是 macOS 全屏；透明无边框的手机窗口进全屏会变成一块黑底，所以计划改成「适应屏幕」。这是本计划的主动决定，若仍要保留全屏需要另做全屏画布方案。
- **换机型/自定义分辨率**：手机外框比例变化时，控制器要更新 `contentAspectRatio` 并把窗口夹到当前屏幕可容纳的尺寸，再重排三个面板。
- **缩放锚点**：程序化改尺寸（适应屏幕、换机型、恢复上次尺寸）时保持手机上边缘 `maxY` 不动，视觉上手机从顶部往下长；坞顶部对齐不会跳。
- **尺寸迁移**：旧 autosave 名 `UITestBench.MainWindow` 存的是 1120×780 大窗，必须换新名（如 `UITestBench.PhoneWindow`），并把恢复出的尺寸夹到当前屏幕可用范围。
- **窗口位置夹取**：坞在手机左侧、胶囊在手机下方，手机窗口贴边时它们会跑出屏幕。移动/恢复/缩放时把手机 frame 夹到「左侧留出坞宽 + 间距、下方留出胶囊高 + 间距、四周留出阴影」的安全区（`visibleFrame` 内）；抽屉空间不够时按上面的夹边规则处理。屏幕太小放不下时优先保证手机与胶囊可见，坞允许被压缩到屏幕内。
- **启动安装阶段**：`setup.phase != .ready` 时手机窗口显示 `SetupScreen`，坞面板保留（可看诊断/设置），胶囊面板隐藏。

## 验证

```bash
cd /Users/jarvis/uitestbench-worktrees/ui-1-3-0
swift build
swift test                                   # Core 全部用例
swift test --filter FloatingPanelLayoutTests
swift test --filter PhoneLayoutTests
swift test --filter DockDrawerStateTests
xcodegen generate
Scripts/package.sh 1.4.0                      # 出 DMG
```

手工验收清单（浅色 + 深色各一遍，亮桌面 + 暗桌面）：

1. 启动后只有手机、左侧坞胶囊、下方胶囊；没有可见窗口边框/大画布。
2. 拖动手机边框、坞空白处、胶囊空白处：三块整体移动，相对位置不变。
3. 拖手机边缘：等比缩放，坞/胶囊/抽屉始终吸附；窗口位置记住。
4. 悬停坞项 150ms：卡片从坞**左侧**滑出，垂直居中于坞；移开 250ms 收起；从坞划到卡片不闪。
5. 点击坞项钉住；点手机、点其他面板收起；Esc 收起；点卡片内按钮/输入框正常。
6. 深色模式下坞的全部图标/文字、交通灯、底部工具键清晰可读；浅色同理。
7. 启动设备、运行 APK、截图、标注、扫码全链路不回退。
8. 最小化/恢复、置顶、适应屏幕、多显示器拖动、退出清理流程正常。
9. 全新安装路径（无 SDK）下手机屏显示安装向导，坞可用，胶囊隐藏。

## 风险

1. **borderless 窗口的系统行为**（最小化/缩放/阴影）—— M0 先验证，失败则调整载体（隐藏式最小化）。
2. **多面板焦点与文本输入** —— `becomesKeyOnlyIfNeeded` + 点击手机恢复键盘；M0 验证。
3. **子窗口跟随** —— 只依赖 `addChildWindow` 的自动移动，缩放/换屏用通知重排；不要求子窗口自己可拖动。
4. **面板尺寸反馈环** —— 尺寸回报加阈值，抽屉高度上限 560。
5. **改动面大** —— M2 先做纯状态上提，保持行为不变；M3/M4 再动窗口载体，出问题时可以单独回退里程碑。

## 执行记录（2026-10-23）

### 实际结果

- 1.4.0 实现了本计划的全部里程碑；1.4.1、1.4.2 是同一线的补丁，最终发布版本为
  **1.4.2 / build 13**（tag `v1.4.2`，main `1b9e75f`）。
- DMG：`dist/UI验收台-1.4.2.dmg`，2.2 MB，SHA-256
  `ddea389798f589786e48c58c607f229c8d03b63e604aafa33eae52515d8ca8e1`。
- `swift test`：590 通过 / 30 skip / 0 失败；`TeamDeviceKeyProvisionerTests` 11 通过。

### 与计划的偏差

| 项 | 计划 | 实现 |
|---|---|---|
| 面板阴影留白 | `shadowPadding = 18` | **40**（以 `FloatingPanelsController.shadowPadding` 为准） |
| 手机窗口载体 | 先试 `WindowGroup` 改 styleMask | M0 判定不行，改为 AppDelegate 手工创建 `PhoneWindow` + `NSHostingView` |
| 黄点行为 | 最小化 | 无边框窗口 `miniaturize` 无效，改为「隐藏窗口」，点 Dock 图标恢复 |
| 版本 | 1.4.0 | 1.4.0 → 1.4.1 → 1.4.2（扫码下载页修复） |

### 1.4.1 / 1.4.2 补丁

- `DownloadedContent` 按内容判包 / 网页；桌面 UA 只拿到网页时用手机 UA 重试。
- `APKPageLink` 从落地页找 `.apk` 直链并带正确 `Referer`；仍只有网页时给出「在浏览器中打开链接」。
- `APKPageDetail` 处理 JS 空壳下载页（`/content-web/download.html?id=…` → `/content-web/app/detail.do` → JSON 的 `downloadUrl`）。

### 尚未完成

- 在应用里用开发提供的那张二维码复测 1.4.2 的完整链路（扫码 → 面板 → 下载）。
- 真实 macOS 12.3 机器、多显示器、亮 / 暗桌面壁纸下的观感。
- 1.4.0 线已在开发机手工过：整组拖动、等比缩放后吸附、抽屉左侧居中、Esc / 钉住、深浅色可读、适应屏幕、黄点隐藏与 Dock 恢复、置顶、三键导航条消失；完整清单见 [docs/acceptance-testing.md](../../acceptance-testing.md) 的验收记录。
