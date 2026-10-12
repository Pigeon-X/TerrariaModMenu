#!/usr/bin/env bash
# =============================================================================
#  真机测试工具（靠 Xcode 自带的 devicectl）
#
#  能干的活：列出真机 / 装包 / 启动并抓控制台 / 把插件日志拉回本地 / 真机截图
#
#  前提：
#    1. iPhone 用数据线连到 Mac，手机上点「信任此电脑」
#    2. 目标 App 已经用你的 Apple ID 签过名装过一次
#       （Sideloadly / AltStore / TrollStore —— 签名这步代替不了，
#         因为要用你自己的 Apple ID）
#
#  用法：
#    bash scripts/device_test.sh list              # 看有哪些真机
#    bash scripts/device_test.sh install <装好的.app>
#    bash scripts/device_test.sh launch            # 启动游戏（不挂控制台）
#    bash scripts/device_test.sh console           # 启动并实时打印 app 输出
#    bash scripts/device_test.sh log               # 把插件日志拉到本地并打印
#    bash scripts/device_test.sh shot              # 真机截屏存到 build/device/
#    bash scripts/device_test.sh crash             # 拉最近的应用崩溃日志
# =============================================================================
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

BUNDLE="com.505games.terraria"      # 游戏本体
OUT="$repo/build/device"
mkdir -p "$OUT"

# 取第一台「真机」（reality 不是 simulated）
pick_device() {
  xcrun devicectl list devices --json-output - 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for dev in d.get("result",{}).get("devices",[]):
    if dev.get("connectionProperties",{}).get("tunnelState") is None: pass
    # 只挑真机
    hw = dev.get("hardwareProperties",{})
    if hw.get("reality") == "physical":
        print(dev.get("identifier","")); sys.exit(0)
'
}

DEV="$(pick_device)"
case "${1:-}" in
  list)
    xcrun devicectl list devices
    exit 0
    ;;
esac

if [ -z "$DEV" ]; then
  cat >&2 <<'EOF'
没找到真机。要做的：
  1) 用数据线把 iPhone 连到 Mac
  2) 手机上弹「信任此电脑」点信任（没弹就去 设置→通用→VPN与设备管理 里信任）
  3) 再跑一次本命令
（连着的时候也可以只看一眼：bash scripts/device_test.sh list）
EOF
  exit 1
fi

echo "[真机] 设备：$DEV"

case "${1:-log}" in
  install)
    [ -n "${2:-}" ] || { echo "用法：$0 install <xxx.app 或 xxx.ipa>" >&2; exit 2; }
    xcrun devicectl device install app --device "$DEV" "$2"
    ;;
  launch)
    xcrun devicectl device process launch --device "$DEV" --terminate-existing "$BUNDLE"
    ;;
  console)
    # --console 会把 app 的 stdout/stderr 桥到这边，日志会一直刷
    xcrun devicectl device process launch --device "$DEV" --terminate-existing --console "$BUNDLE"
    ;;
  log)
    # 插件的日志写在 app 沙盒的 Documents 里，直接拉回来
    xcrun devicectl device copy from --device "$DEV" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE" \
        --source Documents/TerrariaModMenu.log \
        --destination "$OUT/TerrariaModMenu.log"
    echo "== 已拉到 $OUT/TerrariaModMenu.log（最后 60 行）=="
    tail -n 60 "$OUT/TerrariaModMenu.log"
    ;;
  shot)
    xcrun devicectl device capture --device "$DEV" "$OUT/screen.png"
    echo "== 截图：$OUT/screen.png =="
    ;;
  crash)
    xcrun devicectl device copy from --device "$DEV" \
        --domain-type systemCrashLogs --source . --destination "$OUT/crashlogs" || true
    ls -t "$OUT/crashlogs" 2>/dev/null | head -5
    ;;
  *)
    sed -n '2,22p' "${BASH_SOURCE[0]}"
    ;;
esac
