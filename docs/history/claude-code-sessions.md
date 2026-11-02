# 旧会话存档（Claude Code）

2026-10-20 到 2026-10-26 期间，这个项目是用 Cursor 里的 Claude Code 插件做的。
会话原文是 `~/.claude/projects/-Users-jarvis-Desktop--------1-0-0/*.jsonl`，
一共 7 个、约 124 MB，**不进仓库**（太大，而且逐条工具调用对后来的人没什么用）。

本文件是索引：想知道某个决定当时是怎么讨论出来的，按日期挑文件，再 `grep` 关键词。

| 日期 | 会话文件 | 体积 | 用户轮次 | 起点 |
|---|---|---|---|---|
| 2026-10-20 | `74a36003-0787-43fd-b600-cb450a0c9f98.jsonl` | 0.7 MB | 1 | 安装 grilling / grill-me 两个技能 |
| 2026-10-20 | `cadff309-d34c-4a59-bb27-46e0d0980ea1.jsonl` | 0.1 MB | 7 | 工具链通了，7 条测试全绿 |
| 2026-10-20 → 10-21 | `d1d327ad-7178-4d52-a38e-3a5c38b391df.jsonl` | 54 MB | 73 | 方案评审：桌面上就能用的对图验收工具 |
| 2026-10-21 → 10-22 | `5b7b056d-9498-4a6e-a4ea-528358fe2bd4.jsonl` | 11 MB | 22 | 扫码取 APK 读不出来（1.2.0） |
| 2026-10-22 → 10-23 | `31e3e22e-8654-4595-a806-43bf68982604.jsonl` | 16 MB | 16 | 主窗口布局：手机 + 悬浮舵式（1.3.0） |
| 2026-10-23 → 10-26 | `6ec2b1ae-2c97-4136-8810-7886d16c236a.jsonl` | 40 MB | 17 | 1.3.0 体验反馈 → 悬浮面板（1.4.0） |
| 2026-10-26 | `bde1d5d0-743d-4acb-b8cc-30bbcbae37e6.jsonl` | 3 MB | 10 | 挽留弹窗：返回键入口（1.4.3） |

查法示例：

```bash
cd ~/.claude/projects/-Users-jarvis-Desktop--------1-0-0
# 某次讨论里提到设备 ID 的段落
grep -h '设备 ID' 6ec2b1ae-2c97-4136-8810-7886d16c236a.jsonl | head -20
# 把一份会话里的用户原话抽出来
python3 -c 'import json,sys
for l in open(sys.argv[1],encoding="utf-8"):
    d=json.loads(l)
    if d.get("type")=="user" and not d.get("isMeta"):
        c=d.get("message",{}).get("content")
        t=c if isinstance(c,str) else "".join(b.get("text","") for b in c if isinstance(b,dict))
        if t.strip(): print(t[:200].replace("\n"," "))' 6ec2b1ae-2c97-4136-8810-7886d16c236a.jsonl
```

DSH 的会话格式（zstd 压缩）和 Claude Code 的裸 jsonl 不通用，这批记录只能当资料读，
没法在新会话里接着聊。结论与决策已经沉淀进 [docs/plans/](../plans/README.md) 和
[docs/agent-memory/](../agent-memory/README.md)，日常开发不需要翻原文。
