# 1.5.0 镜像延迟与中文输入优化方案

日期：2026-11-02
状态：与老大逐条确认（Q1–Q18），待开工
对应版本：1.5.0

## 结论先行

老大提的三件事，是两个根因加一个独立的能力缺失：

1. **卡顿（现象 1）与不跟手（现象 2）是同一个根因**：镜像链路的「不丢帧串行解码 + 无时基显示」，叠加「大屏机型 1.7 倍像素的软编码在抢设备 CPU」。症状会表现为**延迟随时间累积**，不是恒定延迟。
2. **中文输入（现象 3）是两层缺失**：客户端 `KeyboardInput` 硬拦非 ASCII（源码层），AOSP 镜像里也没有中文输入法（镜像层）。只改任一层都不通。

## 依据（读码与时序事实）

| 事实 | 位置 |
|---|---|
| 「读一帧 → 同步解码 → 入队」串行循环，中途不丢帧、不看时间戳 | `Sources/UITestBenchCore/MirrorEngine.swift:119-170` |
| 每帧最多阻塞 2 秒等解码回调 | `Sources/UITestBenchCore/H264Decoder.swift:192` |
| 设备 pts 直接当 PTS，没有给 layer 设 timebase | `Sources/UITestBenchCore/VideoSampleBuffer.swift:23-27` |
| 入队前不检查 `readyForMoreMediaData`，队列只进不出 | `Sources/UITestBenchApp/MirrorModel.swift:264-269` |
| 流参数 1920/60，未传 `video_bit_rate`（服务端默认 8 Mbps） | `Sources/UITestBenchCore/ScrcpySession.swift:18-19`、`Sources/UITestBenchCore/ScrcpyServerCommand.swift:31-55` |
| 控制消息在主线程持锁阻塞写 | `Sources/UITestBenchCore/ScrcpyInputSink.swift:108-124`（调用方 `Sources/UITestBenchApp/MirrorModel.swift:176-187`） |
| 键盘只放行 `0x20…0x7E` | `Sources/UITestBenchCore/KeyboardInput.swift:58-61` |
| 服务端有 `TYPE_SET_CLIPBOARD` / `TYPE_ACK_CLIPBOARD` / `setPrimaryClip` / `CLIPBOARD_TEXT_MAX_LENGTH`；无 `keyboard=` 启动参数，但控制层有 `UhidManager` / `TYPE_UHID_INPUT` | jar（5.0.1，733,930 B，sha256 `764eb6f7…c536`） |
| 服务端支持 `video_bit_rate` / `video_codec_options` / `max_fps` | 同上 |
| 本机 AVD 实际是「大屏」1440×3120 @560dpi，`-gpu host` 已生效（Apple M3 / Metal），非软渲染 | `Sources/UITestBenchCore/DeviceProfile.swift:19`、`Sources/UITestBenchCore/EmulatorController.swift:35-44` |
| 镜像里只有 `com.android.inputmethod.latin`，无拼音包 | AVD system.img（android-34/default/arm64-v8a） |

## 已定决策

| # | 决策 | 结论与理由 |
|---|---|---|
| D1 | 归因方式 | 不靠体感。先做测量再改代码，「延迟随时间增长」是判定链路问题的唯一硬证据 |
| D2 | 验收口径 | 拖动列表 10 秒镜像 p95 帧间隔 ≤ 33ms；滑动停下 150ms 内追上设备；「点一下到画面变化」p95 ≤ 120ms；连续 10 分钟延迟不漂移 |
| D3 | scrcpy jar | **不换**。中文走剪贴板不需要 uhid，只追加服务端已支持的启动参数，规避「jar 与控制消息布局必须成对」的风险 |
| D4 | 改动顺序 | 先算法（丢帧 / 时基 / 异步写）后参数（帧率、码率）。降参数救不了延迟累积 |
| D5 | 延迟 vs 帧率 | **保延迟**。待显示帧槽位深度锁死为 1，解不过来就丢旧帧。这是官方 scrcpy 客户端的世界观，也符合验收台「看此刻屏幕」的用途 |
| D6 | 编码档 | 两档，**对用户可见**（设计同事对帧率不陌生，需要的是影响说明而不是隐藏），切档即重连（弹「画面重连中」） |
| D7 | 大屏兜底 | 大屏机型默认走「流畅」档，standard 默认「清晰」档，用户可改 |
| D8 | 中文输入形态 | 画面内直接组字（`NSTextInputClient`），提交后走「写设备剪贴板 + `KEYCODE_PASTE`」。落地顺序是先打通底层通路，再做交互壳 |
| D9 | 剪贴板副作用 | 接受：会覆盖设备剪贴板、密码框等禁粘输入框失效；写进文档 |
| D10 | spike 兜底 | 若 `SET_CLIPBOARD` 线格式逆不出来，退回「往 AVD 装开源中文输入法 + 鼠标点虚拟键盘」（已获授权，仅本机、不上传、不进仓库）；装过 IME 的 AVD 标记为「非标准环境」 |
| D11 | 可观测 | 延迟 HUD 走隐藏快捷键 ⌥⌘L，不进正式 UI |
| D12 | 回归用例 | 60 秒冒烟进真机用例（`UITESTBENCH_LATENCY_ACCEPTANCE=1`，默认可 skip）；10 分钟长测留发版前人工跑 |
| D13 | 范围 | 「窗口不可见时挂起解码」**不做**，只记进后续 backlog，避免混在一起分不清功劳 |
| D14 | 文档 | `README.md:93`、`docs/architecture.md:63`、`docs/plans/encapsulated-swimming-boole.md:327`、`Sources/UITestBenchCore/KeyboardInput.swift:13` 四处「只支持 ASCII / 中文做不到」的说法必须同步；`KeyboardInput.swift:13` 那句「界面上会说明」是假的，一并修 |
| D15 | 版本 | 1.5.0（含新能力，不是纯修复）。走 `project.yml` + `Scripts/package.sh` 流程 |
| D16 | 环境 | 发布前需在老大的**真 macOS 12.3** 上验一遍，仓库约定不可绕 |

## 工作分解

### P0-0 最小可观测（0.5 天）

先做 HUD，因为**没有它拿不到基线**，而基线是后面所有参数的依据。

- 位置：`Sources/UITestBenchApp/MirrorModel.swift` 里 `MirrorDisplayView` 旁挂一个统计器
- 显示：解码 fps、待显示槽位是否被占用、帧年龄（帧 pts 与本机时钟差）、最近 100 帧的 p95
- 开关：`NSEvent` 本地监视器拦 ⌥⌘L（复用 `Design/DockModel.swift:113` 那套监视器写法）
- 验收：能在一屏内看到「延迟是否随时间变大」

### P0-1 基线测量（0.2 天）

- 起模拟器，跑样本 APK 主列表页，来回滑动 10 分钟
- 记录：起始 p95、10 分钟后 p95、槽位被丢弃帧数
- 产出：基线数字进本文档「基线」一节；同时验证「增长型 vs 恒定型」

### P0-2 链路改造（2 天）

三步，按顺序做，每步单独可验：

1. **单帧槽位（丢旧帧）**：`Sources/UITestBenchCore/MirrorEngine.swift` 把「解码」与「交给显示层」解耦，解码线程只往一个深度为 1 的槽位写，覆盖旧帧。解码队列不再等待显示。
2. **显示即入队**：`Sources/UITestBenchCore/VideoSampleBuffer.swift` 给帧加 `kCMSampleAttachmentKey_DisplayImmediately`，`Sources/UITestBenchApp/MirrorModel.swift:264-269` 改成 `requestMediaDataWhenReady` 拉取 + `readyForMoreMediaData` 判定，去掉「盲 enqueue」。
3. **控制通道写入挪出主线程**：`Sources/UITestBenchCore/ScrcpyInputSink.swift` 加串行写队列，主线程只入队不阻塞；锁仍在，但不再跨 IO 持锁。

验收：D2 的数字达标，且 HUD 上的帧年龄不随时长增长。

### P0-3 剪贴板 spike（0.5 天，可与 P0-2 并行）

- 目标：从 dex 里确认 5.0.1 的 `TYPE_SET_CLIPBOARD` 线格式（seq + paste 标志 + 文本长度前缀），实现 `setClipboardAndPaste(text)`
- 文件：`Sources/UITestBenchCore/ScrcpyControlMessage.swift`、`Sources/UITestBenchCore/ScrcpyProtocol.swift`
- 验证：一个独立脚本打通「写剪贴板 → `KEYCODE_PASTE`(279) → 设备输入框出现汉字」，再接进 App
- 失败即触发 D10 兜底

### P1-1 参数与档位（0.5 天）

- `Sources/UITestBenchCore/ScrcpyServerCommand.swift`：追加 `video_bit_rate`，码率随档位
- 新 `MirrorQualityMode`（`.smooth` 30fps/4Mbps、`.sharp` 60fps/8Mbps）放 Core，带纯函数 `arguments(for profile:)`，可单测
- 持久化照 `Sources/UITestBenchCore/ThemeMode.swift:14-16` 的 UserDefaults 样板
- UI 放 `Sources/UITestBenchApp/Design/SettingsDrawer.swift`，切档即重连并提示「画面重连中」
- 说明文案（已确认口径）：
  - **流畅（30fps）**：画面更跟手、更省 CPU，适合看布局和点击态。代价是细微动效的掉帧看不出来——真机只有三十几帧的转场，在这里会被抹平
  - **清晰（60fps）**：更接近真机的动效手感，适合验转场、拖拽、列表惯性。代价是延迟可能累积、编码器吃 CPU 更凶

### P1-2 中文输入（1.5 天）

- `Sources/UITestBenchApp/MirrorModel.swift` 里的 `MirrorDisplayView` 实现 `NSTextInputClient` 最小集：`insertText`、`setMarkedText`、`unmarkText`、`hasMarkedText`、`markedRange`、`selectedRange`、`firstRect(forCharacterRange:)`、`doCommandBySelector`
- `Sources/UITestBenchCore/KeyboardInput.swift`：ASCII 可打印字符仍走 `INJECT_TEXT`（快路径，与真机逐键一致）；非 ASCII 不再丢弃，交给组字回调用剪贴板通路
- `MirrorInputSink` 增加 `setClipboardAndPaste(text)`
- 已知限制写进文档：组字过程只在 Mac 侧可见（设备屏幕上不出现拼音），候选词由 Mac 输入法提供

### P1-3 用例（0.5 天）

- Core 单测：丢帧槽位策略、`MirrorQualityMode` 参数生成、`setClipboard` 字节编码（逐字节断言）、`KeyboardInput` 新分支
- 真机用例：`UITESTBENCH_LATENCY_ACCEPTANCE=1` 跑 60 秒，断言 p95 与「不漂移」
- 遵守仓库 TDD 约定：先红后绿

### P2 文档与发版（0.5 天）

- 同步 D14 那四处说法，补本文档链接
- `project.yml` 版本 1.5.0 / build 15，`Scripts/package.sh` 默认版本
- `docs/architecture.md` 补「丢帧策略」与「输入法双路」两段

合计约 **5.5 天**（不含老大真机验证与发版打包）。

## 验收

1. D2 四个数字全部达标（大屏机型在「流畅」档，standard 在「清晰」档各测一遍）
2. HUD 上帧年龄在 10 分钟内不增长
3. 中文：点击输入框 → 在画面上敲拼音 → 候选词出现 → 回车后设备输入框出现汉字
4. ASCII 打字手感与现状一致（无回归）
5. `swift test` 全绿；真机短测用例通过
6. 老大在真 macOS 12.3 上跑一遍

## 风险与回滚

| 风险 | 应对 |
|---|---|
| `SET_CLIPBOARD` 线格式逆不出来 | 触发 D10，退回装开源 IME；spike 放在最前面就是为了早暴露 |
| 丢帧让「跳帧」被误读成 bug | HUD + 文档说明；不提供关闭丢帧的开关（避免第二个状态源） |
| 30fps 档位掩盖真实掉帧 | 文案已明说，档位可切回「清晰」复核 |
| 切档重连打断测试 | 提示文案「画面重连中」，不做静默重连 |
| 改动互相污染、无法定位 | 按 P0-2 的三步顺序各自提交，每步都能单独回滚 |

## 不做什么

- 不换 scrcpy jar、不动 AVD 硬件参数与镜像（`DeviceProfile` 与团队统一设备 ID 那套零改动）
- 不做 uhid 键盘（B 方案用不上，风险收益不划算）
- 不做「窗口不可见挂起解码」（D13）
- 不引入第三方 Swift 依赖

## 基线

测量时间 2026-11-02，机器 Apple M3，AVD `uitestbench`（1440×3120、density 560、报告 60Hz，
`-gpu host`，Metal/OpenGL ES 3.0 翻译层）。拖动由用例通过控制通道以 60Hz `touchMove` 注入，
连续 60 秒；`adb shell input swipe` 不能用来测（每条命令之间有空档，量出来的是空档）。

| 项 | 实测 | 说明 |
|---|---|---|
| 到达帧率 | **14.0 fps**（839 帧/60 秒） | 帧间隔 p50 72.8 ms、p95 111.9 ms |
| 漂移 | 前 10 秒 p95 104.6 ms，后 10 秒 p95 111.7 ms | **恒定型，不是增长型**：60 秒里没有越跑越慢 |
| 分辨率影响 | 886×1920 → 14.6 fps；590×1280 → 14.8 fps；472×1024 → 14.8 fps | 与 `max_size` 无关 |
| 码率/fps 影响 | `smooth` 30fps/4Mbps → 12.4 fps；`sharp` 60fps/8Mbps → 14.6 fps | 与 `max_fps`/`video_bit_rate` 无关 |
| 客户端等待 | `readP50 = 95.9 ms`（等下一个包） | 时间全花在等设备发包 |
| 客户端解码 | `decodeP50 = 2.27 ms`、`decodeP95 = 3.29 ms` | 解码不是瓶颈 |
| headless vs 带窗口 | 14.3 fps vs 14.3 fps | `-no-window` 不是原因 |
| guest 分辨率降到 540×1170 | 14.5 fps | 合成分辨率不是原因 |
| guest 自身录制 | `screenrecord` 6.6 秒只有 **81 帧（12.2 fps）** | 独立的捕获路径同样只有 ~12 fps |
| guest CPU | 4 核里 296%/400% idle（mediacodec 38%） | 没跑满 |

**结论**：这一代开发机上的 AOSP 模拟器，画面（合成 + 编码）本身就只有 12–15 fps 的产出能力，
和我们的解码/显示链路无关（客户端解码 2 ms、等待 96 ms；连 `screenrecord` 自己也只有 12 fps）。
所以 D2 的「p95 ≤ 33 ms」在这台机器上不可能达到；它只能作为真机/更强设备上的门槛。

因此 `MirrorLatencyAcceptanceTests` 分两层断言：帧数下限（> 400，防「画面根本没动」）
和「不漂移」（后 10 秒 p95 ≤ max(前 10 秒 p95 × 1.5, 34 ms)）默认跑；绝对阈值
`p95 ≤ 33 ms` 只在传 `UITESTBENCH_LATENCY_TARGET_P95_MS=33` 时断言 —— 换到真机时补上这个变量。

P0-2 的三步改造（单帧槽位丢旧帧、`requestMediaDataWhenReady` 喂帧、控制通道写入挪出主线程）
在这个环境里**量不出差别**，因为设备根本不产帧。它们的价值要用 HUD 在真机上看，或者在
guest 能跑满 60 fps 的环境里回归。同理，D6/D7 两档编码在模拟器上也分不出高下（12.4 vs 14.6 fps
的差值在噪声里），只能靠真机手感判断。
