#pragma once
//
// 桌面预览器用的假数据（不参与 iOS 构建）
//
#include <string>
#include <vector>

namespace il2 {
inline bool ready() { return true; }
inline int symbol_count() { return 15121; }
inline const char* last_missing() { return "（预览模式，无真实符号）"; }
}  // namespace il2

namespace mods {

struct Mod {
    std::string name;
    std::string version;
    std::string author;
    std::string description;
    std::string entry = "main.lua";
    bool enabled = true;
    std::string dir;
    void* L = nullptr;
    bool loaded = true;
    std::string error;
};

inline const std::vector<Mod>& list() {
    static std::vector<Mod> v = [] {
        std::vector<Mod> out;
        Mod a;
        a.name = "示例Mod"; a.version = "1.0"; a.author = "you";
        a.description = "预览器里的假数据，用来验证面板布局";
        out.push_back(a);
        Mod b;
        b.name = "连锁挖矿"; b.version = "1.0.0"; b.author = "Terraria-Imgui";
        b.description = "破坏矿石时自动连锁破坏同类型相连方块";
        out.push_back(b);
        Mod c;
        c.name = "加载失败的例子"; c.loaded = false; c.error = "找不到入口脚本 main.lua";
        out.push_back(c);
        return out;
    }();
    return v;
}

inline const std::string& root_dir() {
    static std::string s = "Documents/Mods/";
    return s;
}

inline void reload() {}

}  // namespace mods
