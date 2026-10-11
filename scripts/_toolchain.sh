#!/usr/bin/env bash
# =============================================================================
#  被其它脚本 source 的共用部分：定位工具链
#
#  用法：  . "$repo/scripts/_toolchain.sh"
#          detect_xcode
#          sdk="$(ios_sdk)"; cxx="$(pick_clangxx)"
#
#  两个坑都在这儿绕开：
#   1. 从 App Store 装完 Xcode 后 `xcode-select -p` 依然指着 CommandLineTools，
#      而切换它要 `sudo xcode-select -s` —— 所以这里改用 DEVELOPER_DIR。
#   2. **同意 Xcode 许可协议之前 `xcrun` 整个不可用**（会报
#      "You have not agreed to the Xcode license agreements"）。
#      但编译其实不受影响，所以我们不走 xcrun，直接按路径取 Xcode 自带的
#      clang 和 SDK —— 许可协议没同意也能正常编译。
# =============================================================================

# 找到 Xcode 就 export DEVELOPER_DIR；返回 0 表示找到了
detect_xcode() {
  if [ -n "${DEVELOPER_DIR:-}" ] && [ -d "$DEVELOPER_DIR" ]; then
    return 0
  fi

  # 已经用 xcode-select 切到 Xcode 的就是它
  local cur
  cur="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  case "$cur" in
    *Xcode*.app/Contents/Developer)
      export DEVELOPER_DIR="$cur"
      return 0
      ;;
  esac

  # 否则在 /Applications 里找（App Store 装完就是这一种）
  local app
  for app in /Applications/Xcode*.app; do
    if [ -d "$app/Contents/Developer" ]; then
      export DEVELOPER_DIR="$app/Contents/Developer"
      return 0
    fi
  done
  return 1
}

# Xcode 自带的编译器（绕开 xcrun）；没有 Xcode 就退回命令行工具的
pick_clangxx() {
  if [ -n "${DEVELOPER_DIR:-}" ] &&
     [ -x "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++" ]; then
    printf '%s\n' "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"
    return
  fi
  local c
  c="$(xcrun -f clang++ 2>/dev/null || true)"
  if [ -n "$c" ] && [ -x "$c" ]; then
    printf '%s\n' "$c"
  else
    command -v clang++
  fi
}

pick_clang() {
  if [ -n "${DEVELOPER_DIR:-}" ] &&
     [ -x "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" ]; then
    printf '%s\n' "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    return
  fi
  local c
  c="$(xcrun -f clang 2>/dev/null || true)"
  if [ -n "$c" ] && [ -x "$c" ]; then
    printf '%s\n' "$c"
  else
    command -v clang
  fi
}

# ---- SDK 路径（先走 Xcode 的固定路径，绕开 xcrun）--------------------------

ios_sdk() {          # 真机 SDK
  local p="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
  if [ -n "${DEVELOPER_DIR:-}" ] && [ -d "$p" ]; then
    printf '%s\n' "$p"
    return
  fi
  local x
  x="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
  if [ -n "$x" ] && [ -d "$x" ]; then
    printf '%s\n' "$x"
    return
  fi
  # 退到本地下载的那个 SDK（没装 Xcode 时的路子）
  python3 - "${repo:-.}/third_party/ios-sdk" <<'PY'
import glob, os, re, sys
best = None
for p in glob.glob(os.path.join(sys.argv[1], 'iPhoneOS*.sdk')):
    m = re.search(r'iPhoneOS(\d+(?:\.\d+)*)\.sdk$', os.path.basename(p))
    if not m:
        continue
    v = tuple(int(x) for x in m.group(1).split('.'))
    if best is None or v > best[0]:
        best = (v, p)
print(best[1] if best else '')
PY
}

sim_sdk() {          # 模拟器 SDK
  local p="$DEVELOPER_DIR/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
  if [ -n "${DEVELOPER_DIR:-}" ] && [ -d "$p" ]; then
    printf '%s\n' "$p"
    return
  fi
  local x
  x="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
  [ -n "$x" ] && [ -d "$x" ] && printf '%s\n' "$x"
}

mac_sdk() {          # macOS SDK
  local p="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
  if [ -n "${DEVELOPER_DIR:-}" ] && [ -d "$p" ]; then
    printf '%s\n' "$p"
    return
  fi
  local x
  x="$(xcrun --show-sdk-path 2>/dev/null || true)"
  [ -n "$x" ] && [ -d "$x" ] && printf '%s\n' "$x"
}

# 许可协议同意了吗？（xcrun / simctl 这类工具需要）
license_ok() {
  xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1
}

# make：**别用 /usr/bin/make**。
# 装完 Xcode 之后 /usr/bin/make 变成了会走 Xcode 许可检查的 shim，
# 许可没同意时哪怕在空目录里跑都直接失败（exit 69）。按绝对路径调用就没事。
pick_make() {
  if [ -x /Library/Developer/CommandLineTools/usr/bin/make ]; then
    printf '%s\n' /Library/Developer/CommandLineTools/usr/bin/make
    return
  fi
  if [ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/usr/bin/make" ]; then
    printf '%s\n' "$DEVELOPER_DIR/usr/bin/make"
    return
  fi
  command -v make
}

# 同理：otool / ld / nm / as / ar / strings / install_name_tool … 这些
# /usr/bin 下的开发工具也全是走许可检查的 shim。取一份能直接用的。
pick_tool() {
  local name="$1"
  if [ -x "/Library/Developer/CommandLineTools/usr/bin/$name" ]; then
    printf '%s\n' "/Library/Developer/CommandLineTools/usr/bin/$name"
    return
  fi
  if [ -n "${DEVELOPER_DIR:-}" ] &&
     [ -x "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/$name" ]; then
    printf '%s\n' "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/$name"
    return
  fi
  command -v "$name"
}
