---
name: uitestbench-team-device-id
description: 团队统一设备 ID 的固定 userkey、样本 16 位 ID 与后台 32 位 MD5 的对应关系
metadata:
  node_type: memory
  type: project
  modified: 2026-10-21T07:43:13.501Z
  originSessionId: d1d327ad-7178-4d52-a38e-3a5c38b391df
---

UI验收台 v1.1.0 起启用团队统一设备 ID：所有 AVD 的 `userkey` 固定为
`C0F8B2FAA0DA029E9AABDF6417C0961EDE427A37D3292BF8540C5170D0B6DA22`。
SSAID = HMAC-SHA256(userkey, APK 签名证书数组的序列化字节；证书按顺序、每个带 4 字节长度前缀) 的小写 hex 前 16 位，所以同一套签名证书在所有电脑上得到同一个 ID，开发只配一次白名单。

样本包 `com.qsnfrkgk.vdvfeh`：

- 应用看到的 16 位 Android ID：`10f5f004470a2797`
- 反馈后台显示的 32 位值：`193fd7d4b0869c1e00c1c6dae9daff6c` = `MD5("10f5f004470a2797")`，不是另一台设备
- `settings get secure android_id` 返回的设备种子 `1f646a861890fbdd` 不是应用 ID；`settings_ssaid.xml` 里的 `userkey` 行也不是，给开发会加白失败

写入时机是设备开机完成、交出画面之前。已有表就替换 userkey 并删除旧的按 UID 行；全新 AVD 可能还没有 `settings_ssaid.xml`，要新建空表并修正 `system:system` / `600` / `restorecon`。改完要重启系统框架（`su 0 stop` → 等 zygote stopped → 改文件 → `su 0 start`），否则 SettingsProvider 会用内存旧表覆盖。

ID 在反复运行、清数据、完全重装、停止/重启设备、换电脑后都不变；换签名证书或手动换 userkey 才变。代价是所有人共享按设备保存的应用状态，不只是白名单。

**Why:** 这套机制跨代码、系统文件和后台展示三层，单看任何一层都容易把设备种子、userkey 或 MD5 当成「设备 ID」。

**How to apply:** 开发要设备 ID 时给 16 位 SSAID；后台显示 32 位时给同一行的 MD5。详细说明与排查见 `docs/device-id.md`，具体实现见 `DeviceIdentity.swift` 与 `TeamDeviceKeyProvisioner.swift`。
