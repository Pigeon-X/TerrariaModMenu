#!/usr/bin/env bash
# =============================================================================
#  环境体检：这台 Mac 现在能干什么、还缺什么
#
#  用法：bash scripts/check_env.sh
# =============================================================================
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo/scripts/_toolchain.sh"
detect_xcode || true

ok()   { printf '  ✅ %s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; }

echo "== 系统 =="
printf '  macOS %s（%s）\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"

echo "== 编译工具链 =="
if xcode-select -p >/dev/null 2>&1; then
  dev="$(xcode-select -p)"
  if [[ "$dev" == *CommandLineTools* ]]; then
    ok "命令行工具：$dev"
  else
    ok "xcode-select 指向 Xcode：$dev"
  fi
else
  bad "连命令行工具都没有 —— 先跑 xcode-select --install"
fi
if [ -n "${DEVELOPER_DIR:-}" ]; then
  ok "完整 Xcode：$DEVELOPER_DIR（走 DEVELOPER_DIR，不需要 sudo）"
  if xcodebuild -version >/dev/null 2>&1; then
    printf '  %s\n' "$(xcodebuild -version 2>/dev/null | head -1)"
  else
    warn "xcodebuild 用不了 —— 多半是还没同意 Xcode 许可协议（开一次 Xcode，输管理员密码即可）"
  fi
else
  warn "没有完整 Xcode（只有命令行工具）—— 编不了模拟器版，也用不了 simctl"
fi
printf '  clang: %s\n' "$("$(pick_clangxx)" --version 2>/dev/null | head -1)"

echo "== iOS SDK（编 dylib 用）=="
if sdk="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)" && [ -n "$sdk" ] && [ -d "$sdk" ]; then
  ok "Xcode 自带的：$sdk"
else
  warn "Xcode 自带的拿不到（没装完整 Xcode）"
  found="$(ls -d "$repo"/third_party/ios-sdk/iPhoneOS*.sdk 2>/dev/null || true)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found" | while read -r p; do ok "本地下载的：$p"; done
  else
    bad "本地也没有 —— 跑 bash scripts/fetch_ios_sdk.sh（约 220 MB）"
  fi
fi

echo "== macOS SDK（编预览器用）=="
probe="$(mktemp -d)/probe"
good=""
for c in $(xcrun --show-sdk-path 2>/dev/null || true) \
         $(ls -d /Library/Developer/CommandLineTools/SDKs/*.sdk 2>/dev/null); do
  [ -d "$c" ] || continue
  if printf 'int main(){return 0;}\n' | clang++ -x c++ -isysroot "$c" \
       -framework Foundation -o "$probe" - >/dev/null 2>&1; then
    good="$c"
    break
  fi
done
[ -n "$good" ] && ok "能用的是：$good" || bad "没有能链接的 macOS SDK"

echo "== 依赖 =="
[ -f "$repo/third_party/imgui/imgui.cpp" ] && ok "imgui" || bad "imgui 没拉 —— bash scripts/fetch_deps.sh"
[ -f "$repo/third_party/lua/src/lua.h" ]  && ok "lua"   || bad "lua 没拉 —— bash scripts/fetch_deps.sh"

echo "== 装到真机上要用的 =="
if xcrun simctl list runtimes >/dev/null 2>&1; then
  ok "有 iOS 模拟器运行时（需要完整 Xcode）"
else
  warn "没有 iOS 模拟器（simctl 不可用）—— 注意：就算有，也跑不了设备版 IPA"
fi
devs="$(system_profiler SPUSBDataType 2>/dev/null | grep -icE 'iPhone|iPad' || true)"
if [ "${devs:-0}" -gt 0 ]; then
  ok "USB 上接着 iOS 设备"
else
  warn "没检测到 iOS 设备"
fi
ls /Applications 2>/dev/null | grep -qiE 'sideloadly|altstore|trollstore' \
  && ok "装了重签工具（Sideloadly / AltStore / TrollStore）" \
  || warn "没装重签工具 —— IPA 注入后要用它签名才能装"

echo "== GitHub =="
if [ -d "$repo/.git" ]; then
  ok "工程是 git 工作副本（remote: $(git -C "$repo" remote get-url origin 2>/dev/null)）"
else
  warn "工程不是 git 工作副本"
fi
if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
     -T git@github.com >/dev/null 2>&1; then
  ok "GitHub SSH 可用（能推代码、能触发 CI）"
else
  warn "GitHub SSH 不可用（推不了代码，只能本地编译）"
fi

echo
echo "== 结论 =="
echo "  编 dylib：bash scripts/build_ios_local.sh"
echo "  调 UI  ：bash scripts/build_preview_mac.sh && ./build/TerrariaModMenu-Preview-mac"
echo "  出成品：bash scripts/make_release.sh"
echo "  装真机：需要 iOS 设备 + 重签工具（+ Apple ID）"
