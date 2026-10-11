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
#  用法：
#     bash scripts/publish.sh                 # 自动生成提交说明
#     bash scripts/publish.sh "改了什么"        # 指定提交说明
#
#  前提：本机的 SSH key 要有这个仓库的写权限
#    （GitHub → 仓库 → Settings → Deploy keys，勾上 Allow write access；
#      或者加成账号级 SSH key，那样所有仓库都能推）
# =============================================================================
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

msg="${1:-}"

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

cat <<'EOF'

推好了。仓库里的 GitHub Actions 会自动：
  · 编译 TerrariaModMenu.dylib
  · 把产物写回 dist/（提交信息带 [skip ci]）
过几分钟 git pull 就能拿到新编的 dylib。
EOF
