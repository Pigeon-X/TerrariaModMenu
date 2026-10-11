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

# 这三项允许从外面覆盖（scripts/build_ios_local.sh 会传进来）。
# 判断写这么啰嗦是因为 CXX/CC 在 make 里有内置默认值，origin 是 "default"，
# 不能简单用 ?= —— 那样会保留 make 自带的 g++。
# 另外：没同意 Xcode 许可协议时 xcrun 不可用，外面传进来就能照常编译。
ifeq ($(filter command line environment,$(origin SDKROOT)),)
SDKROOT  := $(shell xcrun --sdk iphoneos --show-sdk-path)
endif
ifeq ($(filter command line environment,$(origin CXX)),)
CXX      := $(shell xcrun -sdk iphoneos -f clang++)
endif
ifeq ($(filter command line environment,$(origin CC)),)
CC       := $(shell xcrun -sdk iphoneos -f clang)
endif

ARCH     := arm64
MIN_IOS  := 15.0

# ---- 平台 ------------------------------------------------------------------
# MODE=sim：编 iOS **模拟器** 版，给 simhost 壳 App 用（scripts/build_simhost.sh）。
#   产物名带 -sim 后缀，免得把真机版的 build/TerrariaModMenu.dylib 覆盖掉。
ifeq ($(MODE),sim)
  NAME           := TerrariaModMenu-sim
  BUILD          := build-sim
  PLATFORM_FLAGS := -mios-simulator-version-min=$(MIN_IOS)
else
  NAME           := TerrariaModMenu
  PLATFORM_FLAGS := -miphoneos-version-min=$(MIN_IOS)
endif

# -DNDEBUG 很关键：ImGui 的 IM_ASSERT 默认映射到 assert()，
# 没定义 NDEBUG 的话 release 包里断言依然生效，一旦触发就直接 abort（表现为闪退）。
COMMON   := -arch $(ARCH) -isysroot $(SDKROOT) $(PLATFORM_FLAGS) \
            -O2 -DNDEBUG -fvisibility=hidden -Wall -Wno-unused-parameter

CXXFLAGS := -std=c++17 -fobjc-arc $(COMMON) -Isrc
CFLAGS   := $(COMMON) -Isrc

LDFLAGS  := $(COMMON) -dynamiclib \
            -install_name @executable_path/Frameworks/$(NAME).dylib \
            -framework Foundation -framework UIKit -framework Metal \
            -framework QuartzCore -framework CoreGraphics

ifeq ($(MODE),specific)
  CXXFLAGS += -DMODMENU_SPECIFIC=1
  $(info [ModMenu] 构建：专用版（含偏移表）)
else ifeq ($(MODE),sim)
  CXXFLAGS += -DMODMENU_SIMHOST=1
  $(info [ModMenu] 构建：模拟器宿主版（无 IL2CPP，直接起渲染层）)
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

ifneq ($(wildcard third_party/lua/src/lua.h),)
  # 注意：Lua 源码包里头文件和 .c 都在 src/ 子目录下，
  # 而且 C++ 那边（lua_api.cpp / mod_loader.cpp）也要能找到 lua.h
  LUA_DIR := third_party/lua/src
  # LUA_USE_IOS 内部已经会定义 LUA_USE_POSIX，别再重复定义（会告警）
  CFLAGS    += -I$(LUA_DIR) -DLUA_USE_IOS
  CXXFLAGS  += -I$(LUA_DIR) -DLUA_USE_IOS
  SRC_C   += $(filter-out $(LUA_DIR)/lua.c $(LUA_DIR)/luac.c, \
              $(wildcard $(LUA_DIR)/*.c))
endif

# ---- 目标 ------------------------------------------------------------------
# C 文件用独立后缀 .lo：
#   · 避免和 C++ 的 %.o 规则打架（clang++ 会把 .c 当 C++ 编）
#   · 避免 build/c/xxx.o 同时被 $(BUILD)/%.o 和 $(BUILD)/c/%.o 两条模式规则匹配
OBJ_CPP := $(patsubst %,$(BUILD)/%.o,$(SRC_CPP))
OBJ_C   := $(patsubst %.c,$(BUILD)/c/%.lo,$(SRC_C))
OBJ     := $(OBJ_CPP) $(OBJ_C)

.PHONY: all generic specific sim clean

all: $(BUILD)/$(NAME).dylib

generic:
	@$(MAKE) --no-print-directory MODE=generic all

specific:
	@$(MAKE) --no-print-directory MODE=specific all

sim:
	@$(MAKE) --no-print-directory MODE=sim all

$(BUILD)/$(NAME).dylib: $(OBJ)
	@mkdir -p $(dir $@)
	$(CXX) $(LDFLAGS) -o $@ $^
	@echo "[ModMenu] 产物：$@"

$(BUILD)/%.o: %
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/c/%.lo: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf $(BUILD)/src $(BUILD)/third_party $(BUILD)/$(NAME).dylib
