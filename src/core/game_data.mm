#include "game_data.hpp"

#include <cstring>
#include <map>

#include "../il2cpp_api.hpp"
#include "../mm_log.hpp"

namespace gd {
namespace {

il2::Method* g_itemName = nullptr;
il2::Method* g_npcName = nullptr;
il2::Method* g_buffName = nullptr;
bool g_tried = false;

std::map<int, std::string> g_itemCache, g_npcCache, g_buffCache;
std::vector<std::pair<int, std::string>> g_itemTable, g_npcTable, g_buffTable;
bool g_tablesBuilt = false;

// 调 Lang.GetXxxNameValue(id) -> 名字
std::string call_name(il2::Method* m, int id, std::map<int, std::string>& cache) {
    if (!m) return "";
    auto it = cache.find(id);
    if (it != cache.end()) return it->second;
    int32_t arg = id;
    void* args[1] = {&arg};
    void* exc = nullptr;
    il2::Object* ret = il2::runtime_invoke(m, nullptr, args, &exc);
    std::string name = (!exc && ret) ? il2::to_utf8(reinterpret_cast<il2::String*>(ret)) : std::string();
    cache[id] = name;
    return name;
}

// 扫表：从 1 开始，连续 60 个空名就认为到头了
std::vector<std::pair<int, std::string>> scan(il2::Method* m, std::map<int, std::string>& cache) {
    std::vector<std::pair<int, std::string>> out;
    if (!m) return out;
    int empty = 0;
    for (int id = 1; id < 20000 && empty < 60; ++id) {
        std::string n = call_name(m, id, cache);
        if (n.empty()) { ++empty; continue; }
        empty = 0;
        out.emplace_back(id, std::move(n));
    }
    return out;
}

}  // namespace

bool init() {
    if (g_itemName) return true;
    // 注意：这里**不能**像以前那样"只试一次"。
    // 真机日志里出现过「全表已建 —— 物品 0 / NPC 0 / Buff 0 项」：
    // 第一次调用时 IL2CPP 恰好还没就绪，g_tried 被置上后就再也不重试，
    // 于是物品/NPC/Buff 三个表永远是空的（搜索页全空）。
    // 改成"没就绪就下次再来"，并且每条失败路径都打日志。
    if (!il2::ready()) return false;

    il2::Domain* d = il2::domain_get();
    if (!d) { mm::logf("数据层：domain 拿不到"); return false; }
    il2::Assembly* a = il2::domain_assembly_open(d, "Assembly-CSharp");
    il2::Image* img = a ? il2::assembly_get_image(a) : nullptr;
    if (!img) { mm::logf("数据层：拿不到 Assembly-CSharp 镜像"); return false; }
    il2::Class* lang = il2::class_from_name(img, "Terraria", "Lang");
    if (!lang) { mm::logf("数据层：找不到 Terraria.Lang"); return false; }

    g_itemName = il2::class_get_method_from_name(lang, "GetItemNameValue", 1);
    g_npcName = il2::class_get_method_from_name(lang, "GetNPCNameValue", 1);
    g_buffName = il2::class_get_method_from_name(lang, "GetBuffName", 1);
    mm::logf("数据层：Lang 方法 物品=%s NPC=%s Buff=%s",
             g_itemName ? "有" : "无", g_npcName ? "有" : "无", g_buffName ? "有" : "无");
    return g_itemName != nullptr;
}

bool ready() { return g_itemName != nullptr; }

std::string item_name(int id) { if (!init()) return ""; return call_name(g_itemName, id, g_itemCache); }
std::string npc_name(int id) { if (!init()) return ""; return call_name(g_npcName, id, g_npcCache); }
std::string buff_name(int id) { if (!init()) return ""; return call_name(g_buffName, id, g_buffCache); }

const std::vector<std::pair<int, std::string>>& item_table() {
    if (!g_tablesBuilt) {
        // ⚠️ 必须先把 Lang 方法解析出来再扫表 —— 之前漏了这一步，
        //    界面直接调 item_table() 时 g_itemName 还是空的，
        //    于是扫出来永远是「物品 0 / NPC 0 / Buff 0 项」。
        if (!init()) {
            mm::logf("数据层：init 失败，三个表建不出来");
            return g_itemTable;      // 空表，但**不**置 g_tablesBuilt，下次还会重试
        }
        g_tablesBuilt = true;
        g_itemTable = scan(g_itemName, g_itemCache);
        g_npcTable = scan(g_npcName, g_npcCache);
        g_buffTable = scan(g_buffName, g_buffCache);
        mm::logf("数据层：全表已建 —— 物品 %zu / NPC %zu / Buff %zu 项",
                 g_itemTable.size(), g_npcTable.size(), g_buffTable.size());
    }
    return g_itemTable;
}
const std::vector<std::pair<int, std::string>>& npc_table() { item_table(); return g_npcTable; }
const std::vector<std::pair<int, std::string>>& buff_table() { item_table(); return g_buffTable; }

}  // namespace gd
