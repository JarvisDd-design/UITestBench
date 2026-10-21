# 设备 ID

开发在测试后台按「设备 ID」加白名单时，要给的是**应用自己看到的 16 位 Android ID**。有些后台把它存成 32 位 MD5，那是同一个值的另一种写法，不是另一台设备。

## 先分清三个值

| 值 | 例子 | 是什么 | 能不能给开发 |
|---|---|---|---|
| 应用看到的 Android ID（SSAID） | `10f5f004470a2797` | 应用调用 `Settings.Secure.ANDROID_ID` 得到的 16 位值 | **能**，这就是白名单要的 |
| 后台显示的 32 位 ID | `193fd7d4b0869c1e00c1c6dae9daff6c` | 上面那个值的 `MD5(文本)` | **能**，同一个 ID |
| 设备种子 | `1f646a861890fbdd` | `settings get secure android_id` 的返回值 | 不能，加白名单不会生效 |
| AVD 的 `userkey` | 64 位十六进制 | 整台设备的随机密钥，SSAID 的输入之一 | 不能，不是应用 ID |

工具界面「运行」区显示第一行是 16 位 SSAID，第二行是 32 位 MD5，两行各有复制按钮。按后台实际显示的列选。

## SSAID 怎么来的

Android 8 以后，每个应用看到的 Android ID 不再是一台设备一个，而是按应用算出来的：

```
SSAID = HMAC-SHA256(userkey, 签名证书数组的序列化字节)
        取小写十六进制前 16 位
```

证书数组按 AOSP 的格式序列化：按签名顺序，每个证书前加 4 字节长度前缀，再接 DER 字节。

- 输入只有两个：设备的 `userkey` 和 APK 的签名证书。
- **与包名、UID、安装次数、是否清数据无关。**
- 同一套签名证书签的所有包，共用同一个 SSAID。
- 系统把结果按 UID 存进 `/data/system/users/0/settings_ssaid.xml`，一行一个应用；`name` 是 UID，`value` 才是 ID。
- 应用第一次读取时才写入。所以刚装好、还没启动过（或隐私弹窗还没同意）时，表里可能没有它的行。

## 团队统一设备 ID

如果每台电脑的模拟器各自随机生成 `userkey`，同一个包在每台机器上会得到不同 ID，开发就得给几十个人逐个加白名单。v1.1.0 起把这件事反过来：

- 所有 AVD 的 `userkey` 固定成同一个常量 `TeamDeviceKey.value`：
  `C0F8B2FAA0DA029E9AABDF6417C0961EDE427A37D3292BF8540C5170D0B6DA22`
- 设备第一次启动、系统开机完成后，`TeamDeviceKeyProvisioner` 检查 `settings_ssaid.xml`；不对就写入团队密钥，并清掉所有旧的按 UID 行（否则应用会继续读旧值）。
- 写入顺序必须是：`su 0 stop` → 等 zygote 停下 → 改文件 → `su 0 start` → 等 PackageManager 与 SettingsProvider 真正可用。不停框架直接改，SettingsProvider 会把内存里的旧表覆盖回去。
- 全新 AVD 第一次开机可能还没有 `settings_ssaid.xml`。这时会新建一张只有 `userkey` 的空表，并把属主 / 权限 / SELinux 标签修正为 `system:system`、`600`、`system_data_file`；否则系统服务读不到，应用还是拿到随机 ID。
- 已经等于团队密钥时直接跳过，正常启动只多一条 adb 查询命令。
- 写入失败只显示橙色警告，不阻断设备启动；下次启动会重试。

结果：**所有装了本工具、使用同一套签名证书的电脑，看到的是同一个 SSAID。** 开发只需要配一次白名单。

### 什么时候会变

| 操作 | ID 是否变 |
|---|---|
| 同一个包反复运行、清数据、完全重装 | 不变 |
| 停止设备 / 重启设备 / 重启工具 | 不变 |
| 换一台电脑、全新安装本工具 | 不变（团队密钥相同） |
| 换一套签名证书 | **变**（这是设计使然） |
| 应用自己改变了上报算法（例如换盐、换哈希） | 后台值可能变，但 SSAID 本身不变 |
| 手动改掉 AVD 的 userkey | 变 |

### 代价

团队统一 ID 让所有人共享同一个「设备身份」。如果应用不只是拿它做白名单，还按设备 ID 保存登录态、试用次数、偏好等，那么所有同事会共享同一份状态。这是统一 ID 的固有代价，不是 bug；需要隔离状态时，只能单独给某台设备换一个 `userkey`。

这个 ID 是测试环境的设备标识，**不是密钥材料，不参与鉴权**。

## 手动核对

设备起来、应用启动并同意隐私弹窗后：

```bash
ADB="$HOME/Library/Application Support/UI验收台/sdk/platform-tools/adb"
"$ADB" -s emulator-5554 shell su 0 abx2xml /data/system/users/0/settings_ssaid.xml -
```

在输出里找 `package="<包名>"` 且 `name` 为纯数字的那一行，`value` 就是应用看到的 ID；`name="userkey"` 那一行是设备密钥，不要发给开发。

样本包 `com.qsnfrkgk.vdvfeh` 在团队密钥下的值是 `10f5f004470a2797`，MD5 是 `193fd7d4b0869c1e00c1c6dae9daff6c`。可以用它做一次冒烟核对。

## 排查

| 现象 | 原因 / 处理 |
|---|---|
| 界面显示「应用还没读取」 | 应用还没启动，或隐私弹窗没同意。启动应用、点掉弹窗后按「刷新」。 |
| 两台电脑 ID 不同 | 先看界面有没有橙色「团队设备 ID」警告；再确认两台机器装的是同一版本、包的签名证书是否相同。 |
| 后台值对不上，但都是 32 位 | 复制界面上的「MD5」那一行；不要拿 16 位值去和 32 位后台比。 |
| 第一次启动设备多花了 10–30 秒 | 正在写团队密钥并重启系统框架，属正常；之后启动不会重复。 |
| 写入失败 | 按警告里的说明停止设备后重试；仍失败就看「诊断」里的 adb 输出。 |
| 开发只认 OAID | 模拟器没有 OAID，IMEI 也为空；需要开发支持用 Android ID 加白。 |

实现位置：`Sources/UITestBenchCore/DeviceIdentity.swift`（读取、解析、MD5、建表）与 `Sources/UITestBenchCore/TeamDeviceKeyProvisioner.swift`（写入与恢复）。
