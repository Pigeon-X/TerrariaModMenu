#!/usr/bin/env bash
# 拉第三方源码到 third_party/（不需要提交进仓库）
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p third_party

if [ ! -d third_party/imgui/.git ]; then
  # 固定版本：1.92 起字体系统改动较大，先锁在稳定的 1.90.9
  echo "==> 拉取 Dear ImGui v1.90.9"
  git clone --depth 1 --branch v1.90.9 https://github.com/ocornut/imgui.git third_party/imgui
else
  echo "==> Dear ImGui 已存在，跳过"
fi

if [ ! -f third_party/lua/lua.h ]; then
  echo "==> 拉取 Lua 5.4.7"
  tmp="$(mktemp -d)"
  curl -fL -o "$tmp/lua.tar.gz" https://www.lua.org/ftp/lua-5.4.7.tar.gz
  tar -xzf "$tmp/lua.tar.gz" -C third_party
  mv third_party/lua-5.4.7 third_party/lua
  rm -rf "$tmp"
else
  echo "==> Lua 已存在，跳过"
fi

echo "==> 完成"
