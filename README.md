# UI验收台

公司内部 macOS 工具：把 Android APK 跑在本地模拟器里，用鼠标直接操作，看到问题就截图圈出来，导出一张能发给开发的图。

不找测试机、不记 adb 命令、退出不留业务数据。

- 当前版本：**1.4.2**（2026-10-23）
- 系统要求：macOS 12.3 及以上，**仅 Apple 芯片（arm64）**
- 分发方式：内部 `.dmg`，不做 Apple 公证，靠包内的「首次打开.command」绕过 Gatekeeper
- 不对外发布，不上传 APK 到任何第三方服务

## 功能

| 范围 | 已实现 |
|---|---|
| 界面 | 只有手机画面本身：无边框、可等比缩放的手机窗口，左侧悬浮坞胶囊（素材 / 设备 / 应用 / 诊断 / 设置）与下方操作胶囊都吸附在手机旁；悬停坞项时卡片从坞左侧弹出，可点击钉住，Esc 收起；三块一起拖动；浅色 / 深色两套主题，不跟随系统 |
| 首次准备 | 自动下载 / 校验 Android platform-tools、emulator、Android 14 AOSP 镜像（约 1.5–2 GB）；支持断点续传、离线包导入、自定义镜像源 |
| 设备 | 预设机型与自定义宽高 / DPI；启动后隐藏 Android 底部三键导航条，画面完整交给被测应用（旧设备首次启动自动迁移，冷启动一次）；重新打开应用时会读回设备实际分辨率，手机外框比例与画面一致；快照快速启动；停止 / 重启 |
| APK 来源 | **屏幕取景框实时扫二维码**（可拖动玻璃卡片、320×320 透明取景区，出现后 2 秒开始扫）；二维码是 APK 下载链接时自动跟随，先按桌面 UA 取，拿到落地页再用手机 UA 重试，从页面里找 `.apk` 直链；空壳下载页（地址由页面脚本调详情接口取得）会照着页面自己的请求问一次接口再下载；拖入 APK / 二维码截图 / 图片数据；剪贴板粘贴；粘贴下载链接；选择本地文件 |
| APK 解析 | 包名、应用名、版本、minSdk / targetSdk、ABI、启动 Activity；架构 / API / 拆分包等兼容性预检，中文解释 |
| 运行 | 安装、启动、清数据重开、保留数据重开、完全重装、停止 |
| 画面 | 自实现 scrcpy 协议，内嵌实时画面；屏幕录制权限只在扫码时申请，且只读取取景框区域、只在内存中识别 |
| 输入 | 点击、拖拽、滚轮、ASCII 键盘输入 |
| 截图标注 | 冻结画面，矩形 / 箭头 / 文字 / 画笔 / 颜色 / 撤销重做；保存 PNG 或复制到剪贴板 |
| 设备 ID | 读取应用实际看到的 Android ID；显示后台常用的 32 位 MD5；团队统一设备 ID（见 [docs/device-id.md](docs/device-id.md)） |
| 清理 | 退出时卸载被测应用、清数据、删临时 APK；强杀后下次启动自检清理 |
| 诊断 | 折叠日志与「复制诊断信息」 |

## 给设计同事：安装

1. 打开 `dist/UI验收台-<版本>.dmg`。
2. 把「UI验收台.app」拖进「应用程序」。
3. 双击 DMG 里的「首次打开.command」。它会给「应用程序」里那份应用去掉下载隔离标记并打开它（找不到时退回打开 DMG 里的副本）。之后正常双击即可。
4. 按向导下载 Android 组件；之后在左侧坞「素材」里点「扫描屏幕二维码」对准二维码，或把 APK 拖进手机屏开始。

更完整的操作说明在打包产物里的 `使用说明.rtf`，其源文在 [Scripts/package.sh](Scripts/package.sh)。

## 开发

依赖：Xcode 15.2（Swift 5.9）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
# 生成 Xcode 工程（改了 project.yml 之后必须重新跑）
xcodegen generate

# 纯逻辑单测；真实模拟器用例默认跳过
swift test

# Xcode 工程测试。derivedData 放在 ASCII 路径下，中文项目路径会让测试运行器
# 报 “Failed to create a bundle instance”
xcodebuild test \
  -project UITestBench.xcodeproj \
  -scheme UITestBench \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/uitestbench-xcodebuild

# 打 DMG，默认 1.4.2，输出到 dist/
Scripts/package.sh 1.4.2
```

工程是双轨的：`Package.swift` 供 `swift build` / `swift test`，`project.yml` 经 XcodeGen 生成 `UITestBench.xcodeproj`，两者共用 `Sources/`，切换时源码不改。

### 版本号

改 `project.yml` 里的 `CFBundleShortVersionString` / `CFBundleVersion`，然后 `xcodegen generate`；同时更新 `Scripts/package.sh` 的默认版本与说明文字。`Project/UITestBenchApp-Info.plist` 是生成物。

## 目录

```
Sources/UITestBenchCore/   纯逻辑：SDK、AVD、scrcpy、APK、设备 ID、清理
Sources/UITestBenchApp/    SwiftUI 界面与各 Model
Tests/UITestBenchCoreTests/ 单元测试 + 默认跳过的真实模拟器验收
Project/                   XcodeGen 生成的 Info.plist 等
Scripts/package.sh         构建 .dmg
docs/                      架构、设备 ID、验收说明
docs/history/              早期原型方案（历史，不代表现状）
docs/superpowers/plans/    主窗口改版计划与执行实测（随 1.4.0 发布）
```

工具自己的数据都在 `~/Library/Application Support/UI验收台/`：`sdk/`、`avd/`、`tmp/`、`logs/`。用户选中的原始 APK 与导出的截图不在清理范围内。

## 文档

- [docs/architecture.md](docs/architecture.md) — 模块划分与关键数据流
- [docs/device-id.md](docs/device-id.md) — 16 位 Android ID、32 位后台 MD5、团队统一 ID
- [docs/acceptance-testing.md](docs/acceptance-testing.md) — 真机（模拟器）验收怎么跑
- [docs/history/codex-prototype.md](docs/history/codex-prototype.md) — 最早的产品原型方案（归档）

## 已知限制

- 只支持带 `arm64-v8a` 原生库的包；只有 `armeabi-v7a` 的包装不上。纯 Java/Kotlin 包不受影响。
- 模拟器不是真机：风控、Play Integrity、DRM、推送、相机、NFC 等行为可能不同。
- 中文输入不支持：控制通道只支持 ASCII，AOSP 镜像也没有中文输入法。
- 1.3.0 起界面不再提供返回 / Home / 最近任务按钮及其快捷键；删除键和 Esc 也不再映射成返回，由模拟器内的导航栏或手势完成。
- 没有 OAID；IMEI 为空。只认 OAID 的白名单需要开发改用 Android ID。
- 团队统一设备 ID 会让所有人共享同一份「按设备保存」的应用状态，而不只是共享白名单。
- macOS 12.3 尚未在真实 macOS 12.3 机器上验收；代码只用了 12.3 可用的 API。
- 扫码拿到需要登录的分享页（飞书、企业网盘等）时，工具不会替用户登录：会说明这是网页，并给出「在浏览器中打开链接」，登录或点「下载」后再把 APK 拖进来。
- 屏幕扫码依赖系统「屏幕录制」权限：授权后通常要重启应用才生效；升级重签后可能需要在系统设置里重新勾选。如果系统设置里显示已开启、应用却仍提示未授权（ad-hoc 重签的已知错位），点权限卡片里的「重置授权」，再退出重开应用重新授权。

## 许可

随包的 `scrcpy-server.jar` 版权归 Genymobile，按 Apache License 2.0 发布。完整许可证在应用内「关于 → 查看完整许可证」。
