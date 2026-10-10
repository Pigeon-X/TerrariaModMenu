#pragma once
//
// Mod 加载器：扫描 App 沙盒的 Documents/Mods/<名字>/，
// 读 mod.json（可选）+ main.lua（必须），跑 onLoad/onUpdate/onUnload。
//
#include <string>
#include <vector>

struct lua_State;

namespace mods {

struct Mod {
    std::string name;         // 目录名（也是菜单里的 Tab 名）
    std::string version;
    std::string author;
    std::string description;
    std::string entry = "main.lua";
    bool enabled = true;
    std::string dir;          // 绝对路径
    lua_State* L = nullptr;
    bool loaded = false;
    std::string error;
};

// Mods 根目录绝对路径（Documents/Mods）
const std::string& root_dir();

// 扫描目录并加载全部 Mod（需要 IL2CPP 已就绪）。可重复调用=重载。
void reload();

// 每帧调用：onUpdate + 协程推进
void tick();

// 卸载全部（先跑 onUnload）
void unload_all();

// 已发现的 Mod 列表（含加载失败的信息）
const std::vector<Mod>& list();

}  // namespace mods
