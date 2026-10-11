#!/usr/bin/env bash
# =============================================================================
#  把插件发到 GitHub 上游（Pigeon-X/TerrariaModMenu）
#
#  做三件事：
#    1. 把本地改动提交
#    2. 推到 origin（SSH）
#    3. 提示：仓库里的 GitHub Actions 会自动编译 dylib，
#       并把产物写回 dist/TerrariaModMenu.dylib（这就是"发出来"的成品）
#
#  推完还会**等 CI 编好、把产物拉回来、同步到 ios 文件夹根目录**，
#  这样工作区里那份 dylib 永远和上游一致。
#
#  用法：
#     bash scripts/publish.sh                 # 自动生成提交说明
#     bash scripts/publish.sh "改了什么"        # 指定提交说明
#     bash scripts/publish.sh --no-wait       # 推完就走，不等 CI
#
#  前提：本机的 SSH key 要有这个仓库的写权限
#    （GitHub → 仓库 → Settings → Deploy keys，勾上 Allow write access；
#      或者加成账号级 SSH key，那样所有仓库都能推）
# =============================================================================
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

wait_ci=1
msg=""
for a in "$@"; do
  case "$a" in
    --no-wait) wait_ci=0 ;;
    *)         [ -z "$msg" ] && msg="$a" ;;
  esac
done

before_head="$(git rev-parse origin/main 2>/dev/null || echo none)"

if [ -z "$(git status --porcelain)" ]; then
  echo "没有改动，直接推一次试试（可能是之前提交过没推上去）"
else
  if [ -z "$msg" ]; then
    n=$(git status --porcelain | wc -l | tr -d ' ')
    msg="更新插件（$n 个文件）"
  fi
  git add -A
  git commit -q -m "$msg"
  echo "已提交：$msg"
  git --no-pager log --oneline -1
fi

# 顺手把本地编好的那份拷到上层 ios 文件夹根目录（省得去 GitHub 拿）
here_root="$(dirname "$repo")"
if [ -f "$repo/build/TerrariaModMenu.dylib" ]; then
  cp -f "$repo/build/TerrariaModMenu.dylib" "$here_root/TerrariaModMenu.dylib" && \
    echo "已拷到：$here_root/TerrariaModMenu.dylib"
fi

echo "推送到 origin ..."
if ! GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" git push origin main 2>&1; then
  cat >&2 <<'EOF'

推送失败。最常见的原因是这把 SSH key 没有这个仓库的写权限。
去 GitHub 把这个仓库加上写权限：
  Settings → Deploy keys → Add deploy key → 勾选 "Allow write access"
或者把它加成账号级 key（Settings → SSH and GPG keys），一次管所有仓库。
EOF
  exit 1
fi

if [ "$wait_ci" = 0 ]; then
  cat <<'EOF'

推好了。仓库里的 GitHub Actions 会自动编译 dylib 并写回 dist/。
想过一会儿把上游那份同步到工作区：
    git pull && cp dist/TerrariaModMenu.dylib ../TerrariaModMenu.dylib
EOF
  exit 0
fi

# ---- 等 CI 把产物提交回来，再同步到工作区 ----------------------------------
echo "等 CI 编译并回传产物（最多 8 分钟，Ctrl-C 可以先走）..."
ok=0
for _ in $(seq 1 16); do
  sleep 30
  git fetch -q origin main 2>/dev/null || continue
  now_head="$(git rev-parse origin/main 2>/dev/null || echo none)"
  [ "$now_head" = "$before_head" ] && continue
  if git --no-pager log --oneline -1 origin/main | grep -q "ci:"; then
    if git pull -q --rebase origin main; then ok=1; break; fi
  fi
done

if [ "$ok" = 1 ] && [ -f "$repo/dist/TerrariaModMenu.dylib" ]; then
  cp -f "$repo/dist/TerrariaModMenu.dylib" "$here_root/TerrariaModMenu.dylib"
  echo
  echo "已同步上游产物到：$here_root/TerrariaModMenu.dylib"
  echo "  $(wc -c <"$here_root/TerrariaModMenu.dylib" | tr -d '[:space:]') 字节  sha256=$(shasum -a 256 "$here_root/TerrariaModMenu.dylib" | cut -c1-16)"
else
  cat <<'EOF'

CI 还没回传（可能还在排队）。过几分钟跑这两条同步一下：
    git pull
    cp dist/TerrariaModMenu.dylib ../TerrariaModMenu.dylib
EOF
fi
