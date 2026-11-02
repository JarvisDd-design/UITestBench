---
name: uitestbench-dmg-location
description: 出包后要把 DMG 放到桌面项目文件夹的 dist/，用户只在那里找安装包
metadata:
  node_type: memory
  type: feedback
  originSessionId: bde1d5d0-743d-4acb-b8cc-30bbcbae37e6
  modified: 2026-10-26T09:34:45.416Z
---

UI验收台的代码在 worktree `/Users/jarvis/uitestbench-worktrees/ui-1-3-0` 开发，`Scripts/package.sh` 默认把
DMG 输出到 worktree 的 `dist/`；但用户找安装包的位置是主检出
`/Users/jarvis/Desktop/桌面测试工具/1.0.0/dist/`。

**Why:** 2026-10-26 交付 1.4.3 时我只说了工作树的 `dist/`，用户看到桌面文件夹里没有 1.4.3，认为我放错了位置。
桌面项目虽然还停在 1.2.0 代码，但 `dist/` 是用户约定的产物目录（1.4.2 也曾被复制过去）。

**How to apply:** 每次打包完成后，把新 DMG 复制到桌面项目 `dist/`（保留工作树里的原件），并在汇报里直接给出
桌面那份的路径与 SHA-256；不要只报工作树路径。相关发布状态见 [[uitestbench-1-4-release-pending]]。
