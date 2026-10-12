#!/usr/bin/env bash
# =============================================================================
#  在 Mac 上本地编译 TerrariaModMenu.dylib —— 不需要完整 Xcode
#
#  只需要：Xcode 命令行工具（xcode-select --install）
#        + 一个 iPhoneOS.sdk（scripts/fetch_ios_sdk.sh 会下）
#  或者：装了完整 Xcode，脚本会自动优先用 Xcode 自带的 SDK。
#
#  用法：
#     bash scripts/build_ios_local.sh            # 通用版（默认）
#     bash scripts/build_ios_local.sh specific   # 专用版
#     MODMENU_IOS_SDK=/path/to/iPhoneOS16.5.sdk bash scripts/build_ios_local.sh
#
#  产物：build/TerrariaModMenu.dylib
# =============================================================================
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

# 装了完整 Xcode 就切过去（不用 sudo）
. "$repo/scripts/_toolchain.sh"
detect_xcode || true

mode="${1:-generic}"
case "$mode" in
  generic|specific) ;;
  *) echo "用法：$0 [generic|specific]" >&2; exit 2 ;;
esac

# ---- 找一个能用的 iPhoneOS SDK ---------------------------------------------
# 优先 Xcode 自带的（走 DEVELOPER_DIR 固定路径，绕开需要许可协议的 xcrun），
# 没有 Xcode 才退到 third_party/ios-sdk/ 下本地下载的那个。
sdk="${MODMENU_IOS_SDK:-$(ios_sdk)}"
if [ -z "$sdk" ] || [ ! -d "$sdk" ]; then
  cat >&2 <<'EOF'
找不到 iPhoneOS SDK。两条路：
  A. 装完整 Xcode（App Store），然后重跑本脚本；
  B. 不装 Xcode：bash scripts/fetch_ios_sdk.sh   （约 220 MB）
EOF
  exit 1
fi

MAKE="$(pick_make)"
clangxx="$(pick_clangxx)"
clangc="$(pick_clang)"

echo "[ModMenu] SDK: $sdk"
echo "[ModMenu] 编译器: $clangxx"

# Makefile 里的 SDKROOT / CXX / CC 是靠 xcrun 探测的，没 Xcode 时探测不到；
# 这里从命令行覆盖掉它们（命令行赋值优先级最高）。
"$MAKE" "$mode" SDKROOT="$sdk" CXX="$clangxx" CC="$clangc"

out="build/TerrariaModMenu.dylib"
if [ ! -f "$out" ]; then
  echo "编译没有产出 $out" >&2
  exit 1
fi

# ---- 自检：确认它真的是个 iOS 的 arm64 dylib -------------------------------
OTOOL="$(pick_tool otool)"
plat="$("$OTOOL" -l "$out" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')"
minos="$("$OTOOL" -l "$out" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
name="$("$OTOOL" -D "$out" | tail -1)"
echo "[ModMenu] 产物：$out"
echo "          platform=${plat}（2 = iOS，7 = iOS 模拟器）  minos=${minos}"
echo "          install_name=${name}"
if [ "$plat" != "2" ]; then
  echo "⚠️ 这不是 iOS 设备版的 dylib，注入进 IPA 是跑不起来的。" >&2
  exit 1
fi

# ---- 顺手放一份到上层 ios 文件夹 -------------------------------------------
# 约定：插件成品永远在 ios 文件夹根目录有一份，不用去 GitHub 拿、也不用翻 build/。
# 放在这里（而不是只放在出包/发布脚本里）是为了"不管走哪条路编，
# 工作区那份都是最新的"。
dest="$(dirname "$repo")/TerrariaModMenu.dylib"
if cp -f "$out" "$dest" 2>/dev/null; then
  echo "          已放到工作区：$dest"
else
  echo "          （没能拷到 $dest，可能没写权限，不影响编译）"
fi
