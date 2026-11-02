# 记忆索引

- [AOSP 14 模拟器的输入怪癖](aosp14-emulator-input-quirks.md) — 滚动事件注进去应用不响应；转屏后应用只是信箱式适配
- [M3c 滚轮改合成拖动](uitestbench-m3c-scroll-workaround.md) — 滚轮走「按下→挪几步→停→抬起」，节拍与停顿是防甩动的关键
- [真机验收环境](uitestbench-real-acceptance-env.md) — 环境变量、9 个生命周期用例、双 AVD 开关与样例 APK 路径
- [团队统一设备 ID](uitestbench-team-device-id.md) — 固定 userkey，所有电脑同签名证书得到同一个 ID；后台 32 位是 MD5
- [xcodebuild 中文路径测试坑](uitestbench-xcodebuild-chinese-path.md) — derivedData 在中文目录下会报 bundle instance，改用 /tmp
- [计划文件位置](uitestbench-plan-location.md) — 基础计划、1.3.0/1.4.0 改版计划位置、当前版本与剩余验收
- [1.2.0 扫码决策](uitestbench-1-2-0-scan-pending.md) — 玻璃卡片/2 秒准备期/对勾翻转坑；已实扫过真实码，剩观感与 12.3
- [1.4.x 发布状态](uitestbench-1-4-release-pending.md) — 1.4.3 已出包并推 GitHub（公开仓库不传 DMG）；分发走内部渠道；剩应用内扫码复测与 12.3
- [DMG 交付位置](uitestbench-dmg-location.md) — 出包后复制到桌面项目 dist/，用户只在那里找安装包
