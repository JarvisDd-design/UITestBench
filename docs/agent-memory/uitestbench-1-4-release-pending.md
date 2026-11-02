---
name: uitestbench-1-4-release-pending
description: 1.4.x「手机 + 三个吸附悬浮面板」的实现、打包与分发状态；1.4.3 恢复返回键入口（2026-10-26）
metadata:
  node_type: memory
  type: project
  originSessionId: 6ec2b1ae-2c97-4136-8810-7886d16c236a
  modified: 2026-10-26T09:26:43.791Z
---

> 2026-11-02 备注：本条是 1.4.x 的状态快照，发布状态已被 1.5.0 接替。
> 现状见 README、`project.yml` 与 [docs/acceptance-testing.md](../acceptance-testing.md) 的验收记录。

1.4.0 把界面改成「只有手机 + 坞胶囊 + 底胶囊 + 左侧抽屉」：手机是无边框可等比缩放的
`PhoneWindow`，另外三块是 `BenchPanel` 子窗口，由 `FloatingPanelsController` 吸附定位。
1.4.1 → 1.4.2 是同一线的补丁：修「二维码是 APK 下载链接却报不是 APK」。代码在 worktree
`/Users/jarvis/uitestbench-worktrees/ui-1-3-0`，分支 `feat/ui-1-3-0-redesign`。2026-10-23 已提交
`1b9e75f release: UI验收台 1.4.2`，并推送 GitHub：main 快进到 `1b9e75f`，annotated tag `v1.4.2`。
设计记录在仓库 `docs/superpowers/plans/2026-10-23-ui-1-4-0-floating-panels.md`（从本机计划补入），
1.3.0 的旧计划已标注被取代，见 [[uitestbench-plan-location]]。

- `swift test` 590 通过 / 30 skip / 0 失败；`TeamDeviceKeyProvisionerTests` 11 通过；Release 构建成功。
- DMG：`dist/UI验收台-1.4.2.dmg`，2.2 MB，SHA-256
  `ddea389798f589786e48c58c607f229c8d03b63e604aafa33eae52515d8ca8e1`，版本 1.4.2 / 13，
  ad-hoc 签名；内含 `使用说明.rtf`（顶部写清「设备 ID 不需要配置」）与 `首次打开.command`。
  dist/ 现在保留 1.3.0、1.4.0、1.4.1、1.4.2 四份。
- **分发未定**：仓库 `JarvisDd-design/UITestBench` 是公开的，按红线只推源码，不传 DMG / 公司 APK；
  GitHub 上没有 Release，`gh` 也未登录。用户问过「怎么没有安装包 / 下载地址」，我给了本地 DMG 路径
  与 SHA-256，并提出「内部渠道」或「私有仓库 Release」两条路；用户拒绝了那次选择，至今没有拍板。
  不要把 DMG 传到公开仓库。
- 主检出 `/Users/jarvis/Desktop/桌面测试工具/1.0.0` 仍停在本地 1.2.0（remote main 已是 1.4.2）；
  要用主检出时先让用户自己 pull。
- 设备 ID 无需配置：当前 AVD 的 `settings_ssaid.xml` 里 `userkey` 已是
  `TeamDeviceKey.value`（`C0F8…DA22`）；全新设备建表逻辑由 11 个 provisioner 单测覆盖。
  真机跨设备用例 `testAFreshDeviceGetsTheSameTeamDeviceID` 仍待空闲时跑。
- 用户的真实二维码链接是第三方分发平台：`app.push.example.com/content-web/download.html?id=…`。
  页面 HTML 里没有 `.apk`，由 `js/download.js` 调 `/content-web/app/detail.do?id=…`
  取得 JSON 里的 `downloadUrl`。1.4.2 新增 `APKPageDetail` 专处理这种空壳页；
  已用这条真实链接跑通完整获取（包名 `com.whxxoezi.nkckw`，版本 1.1.0，60.8 MB，约 2.6 秒）。
- 1.4.1 已做的：`DownloadedContent` 按内容判包 / 网页；桌面 UA 拿到网页时换手机 UA 重试；
  两张页面都由 `APKPageLink` 找 `.apk` 直链并带正确 `Referer`；仍只有网页就提示并给
  「在浏览器中打开链接」。`ZipReader` 容忍非 UTF-8 条目名（GBK 资源名），`ApkInspector`
  区分 `notAZipArchive` 与 `damagedArchive`。
- 已在开发机实测（1.4.0 线）：整组拖动、边缘等比缩放后坞/胶囊重新吸附、抽屉在坞左侧垂直居中、
  hover 桥接与钉住、Esc 收起、深浅色可读、适应屏幕/恢复、黄点隐藏 + Dock 图标恢复、
  置顶、启动设备/镜像/截图标注 sheet、三键导航条消失、机型分辨率回读。
- 未做（只能用户本人验）：用 1.4.2 在应用里扫那张二维码；真实 macOS 12.3 机器、多显示器、
  全新安装向导、亮 / 暗桌面壁纸观感。
- 2026-10-26 **1.4.3**：恢复了返回键入口（被测应用挽留弹窗只在系统返回键退出时出现）。
  运行态底胶囊加 `chevron.backward` 图标；应用级 ⌘[ 由 Core 的 `DeviceBackShortcutPolicy`
  判定（输入框编辑中、sheet / 模态不抢键）。Esc / Delete 仍不映射返回，Home / 最近任务不提供。
  用户已手工确认按钮可用。`swift test` 598 通过 / 30 skip。main 快进到 `c7a0fd6`，
  annotated tag `v1.4.3` 已推；DMG `dist/UI验收台-1.4.3.dmg`，2.2 MB，SHA-256
  `4a1d82a509b9b8502601e4abe1bb840e7bd2cdb72a305f7786127fdaca77140b`，版本 1.4.3 / 14。
  分发仍走内部渠道，DMG 不上公开仓库。

**Why:** 「已实现 / 已打包 / 已推 GitHub」都不等于「已验证」，而且公开仓库不能放安装包；
分发这件事还卡在用户决策上，下个会话不要擅自上传。

**How to apply:** 汇报时给出 DMG 路径、SHA-256 和验收清单，明确 12.3 与人工验收未完成；
用户再问下载地址时，先重申公开仓库放不了 DMG，等用户选内部渠道或私有仓库。
