---
name: uitestbench-m3c-scroll-workaround
description: UI验收台的滚轮走「合成短拖动」而非 scrcpy 的滚动消息，以及与节拍/停顿相关的两个关键参数
metadata:
  node_type: memory
  type: project
  originSessionId: d1d327ad-7178-4d52-a38e-3a5c38b391df
  modified: 2026-10-21T07:41:53.504Z
---

UI验收台（`/Users/jarvis/Desktop/桌面测试工具/1.0.0`）的控制通道里，滚轮**不发** `INJECT_SCROLL_EVENT`，而是由 `Sources/UITestBenchCore/DragScrollSink.swift` 翻译成一段短拖动：按下 → 6 步移动 → 停顿 → 抬起。原因见 [[aosp14-emulator-input-quirks]]。

两个调参结论（都是实测出来的，改动前先读代码注释）：

- **移动事件必须有节拍。** 一开始 6 步连着写，全落在同一毫秒里，安卓 velocity tracker 算出极大速度，滚一格实测走了约 1994 px（意图 125 px）。现在每步间隔 12 ms、抬手前停 120 ms（抬手前 100 ms 内无位移 → 甩动速度为 0），实测一格约 89 px。
- **手势在串行 `DispatchQueue` 上执行。** 一方面不阻塞主线程，另一方面保证连续两格不交错——交错会被系统当成两根手指。

测试注入节拍为 0 并用 `queue.sync {}` 排水，因此单测是确定性的；真机验收见 `Tests/UITestBenchCoreTests/RealControlAcceptanceTests.swift` 里的滚轮与拖动用例。

**Why:** 甩动问题不靠肉眼判断，是用位移数值量化后定位的；直接改参数没有依据。

**How to apply:** 滚轮手感再出问题，先量位移（期望每格约 100 画面像素），再调 `stepInterval` / `settleInterval`，不要退回滚动消息。
