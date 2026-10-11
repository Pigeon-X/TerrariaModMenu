#!/usr/bin/env bash
# =============================================================================
#  编译 macOS 原生预览器
#
#  产物：build/TerrariaModMenu-Preview-mac
#  依赖：只需要 Xcode 命令行工具（Command Line Tools）——
#        **不需要完整 Xcode**，因为这是 macOS 程序，用系统自带的 macOS SDK。
#
#  用法：
#     bash scripts/build_preview_mac.sh
#     ./build/TerrariaModMenu-Preview-mac                 # 交互调 UI
#     ./build/TerrariaModMenu-Preview-mac --shot ui.png   # 出截图
# =============================================================================
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

# 装了完整 Xcode 就切过去（不用 sudo）
. "$repo/scripts/_toolchain.sh"
detect_xcode || true
CXX="$(pick_clangxx)"

imgui="third_party/imgui"
if [ ! -f "$imgui/imgui.cpp" ]; then
  echo "缺少 $imgui —— 先跑 bash scripts/fetch_deps.sh" >&2
  exit 1
fi

out="build/TerrariaModMenu-Preview-mac"
mkdir -p build

# ---- 挑一个「能链接」的 macOS SDK ------------------------------------------
# 这台机器的坑：xcrun 默认给的 MacOSX27.0.sdk 比自带的 ld-1267 新，
# 里面的 .tbd 用到了 ld 不认识的架构名（arm64e.x1），链接阶段直接报
# "unknown architecture / malformed file"。所以这里实测一个能用的。
#
# 想手工指定：MODMENU_MAC_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
pick_sdk() {
  local probe="build/.sdk_probe"
  if [ -n "${MODMENU_MAC_SDK:-}" ]; then
    printf '%s\n' "$MODMENU_MAC_SDK"
    return
  fi
  local cands
  # 装了 Xcode 就优先用它的 macOS SDK（走固定路径，不碰 xcrun）
  cands="$( (mac_sdk)
            (xcrun --show-sdk-path 2>/dev/null || true)
            ls -d /Library/Developer/CommandLineTools/SDKs/*.sdk /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/*.sdk 2>/dev/null
          )"
  for c in $cands; do
    [ -d "$c" ] || continue
    if printf 'int main(){return 0;}\n' | "$CXX" -x c++ -isysroot "$c" \
         -framework Foundation -o "$probe" - >/dev/null 2>&1; then
      printf '%s\n' "$c"
      return
    fi
  done
}

sdk="$(pick_sdk)"
if [ -z "$sdk" ]; then
  echo "找不到能用的 macOS SDK（试着装/更新 Xcode 命令行工具：xcode-select --install）" >&2
  exit 1
fi
rm -f build/.sdk_probe

echo "[预览器] SDK: $sdk"

# 和 Windows 预览器用同一套开关：
#   -DMODMENU_PREVIEW  让 src/ui/menu.mm 走假数据分支（不碰 iOS / IL2CPP）
#   -DNDEBUG           关掉 ImGui 的 IM_ASSERT（否则断言会 abort）
"$CXX" -std=c++17 -fobjc-arc -O1 -g -isysroot "$sdk" \
  -DNDEBUG -DMODMENU_PREVIEW \
  -I"$imgui" -I"$imgui/backends" -Isrc -Isrc/ui \
  -Wno-unused-parameter -Wno-deprecated-declarations \
  preview/main_mac.mm \
  src/ui/menu.mm \
  src/ui/cheat_ui.mm \
  "$imgui/imgui.cpp" \
  "$imgui/imgui_draw.cpp" \
  "$imgui/imgui_tables.cpp" \
  "$imgui/imgui_widgets.cpp" \
  "$imgui/backends/imgui_impl_osx.mm" \
  "$imgui/backends/imgui_impl_metal.mm" \
  -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore \
  -framework ImageIO -framework CoreGraphics -framework Foundation \
  -framework GameController \
  -o "$out"

echo "[预览器] 产物：$out"
