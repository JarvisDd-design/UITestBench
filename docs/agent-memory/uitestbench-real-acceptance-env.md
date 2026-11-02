---
name: uitestbench-real-acceptance-env
description: UI验收台真机验收的环境变量、9 个生命周期用例、双 AVD 开关与样本 APK 路径
metadata:
  node_type: memory
  type: project
  originSessionId: d1d327ad-7178-4d52-a38e-3a5c38b391df
  modified: 2026-10-21T07:42:45.692Z
---

真机（模拟器）验收测试的运行方式：

```bash
UITESTBENCH_REAL_SETUP=1 \
UITESTBENCH_SDK_DIR="$HOME/Library/Application Support/UI验收台" \
APK_SAMPLE="/Users/jarvis/Downloads/apk-sample-20261020-175143/sample.apk" \
swift test --filter RealAppLifecycleAcceptanceTests
```

- 不设 `UITESTBENCH_REAL_SETUP=1` 时这些用例整组 skip，属于正常现象。
- 生命周期套件共 9 个用例，默认跑 8 个、跳过 1 个，整套约 3 分钟（193 秒）；每个用例各自启动/停止模拟器。
- 跨设备用例要加 `UITESTBENCH_TWO_AVDS=1`：它会停掉主 AVD，在 `/tmp/UITestBenchSecondDevice-*` 建第二台、端口 5556、`wipeData: true`。
- 样本包：`com.qsnfrkgk.vdvfeh`，样本自身 versionName 1.1.0、versionCode 11（不是工具版本）。应用有隐私弹窗，必须先点 resource-id 后缀 `:id/btn_agree`，否则应用不写 SSAID，读设备 ID 会失败。
- 设备 1080×2400 / 420 dpi；`screencap` 截图是 1080×2400，scrcpy 镜像是 864×1920（scale 0.8），两套坐标不要混用。
- `xcodebuild test` 的 derivedData 不要放在中文项目路径下，见 [[uitestbench-xcodebuild-chinese-path]]。
- 设备 ID 的预期值见 [[uitestbench-team-device-id]]。

**Why:** 环境变量名、用例数量和样本路径只存在于会话经验里，仓库文档现在虽有记录，但下次仍要先确认样本路径是否存在。

**How to apply:** 需要跑真机验收时直接照抄上面的命令；若 `APK_SAMPLE` 不存在，先向用户要新的样本路径。失败后检查残留的 emulator 进程与 `/tmp/uitestbench-*`。
