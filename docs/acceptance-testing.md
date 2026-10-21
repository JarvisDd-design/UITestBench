# 验收测试

分两层：默认的纯逻辑单测，和需要真实 SDK / 模拟器 / 样本 APK 的验收测试。后者默认整组 skip，不设环境变量时 `swift test` 只跑单测。

## 环境

| 变量 | 用途 |
|---|---|
| `UITESTBENCH_REAL_SETUP=1` | 打开真实环境用例 |
| `UITESTBENCH_SDK_DIR` | **支持目录**（其下是 `sdk/`、`avd/`），不是 `sdk/` 本身 |
| `APK_SAMPLE` | 样本 APK 的路径；仓库不附带 |
| `UITESTBENCH_TWO_AVDS=1` | 允许停掉主 AVD、另建一台全新的第二设备，跑跨设备用例 |
| `UITESTBENCH_KEEP_RUNNING=1` | 调试用：让「停止后立刻重启」用例在停止后不再启动，方便手工检查（该用例会因此失败） |

示例（把 `APK_SAMPLE` 换成本机实际的样本路径）：

```bash
export UITESTBENCH_REAL_SETUP=1
export UITESTBENCH_SDK_DIR="$HOME/Library/Application Support/UI验收台"
export APK_SAMPLE="/path/to/sample.apk"
```

要求：

- SDK 已装好（platform-tools、emulator、Android 14 AOSP arm64 镜像）；没有就先用应用向导装。
- `5554` / `5556` 端口空闲，先停掉工具里正在运行的设备和其它模拟器。
- 样本包 `com.qsnfrkgk.vdvfeh` 有隐私弹窗，按钮 resource-id 是 `com.qsnfrkgk.vdvfeh:id/btn_agree`。应用要等弹窗同意后才写 SSAID，读设备 ID 的用例会先点它。

## 跑生命周期验收

```bash
UITESTBENCH_REAL_SETUP=1 \
UITESTBENCH_SDK_DIR="$HOME/Library/Application Support/UI验收台" \
APK_SAMPLE="/path/to/sample.apk" \
swift test --filter RealAppLifecycleAcceptanceTests
```

9 个用例，默认 8 个跑、1 个跳过，约 3 分钟。每个用例自己启动 / 停止模拟器。

### 用例

| 用例 | 验证什么 |
|---|---|
| `testInstallLaunchClearDataAndUninstall` | 安装、启动到前台、清数据不卸载、卸载干净 |
| `testRunStartsWithTheFirstLaunchFlow` | 「运行」是真正的第一次打开，能看到隐私 / 引导页 |
| `testReportsTheDeviceIDTheAppSeesAndKeepsItAcrossRestart` | 读到 16 位 SSAID，停止 / 重启设备后不变 |
| `testTeamDeviceKeyProducesTheSharedDeviceID` | 自动写入团队密钥，样本得到 `10f5f004470a2797`，重启后不变 |
| `testWritingTheTeamKeyChangesTheDeviceIDToTheSharedOne` | 先用随机密钥启动得到别的 ID，再写团队密钥，ID 变成团队值 |
| `testAFreshDeviceGetsTheSameTeamDeviceID` | 全新第二台 AVD（随机 userdata）写入团队密钥后，得到同一个 ID；需 `UITESTBENCH_TWO_AVDS=1` |
| `testScreenshotCapturesTheCurrentFrame` | `screencap` 回来的是可解码 PNG，尺寸与机型一致 |
| `testScreenshotCanBeAnnotatedAndExported` | 标注后导出的图能解码、尺寸正确 |
| `testShutdownLeavesNothingOnTheDeviceOrDisk` | 退出清理后设备上没有包、临时目录为空 |

### 跨设备用例

```bash
UITESTBENCH_REAL_SETUP=1 \
UITESTBENCH_SDK_DIR="$HOME/Library/Application Support/UI验收台" \
APK_SAMPLE="/path/to/sample.apk" \
UITESTBENCH_TWO_AVDS=1 \
swift test --filter testAFreshDeviceGetsTheSameTeamDeviceID
```

它会停掉主 AVD，在 `/tmp/UITestBenchSecondDevice-<UUID>/` 下建第二台 AVD，端口 `5556`，`wipeData: true` 冷启动。第一次启动会多花 10–30 秒重启系统框架写团队密钥。teardown 会停止并删除临时目录。

## 其它真实环境套件

| 套件 | 前置 | 内容 |
|---|---|---|
| `RealEnvironmentAcceptanceTests` | `UITESTBENCH_REAL_SETUP=1` | 从零下载约 2 GB、安装、起模拟器；首次 10–20 分钟 |
| `RealEmulatorAcceptanceTests` | `UITESTBENCH_SDK_DIR` | 模拟器起停、换分辨率；首次建 AVD 约 1–3 分钟 |
| `RealScrcpyAcceptanceTests` | `UITESTBENCH_REAL_SETUP=1` | 握手、配置包、第一帧 |
| `RealMirrorAcceptanceTests` | `UITESTBENCH_REAL_SETUP=1` | 连续出帧、转屏、断流重连 |
| `RealControlAcceptanceTests` | `UITESTBENCH_REAL_SETUP=1` | 点击、拖动、滚轮、文字、返回键，断言在系统界面的真实变化上 |
| `RealApkAcceptanceTests` | `APK_SAMPLE` | 用真实 APK 验收解析 |
| `RealArchiveAcceptanceTests` | `APK_SAMPLE`、`PLATFORM_TOOLS_ZIP` | 真实归档解压 |
| `RealSdkRepositoryAcceptanceTests` | `SDK_REPO_DIR` | Google 清单解析，只断言结构不变量 |

## Xcode 工程

```bash
xcodebuild test \
  -project UITestBench.xcodeproj \
  -scheme UITestBench \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/uitestbench-xcodebuild
```

**不要把 `-derivedDataPath` 放在本项目的中文路径下。** Xcode 的测试运行器在中文 derived data 路径上会报 `Failed to create a bundle instance`，同一份测试 bundle 用 `xcrun xctest` 直接跑却正常。用 `/tmp` 下的 ASCII 路径。

## 清理

- 正常结束：用例会卸载样本包、停止模拟器、删除自己创建的临时目录。
- 测试失败：先确认没有残留的 `emulator` 进程、`emulator-5554/5556` 设备、`/tmp/uitestbench-*`、`/tmp/UITestBenchSecondDevice-*`。
- 不要把用户选的原始 APK 或离线归档当成临时文件删掉。

## 已知环境怪癖

- **框架重启后 `sys.boot_completed` 不会清零**，不能用它判断系统是否恢复；要等 `pm path android` 返回 `package:` 且 `settings get secure android_id` 非空。
- **AOSP 14 镜像上 `INJECT_SCROLL_EVENT` 无效**，滚轮走 `DragScrollSink` 的合成拖动；相关验收断言的是真实位移。
- **应用锁竖屏时转屏只是信箱式适配**，不要设计依赖应用横屏布局的真机用例；转屏映射用单测 + 视频尺寸变化验证。
- **macOS 12 尚未实测**：代码只用了 macOS 12 可用的 API，仍需在真实的 macOS 12 机器上跑一次安装、启动、模拟器与截图链路。

## 验收记录

- 2026-10-21：`swift test` 与 `xcodebuild test` 全绿，真实环境用例如期 skip；生命周期套件默认 8 个用例通过，约 3 分钟；单独开启 `UITESTBENCH_TWO_AVDS=1` 后，全新第二台 AVD 冷启动写入团队密钥也得到同一个 `10f5f004470a2797`；1.1.0 与 1.1.1 DMG 已打包。
