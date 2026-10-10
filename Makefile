# ---------------------------------------------------------------------------
# Terraria iOS Mod Menu —— 构建 TerrariaModMenu.dylib
#
#   make generic     通用版（按名解析 IL2CPP，不依赖任何偏移）
#   make specific    专用版（额外启用针对具体版本的偏移表）
#
# 需要 macOS + Xcode 命令行工具（xcrun）。
# 没有 Mac 就用 .github/workflows/build.yml 跑 CI。
# ---------------------------------------------------------------------------

NAME     := TerrariaModMenu
BUILD    := build
MODE     ?= generic

SDKROOT  := $(shell xcrun --sdk iphoneos --show-sdk-path)
CXX      := $(shell xcrun -sdk iphoneos -f clang++)
CC       := $(shell xcrun -sdk iphoneos -f clang)

ARCH     := arm64
MIN_IOS  := 15.0

COMMON   := -arch $(ARCH) -isysroot $(SDKROOT) -miphoneos-version-min=$(MIN_IOS) \
            -O2 -fvisibility=hidden -Wall -Wno-unused-parameter

CXXFLAGS := -std=c++17 -fobjc-arc $(COMMON) -Isrc
CFLAGS   := $(COMMON) -Isrc

LDFLAGS  := $(COMMON) -dynamiclib \
            -install_name @executable_path/Frameworks/$(NAME).dylib \
            -framework Foundation -framework UIKit -framework Metal \
            -framework QuartzCore -framework CoreGraphics

ifeq ($(MODE),specific)
  CXXFLAGS += -DMODMENU_SPECIFIC=1
  $(info [ModMenu] 构建：专用版（含偏移表）)
else
  $(info [ModMenu] 构建：通用版（纯按名解析）)
endif

# ---- 源码 ------------------------------------------------------------------
SRC_CPP := $(shell find src -name '*.mm' -o -name '*.cpp' 2>/dev/null)
SRC_C   := $(shell find src -name '*.c' 2>/dev/null)

# ---- 第三方（脚本拉下来后自动参与编译）-------------------------------------
ifneq ($(wildcard third_party/imgui/imgui.cpp),)
  CXXFLAGS += -Ithird_party/imgui -Ithird_party/imgui/backends
  SRC_CPP  += $(wildcard third_party/imgui/*.cpp) \
              $(wildcard third_party/imgui/backends/imgui_impl_metal.mm)
endif

ifneq ($(wildcard third_party/lua/lua.h),)
  # 注意：C++ 那边（lua_api.cpp / mod_loader.cpp）也要能找到 lua.h，
  # 所以 CFLAGS 和 CXXFLAGS 都得加
  CFLAGS    += -Ithird_party/lua -DLUA_USE_IOS -DLUA_USE_POSIX
  CXXFLAGS  += -Ithird_party/lua -DLUA_USE_IOS -DLUA_USE_POSIX
  SRC_C   += $(filter-out third_party/lua/lua.c third_party/lua/luac.c, \
              $(wildcard third_party/lua/*.c))
endif

# ---- 目标 ------------------------------------------------------------------
# C 文件单独放一个目录，避免和 C++ 的 %.o 规则打架（clang++ 会把 .c 当 C++ 编）
OBJ_CPP := $(patsubst %,$(BUILD)/%.o,$(SRC_CPP))
OBJ_C   := $(patsubst %,$(BUILD)/c/%.o,$(SRC_C))
OBJ     := $(OBJ_CPP) $(OBJ_C)

.PHONY: all generic specific clean

all: $(BUILD)/$(NAME).dylib

generic:
	@$(MAKE) --no-print-directory MODE=generic all

specific:
	@$(MAKE) --no-print-directory MODE=specific all

$(BUILD)/$(NAME).dylib: $(OBJ)
	@mkdir -p $(dir $@)
	$(CXX) $(LDFLAGS) -o $@ $^
	@echo "[ModMenu] 产物：$@"

$(BUILD)/%.o: %
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/c/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf $(BUILD)/src $(BUILD)/third_party $(BUILD)/$(NAME).dylib
