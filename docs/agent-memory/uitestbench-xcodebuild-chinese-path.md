---
name: uitestbench-xcodebuild-chinese-path
description: xcodebuild test 的 derivedData 落在中文项目路径下会报 Failed to create a bundle instance
metadata:
  node_type: memory
  type: project
  modified: 2026-10-21T07:40:57.441Z
  originSessionId: d1d327ad-7178-4d52-a38e-3a5c38b391df
---

UI验收台项目路径含中文（`/Users/jarvis/Desktop/桌面测试工具/1.0.0`）。`xcodebuild test` 若把 `-derivedDataPath` 放在项目内的 `.build/xctest`，测试运行器会报：

```
Failed to create a bundle instance
```

同一份测试 bundle 用 `xcrun xctest` 直接运行却正常，说明是 Xcode 测试运行器对非 ASCII derived data 路径的怪癖，不是测试代码问题。

**Why:** 这个报错看起来像测试 bundle 损坏，容易误删 derivedData 或改测试配置，浪费一轮排查。

**How to apply:** 跑 `xcodebuild test` 时把 `-derivedDataPath` 指到 ASCII 路径，例如 `/tmp/uitestbench-xcodebuild`；`swift test` 不受影响。
