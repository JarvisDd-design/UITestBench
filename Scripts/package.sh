#!/bin/bash
# 打一个可以直接发给设计同事的 .dmg。
#
#   Scripts/package.sh            默认 1.4.3，输出到 dist/
#
# 只出 Apple 芯片（arm64）版本：模拟器镜像也只用 arm64-v8a，Intel 机器上没有意义。
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-1.4.3}"
APP_NAME="UI验收台"
PRODUCT="UITestBenchApp"
STAGE=".build/dmg-stage"
DERIVED=".build/release"
OUT="dist/${APP_NAME}-${VERSION}.dmg"

rm -rf "$STAGE"
mkdir -p "$STAGE" dist

echo "==> 构建 Release（arm64）"
xcodebuild \
  -project UITestBench.xcodeproj \
  -scheme UITestBench \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  build

BUILT_APP="$DERIVED/Build/Products/Release/${PRODUCT}.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "构建产物不存在：$BUILT_APP" >&2
  exit 1
fi

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT_APP/Contents/Info.plist")
if [ "$BUILT_VERSION" != "$VERSION" ]; then
  echo "版本不一致：app=$BUILT_VERSION，参数=$VERSION" >&2
  exit 1
fi

echo "==> 组装磁盘映像内容"
cp -R "$BUILT_APP" "$STAGE/${APP_NAME}.app"

cat > "$STAGE/首次打开.command" <<'SCRIPT'
#!/bin/bash
# 这个包没有做 Apple 公证，直接双击会被 Gatekeeper 拦下。
# 脚本先把「从网络下载」的隔离标记去掉，再打开应用。
# 用户按说明已经把应用拖进「应用程序」，所以要清的是那一份；
# 只有找不到时才退回 DMG 卷内的原件。
APP="/Applications/UI验收台.app"
if [ ! -d "$APP" ]; then
  APP="$(cd "$(dirname "$0")" && pwd)/UI验收台.app"
fi
if [ ! -d "$APP" ]; then
  echo "没在「应用程序」里找到「UI验收台.app」。请先把 .dmg 里的应用拖进「应用程序」，再双击本脚本。"
  read -r -p "按回车关闭…" _
  exit 1
fi
# 清理隔离标记失败不阻断：至少把应用打开，让用户看到具体提示。
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
open "$APP"
SCRIPT
chmod +x "$STAGE/首次打开.command"

cat > "$STAGE/使用说明.txt" <<TEXT
UI验收台 ${VERSION}

先看这里
  · 安装只需要三步：把应用拖进「应用程序」→ 双击「首次打开.command」
    → 按向导下载 Android 组件。
  · 设备 ID 不需要任何配置。第一次启动设备时，工具会自动写入团队设备密钥；
    所有电脑对同一套签名证书的包都会得到同一个 ID。详见文末「设备 ID」。

第一次打开
  1. 把「UI验收台.app」拖进「应用程序」。
  2. 双击「首次打开.command」。它会去掉系统给下载文件加的隔离标记，然后打开应用。
     （这个包没有做苹果公证，直接双击应用会被拦下。）
  3. 之后正常双击应用即可。

第一次使用
  · 应用会自动下载 Android 组件（约 1.5–2 GB），请留出时间和磁盘空间。
    如果下载很慢或连不上 Google，可在「设置」里导入离线组件包，或改用
    公司镜像源；不需要另外安装 Android Studio 或命令行工具。
  · 获取 APK 的四种方式：
      1. 点「扫描屏幕二维码」：屏幕中央出现一张可拖动的玻璃卡片，
         中间是 320×320 的透明取景框。出现后先有 2 秒准备时间，
         再开始扫描；把框对准飞书、浏览器、微信里的二维码即可。
         识别成功后卡片显示对勾并停留 1 秒，主窗口自动恢复，
         确认下载地址再点「下载」。
      2. 把 APK 文件拖进方框。
      3. 把二维码截图拖进方框，或点「从剪贴板粘贴」（⌘⇧V）。
      4. 粘贴下载链接，或选择本地文件。
  · 界面上没有普通窗口：手机画面左边是悬浮坞胶囊，鼠标悬停或点击会从
    左侧弹出卡片——素材（APK）、设备（机型、启动/停止）、应用（运行状态、
    设备 ID）、诊断、设置；手机下方是操作胶囊，负责运行、截图、重开。
    拖动坞、胶囊或手机边框都会带着整组一起移动；拖手机左右边缘可等比缩放，
    坞和胶囊会重新吸附。按 Esc 收起卡片，黄点隐藏整组，点 Dock 图标恢复。
  · 屏幕扫码第一次使用会请求「屏幕录制」权限。画面只读取取景框里的
    区域，仅在本机内存中识别，不保存、不上传。
  · 如果授权后仍然没有画面，请退出并重新打开应用；升级安装包后如果
    扫码异常，到「系统设置 → 隐私与安全性 → 屏幕录制」里取消勾选再
    重新勾选「UI验收台」。系统设置里显示已开启、应用却仍提示未授权时，
    点权限卡片里的「重置授权」，再退出重开应用重新授权。
  · 在左侧坞「设备」里选机型 → 启动设备，再到「素材」取 APK、点手机下方「运行应用」。
  · 启动设备后，屏幕底部的 Android 三键导航条不再显示，整块画面留给被测应用。
    已有的模拟器第一次启动会自动调整并冷启动一次（比平时稍慢），之后恢复快速启动。
  · 「运行应用」每次都会清空应用数据，等同于第一次打开——引导页、隐私协议
    这类只在首次出现的流程都能看到。
  · 想核对「第二次打开」的界面（例如已登录状态），用「保留数据重开」。
  · 右侧画面里可以直接用鼠标点击、拖动、滚轮、键盘输入。滚轮在画面旁边的
    空白处也能用。
  · 运行应用后，手机下方胶囊里会出现返回图标；也可以按 ⌘[。想验证
    「按系统返回键退出时的挽留弹窗」这类场景，用它给应用发返回键。
    Home 和最近任务不提供，Esc 和删除键也不会映射成返回。
  · 点「停止设备」后按钮会显示「正在停止…」，等模拟器把快照存完（几秒）
    再恢复。正常停止后下次是快速启动；如果直接强退应用，下次启动会慢一些。

设备 ID 与测试配置
  · 你不需要做任何设备 ID 配置，也不用改模拟器设置。全新电脑第一次启动
    设备时，工具会自动写入团队密钥；之后启动不会重复。
  · 有些应用要开发在后台按「设备 ID」加白名单，才会出现测试场景。
    运行应用之后，左侧坞「应用」抽屉的「运行状态」里会显示「设备 ID」——这是应用自己看到的
    Android ID，点「复制」发给开发即可。
  · 如果开发后台显示的是 32 位设备 ID，点下面的「复制 MD5」：那是同一个
    Android ID 的 MD5，不是另一台设备。两列按后台实际显示的选择。
  · 本版本已启用「团队统一设备 ID」：所有安装了本工具的电脑，对同一套
    签名证书的包，看到的都是同一个 ID。开发只需要配一次白名单。
  · 首次写入会重启一次系统框架（约 10–30 秒）；界面上会显示
    「团队设备 ID 已启用」。
  · 同一个包反复运行、清数据重开、完全重装、停止/重启设备、换电脑，
    ID 都不会变。
  · 同一套签名证书签的所有包共用这个 ID；只有换一套签名证书，才会得到
    另一个 ID。
  · 如果应用自己按设备 ID 保存状态或数据（而不只是做白名单），团队所有人
    会共享同一份状态——这是统一 ID 的代价。
  · 重置模拟器数据后，工具会自动重新写入团队密钥。
  · 模拟器没有 OAID（应用的 OAID SDK 会报 manufacturer not support），
    IMEI 也是空的。如果开发只认 OAID，需要他那边支持用 Android ID 加白。

截图与标注
  · 点画面下方的「截图」，画面会冻结。
  · 矩形、箭头、画笔、文字都能用；支持撤销/重做与颜色选择。
  · 「保存…」导出 PNG，「复制」直接贴进聊天工具。

数据不留存
  · 退出应用时会卸载被测应用、清掉数据、删除临时 APK。
  · 你选中的原始 APK 与导出的截图不会被删除。
  · 如果应用被强制结束，下次启动会自动清理上次的残留。

已知限制
  · 只支持 64 位（arm64）原生库的包；纯 Java/Kotlin 包不受影响。
  · 模拟器不是真机：风控、Play Integrity、推送、相机等可能与真机不同。
  · 中文输入暂不支持（控制通道只支持 ASCII）。
  · 需要 macOS 12.3 及以上，仅 Apple 芯片。

本工具包含 scrcpy 服务端（scrcpy-server.jar），
版权归 Genymobile 所有，按 Apache License 2.0 发布。
完整许可证见应用内「关于 → 查看完整许可证」。
TEXT

# .rtf 在 macOS 上双击就能用「文本编辑」打开，比 .txt 更适合发给设计同事。
textutil -convert rtf -output "$STAGE/使用说明.rtf" "$STAGE/使用说明.txt"
rm "$STAGE/使用说明.txt"

echo "==> 生成 $OUT"
rm -f "$OUT"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$OUT" >/dev/null

echo "完成：$OUT"
ls -lh "$OUT"
