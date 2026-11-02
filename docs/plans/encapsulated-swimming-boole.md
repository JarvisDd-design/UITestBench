# UI验收台 v1 —— Mac 桌面 APK 运行与标注工具

## Context

原本的方案是一套带评分、对图、报告的完整「UI 自动验收」产品设计，P0 阶段是模拟数据原型。讨论下来，真正的痛点是另一件事：

**设计同事要核对一个安卓包的界面，就得先弄一台安卓手机、装包、截图、再把问题描述清楚。** 这个过程里，手机是瓶颈，截图是瓶颈，「问题说不清」也是瓶颈。

所以这一版不做对图、不做评分，只解决三件事：

1. 拿到包就能在桌面上跑起来，不用找测试机；
2. 鼠标能直接点，不用记 adb 命令；
3. 看到问题能当场圈出来、存成一张能发出去的图。

一句话：**把「看界面」这件事从手机搬到桌面，并且看完不留痕。**

---

## 需求确认结果

| # | 决策点 | 结论 |
|---|---|---|
| 1 | 对图 | 人眼核对，不做设计稿 diff、不做评分 |
| 2 | 标注 | 必须做：截图 → 冻结 → 标注 → 导出 |
| 3 | APK 来源 | **屏幕取景框实时扫码（1.2.0 已实现）** + 拖入二维码截图 + 粘贴链接 + 本地文件；可拖动的玻璃卡片、中央 320×320 透明取景区，出现后 2 秒准备再扫，只捕获取景区且不落盘 |
| 4 | 设备 | 本地模拟器，不做真机、不做云端 |
| 5 | 画面 | **自实现 scrcpy 服务端协议**，真内嵌、零权限、点击 10–20 ms |
| 6 | 系统镜像 | AOSP `default`，Android 14 / API 34，约 1 GB |
| 7 | 机型 | 3–5 个预设，共用一份镜像，可手改宽高与 DPI |
| 8 | 换机型 | 同一台虚拟设备改分辨率，重启生效 |
| 9 | 数据留存 | 退出即清业务数据；APK 仅会话内保留；启动自检清残留 |
| 10 | 复测 | 默认「清数据重开」，另给「完全重装」 |
| 11 | 标注工具 | 矩形、箭头、文字、画笔、颜色、撤销/重做；不做马赛克 |
| 12 | 标注产物 | 系统保存框显式保存 + 复制到剪贴板 |
| 13 | 下载源 | 支持自定义镜像地址，默认 Google |
| 14 | 鉴权 | 静态直链；预留全局 Token 请求头 |
| 15 | 分发 | `.dmg` 内含应用 + 「首次打开」脚本，不公证，仅 Apple 芯片 |
| 16 | 系统要求 | macOS 12 及以上 |
| 17 | 日志 | 折叠在「诊断」里，提供「复制诊断信息」 |
| 18 | 马赛克 | 不做（内部应用，明确取舍） |

---

## 画面方案：为什么是「自实现 scrcpy 协议」

这一块是本项目最大的技术决策，过程值得记下来，避免以后重走弯路。

**没有用 scrcpy 本体，是因为它嵌入不了。** scrcpy 自己创建一个 SDL 窗口，没有提供把画面交给别的应用的接口。把它的窗口抓下来贴进我们的视图，要付出三个代价：

1. 每个同事第一次打开都要授权「屏幕录制」，**而且每次发新版授权都会失效，要重新授权**；
2. macOS 12–13 的捕获 API 不接受屏幕外窗口，只能把 scrcpy 窗口压在我们主窗口底下当「底片」，**用户一拖动主窗口，底下那台手机就会露出来**；
3. 抓来的画面是只读的，用户点在我们的视图上，事件到不了 scrcpy，**点击还是得绕回 adb**——延迟和最简单的方案一样，等于白付上面两个代价。

**所以只用它的服务端，不用它的界面。** scrcpy 的跟手不是魔法，来自两件事：视频流不做缓冲、控制走常驻 socket。这两件事我们都可以自己做，代价是实现它那套协议。

换来的是：真内嵌、零权限、视频 50–80 ms、点击 10–20 ms，额外体积只有一个约 100 KB 的 jar。

---

## 首版做什么

- 首次向导：检测 / 下载 / 校验 Android 组件，支持暂停继续、断点续传、离线包导入、自定义镜像源
- 机型预设与自定义分辨率
- APK 来源：拖入二维码图片解码、粘贴链接下载、选择本地文件
- APK 解析：包名、应用名、版本、minSdk/targetSdk、ABI、启动 Activity
- 兼容性预检：架构不匹配、API 过高、拆分包、损坏包，全部给中文解释
- 启动模拟器 → 安装 → 启动，全程可见、可取消、失败有原因
- 内嵌实时画面 + 鼠标点击 / 拖拽 / 滚轮 / 键盘
- 清数据重开、完全重装、停止
- 截图 → 冻结 → 标注 → 保存 / 复制
- 退出清理与启动自检
- 诊断信息一键复制

## 首版不做什么

| 不做 | 原因 |
|---|---|
| 设计稿对图、diff | 下一版；本版只保证「能稳定拿到截图」 |
| 评分 / 通过判定 | 未经真实样本校准 |
| 真机、云手机 | 与「取消真机」的目标冲突；云端还有包外传的合规问题 |
| 多设备并行 | 单设备串行足够 |
| AAB / 拆分 APK / XAPK | 遇到时明确提示不支持 |
| 马赛克 | 已确认不需要 |
| 操作录制回放 | 依赖控件定位，风险高 |
| 自动更新 | 手动换版本即可 |

---

## 技术路线

### 1. 工程与依赖

- SwiftUI，**macOS 12 部署目标**，Swift 5 语言模式 + async/await
- 因为要支持 12：不用 `@Observable`、`NavigationSplitView`、`ContentUnavailableView`；用 `ObservableObject` + `@Published`，布局用 `HSplitView`
- **工程形态双轨，共用同一份源码树**：
  - Xcode 到位前：`Package.swift` + `swift build` / `swift test`（Command Line Tools 已具备）
  - Xcode 到位后：加 `project.yml`（XcodeGen），拿到 SwiftUI 预览与调试器
  - 两个工程都读 `Sources/`，切换时**源码一行不改**
- **零第三方库**，唯一的随包资源是 `scrcpy-server.jar`（约 100 KB，Apache-2.0，需在「关于」里保留版权声明）：
  - ZIP 自己读中央目录，解压用系统 `Compression` 框架
  - 二维码解码用系统 `CIDetector`（`CIDetectorTypeQRCode`）
  - 视频解码用 `VideoToolbox`，渲染用 `AVSampleBufferDisplayLayer`
- 抽象两个接口，保证画面方案可替换：
  ```swift
  protocol MirrorVideoSource: AnyObject {   // 产出 CMSampleBuffer
      var frames: AsyncStream<VideoFrame> { get }
      func start() async throws
      func stop() async
  }
  protocol MirrorInputSink: AnyObject {     // 注入点击/滚动/按键
      func tap(_ p: DevicePoint) async
      func drag(from: DevicePoint, to: DevicePoint, duration: Int) async
      func scroll(at: DevicePoint, dx: Int, dy: Int) async
      func key(_ code: AndroidKey) async
      func text(_ s: String) async
  }
  ```

### 2. scrcpy 协议实现（风险最高的一块）

**握手**

1. `adb push scrcpy-server.jar /data/local/tmp/`
2. `adb forward tcp:<p1> localabstract:scrcpy`（视频）、`tcp:<p2>`（控制）
3. `adb shell CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server <version> tunnel_forward=true audio=false control=true cleanup=true max_size=1920 max_fps=60`

**视频通道**

- 连接后依次读：设备名（64 字节）、编码器类型（4）、宽（4）、高（4）
- 之后每帧：PTS（8 字节）+ 长度（4 字节）+ 负载
- 首个包是 SPS/PPS，交给 `CMVideoFormatDescriptionCreateFromH264ParameterSets` 建解码会话
- 之后每包一个访问单元，封装成 `CMSampleBuffer` 送 `VTDecompressionSession`
- 输出 `CVPixelBuffer` → `AVSampleBufferDisplayLayer`

注意：H.264 流没有容器时间戳，PTS 来自协议头；设备旋转会改变宽高，必须重建解码会话。

**控制通道**

常驻 socket，二进制消息，按锁定的版本布局逐字段写入：

| 消息 | 用途 |
|---|---|
| `INJECT_TOUCH_EVENT` | 点击、按下拖动 |
| `INJECT_SCROLL_EVENT` | 滚轮 → 上下滑动 |
| `INJECT_KEYCODE` | 返回、Home、最近任务 |
| `INJECT_TEXT` | 键盘输入（仅 ASCII） |

**必须锁死的三件事**

1. **jar 与客户端实现成对发布。** 协议布局随版本变化（例如某版在触摸事件里加了 `actionButton`），不一致时表现为乱点或崩溃，很难排查。启动时校验服务端版本号，不匹配直接报错，不静默降级。
2. **断流必须重连。** socket 断开不能停在最后一帧，要自动重连并重建解码会话。
3. **保留降级开关。** 若协议实现在某些模拟器版本上不稳，把 `MirrorVideoSource` 换成基于 `screenrecord` 的实现（方案 A），上层视图与输入层不动。这条后路要在写代码时预留，不是出事再改。

### 3. 输入映射

- 视图坐标 → 设备坐标：按缩放比与留白偏移换算，旋转后重新计算
- 点击 → `INJECT_TOUCH_EVENT`（按下 + 抬起）
- 拖动 → 同一条消息连续发送，中间按帧插入移动事件
- 滚轮 → `INJECT_SCROLL_EVENT`
- 键盘 → `INJECT_TEXT`（仅 ASCII；中文输入是已知限制，见下）

### 4. SDK 自举（不依赖 Java）

`sdkmanager` / `avdmanager` 是 Java 工具，同事机器上不会有 JDK，因此完全绕开：

直接从 Google 清单解析版本与地址，下载 zip 解包：

- `https://dl.google.com/android/repository/repository2-3.xml` → platform-tools、emulator
- `https://dl.google.com/android/repository/sys-img/android/sys-img2-3.xml` → `system-images;android-34;default;arm64-v8a`

流程：下载到临时文件 → SHA-1 校验 → 解压到临时目录 → 原子换入。任一步失败可重试，不留半成品。

首次总下载约 **1.5–2 GB**（AOSP 镜像比带 Google 框架的省一半）。

目录全部收在自己的作用域内，便于清理：

```
~/Library/Application Support/UI验收台/
  sdk/            platform-tools、emulator、system-images
  avd/            通过 ANDROID_AVD_HOME 指向这里，不污染 ~/.android
  tmp/<session>/  会话临时目录，退出即删
```

### 5. 设备与机型

不做 `avdmanager`，直接生成 AVD 配置文件，关键键：

```
abi.type=arm64-v8a
image.sysdir.1=system-images/android-34/default/arm64-v8a/
tag.id=default
hw.lcd.width / hw.lcd.height / hw.lcd.density
hw.ramSize=2048
hw.keyboard=yes
hw.gpu.enabled=yes
hw.gpu.mode=auto
```

三个预设（共用同一份镜像，只改宽高与 DPI）：

| 预设 | 分辨率 | DPI |
|---|---|---|
| 小屏 | 1080 × 2340 | 420 |
| 主流 | 1080 × 2400 | 420 |
| 大屏 | 1440 × 3120 | 560 |

换机型 = 改 `config.ini` + 重启模拟器（20–40 秒），不新建设备、不多占磁盘。

启动用 `-no-boot-anim`；退出流程是「卸载 → 清数据 → 存快照 → 关闭」，这样下次冷启动靠快照 5 秒内起来，且快照里是干净的。

### 6. APK 来源

```swift
enum APKSource: Sendable {
    case localFile(URL)
    case remote(URL)          // 二维码或粘贴的链接
}
```

- 二维码：图片交给 `CIDetector`，只接受 `http/https` 载荷，否则提示「这张图里没有找到下载地址」
- 链接：先 HEAD 拿大小，再流式下载，显示进度，可取消
- 预留全局 Token：设置里填键值对，作为请求头附加
- 屏幕取景框扫码（1.2.0）：`ScreenScannerModel` + `ScreenRegionCapture`（ScreenCaptureKit，仅 12.3+）只捕获玻璃卡片中央 320×320 取景区，10 fps；面板出现后 2 秒准备期（捕获预热、`ScanSession` 不判定、光带不动），随后浅蓝光带开始扫；`ScanSession` 在 Core 里做识别、选最近码与连续两帧确认；命中后停扫、显示对勾 0.5 秒，再弹确认条，点「下载」才走 `APKAcquirer`（`.scanned` 策略）。捕获帧只在内存中识别，不写盘、不进日志

### 7. 解析与兼容性

纯 Swift，读 ZIP 中央目录 + 解析二进制 `AndroidManifest.xml`（AXML）：string pool（UTF-8 / UTF-16）、resource map、start element、属性类型。

要拿到：`manifest@package`、`versionCode`、`versionName`、`uses-sdk` 的 min/target、`application@label`、带 `MAIN` + `LAUNCHER` 的 activity、`lib/<abi>/` 目录名。

`application@label` 若是资源引用，**不猜**，显示「未知」，装完后用 `dumpsys package` 补齐。

```swift
enum CompatibilityIssue: Equatable, Sendable {
    case minSdkTooHigh(required: Int, device: Int)
    case noMatchingAbi(apk: [String])
    case splitApkUnsupported
    case manifestUnreadable
}
```

规则：`minSdk > 34` 阻断；有 `lib/<abi>` 但无 `arm64-v8a` 阻断；纯 Java/Kotlin 包放行。

### 8. 安装、启动、重置

- 安装：`adb install -r -t`
- 启动：`am start -W -n pkg/activity`，失败回退 `monkey -p pkg -c android.intent.category.LAUNCHER 1`
- 清数据重开：`pm clear` → 重新 start
- 完全重装：`uninstall` → `install` → start

错误必须翻译成人话，不能把 `INSTALL_FAILED_*` 甩给设计同事：

| 原始 | 用户看到 |
|---|---|
| `INSTALL_FAILED_NO_MATCHING_ABIS` | 这个包只带 32 位 ARM 库，Apple 芯片的模拟器装不了 |
| `INSTALL_FAILED_OLDER_SDK` | 这个包要求的 Android 版本比当前设备高 |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 设备上有同包名但签名不同的版本，先卸载 |
| `INSTALL_PARSE_FAILED_NO_CERTIFICATES` | 包没有签名或已损坏 |
| `INSTALL_FAILED_INSUFFICIENT_STORAGE` | 虚拟设备空间不足 |

### 9. 截图与标注

- 截图：`exec-out screencap -p`，拿到 PNG 后**立即冻结画面**
- 标注画布：矩形、箭头、文字、自由画笔、颜色选择、撤销/重做
- 产物：`NSSavePanel` 显式保存 + 「复制到剪贴板」
- 因为工具承诺退出即清，**标注产物必须由用户显式带走**，否则会出现「标了半天关掉就没了」

### 10. 数据不留存

清理发生在两处：

- **退出时**：卸载被测应用 → 清数据 → 删临时 APK → 删未导出的截图 → 存快照 → 关模拟器
- **启动时自检**：检查上次是否有残留（已安装的包、`tmp/` 里的文件），有就先清掉，再进入主流程

这是「不留存」唯一的兜底——任务管理器强杀一次，只靠退出钩子就破了。

保留的只有引擎本身（SDK、系统镜像、AVD、快照），因为那不是被测内容。

### 11. 分发

`.dmg` 里放三样：

```
UI验收台.app
首次打开.command      # xattr -d com.apple.quarantine，然后 open
使用说明.rtf
```

macOS 15 已经取消「右键 → 打开」的绕过方式，未公证应用会被直接拦住，必须进系统设置手动放行。脚本省掉这一步。

随包资源 `scrcpy-server.jar` 为 Apache-2.0，需在「关于」页保留版权与许可声明。

---

## 界面结构

单窗口，`HSplitView`，左边控制、右边手机。

**左栏（宽约 320，可拖拽）**

- APK 来源区：拖放区（支持 `.apk` 与二维码图片）、「粘贴链接」输入框、状态
- 包信息：应用名、包名、版本、大小、minSdk、ABI
- 兼容性结论：通过 / 阻断 + 原因
- 机型：三选一 + 自定义宽高 DPI
- 主按钮：随阶段变化（准备环境 / 启动设备 / 运行 / 停止）
- 运行中操作：清数据重开、完全重装、截图
- 底部折叠「诊断」：日志 + 复制诊断信息

**右栏**

- 手机外框（可开关，默认开）
- 实时画面，等比缩放
- 未运行时为空状态，说明「拖一个包进来开始」

**截图模式**

画面冻结，顶部浮出工具条（矩形 / 箭头 / 文字 / 画笔 / 颜色 / 撤销 / 保存 / 复制），其余区域变暗。

状态用文字 + 图标 + 颜色三重表达；空态、加载态、失败态都要有。

---

## 已知边界（必须让使用者知道）

1. **只支持 64 位原生库。** 只带 `armeabi-v7a` 的包装不上；纯 Java/Kotlin 包不受影响。
2. **模拟器不是真机。** 风控、Play Integrity、DRM、推送、相机、NFC 等可能与真机不同，个别应用会拒绝在模拟器运行。
3. **中文输入靠设备剪贴板。** 1.5.0 起中文可输入：Mac 侧输入法组字，提交后写设备剪贴板再补一次粘贴键（服务端不会自己发）。代价是覆盖设备剪贴板，密码框里粘贴会失败。ASCII 仍走 `INJECT_TEXT` 快路径。
4. **画面延迟约 50–80 ms，点击约 10–20 ms。** 静态核对无感，快速滑动可能有轻微拖影。
5. **macOS 12 未实测。** 代码层面只用 12 可用的 API，但需要在 12 的机器上跑一次才算数。

---

## 里程碑

| # | 内容 | 完成标志 | 估时 |
|---|---|---|---|
| M0a | CLT + SwiftPM 立工程，纯逻辑库骨架 + 空窗口 | `swift test` 通过，窗口能启动 | 1d |
| M0b | Xcode 到位后加 XcodeGen 工程 | `xcodebuild build` 成功，预览可用 | 0.5d |
| M1 | 首次向导 + SDK 下载（镜像源、续传、离线导入） | 从零装齐，断网可恢复 | 3d |
| M2 | AVD 生成、启动、快照、换分辨率 | 能起能关，换机型生效 | 2d |
| M3a | scrcpy 握手 + 解出第一帧 | 静态画面上屏 | 2d |
| M3b | 连续解码与渲染、旋转、断流重连 | 流畅播放，转屏正常 | 2d |
| M3c | 控制通道：点击、拖拽、滚轮、按键 | 鼠标操作准确 | 2d |
| M3d | 健壮性：版本校验、重连、降级开关 | 拔线/重连不崩 | 1.5d |
| M4 | 坐标映射与输入手感打磨 | 缩放、留白、旋转后仍准确 | 1.5d |
| M5 | APK 来源 + 解析 + 兼容性 | 二维码/链接/本地三条路都通 | 3d |
| M6 | 安装、启动、重置、错误翻译 | 五类失败都有中文解释 | 1.5d |
| M7 | 截图与标注 | 六种工具可用，能存能复制 | 3d |
| M8 | 清理与自检 | 强杀后重启能自愈 | 1d |
| M9 | 分发 | `.dmg` 在干净机器上双击可用 | 1d |

**约 24 个工作日**，单人。M3 系列占 7.5 天，是最可能超时的部分——协议细节只能靠真实设备反复试。

---

## 验证方式

### 自动化

```bash
xcodebuild test -scheme UITestBench -destination 'platform=macOS'
```

- `AXmlParser`：固定 fixture 断言 package / minSdk / targetSdk / launcher
- `ZipReader`：损坏包、空包、缺 manifest、zip64
- `CompatibilityChecker`：32 位阻断、纯 Java 放行、API 过高阻断
- `CoordinateMapper`：缩放、留白、旋转后的坐标换算
- `ControlMessageEncoder`：各类控制消息的字节布局（用固定版本的服务端做金标准）
- `ADBError`：各类 `FAILED_*` 的映射
- `AVDConfig`：生成的键集合完整，`image.sysdir.1` 指向已装镜像
- `Cleaner`：给定残留文件/包名，断言清干净
- **不写**界面快照测试

### 手工端到端（每版必跑）

在一台没装过 Android 任何东西的 Mac 上：

1. 双击 `.dmg` → 运行「首次打开」→ 应用能启动
2. 向导下载 → 中途断网 → 恢复续传
3. 拖入二维码截图 → 解析出链接 → 下载 → 显示包信息
4. 选机型 → 启动 → 画面出现在右侧 → 鼠标点击有反应
5. 换机型 → 分辨率变化 → 重新点仍准确
6. 截图 → 标注 → 保存 → 打开图片检查
7. 强制退出应用 → 重新打开 → 提示已清理残留 → 设备上确实没有那个包
8. 拖入一个只有 `armeabi-v7a` 的包 → 给出中文解释，不是 adb 日志

---

## 风险

| 风险 | 影响 | 应对 |
|---|---|---|
| scrcpy 协议随版本漂移 | 点了没反应或乱点 | 锁定 jar 版本、启动校验、不匹配直接报错 |
| 协议实现卡在某台模拟器上 | 画面出不来 | `MirrorVideoSource` 换成 screenrecord 实现，上层不动 |
| 断流不重连 | 停在最后一帧 | 心跳 + 自动重连 + 重建解码会话 |
| 公司包是 32 位 | 装不上 | 预检拦截并解释；后续再评估真机路径 |
| 应用检测模拟器 | 跑不起来 | 无解，只能说明；这是模拟器的固有边界 |
| AVD 配置键随版本变化 | 起不来 | 先真实启动校准一次，固化模板，提供「修复设备」 |
| macOS 12 表现 | 未知 | 代码只用 12 的 API，由你在 12 的机器上实测后反馈 |
| 未公证被 Gatekeeper 拦 | 打不开 | 首次打开脚本 + 说明文档 |

---

## 下一版怎么接

截图能力一旦稳定，对图只是在这条链上加一个视图：

1. **v1.1 对图**：选一张设计稿（本地图片），与当前截图并排 / 叠加 / 差异
2. **v1.2 检查点与复测**：把「页面 + 设计稿 + 截图」存成检查点，新包来了重跑
3. **v1.3 设计源**：接 Figma 导出或 API
4. **v1.4 规则检查**：安全区、点击区域、文本截断
5. **评分**：最后做，必须先用真实页面和人工标注校准

---

## 开工方式：Xcode 不在路上也能开工

Xcode 的安装需要 Apple ID 登录与两步验证，这一步只能你本人操作，我不碰你的账号。所以分工是这样：

**你做的（一次性，约 5 分钟操作）**

1. 登录 <https://developer.apple.com/download/all/>，搜索 Xcode，下载最新 `.xip`（约 3.5 GB）
2. 放到 `~/Downloads`

**我做的（拿到文件之后）**

1. 校验完整性 → 解压 → 移到 `/Applications` → `xcode-select --switch` → 同意许可 → 装首次运行组件 → 验证 `xcodebuild -version`
2. **不装 iOS 模拟器运行时**：本项目只做 macOS，装上会多吃 20 GB。当前 73 GB 可用空间，装了 macOS 开发环境后仍在安全区间

**你下载期间我同步开工**

Command Line Tools 已经装了（16.4），它自带 Swift 编译器和 SwiftPM。所以不必等：

```
Sources/
  UITestBenchCore/     纯逻辑库，可单测
  UITestBenchApp/      SwiftUI 界面
Tests/
  UITestBenchCoreTests/
Package.swift          先立这个
project.yml            Xcode 到位后再加
```

`swift build` / `swift test` 都不需要 Xcode。

第一周可以先做完这些不依赖界面调试的部分：

1. `AXmlParser` —— 二进制 XML 解析，最大的一块纯逻辑
2. `ZipReader` —— 中央目录 + `Compression` 解压
3. `CompatibilityChecker` —— 兼容性判定规则
4. `CoordinateMapper` —— 缩放、留白、旋转的坐标换算
5. `ControlMessageEncoder` —— scrcpy 控制消息的字节布局

代价是没有 SwiftUI 预览、没有断点，界面改一次要重编一次。所以**界面相关的 M7（截图与标注）尽量排到 Xcode 到位之后**。

Xcode 装好后补一个 `project.yml`，复用同一份 `Sources/`，源码一行不改。
