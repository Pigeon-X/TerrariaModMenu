#!/usr/bin/env bash
# =============================================================================
#  模拟器宿主 App：在 iOS 模拟器里跑插件的渲染层
#
#  做三件事：
#    1. 编一份**模拟器版**的 dylib（make sim，产物带 -sim 后缀，不碰真机版）
#    2. 编壳 App 并装进 build/TerrariaSimHost.app
#    3. 装进模拟器跑起来（需要同意过 Xcode 许可协议）
#
#  用法：
#     bash scripts/build_simhost.sh            # 编译 + 尝试装进模拟器运行
#     bash scripts/build_simhost.sh --no-run   # 只编译
#     bash scripts/build_simhost.sh --open     # 启动时直接展开菜单（不用手点）
#     bash scripts/build_simhost.sh --shot a.png   # 启动后截一张图
#     bash scripts/build_simhost.sh --log      # 看插件在模拟器里的日志
#
#  能验证：Metal 叠加层、悬浮球点开/拖动、图标纹理、中文字体、按需渲染
#  验证不了：IL2CPP 反射、修改器（那些必须有游戏本体）
# =============================================================================
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

. "$repo/scripts/_toolchain.sh"
detect_xcode || true

BUNDLE_ID="local.terrariamodmenu.simhost"
app="$repo/build/TerrariaSimHost.app"

# 挑一台可用的 iPhone 模拟器（第一次找到就返回它的 udid）
simctl_dev() {
  xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
booted, others = [], []
for runtime, devs in d.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for x in devs:
        if not x.get("isAvailable"):
            continue
        if "iPhone" not in x.get("name", ""):
            continue
        (booted if x.get("state") == "Booted" else others).append(x["udid"])
# 已经开着的优先 —— 模拟器里可能同时开着好几台，别装到另一台上去
print((booted or others or [""])[0])
'
}

run=1
open_menu=0
shot=""
while [ $# -gt 0 ]; do
  case "$1" in
  --no-run) run=0; shift ;;
  --open)   open_menu=1; shift ;;
  --shot)   shot="${2:-}"; shift 2 ;;
  --log)
    license_ok || { echo "xcrun 不可用 —— 先跑：sudo xcodebuild -license accept" >&2; exit 1; }
    dev="$(simctl_dev || true)"
    [ -n "$dev" ] || { echo "没有可用的模拟器设备" >&2; exit 1; }
    container="$(xcrun simctl get_app_container "$dev" "$BUNDLE_ID" data 2>/dev/null || true)"
    [ -n "$container" ] || { echo "模拟器里还没装过宿主 App，先跑一次 $0" >&2; exit 1; }
    log="$container/Documents/TerrariaModMenu.log"
    [ -f "$log" ] || { echo "还没有日志：$log" >&2; exit 1; }
    tail -n 60 "$log"
    exit 0
    ;;
  -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

# ---- 0) 要有 Xcode（模拟器 SDK 只有它有）-----------------------------------
simsdk="$(sim_sdk)"
if [ -z "$simsdk" ]; then
  cat >&2 <<'EOF'
找不到 iPhoneSimulator SDK —— 这个必须要完整 Xcode。
装好之后如果 xcrun 报"没同意许可协议"，先跑：sudo xcodebuild -license accept
EOF
  exit 1
fi

cxx="$(pick_clangxx)"
cc="$(pick_clang)"
MAKE="$(pick_make)"

echo "[simhost] 模拟器 SDK: $simsdk"

# ---- 1) 模拟器版 dylib -----------------------------------------------------
echo "[simhost] 1/3 编模拟器版 dylib ..."
"$MAKE" sim SDKROOT="$simsdk" CXX="$cxx" CC="$cc" | tail -3

plug="$repo/build-sim/TerrariaModMenu-sim.dylib"
[ -f "$plug" ] || { echo "没产出 $plug" >&2; exit 1; }

# ---- 2) 壳 App -------------------------------------------------------------
echo "[simhost] 2/3 组装 App bundle ..."
rm -rf "$app"
mkdir -p "$app/Frameworks"

"$cxx" -std=c++17 -fobjc-arc -O1 -g -DNDEBUG \
  -arch arm64 -isysroot "$simsdk" -mios-simulator-version-min=15.0 \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
  -Wno-deprecated-declarations \
  "$repo/simhost/main.mm" -o "$app/TerrariaSimHost"

cp "$repo/simhost/Info.plist" "$app/Info.plist"
cp "$plug" "$app/Frameworks/TerrariaModMenu.dylib"

# clang 会把 dSYM 生成在可执行文件旁边 —— 也就是 App 包里面。挪出去，保持包干净。
if [ -d "$app/TerrariaSimHost.dSYM" ]; then
  rm -rf "$repo/build/TerrariaSimHost.dSYM"
  mv "$app/TerrariaSimHost.dSYM" "$repo/build/TerrariaSimHost.dSYM"
fi

# arm64 上跑的二进制至少要有个 ad-hoc 签名
codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1 \
  || echo "[simhost]   警告：ad-hoc 签名失败（不一定影响模拟器运行）"

echo "[simhost]   产物：$app"

# ---- 3) 装进模拟器 ---------------------------------------------------------
open_gui() {
  # Xcode 26 起 Simulator.app 被 DeviceHub.app 取代了（Xcode 27 里已经找不到
  # Simulator.app），老的 `open -a Simulator` 会直接失败："Unable to find
  # application named 'Simulator'"，界面也就不会弹出来。这里两个都试。
  local dh="/Applications/Xcode.app/Contents/Applications/DeviceHub.app"
  local sx
  sx="$(/usr/bin/xcode-select -p 2>/dev/null)/Applications/Simulator.app"
  if [ -d "$dh" ]; then
    open "$dh" 2>/dev/null && return 0
  fi
  if [ -d "$sx" ]; then
    open "$sx" 2>/dev/null && return 0
  fi
  return 1
}

if [ "$run" = 0 ]; then
  exit 0
fi

if ! license_ok; then
  echo
  echo "[simhost] ⚠️  还不能自动装进模拟器：Xcode 许可协议没同意。"
  echo "           跑一次：sudo xcodebuild -license accept"
  echo "           （然后重新执行本脚本即可自动装+启动）"
  exit 0
fi

echo "[simhost] 3/3 装进模拟器 ..."
dev="$(simctl_dev)"
if [ -z "$dev" ]; then
  echo "[simhost]   没有可用的 iPhone 模拟器 —— 打开 Xcode → Settings → Components"
  echo "           下载一个 iOS 模拟器运行时，再重跑本脚本。"
  exit 0
fi

xcrun simctl boot "$dev" 2>/dev/null || true
xcrun simctl bootstatus "$dev" -b >/dev/null 2>&1 || true
xcrun simctl install "$dev" "$app"
if [ "$open_menu" = 1 ]; then
  # simctl 用 SIMCTL_CHILD_ 前缀把环境变量透给 App
  export SIMCTL_CHILD_MODMENU_SIM_START_OPEN=1
fi
xcrun simctl launch "$dev" "$BUNDLE_ID" || true
if open_gui; then
  echo "[simhost] 已打开模拟器界面（DeviceHub）—— 在窗口里点左边的紫色球就能展开菜单"
else
  echo "[simhost] ⚠️  没能自动打开模拟器界面，手动开："
  echo "           open \"/Applications/Xcode.app/Contents/Applications/DeviceHub.app\""
fi

if [ -n "$shot" ]; then
  sleep 3
  xcrun simctl io "$dev" screenshot "$shot" >/dev/null 2>&1 && echo "[simhost] 截图：$shot"
fi

echo
echo "[simhost] 已启动。看插件自己的日志："
echo "            bash scripts/build_simhost.sh --log"
