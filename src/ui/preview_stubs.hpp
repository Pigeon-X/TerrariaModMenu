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

// ---- 假的物品/NPC/Buff 表（真机上这些来自游戏的 Lang 反射）------------------
namespace gd {
inline bool init() { return true; }
inline bool ready() { return true; }

inline const std::vector<std::pair<int, std::string>>& item_table() {
    static const std::vector<std::pair<int, std::string>> v = [] {
        const char* names[] = {
            "铜短剑", "铁短剑", "银短剑", "金短剑", "铂金短剑", "木剑",
            "仙人掌剑", "铜镐", "铁镐", "银镐", "金镐", "铂金镐",
            "铜斧", "铁斧", "银斧", "金斧", "铂金斧", "木弓",
            "红药水", "蓝药水", "魔法水晶", "生命水晶", "星星雕像", "地牢钥匙",
            "天使之翼", "恶魔之翼", "熔岩靴", "赫尔墨斯靴", "附魔剑", "村正",
            "光之枪", "星怒", "附魔回旋镖", "土块", "石块", "木材",
        };
        std::vector<std::pair<int, std::string>> out;
        int id = 1;
        for (const char* n : names) out.emplace_back(id++, n);
        return out;
    }();
    return v;
}

inline const std::vector<std::pair<int, std::string>>& npc_table() {
    static const std::vector<std::pair<int, std::string>> v = [] {
        const char* names[] = {
            "史莱姆", "蓝史莱姆", "绿史莱姆", "僵尸", "恶魔眼", "飞眼怪",
            "骷髅", "骷髅法师", "巨型蠕虫", "蚁狮", "食人鱼", "蝙蝠",
            "克苏鲁之眼", "骷髅王", "世界吞噬怪", "克苏鲁之脑", "史莱姆王",
            "蜂后", "骷髅队长", "机械蠕虫", "双子魔眼", "机械骷髅王",
            "向导", "商人", "护士", "军火商", "树妖", "巫医", "哥布林工匠",
        };
        std::vector<std::pair<int, std::string>> out;
        int id = 1;
        for (const char* n : names) out.emplace_back(id++, n);
        return out;
    }();
    return v;
}
inline const std::vector<std::pair<int, std::string>>& buff_table() {
    static const std::vector<std::pair<int, std::string>> v = {};
    return v;
}
inline std::string item_name(int) { return {}; }
inline std::string npc_name(int) { return {}; }
inline std::string buff_name(int) { return {}; }
}  // namespace gd

// 预览器里"给物品"是空操作（真机上会真的写进背包）
namespace cheat {
inline bool g_stub_in_world = true;      // 预览器可用 --not-in-world 改成 false
inline bool in_world() { return g_stub_in_world; }
inline void give_item(int, int) {}
// 实体页的假数据
inline int npc_stats(int* alive, int* hostile) {
    if (alive) *alive = 12;
    if (hostile) *hostile = 7;
    return 12;
}
inline int kill_npcs(bool) { return 0; }
inline int spawn_npc(int, int) { return 1; }
inline void heal_full() {}
inline void set_world_time(int) {}
inline double world_time_of_day() { return 12.35; }   // 假时钟：12:21
inline void player_stats(int* life, int* lm, int* mana, int* mm, int* def) {
    if (life) *life = 87;
    if (lm) *lm = 140;
    if (mana) *mana = 33;
    if (mm) *mm = 60;
    if (def) *def = 9999;
}
inline bool teleport_to_spawn() { return true; }
}  // namespace cheat
