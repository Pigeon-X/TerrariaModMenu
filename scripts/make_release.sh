#!/usr/bin/env bash
# =============================================================================
#  一键出成品（macOS / Linux 版，对应包根目录的 打包ModMenu成品.ps1）
#
#   1. 找 dylib：优先用本地编译的 build/TerrariaModMenu.dylib
#                （由 scripts/build_ios_local.sh 产出）
#                本地没有才用 GitHub 上 CI 编好的 dist/TerrariaModMenu.dylib
#   2. 注入到「悠然汉化 + 标准版字体」底包
#   3. 输出到包根目录，等你自己签名安装
#
#  用法：
#     bash scripts/make_release.sh                      # 全自动
#     bash scripts/make_release.sh "别的底包.ipa"          # 指定底包
#     bash scripts/make_release.sh -o "输出.ipa"          # 指定输出
#     bash scripts/make_release.sh --no-fetch            # 不联网
#     bash scripts/make_release.sh --dylib 某处/xx.dylib   # 指定 dylib
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
pkg="$(dirname "$repo")"

fetch=1
base_ipa=""
out_ipa=""
dylib=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) fetch=0; shift ;;
    -o|--out)   out_ipa="$2"; shift 2 ;;
    --dylib)    dylib="$2"; shift 2 ;;
    -h|--help)  sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)         echo "未知参数：$1" >&2; exit 2 ;;
    *)          base_ipa="$1"; shift ;;
  esac
done

say() { printf '%s\n' "$*"; }

# ---- 找底包 ----------------------------------------------------------------
if [ -z "$base_ipa" ]; then
  for c in \
    "$pkg/IPA/底包/Terraria_iOS_悠然汉化_标准版字体.ipa" \
    "$pkg/IPA/成品/Terraria-iOS汉化修正-圆体.ipa" \
    "$pkg/Terraria_iOS_悠然汉化_标准版字体.ipa"
  do
    [ -f "$c" ] && base_ipa="$c" && break
  done
fi
if [ -z "$base_ipa" ]; then
  base_ipa="$(find "$pkg" -maxdepth 3 -name '*.ipa' ! -name '*含ModMenu*' -print -quit 2>/dev/null || true)"
fi
if [ -z "$base_ipa" ] || [ ! -f "$base_ipa" ]; then
  echo "找不到底包 IPA，请显式传一个路径：bash scripts/make_release.sh 底包.ipa" >&2
  exit 1
fi

# ---- 输出与 dylib ----------------------------------------------------------
# 成品统一进 IPA/成品/（工作区约定：所有 IPA 只放 IPA/ 这一个文件夹）
[ -n "$out_ipa" ] || out_ipa="$pkg/IPA/成品/Terraria-iOS汉化mod.ipa"
[ -n "$dylib" ]   || dylib="$repo/build/TerrariaModMenu.dylib"

# ---- 1) 准备 dylib ---------------------------------------------------------
# 本地有编译产物就以它为准；同时（可联网时）把 CI 的拉到 dist/ 当备份。
if [ "$fetch" = 1 ] && [ -d "$repo/.git" ]; then
  say '== 1/3 取 CI 的 dylib 备份（dist/）=='
  if git -C "$repo" fetch -q origin main &&
     git -C "$repo" checkout -q origin/main -- dist/TerrariaModMenu.dylib; then
    # dist/ 在 .gitignore 里但被 CI 强制提交；checkout 会把它放进暂存区，
    # 这里撤掉暂存，免得以后 commit 时被捎带上（交接文档 5.11 提过这个坑）。
    git -C "$repo" reset -q dist/TerrariaModMenu.dylib 2>/dev/null || true
  else
    say '   ⚠️ 拉取失败（没网 / 没权限），跳过'
  fi
else
  say '== 1/3 跳过 CI 备份 =='
fi

if [ ! -f "$dylib" ] && [ -f "$repo/dist/TerrariaModMenu.dylib" ]; then
  dylib="$repo/dist/TerrariaModMenu.dylib"
  say '   本地没有 build/TerrariaModMenu.dylib，改用 CI 产物'
fi

if [ ! -f "$dylib" ]; then
  echo "找不到 dylib：$dylib" >&2
  echo "先本地编一个：bash scripts/build_ios_local.sh" >&2
  echo "（或者推到 GitHub 让 CI 编，再重跑本脚本）" >&2
  exit 1
fi
# 注意：macOS 自带 bash 3.2，`$dylib（` 会把多字节的「（」当成变量名的一部分
# 而报 unbound variable，所以这里必须写成 ${dylib}
say "   dylib: ${dylib}（$(wc -c <"$dylib" | tr -d '[:space:]') 字节）"

# ---- 2) 注入 ---------------------------------------------------------------
say '== 2/3 注入 =='
python3 "$repo/scripts/inject_ipa.py" "$base_ipa" --dylib "$dylib" -o "$out_ipa"

# ---- 3) 完成 ---------------------------------------------------------------
say '== 3/3 完成 =='
say "   成品: $out_ipa"
say "   底包: $(basename "$base_ipa")（未改动）"
say '   别忘了重新签名再安装（Sideloadly / AltStore / TrollStore）。'
