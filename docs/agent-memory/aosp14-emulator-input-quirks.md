---
name: aosp14-emulator-input-quirks
description: AOSP 14 模拟器镜像的两个实测怪癖：注入的滚动事件应用层不响应；应用转屏后只是信箱式适配
metadata:
  node_type: memory
  type: project
  originSessionId: d1d327ad-7178-4d52-a38e-3a5c38b391df
  modified: 2026-10-20T12:35:26.487Z
---

在 Android 14 AOSP `default` arm64 镜像（UI验收台项目）上实测：

1. **`INJECT_SCROLL_EVENT` 无效。** `dumpsys input` 的 RecentQueue 能看到 `action=SCROLL`、坐标正确、无丢弃日志，但应用层不响应；同坐标的触摸拖动立刻生效。scrcpy 官方客户端在这台镜像上滚轮同样不工作。所以滚轮走合成短拖动（见 [[uitestbench-m3c-scroll-workaround]]）。

2. **应用锁竖屏，转屏只是信箱式适配。** `wm fixed-to-user-rotation enabled` + `wm user-rotation lock 1` 只把系统栏转成横屏（截图 2400×1080），Settings 与 Launcher3 仍按竖屏布局挤在中间的一条竖条里，uiautomator 报的也仍是应用自己的竖屏坐标系。因此「转屏后点击应用控件」在这台镜像上无法作为我们代码的验收手段——测到的是系统的适配行为，不是坐标映射。

**Why:** 这两条都是靠真机实验才定下来的，光看代码或文档会得出相反结论。

**How to apply:** 再遇到滚动不生效，别怀疑消息字节布局或分派器，直接看 DragScrollSink；要测转屏映射，用单测 + 视频尺寸变化，不要设计依赖应用横屏布局的真机用例。
