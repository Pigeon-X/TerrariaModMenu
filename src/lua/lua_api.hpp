#pragma once
//
// 每个 Mod 一个独立的 Lua 实例，互不干扰：
//   · 自己的 onLoad / onUpdate / onUnload、自己的 MOD_DIR
//   · 自己的协程调度器（Runtime.Spawn）
//   · 自己的 log.txt
//
#include <string>

struct lua_State;

namespace luaapi {

// 建一个 Lua 实例并注册全部 API（还没跑脚本）
lua_State* create_state(const std::string& mod_name, const std::string& mod_dir);

// 关掉实例
void close_state(lua_State* L);

// 执行脚本文件；失败会把错误写进日志并返回 false
bool run_file(lua_State* L, const std::string& path, const char* what);

// 调一个全局函数（0 参），不存在就返回 false
bool call_global(lua_State* L, const char* fn);

// 每帧推进协程调度器
void tick(lua_State* L);

// 该实例当前的 UI 面板数量（诊断用）
int panel_count(lua_State* L);

}  // namespace luaapi
