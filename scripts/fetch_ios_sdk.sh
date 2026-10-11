#!/usr/bin/env bash
# =============================================================================
#  下载 iOS 设备 SDK（不用装 Xcode 也能编 iOS dylib）
#
#  为什么需要它：编译 iOS 的 dylib 只要有 **iPhoneOS.sdk** 就够了，
#  而这个 SDK 只随 Xcode 分发 —— 装完整 Xcode 要 10~40 GB + Apple ID。
#  这里改用 theos/sdks（iOS 越狱/tweak 圈通用的 SDK 镜像）里的一个版本，
#  只拉需要的那一个目录（git 稀疏检出），约 220 MB。
#
#  ⚠️ SDK 本身是 Apple 的东西、由第三方镜像再分发，属于灰色地带，
#     仅供本机自用。想要完全正规的路径，就装 Xcode，然后本脚本不用跑
#     （scripts/build_ios_local.sh 会优先用 Xcode 的 SDK）。
#
#  用法：
#     bash scripts/fetch_ios_sdk.sh            # 默认 iPhoneOS16.5
#     bash scripts/fetch_ios_sdk.sh 15.6       # 指定版本
# =============================================================================
set -euo pipefail

ver="${1:-16.5}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$repo/third_party/ios-sdk"

if [ -d "$dest/iPhoneOS${ver}.sdk" ]; then
  echo "==> 已存在：$dest/iPhoneOS${ver}.sdk，跳过"
  exit 0
fi

mkdir -p "$dest"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ios-sdk.XXXXXX")"

echo "==> 稀疏检出 theos/sdks 里的 iPhoneOS${ver}.sdk"
git clone --filter=blob:none --no-checkout --depth 1 \
  https://github.com/theos/sdks.git "$tmp/sdks"
git -C "$tmp/sdks" sparse-checkout init --cone
git -C "$tmp/sdks" sparse-checkout set "iPhoneOS${ver}.sdk"
git -C "$tmp/sdks" checkout

if [ ! -d "$tmp/sdks/iPhoneOS${ver}.sdk" ]; then
  echo "这个仓库里没有 iPhoneOS${ver}.sdk，可选版本见：" >&2
  echo "  https://github.com/theos/sdks" >&2
  exit 1
fi

mv "$tmp/sdks/iPhoneOS${ver}.sdk" "$dest/"
echo "==> 完成：$dest/iPhoneOS${ver}.sdk（$(du -sh "$dest/iPhoneOS${ver}.sdk" | cut -f1)）"
echo "    临时目录留在 ${tmp}（可以自己删）"
