#!/usr/bin/env bash
# =============================================================================
#  把插件发到 GitHub 上游（Pigeon-X/TerrariaModMenu）
#
#  做三件事：
#    1. 本地先编一遍 —— 编不过就不推，免得把编不过的提交推上去
#    2. 提交 + 推送到 origin
#    3. 把本地编好的 dylib 拷到 ios 文件夹根目录（省得去 GitHub 拿）
#
#  ⚠️ 仓库里**不放任何构建产物**：dist/ 已在 .gitignore 里，
#     上游的 CI 也只做「编译校验」，不回传 dylib / exe / 日志。
#     成品一律在本地产：dylib 用 build_ios_local.sh，IPA 用 ../出包.sh。
#
#  用法：
#     bash scripts/publish.sh                 # 自动生成提交说明
#     bash scripts/publish.sh "改了什么"        # 指定提交说明
#     bash scripts/publish.sh --no-build      # 跳过本地编译校验
#
#  前提：本机 SSH key 有写权限（账号级 key 或该仓库勾了 Allow write access）
# =============================================================================
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

do_build=1
msg=""
for a in "$@"; do
  case "$a" in
    --no-build) do_build=0 ;;
    *)          [ -z "$msg" ] && msg="$a" ;;
  esac
done

# ---- 1) 本地编译校验 -------------------------------------------------------
if [ "$do_build" = 1 ]; then
  echo "本地编译校验 ..."
  if ! bash scripts/build_ios_local.sh 2>&1 | tail -3; then
    echo "编译没过，先修好再推。" >&2
    exit 1
  fi
fi

# ---- 2) 提交 + 推送 --------------------------------------------------------
if [ -z "$(git status --porcelain)" ]; then
  echo "没有改动，直接推一次（可能是之前提交过没推上去）"
else
  if [ -z "$msg" ]; then
    msg="更新插件（$(git status --porcelain | wc -l | tr -d ' ') 个文件）"
  fi
  git add -A
  git commit -q -m "$msg"
  echo "已提交：$msg"
  git --no-pager log --oneline -1
fi

# 先 rebase：上游可能被别处（比如网页上直接改）推过新提交，
# 直接 push 会被拒成 non-fast-forward。
if ! git pull -q --rebase origin main; then
  echo "rebase 有冲突，先解决完再推（git status 看冲突文件）" >&2
  exit 1
fi

echo "推送到 origin ..."
if ! GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" git push origin main; then
  cat >&2 <<'EOF'

推送失败。常见两种原因：
  1. 这把 SSH key 没有该仓库的写权限
     （GitHub → 仓库 → Settings → Deploy keys 勾 Allow write access，
       或者加成账号级 key：Settings → SSH and GPG keys）
  2. 上游有别人的新提交，上面那句 pull --rebase 没成功
EOF
  exit 1
fi

# ---- 3) 同步一份到 ios 文件夹 -------------------------------------------------
root="$(dirname "$repo")"
if [ -f "$repo/build/TerrariaModMenu.dylib" ]; then
  cp -f "$repo/build/TerrariaModMenu.dylib" "$root/TerrariaModMenu.dylib"
  echo
  echo "已放到工作区：$root/TerrariaModMenu.dylib"
  echo "  $(wc -c <"$root/TerrariaModMenu.dylib" | tr -d '[:space:]') 字节"
fi

echo
echo "推好了。上游 CI 只做编译校验，不保留产物 —— 成品以本地产的为准。"
