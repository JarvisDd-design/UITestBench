---
name: uitestbench-plan-location
description: UI验收台的基础计划、1.3.0/1.4.0 改版计划位置与当前版本状态（2026-10-23 更新）
metadata:
  node_type: memory
  type: project
  originSessionId: 31e3e22e-8654-4595-a806-43bf68982604
  modified: 2026-10-23T10:08:42.411Z
---

> 迁移备注（2026-10-26）：本文件从 Claude Code 记忆目录搬进仓库。原先指向 `~/.claude/plans/` 的路径
> 现在都在 [docs/plans/](../plans/README.md) 里，读时按新路径来。

- 基础计划：`docs/plans/encapsulated-swimming-boole.md`（18 条决策 + M0a–M9），讨论 v1 范围时以它为准。
- 1.3.0 主窗口改版计划（repo 内，已标注被 1.4.0 取代）：`docs/superpowers/plans/2026-10-22-ui-1-3-0-redesign.md`。
- 1.4.0 当前形态（手机 + 三个吸附悬浮面板）：`docs/superpowers/plans/2026-10-23-ui-1-4-0-floating-panels.md`；2026-10-23 从本机 `/Users/jarvis/.claude/plans/1-3-0-ui-1-2-3-federated-orbit.md` 补进仓库，文末有执行记录与实际偏差。
- 工作树 `/Users/jarvis/uitestbench-worktrees/ui-1-3-0`，分支 `feat/ui-1-3-0-redesign`。

截至 2026-10-23：基础计划的 M0–M9 已实现；1.2.0 扫码完成；1.3.0 已打包但界面被 1.4.0 整体替换；1.4.2 修了扫码下载页并已推 GitHub（main `1b9e75f` + tag `v1.4.2`），DMG 已出、分发渠道未定，见 [[uitestbench-1-4-release-pending]]。剩余验收都只能由用户本人做：在应用里用原二维码复测 1.4.2、1.4.x 的人工验收、真实 macOS 12.3 机器实测（见 [[uitestbench-real-acceptance-env]]）。

**Why:** 计划散落在会话之外，重开对话时不知道去哪找，容易重复讨论已定决策；1.3.0 的计划虽然进了仓库，但 1.4.0 的最终形态直到 2026-10-23 才补进去，只看旧文档会以为还是左列布局。

**How to apply:** 开始新一轮开发前先读对应计划；汇报进度时对照里程碑，别把「已实现」「已推 GitHub」说成「已人工验收」。
