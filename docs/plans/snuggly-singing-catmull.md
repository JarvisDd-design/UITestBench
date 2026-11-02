# 恢复「返回键」：底胶囊图标 + ⌘[

## Context

被测应用有一个只在「按系统返回键退出应用」时出现的挽留弹窗。当前模拟器 AVD 设置了
`hw.mainKeys=yes`，系统不画屏幕内三键导航条；1.3.0/1.4.x 又把工具里的返回 / Home /
多任务按钮和 Esc/Delete 映射全部删掉了（`README.md` 已知限制），所以现在没有任何入口
能发 `KEYCODE_BACK`。

底层的返回能力其实一直都在：`AndroidKey.back = 4`，`MirrorInputController.pressKey` →
`DragScrollSink` → `ScrcpyInputSink` → scrcpy `INJECT_KEYCODE` 直通，真机用例
`RealControlAcceptanceTests.testTapOpensPageAndBackKeyReturns` 也覆盖了。缺口只在「怎么触发」。

用户已确认：用 **⌘[** 快捷键；运行时在 **底胶囊** 加一个图标返回按钮；只恢复返回；
先改源码，不升版本、不出 DMG。

## 方案

不恢复旧工具栏，也不改 AVD 导航栏。只在应用运行时给一个轻量入口：

1. 底胶囊 `.running` 状态新增 `chevron.backward` 图标按钮，悬停提示「返回（⌘[）」。
2. 应用内监听 ⌘[（输入框编辑中、sheet / 模态上不抢键），发送 `AndroidKey.back`。
3. Esc/Delete 维持现状，不映射返回，避免破坏抽屉收起和输入框退格。

## 实现（严格 TDD）

### 1. Core：按键翻译 + 判定政策

文件：`Sources/UITestBenchCore/KeyboardInput.swift`、
`Tests/UITestBenchCoreTests/KeyboardInputTests.swift`

- 给 `KeyboardInput.Modifiers` 增加 `.shift`。它**不放进** `.shortcuts`，普通文字输入仍由
  `characters` 本身决定大小写；记录 Shift 只是为了区分 ⌘⇧[。
- `action(for:modifiers:)` 在现有快捷键 guard **之前**加：
  ```swift
  if characters == "[", modifiers == .command {
      return .key(.back)
  }
  ```
  这样 ⌘⇧[ 不会误判成 ⌘[。
- 新增判定政策（放在同一文件，避免新增文件后还要重生成 Xcode 工程）：
  ```swift
  public enum DeviceBackShortcutDecision: Equatable, Sendable {
      case send
      case ignore
  }

  public enum DeviceBackShortcutPolicy {
      public static func decision(
          action: KeyboardAction?,
          modifiers: KeyboardInput.Modifiers,
          isEditingText: Bool,
          target: DockClickTarget
      ) -> DeviceBackShortcutDecision
  }
  ```
  规则：
  - 必须 `action == .key(.back)` 且 `modifiers == .command`；
  - `isEditingText` 为真 → `.ignore`；
  - `target` 为 `.sheet` / `.modal` → `.ignore`；`.phone` / `.dock` / `.drawer` /
    `.auxiliary` → `.send`（底胶囊属于 `.auxiliary`）。
- TDD 顺序：先加测试，政策先返回固定 `.ignore` 的 stub，跑
  `swift test --filter KeyboardInputTests` 确认 send 用例 RED 原因正确，再实现到 GREEN。
  用例：
  - `testCommandLeftBracketPressesBack`
  - `testCommandShiftLeftBracketIsNotBack`
  - `testShiftAloneStillTypesText`
  - `testBackShortcutSendsFromPhoneAndCapsule`
  - `testBackShortcutIsIgnoredWhileEditingText`
  - `testBackShortcutIsIgnoredOnSheetsAndModals`
  - `testBackShortcutRequiresExactCommandModifier`
  - `testOtherKeysAreNotBackShortcut`

### 2. App：把按键接到设备

文件：`Sources/UITestBenchApp/MirrorModel.swift`、`Sources/UITestBenchApp/AppModel.swift`、
`Sources/UITestBenchApp/Design/PhoneWindowView.swift`

- `MirrorModel`
  - 重新加回 1.4.x 删掉的：
    ```swift
    func pressKey(_ key: AndroidKey) {
        inputController?.pressKey(key)
    }
    ```
  - 新增 `@Published private(set) var canSendInput = false`，在 `attachInput` 成功 / 失败和
    `stop()` 里维护。不要只用 `case .streaming` 判断：控制通道可能单独失败，画面在但没有输入。
- `AppModel`
  - `startBackKeyMonitor()` 用 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`：
    - 用 `event.charactersIgnoringModifiers ?? event.characters ?? ""` 组装
      `KeyboardInput.action`（避免中文输入法 / 大小写改变字符）；
    - 用 `window.clickTarget(for: event.window)` 得到 `DockClickTarget`，交给
      `DeviceBackShortcutPolicy`；
    - `mirror.canSendInput == false` 时放行，不吞键；
    - `.send` 时调 `sendBackKey()` 并 `return nil`。
  - `sendBackKey()` → `mirror.pressKey(.back)`。
  - `backButtonPressed()` → `sendBackKey()`；手机窗口可见时
    `phoneWindow.makeKey()` + `makeFirstResponder(mirror.display)`，让下一次 ⌘[ 不用再点手机。
  - 把 `NSEvent → KeyboardInput.Modifiers` 的转换抽成 App 层小扩展（包含 Shift），
    `AppModel` 与 `MirrorDisplayView` 共用，删掉 `MirrorDisplayView.keyboardModifiers(for:)`。
- `PhoneWindowView.onAppear` 调 `app.startBackKeyMonitor()`，与 dock 的 Esc 监视器并列。
- 本地监视器只在应用激活时收键；手机窗口或底胶囊是 key 都能用。`MirrorDisplayView.keyDown`
  原有 `.key` 分支保留，作为监视器未安装时的兜底。

### 3. 底胶囊按钮

文件：`Sources/UITestBenchApp/Design/ActionCapsule.swift`、
`Sources/UITestBenchApp/Design/CapsulePanelView.swift`、
`Sources/UITestBenchApp/Design/BenchControls.swift`

- `BenchSecondaryButtonStyle` 增加 `horizontalPadding: CGFloat = 14` 参数；默认值不变，
  现有按钮不受影响。
- `ActionCapsule` 增加 `canSendBack: Bool`、`onBack: () -> Void`；只在 `.running` 分支、
  「运行中」状态之后插入：
  ```swift
  Button { onBack() } label: {
      Image(systemName: "chevron.backward")
          .frame(width: 14, height: 14)
  }
  .buttonStyle(BenchSecondaryButtonStyle(height: 28, horizontalPadding: 7))
  .disabled(!canSendBack)
  .help(canSendBack ? "返回（⌘[）" : "画面还没连上，暂时不能返回")
  .accessibilityLabel("返回")
  ```
- 胶囊与手机同宽：默认 300pt 屏宽内容约 286pt，最小 240pt 时约 226pt。运行态把
  `HStack(spacing:)` 收到 6，截图按钮 `horizontalPadding` 用 10，返回按钮约 28pt 宽，
  保证最小宽度不裁切。实现后在 300 / 240 两档实际看一遍，必要时再微调。
- `CapsulePanelView` 传 `canSendBack: app.mirror.canSendInput`、
  `onBack: { app.backButtonPressed() }`。

### 4. 文档

- `README.md`：功能表输入行加「返回（底胶囊图标 / ⌘[）」；改写已知限制里
  「1.3.0 起不再提供返回」那条，改成「Home / 多任务不提供；返回由底胶囊图标或 ⌘[ 触发；
  Delete / Esc 仍不映射返回」。
- `CLAUDE.md`：输入模块约定补一句：返回仍走 `INJECT_KEYCODE`，运行后由底胶囊图标 + ⌘[
  触发；Esc/Delete 仍不映射返回。
- 不改 1.3.0 历史计划；不升版本、不打包。

## 验证

- `swift test`（单元测试全绿；真实用例默认 skip）。
- `swift build`。
- 手动（`swift run UITestBenchApp` 或 Xcode）：
  1. 启动设备、装入并运行有挽留弹窗的包。
  2. 底胶囊出现返回图标；点击后应用收到返回，挽留弹窗出现。
  3. 点一下手机画面，按 ⌘[，同样出现弹窗；连按两次可测双击返回类逻辑。
  4. 在 APK 链接输入框里按 ⌘[，不应发返回；输入、退格正常。
  5. 抽屉打开时 Esc 仍收起；Delete 仍退格（回归）。
  6. 手机缩到最小宽度（240pt 屏宽）看胶囊不裁切；默认 300pt 再看一次。
- 可选真机回归（约 3 分钟）：
  ```bash
  UITESTBENCH_REAL_SETUP=1 \
  UITESTBENCH_SDK_DIR="$HOME/Library/Application Support/UI验收台" \
  APK_SAMPLE="/path/to/sample.apk" \
  swift test --filter RealControlAcceptanceTests/testTapOpensPageAndBackKeyReturns
  ```

## 边界与风险

- 扫码浮层也归 `.auxiliary`；扫码时按 ⌘[ 会把返回发给设备。若觉得干扰，后续可在
  监视器里加 scanner 状态判断。
- 控制通道失败时 `canSendInput` 为 false，按钮置灰、⌘[ 放行，不会吞键。
- 不改 AVD 的 `hw.mainKeys`，不恢复屏幕内三键导航条；不恢复 Home / 多任务。
- 工作树里已有未提交的文档改动（`CLAUDE.md`、`README.md`、`docs/acceptance-testing.md`、
  1.3.0 计划）；本次在其上追加，不覆盖、不提交。

## 不做

- 不发版、不出 DMG、不提交 commit（等用户先验证手感）。
- 不恢复 Esc / Delete → 返回。
