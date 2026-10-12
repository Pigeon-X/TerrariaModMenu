#include "cheat.hpp"
#include "cheat_state.hpp"

#include <cmath>
#include <cstring>
#include <string>

#include "imgui.h"

#include "../il2cpp_api.hpp"
#include "../mm_log.hpp"
#include "../core/config.hpp"
#include "../core/game_data.hpp"

namespace cheat {
namespace {

// ---- 反射缓存 --------------------------------------------------------------
il2::Class* gMain = nullptr;
il2::Class* gPlayer = nullptr;
il2::Class* gItem = nullptr;
il2::Class* gNpc = nullptr;
bool gReady = false;
bool gTried = false;

// 玩家字段
il2::Field* f_statLife; il2::Field* f_statLifeMax2;
il2::Field* f_statMana; il2::Field* f_statManaMax2;
il2::Field* f_immune; il2::Field* f_noFallDmg; il2::Field* f_ignoreWater;
il2::Field* f_fireWalk; il2::Field* f_hasMolten; il2::Field* f_invis;
il2::Field* f_moveSpeed; il2::Field* f_wingTime; il2::Field* f_wingTimeMax;
il2::Field* f_statDefense; il2::Field* f_endurance;
il2::Field* f_lavaImmune;               // 岩浆免疫（不同版本字段名不一样，见 init）
// Main 字段
il2::Field* f_myPlayer; il2::Field* f_playerArr;
il2::Field* f_dayRate; il2::Field* f_time; il2::Field* f_bloodMoon;
il2::Field* f_eclipse; il2::Field* f_rain; il2::Field* f_sandStorm;
il2::Field* f_windSpeed; il2::Field* f_hardMode;
il2::Field* f_mouseX; il2::Field* f_mouseY;
il2::Field* f_gameMenu;                 // Main.gameMenu：true = 还在主菜单，没进地图
il2::Field* f_playerPos;                // Player.position（生成 NPC 时用来定位）
il2::Field* f_noKnockback;              // Player.noKnockback
il2::Field* f_lifeRegen;                // Player.lifeRegen（回血计数）
il2::Field* f_dayTime;                  // Main.dayTime（白天/黑夜）
il2::Field* f_spawnX; il2::Field* f_spawnY;   // Main.spawnTileX / spawnTileY

// 这一版里 player / myPlayer / gameMenu / spawnTileX 是**属性**不是字段
// （真机日志里自检打的就是「Main.gameMenu getter」）。
// 字段查不到时退回用这些 getter 读 —— 没有它们整个修改器都初始化不了。
il2::Method* f_myPlayer_get = nullptr;
il2::Method* f_playerArr_get = nullptr;
il2::Method* f_gameMenu_get = nullptr;
il2::Method* f_spawnX_get = nullptr;
il2::Method* f_spawnY_get = nullptr;
il2::Method* f_sand_get = nullptr;      // Main.sandStorm 也是属性
il2::Method* f_sand_set = nullptr;

// 沙尘暴的**真实**状态在独立类里，不在 Main 上（真机巡检发现的）：
//   Terraria.GameContent.Events.Sandstorm.Happening / IntendedSeverity
il2::Class* gSandstorm = nullptr;
il2::Field* f_sandHappening = nullptr;
il2::Field* f_sandIntended = nullptr;

// 实体（NPC）字段
il2::Field* f_npcArr;                   // Main.npc（NPC 数组）
il2::Field* f_npcActive; il2::Field* f_npcLife; il2::Field* f_npcType;
il2::Field* f_npcFriendly; il2::Field* f_npcWhoAmI; il2::Field* f_npcPos;

// 开关状态在 cheat_state.hpp（界面和真机共用同一份）

// ---- 小工具 ----------------------------------------------------------------
float read_f(il2::Object* o, il2::Field* f, bool isStatic, float def = 0) {
    if (!f) return def;
    float v = def;
    if (isStatic) il2::field_static_get_value(f, &v);
    else if (o) il2::field_get_value(o, f, &v);
    return v;
}
int32_t read_i(il2::Object* o, il2::Field* f, bool isStatic, int32_t def = 0) {
    if (!f) return def;
    int32_t v = def;
    if (isStatic) il2::field_static_get_value(f, &v);
    else if (o) il2::field_get_value(o, f, &v);
    return v;
}
bool read_b(il2::Object* o, il2::Field* f, bool isStatic) {
    if (!f) return false;
    uint8_t v = 0;
    if (isStatic) il2::field_static_get_value(f, &v);
    else if (o) il2::field_get_value(o, f, &v);
    return v != 0;
}
void write_f(il2::Object* o, il2::Field* f, bool isStatic, float v) {
    if (!f) return;
    if (isStatic) il2::field_static_set_value(f, &v);
    else if (o) il2::field_set_value(o, f, &v);
}
void write_i(il2::Object* o, il2::Field* f, bool isStatic, int32_t v) {
    if (!f) return;
    if (isStatic) il2::field_static_set_value(f, &v);
    else if (o) il2::field_set_value(o, f, &v);
}
void write_b(il2::Object* o, il2::Field* f, bool isStatic, bool v) {
    if (!f) return;
    uint8_t b = v ? 1 : 0;
    if (isStatic) il2::field_static_set_value(f, &b);
    else if (o) il2::field_set_value(o, f, &b);
}

// 字段声明成什么类型（il2cpp_type_get_type 返回 Il2CppTypeEnum）
int field_kind(il2::Field* f) {
    if (!f) return 0;
    il2::Type* t = il2::field_get_type(f);
    return t ? il2::type_get_type(t) : 0;
}

// 按字段**声明的类型**写入。
// 以前是不管类型、按调用方给的宽度硬写：
//   · 字段其实是 int、却按 1 字节写 -> 只写低 1 字节，等于没效果
//   · 字段其实是 bool、却按 4 字节写 -> 把相邻内存写坏（可能直接崩）
// il2cpp_field_set_value 是按字段大小拷贝的，所以整数类统一给一个 4 字节缓冲
// 就够了（小端，低字节优先）。
void write_auto(il2::Object* o, il2::Field* f, bool isStatic, double v) {
    if (!f) return;
    switch (field_kind(f)) {
        case il2::TK_BOOL: {
            uint8_t b = (v != 0.0) ? 1 : 0;
            if (isStatic) il2::field_static_set_value(f, &b);
            else if (o) il2::field_set_value(o, f, &b);
            break;
        }
        case il2::TK_R4: {
            float x = (float)v;
            if (isStatic) il2::field_static_set_value(f, &x);
            else if (o) il2::field_set_value(o, f, &x);
            break;
        }
        case il2::TK_R8: {
            double d = v;
            if (isStatic) il2::field_static_set_value(f, &d);
            else if (o) il2::field_set_value(o, f, &d);
            break;
        }
        case il2::TK_I8: {
            int64_t i = (int64_t)v;
            if (isStatic) il2::field_static_set_value(f, &i);
            else if (o) il2::field_set_value(o, f, &i);
            break;
        }
        default: {      // i32 / u32 / i16 / u8 都走这里
            int32_t i = (int32_t)v;
            if (isStatic) il2::field_static_set_value(f, &i);
            else if (o) il2::field_set_value(o, f, &i);
            break;
        }
    }
}

// 静态属性：调 setter 写值。先看 setter 的参数是什么类型再决定传几字节 ——
// 传错宽度会把相邻内存写坏。参数类型拿不到就不写。
void write_static_prop(il2::Method* setter, double v) {
    if (!setter) return;
    il2::Type* pt = il2::method_get_param(setter, 0);
    const int tk = pt ? il2::type_get_type(pt) : 0;
    void* exc = nullptr;
    if (tk == il2::TK_BOOL) {
        uint8_t b = (v != 0.0) ? 1 : 0;
        void* a[1] = {&b};
        il2::runtime_invoke(setter, nullptr, a, &exc);
    } else if (tk == il2::TK_R4) {
        float f = (float)v;
        void* a[1] = {&f};
        il2::runtime_invoke(setter, nullptr, a, &exc);
    } else if (tk == il2::TK_R8) {
        double d = v;
        void* a[1] = {&d};
        il2::runtime_invoke(setter, nullptr, a, &exc);
    } else {
        int32_t i = (int32_t)v;
        void* a[1] = {&i};
        il2::runtime_invoke(setter, nullptr, a, &exc);
    }
}

// ---- 属性读取（值类型 getter 返回的是装箱对象，要 unbox）--------------------
il2::Object* call_static_getter(il2::Method* g) {
    if (!g) return nullptr;
    void* exc = nullptr;
    return il2::runtime_invoke(g, nullptr, nullptr, &exc);
}
int32_t static_getter_int(il2::Method* g, int32_t def) {
    il2::Object* o = call_static_getter(g);
    if (!o) return def;
    void* p = il2::object_unbox(o);
    return p ? *reinterpret_cast<int32_t*>(p) : def;
}

// 取当前玩家对象（Main.player[Main.myPlayer]）
il2::Object* me() {
    if (!gReady) return nullptr;
    if ((!f_myPlayer && !f_myPlayer_get) || (!f_playerArr && !f_playerArr_get)) return nullptr;

    int32_t idx = -1;
    if (f_myPlayer) il2::field_static_get_value(f_myPlayer, &idx);
    else idx = static_getter_int(f_myPlayer_get, -1);

    void* arr = nullptr;
    if (f_playerArr) il2::field_static_get_value(f_playerArr, &arr);
    else arr = call_static_getter(f_playerArr_get);
    if (!arr || idx < 0 || idx > 255) return nullptr;
    // Il2CppArray: obj(16) + bounds(8) + length(4+4) -> 数据从 32 开始，元素为引用
    return *reinterpret_cast<il2::Object**>(reinterpret_cast<char*>(arr) + 32 + idx * 8);
}

void log_missing(const char* what) { mm::logf("修改器：找不到 %s", what); }

}  // namespace

bool init() {
    if (gReady) return true;
    if (!il2::ready()) return false;
    if (gTried) return false;      // 只尝试一次（类名错了说明版本差异，不刷日志）
    gTried = true;

    il2::Domain* d = il2::domain_get();
    il2::Assembly* a = il2::domain_assembly_open(d, "Assembly-CSharp");
    il2::Image* img = a ? il2::assembly_get_image(a) : nullptr;
    if (!img) { mm::logf("修改器：拿不到 Assembly-CSharp"); return false; }

    gMain = il2::class_from_name(img, "Terraria", "Main");
    gPlayer = il2::class_from_name(img, "Terraria", "Player");
    gItem = il2::class_from_name(img, "Terraria", "Item");
    if (!gMain || !gPlayer) {
        mm::logf("修改器：Terraria.Main / Terraria.Player 没找到");
        return false;
    }

    auto F = [&](il2::Class* k, const char* n) -> il2::Field* {
        return k ? il2::class_get_field_from_name(k, n) : nullptr;
    };

    // 同一个东西在不同游戏版本里字段名可能不一样（离线查过：1.4.5.8 的 iOS 包里
    // 根本没有 hasMolten 这个字符串）。所以这类字段给一串候选名，
    // 谁先解析到就用谁，并把结果打进日志 —— 真机跑一次就知道命中哪个了。
    auto pick = [&](il2::Class* k, std::initializer_list<const char*> names,
                    const char* what) -> il2::Field* {
        if (!k) return nullptr;
        for (const char* n : names) {
            if (il2::Field* f = il2::class_get_field_from_name(k, n)) {
                mm::logf("修改器：%s -> %s", what, n);
                return f;
            }
        }
        mm::logf("修改器：%s 一个候选都没命中（%s 等）", what, *names.begin());
        return nullptr;
    };
    f_statLife = F(gPlayer, "statLife");          f_statLifeMax2 = F(gPlayer, "statLifeMax2");
    f_statMana = F(gPlayer, "statMana");          f_statManaMax2 = F(gPlayer, "statManaMax2");
    f_immune = F(gPlayer, "immune");              f_noFallDmg = F(gPlayer, "noFallDmg");
    f_ignoreWater = F(gPlayer, "ignoreWater");    f_fireWalk = F(gPlayer, "fireWalk");
    // 1.4.5.8 的包里连 "hasMolten" 这个字符串都没有，所以给一串候选名
    f_lavaImmune = pick(gPlayer, {"lavaImmune", "lavaWet", "hasMolten"}, "岩浆免疫字段");
    f_invis = F(gPlayer, "invis");
    f_moveSpeed = F(gPlayer, "moveSpeed");        f_wingTime = F(gPlayer, "wingTime");
    f_wingTimeMax = F(gPlayer, "wingTimeMax");    f_statDefense = F(gPlayer, "statDefense");
    f_endurance = F(gPlayer, "endurance");

    f_myPlayer = F(gMain, "myPlayer");            f_playerArr = F(gMain, "player");
    f_dayRate = F(gMain, "dayRate");              f_time = F(gMain, "time");
    f_bloodMoon = F(gMain, "bloodMoon");          f_eclipse = F(gMain, "eclipse");
    // 这两个字段名/类型不太确定，给候选让它在真机上自己报命中哪个
    f_rain = pick(gMain, {"raining", "rain"}, "下雨字段");
    f_sandStorm = pick(gMain, {"sandStorm", "sandstorm", "sandStormHud"}, "沙尘暴字段");
    f_windSpeed = F(gMain, "windSpeedCurrent");   f_hardMode = F(gMain, "hardMode");
    f_mouseX = F(gMain, "mouseX");                f_mouseY = F(gMain, "mouseY");
    f_gameMenu = F(gMain, "gameMenu");
    f_dayTime = F(gMain, "dayTime");
    // 这两个名字不确定，给候选让日志报命中
    f_noKnockback = pick(gPlayer, {"noKnockback"}, "无视击退字段");
    f_lifeRegen = pick(gPlayer, {"lifeRegen", "lifeRegenCount"}, "回血字段");
    f_spawnX = F(gMain, "spawnTileX");
    f_spawnY = F(gMain, "spawnTileY");

    // 字段找不到的，退回按**属性**取 getter（这一版这几个都是属性）
    {
        auto P = [&](il2::Class* k, const char* n) -> il2::Method* {
            if (!k) return nullptr;
            il2::Property* pr = il2::class_get_property_from_name(k, n);
            return pr ? il2::property_get_get_method(pr) : nullptr;
        };
        if (!f_myPlayer) f_myPlayer_get = P(gMain, "myPlayer");
        if (!f_playerArr) f_playerArr_get = P(gMain, "player");
        if (!f_gameMenu) f_gameMenu_get = P(gMain, "gameMenu");
        if (!f_spawnX) f_spawnX_get = P(gMain, "spawnTileX");
        if (!f_spawnY) f_spawnY_get = P(gMain, "spawnTileY");
        if (!f_sandStorm) {
            if (il2::Property* pr = il2::class_get_property_from_name(gMain, "sandStorm")) {
                f_sand_get = il2::property_get_get_method(pr);
                f_sand_set = il2::property_get_set_method(pr);
            }
        }
        mm::logf("修改器：属性回退 -> myPlayer %s / player %s / gameMenu %s / spawn %s%s",
                 f_myPlayer_get ? "有" : "无", f_playerArr_get ? "有" : "无",
                 f_gameMenu_get ? "有" : "无",
                 f_spawnX_get ? "有" : "无", f_spawnY_get ? "有" : "无");
        mm::logf("修改器：沙尘暴属性 -> getter %s / setter %s",
                 f_sand_get ? "有" : "无", f_sand_set ? "有" : "无");
    }

    // ---- 诊断：player 还是没找到，就把 Main 里带 layer 的名字全列出来 -------------
    // （player / Player 都含 "layer"，一次列全，比继续猜候选名快）
    if (!f_playerArr && !f_playerArr_get) {
        std::string fhits, phits;
        int fn = 0, pn = 0;
        void* it = nullptr;
        while (il2::Field* fd = il2::class_get_fields(gMain, &it)) {
            ++fn;
            const char* n = il2::field_get_name(fd);
            if (n && strstr(n, "layer")) {
                if (!fhits.empty()) fhits += ", ";
                fhits += n;
                fhits += "=";
                fhits += il2::type_kind_name(field_kind(fd));
            }
        }
        it = nullptr;
        while (il2::Property* pr = il2::class_get_properties(gMain, &it)) {
            ++pn;
            const char* n = il2::property_get_name(pr);
            if (n && strstr(n, "layer")) {
                if (!phits.empty()) phits += ", ";
                phits += n;
            }
        }
        mm::logf("修改器：Main 字段 %d 个，含 layer 的：%s", fn, fhits.empty() ? "（无）" : fhits.c_str());
        mm::logf("修改器：Main 属性 %d 个，含 layer 的：%s", pn, phits.empty() ? "（无）" : phits.c_str());
    }

    // ---- 诊断：沙尘暴也没找到，同样把带 Storm 的名字列出来 ----------------------
    if (!f_sandStorm && !f_sand_set) {
        std::string hits;
        void* it2 = nullptr;
        while (il2::Field* fd = il2::class_get_fields(gMain, &it2)) {
            const char* n = il2::field_get_name(fd);
            if (n && (strstr(n, "torm") || strstr(n, "andstorm"))) {
                if (!hits.empty()) hits += ", ";
                hits += n;
                hits += "=";
                hits += il2::type_kind_name(field_kind(fd));
            }
        }
        it2 = nullptr;
        while (il2::Property* pr = il2::class_get_properties(gMain, &it2)) {
            const char* n = il2::property_get_name(pr);
            if (n && (strstr(n, "torm") || strstr(n, "andstorm"))) {
                if (!hits.empty()) hits += ", ";
                hits += n;
                hits += "(属性)";
            }
        }
        mm::logf("修改器：Main 里带 Storm 的名字：%s", hits.empty() ? "（无）" : hits.c_str());
    }

    // ---- 实体（NPC）----
    // 字段名跟安卓版那套按名解析用的是同一批（NPC.active/life/type/friendly/whoAmI）
    gNpc = il2::class_from_name(img, "Terraria", "NPC");
    f_npcArr = F(gMain, "npc");
    f_playerPos = F(gPlayer, "position");
    if (gNpc) {
        auto N = [&](const char* n) -> il2::Field* {
            return il2::class_get_field_from_name(gNpc, n);
        };
        f_npcActive = N("active");     f_npcLife = N("life");
        f_npcType = N("type");         f_npcFriendly = N("friendly");
        f_npcWhoAmI = N("whoAmI");     f_npcPos = N("position");
    }
    mm::logf("修改器：NPC 类 %s，Main.npc %s，NPC.life %s",
             gNpc ? "有" : "无", f_npcArr ? "有" : "无", f_npcLife ? "有" : "无");

    // 沙尘暴：状态不在 Main 上，单独解析这个类
    gSandstorm = il2::class_from_name(img, "Terraria.GameContent.Events", "Sandstorm");
    if (gSandstorm) {
        f_sandHappening = il2::class_get_field_from_name(gSandstorm, "Happening");
        f_sandIntended = il2::class_get_field_from_name(gSandstorm, "IntendedSeverity");
    }
    mm::logf("修改器：Sandstorm 类 %s，Happening %s，IntendedSeverity %s",
             gSandstorm ? "有" : "无", f_sandHappening ? "有" : "无",
             f_sandIntended ? "有" : "无");

    // 名字和指针成对存一份：没解析到的直接把**名字**打进日志，
    // 真机跑一次就知道哪个字段跟这个游戏版本对不上（不用靠猜）。
    // 顺带记上"属性 getter"：有几个名字这版是属性，只有 getter 不算缺
    struct FieldRef { const char* name; il2::Field* f; il2::Method* g; };
    const FieldRef all[] = {
        {"statLife", f_statLife, nullptr},       {"statLifeMax2", f_statLifeMax2, nullptr},
        {"statMana", f_statMana, nullptr},       {"statManaMax2", f_statManaMax2, nullptr},
        {"immune", f_immune, nullptr},           {"noFallDmg", f_noFallDmg, nullptr},
        {"ignoreWater", f_ignoreWater, nullptr}, {"fireWalk", f_fireWalk, nullptr},
        {"lavaImmune", f_lavaImmune, nullptr},   {"invis", f_invis, nullptr},
        {"moveSpeed", f_moveSpeed, nullptr},     {"wingTime", f_wingTime, nullptr},
        {"wingTimeMax", f_wingTimeMax, nullptr}, {"statDefense", f_statDefense, nullptr},
        {"endurance", f_endurance, nullptr},     {"myPlayer", f_myPlayer, f_myPlayer_get},
        {"Main.player", f_playerArr, f_playerArr_get},   {"dayRate", f_dayRate, nullptr},
        {"time", f_time, nullptr},               {"bloodMoon", f_bloodMoon, nullptr},
        {"eclipse", f_eclipse, nullptr},         {"rain", f_rain, nullptr},
        {"sandStorm", f_sandStorm, nullptr},     {"windSpeedCurrent", f_windSpeed, nullptr},
        {"hardMode", f_hardMode, nullptr},       {"gameMenu", f_gameMenu, f_gameMenu_get},
        {"Player.position", f_playerPos, nullptr},
        {"noKnockback", f_noKnockback, nullptr}, {"lifeRegen", f_lifeRegen, nullptr},
        {"dayTime", f_dayTime, nullptr},
        {"spawnTileX", f_spawnX, f_spawnX_get},       {"spawnTileY", f_spawnY, f_spawnY_get},
        {"Main.npc", f_npcArr, nullptr},         {"npc.active", f_npcActive, nullptr},
        {"npc.life", f_npcLife, nullptr},        {"npc.type", f_npcType, nullptr},
        {"npc.friendly", f_npcFriendly, nullptr}, {"npc.whoAmI", f_npcWhoAmI, nullptr},
        {"npc.position", f_npcPos, nullptr},
    };
    int ok = 0, total = 0;
    std::string miss;
    for (const auto& e : all) {
        ++total;
        if (e.f || e.g) { ++ok; continue; }
        if (!miss.empty()) miss += ", ";
        miss += e.name;
    }
    if (miss.empty()) mm::logf("修改器：字段解析 %d/%d 全部命中", ok, total);
    else mm::logf("修改器：字段解析 %d/%d，没解析到：%s", ok, total, miss.c_str());

    // ---- 字段类型体检 ------------------------------------------------------
    // 名字对了不代表类型对。类型错的后果：按 1 字节写 int 字段 = 没效果；
    // 按 4 字节写 bool 字段 = 把相邻内存写坏（可能直接崩）。
    // 这里把「我们打算怎么写」跟「字段实际声明成什么」对一遍，日志里看结论。
    // （写入侧已经改成 write_auto 按真实类型走了，这里只是把差异报出来。）
    {
        struct TypeChk { const char* name; il2::Field* f; int want; };
        const TypeChk chks[] = {
            {"statLife", f_statLife, il2::TK_I4},
            {"statMana", f_statMana, il2::TK_I4},
            {"immune", f_immune, il2::TK_BOOL},
            {"noFallDmg", f_noFallDmg, il2::TK_BOOL},
            {"ignoreWater", f_ignoreWater, il2::TK_BOOL},
            {"fireWalk", f_fireWalk, il2::TK_BOOL},
            {"invis", f_invis, il2::TK_BOOL},
            {"moveSpeed", f_moveSpeed, il2::TK_R4},
            {"wingTime", f_wingTime, il2::TK_R4},
            {"statDefense", f_statDefense, il2::TK_I4},
            {"endurance", f_endurance, il2::TK_R4},
            {"dayRate", f_dayRate, il2::TK_I4},      // 真机日志报：实际是 i32
            {"bloodMoon", f_bloodMoon, il2::TK_BOOL},
            {"eclipse", f_eclipse, il2::TK_BOOL},
            {"rain", f_rain, il2::TK_BOOL},          // 真机日志报：实际是 bool（raining）
            {"sandStorm", f_sandStorm, il2::TK_BOOL},
            {"windSpeedCurrent", f_windSpeed, il2::TK_R4},
            {"hardMode", f_hardMode, il2::TK_BOOL},
            {"noKnockback", f_noKnockback, il2::TK_BOOL},
            {"lifeRegen", f_lifeRegen, il2::TK_I4},
            {"dayTime", f_dayTime, il2::TK_BOOL},
        };
        std::string bad;
        int checked = 0;
        for (const auto& c : chks) {
            if (!c.f) continue;
            ++checked;
            const int got = field_kind(c.f);
            if (got == c.want) continue;
            if (!bad.empty()) bad += "  ";
            bad += c.name;
            bad += " 实际=";
            bad += il2::type_kind_name(got);
            bad += " 预期=";
            bad += il2::type_kind_name(c.want);
        }
        if (bad.empty()) mm::logf("修改器：字段类型体检通过（%d 项）", checked);
        else mm::logf("修改器：字段类型与预期不符 -> %s", bad.c_str());
    }
    if ((!f_playerArr && !f_playerArr_get) || (!f_myPlayer && !f_myPlayer_get)) {
        log_missing("Main.player/myPlayer（字段和属性都没找到）");
        return false;
    }

    gReady = true;
    return true;
}

bool active() {
    return c_god || c_infMana || c_noFall || c_water || c_lava || c_invis || c_speed ||
           c_fly || c_defense || c_noKnockback || c_regen ||
           c_day || c_night || c_freezeTime || c_rain || c_sand ||
           c_wind || c_bloodMoon || c_eclipse || c_hardMode;
}

// 是不是已经进了地图（世界里）。
// 渲染层用它决定悬浮球要不要出现：**主菜单里不显示**，进了地图才弹出来。
bool in_world() {
#ifdef MODMENU_SIMHOST
    return true;   // 模拟器宿主里没有游戏本体，当永远"在地图里"，否则界面没法调
#endif
    // 判断不了就别拦：这时候页面自己会显示"修改器不可用（IL2CPP 未就绪）"，
    // 比笼统地说"要进地图"更准确。
    if (!gReady && !init()) return true;
    // gameMenu 这一版是**属性**，字段找不到就走 getter
    bool menu = true;
    if (f_gameMenu) {
        uint8_t v = 0;
        il2::field_static_get_value(f_gameMenu, &v);
        menu = (v != 0);
    } else if (f_gameMenu_get) {
        menu = (static_getter_int(f_gameMenu_get, 1) != 0);
    } else {
        return true;                 // 都拿不到就别拦，宁可显示出来
    }
    return !menu;                    // gameMenu = true 表示还在主菜单
}

void tick() {
    if (!gReady && !init()) return;
    // C 档的配置写入暂时停用（二分排查闪退）
    if (!active()) return;
    il2::Object* p = me();
    if (!p) return;

    // ⚠️ 一律用 write_auto：它按字段**声明的类型**写，
    //    不像以前那样按调用方给的宽度硬写（类型不符会把相邻内存写坏）。
    //    另外「开关类」字段统一写 3600 而不是 1 —— 万一它其实是个计时器
    //    （比如 Player.immune 是免疫帧数），写 1 只顶 1 帧等于没效果；
    //    写 3600 两种情况都对：bool 非零即为真，int 就是 60 秒免疫。
    const double kFlag = 3600.0;

    if (c_god) {
        write_auto(p, f_immune, false, kFlag);
        int32_t mx = read_i(p, f_statLifeMax2, false, 100);
        write_auto(p, f_statLife, false, mx);
    }
    if (c_infMana) {
        int32_t mx = read_i(p, f_statManaMax2, false, 20);
        write_auto(p, f_statMana, false, mx);
    }
    if (c_noFall) write_auto(p, f_noFallDmg, false, kFlag);
    if (c_water) write_auto(p, f_ignoreWater, false, kFlag);
    if (c_lava) {
        // 走岩浆 + 免疫：几个候选字段能中哪个就写哪个（都写也不冲突）
        write_auto(p, f_fireWalk, false, kFlag);
        write_auto(p, f_lavaImmune, false, kFlag);
        write_auto(p, f_hasMolten, false, kFlag);
    }
    if (c_invis) write_auto(p, f_invis, false, kFlag);
    if (c_noKnockback) write_auto(p, f_noKnockback, false, kFlag);
    if (c_regen) write_auto(p, f_lifeRegen, false, 120);   // 回血计数拉高 = 快速回复
    if (c_speed) write_auto(p, f_moveSpeed, false, v_speed);
    if (c_fly) {
        float mx = read_f(p, f_wingTimeMax, false, 0);
        if (mx <= 0) mx = 300.0f;
        write_auto(p, f_wingTime, false, mx);
    }
    if (c_defense) {
        write_auto(p, f_statDefense, false, 9999);
        write_auto(p, f_endurance, false, 1.0f);
    }

    // 世界（这些是 Main 的静态字段）
    if (c_hardMode) write_auto(nullptr, f_hardMode, true, kFlag);
    if (c_bloodMoon) write_auto(nullptr, f_bloodMoon, true, kFlag);
    if (c_eclipse) write_auto(nullptr, f_eclipse, true, kFlag);
    if (c_rain) write_auto(nullptr, f_rain, true, kFlag);
    if (c_sand) {
        write_auto(nullptr, f_sandStorm, true, kFlag);      // 是字段的话
        write_static_prop(f_sand_set, kFlag);               // 是属性的话
        // 正主：Terraria.GameContent.Events.Sandstorm
        write_auto(nullptr, f_sandHappening, true, 1.0);
        write_auto(nullptr, f_sandIntended, true, 1.0);     // 强度拉满
    }
    if (c_wind) write_auto(nullptr, f_windSpeed, true, 60.0f);
    if (c_day) write_auto(nullptr, f_dayRate, true, 10.0f);      // 时间快进到白天
    if (c_night) write_auto(nullptr, f_dayRate, true, -10.0f);
    if (c_freezeTime) write_auto(nullptr, f_dayRate, true, 0.0f);
}

void load_state() {
    return;   // C 档暂时停用（二分排查闪退）
    c_god = cfg::get_bool("cheat.god", false);
    c_infMana = cfg::get_bool("cheat.infMana", false);
    c_noFall = cfg::get_bool("cheat.noFall", false);
    c_water = cfg::get_bool("cheat.water", false);
    c_lava = cfg::get_bool("cheat.lava", false);
    c_invis = cfg::get_bool("cheat.invis", false);
    c_defense = cfg::get_bool("cheat.defense", false);
    c_speed = cfg::get_bool("cheat.speed", false);
    v_speed = cfg::get_float("cheat.speedVal", 2.0f);
    c_fly = cfg::get_bool("cheat.fly", false);
    c_hardMode = cfg::get_bool("world.hardMode", false);
    c_bloodMoon = cfg::get_bool("world.bloodMoon", false);
    c_eclipse = cfg::get_bool("world.eclipse", false);
    c_rain = cfg::get_bool("world.rain", false);
    c_sand = cfg::get_bool("world.sand", false);
    c_wind = cfg::get_bool("world.wind", false);
    c_day = cfg::get_bool("world.day", false);
    c_night = cfg::get_bool("world.night", false);
    c_freezeTime = cfg::get_bool("world.freeze", false);
    v_itemId = cfg::get_int("item.id", 1);
    v_itemCount = cfg::get_int("item.count", 99);
}


// 给玩家背包塞物品：用 Item.SetDefaults 初始化那块内存
void give_item(int id, int count) {
    if (!gReady || !gItem) return;
    il2::Object* p = me();
    if (!p) return;
    il2::Field* inv = il2::class_get_field_from_name(gPlayer, "inventory");
    if (!inv) { log_missing("Player.inventory"); return; }
    void* arr = nullptr;
    il2::field_get_value(p, inv, &arr);
    if (!arr) return;

    il2::Method* setDefaults = il2::class_get_method_from_name(gItem, "SetDefaults", 2);
    if (!setDefaults) setDefaults = il2::class_get_method_from_name(gItem, "SetDefaults", 1);
    if (!setDefaults) { log_missing("Item.SetDefaults"); return; }

    int32_t elem = il2::class_array_element_size(gItem);
    if (elem <= 0) { mm::logf("修改器：Item 元素大小拿不到"); return; }

    // 找一个空槽
    il2::Field* fType = il2::class_get_field_from_name(gItem, "type");
    int32_t typeOffset = fType ? (int32_t)il2::field_get_offset(fType) : 0;
    int slot = -1;
    for (int i = 0; i < 59; ++i) {
        char* it = reinterpret_cast<char*>(arr) + 32 + i * elem;
        int32_t t = *reinterpret_cast<int32_t*>(it + typeOffset);
        if (t == 0) { slot = i; break; }
    }
    if (slot < 0) slot = 0;

    char* target = reinterpret_cast<char*>(arr) + 32 + slot * elem;
    int32_t a0 = id, a1 = 0;
    void* args[2] = {&a0, &a1};
    void* exc = nullptr;
    il2::runtime_invoke(setDefaults, target, args, &exc);
    if (exc) { mm::logf("修改器：SetDefaults 抛异常"); return; }

    il2::Field* fStack = il2::class_get_field_from_name(gItem, "stack");
    if (fStack) *reinterpret_cast<int32_t*>(target + il2::field_get_offset(fStack)) = count;
    mm::logf("修改器：已放入物品 id=%d x%d（槽位 %d）", id, count, slot);
}

// ---------------------------------------------------------------------------
// 实体（NPC）
// ---------------------------------------------------------------------------
namespace {

// Terraria 的 Main.npc 上限是 200 个槽
constexpr int kNpcSlots = 200;

// 取第 i 个 NPC 对象（数组元素是引用，跟 Player 数组一样的排布：
// Il2CppArray: obj(16) + bounds(8) + length(4+4) -> 数据从 32 开始）
il2::Object* npc_at(int i) {
    if (!gReady || !f_npcArr || i < 0 || i >= kNpcSlots) return nullptr;
    void* arr = nullptr;
    il2::field_static_get_value(f_npcArr, &arr);
    if (!arr) return nullptr;
    return *reinterpret_cast<il2::Object**>(reinterpret_cast<char*>(arr) + 32 + i * 8);
}

}  // namespace

int npc_stats(int* alive, int* hostile) {
    int a = 0, h = 0;
    if (!gReady && !init()) {
        if (alive) *alive = 0;
        if (hostile) *hostile = 0;
        return 0;
    }
    for (int i = 0; i < kNpcSlots; ++i) {
        il2::Object* n = npc_at(i);
        if (!n) continue;
        if (!read_b(n, f_npcActive, false)) continue;
        ++a;
        if (!read_b(n, f_npcFriendly, false)) ++h;
    }
    if (alive) *alive = a;
    if (hostile) *hostile = h;
    return a;
}

int kill_npcs(bool hostile_only) {
    if (!gReady && !init()) return 0;
    int n = 0;
    for (int i = 0; i < kNpcSlots; ++i) {
        il2::Object* o = npc_at(i);
        if (!o || !read_b(o, f_npcActive, false)) continue;
        if (hostile_only && read_b(o, f_npcFriendly, false)) continue;
        // 血量清零，游戏下一帧自己判定死亡（比直接调用伤害函数安全）
        write_i(o, f_npcLife, false, 0);
        ++n;
    }
    mm::logf("修改器：秒杀 %d 个 NPC%s", n, hostile_only ? "（只杀敌对）" : "（全部）");
    return n;
}

int spawn_npc(int type, int count) {
    if (!gReady && !init()) return 0;
    if (!gNpc || !f_npcLife) return 0;

    // 用 NPC.SetDefaults(type) 初始化空槽，再自己把 active / 位置 / whoAmI 写上。
    // 这条路比调 NewNPC 稳：NewNPC 各个版本的参数个数不一样，容易调错。
    il2::Method* setDefaults = il2::class_get_method_from_name(gNpc, "SetDefaults", 1);
    if (!setDefaults) { log_missing("NPC.SetDefaults"); return 0; }

    // 生成在玩家头顶一点点
    float px = 0, py = 0;
    if (il2::Object* p = me()) {
        if (f_playerPos) {
            struct V2 { float x, y; } v{};
            il2::field_get_value(p, f_playerPos, &v);
            px = v.x; py = v.y - 80.0f;
        }
    }

    int made = 0;
    for (int i = 0; i < kNpcSlots && made < count; ++i) {
        il2::Object* o = npc_at(i);
        if (!o || read_b(o, f_npcActive, false)) continue;

        int32_t a0 = type;
        void* args[1] = {&a0};
        void* exc = nullptr;
        il2::runtime_invoke(setDefaults, o, args, &exc);
        if (exc) { mm::logf("修改器：NPC.SetDefaults(%d) 抛异常", type); break; }

        write_i(o, f_npcType, false, type);
        write_i(o, f_npcWhoAmI, false, i);
        if (f_npcPos && (px != 0.0f || py != 0.0f)) {
            struct V2 { float x, y; } pos{px, py};
            il2::field_set_value(o, f_npcPos, &pos);
        }
        write_b(o, f_npcActive, false, true);
        ++made;
    }
    mm::logf("修改器：生成 NPC type=%d x%d（成功 %d）", type, count, made);
    return made;
}

// ---------------------------------------------------------------------------
// 动作类（点一下就生效）
// ---------------------------------------------------------------------------
void heal_full() {
    if (!gReady && !init()) return;
    il2::Object* p = me();
    if (!p) { mm::logf("修改器：回满失败（不在世界里？）"); return; }
    const int32_t life_max = read_i(p, f_statLifeMax2, false, 100);
    const int32_t mana_max = read_i(p, f_statManaMax2, false, 20);
    write_auto(p, f_statLife, false, life_max);
    write_auto(p, f_statMana, false, mana_max);
    mm::logf("修改器：已回满生命 %d / 魔力 %d", life_max, mana_max);
}

// Terraria 的时间：白天 time 0..54000 对应 4:30→19:30；
// 夜里 time 0..32400 对应 19:30→次日 4:30。
void set_world_time(int preset) {
    if (!gReady && !init()) return;
    if (!f_time) return;
    double t = 0;
    bool day = true;
    switch (preset) {
        case 1: day = true;  t = 27000; break;   // 正午 12:00
        case 2: day = true;  t = 54000; break;   // 黄昏 19:30（白天末尾）
        case 3: day = false; t = 16200; break;   // 午夜 00:00
        default: day = true; t = 0; break;       // 清晨 04:30（白天开头）
    }
    // dayTime 要先设：游戏每帧会按它算昼夜，先改 time 再改 dayTime 会被覆盖掉一帧
    write_auto(nullptr, f_dayTime, true, day ? 1.0 : 0.0);
    write_auto(nullptr, f_time, true, t);
    mm::logf("修改器：时间已设为 %s（time=%.0f）", day ? "白天" : "夜晚", t);
}

double world_time_of_day() {
    if (!gReady && !init()) return -1;
    if (!f_time) return -1;
    double t = 0;
    il2::field_static_get_value(f_time, &t);
    const bool day = f_dayTime ? read_b(nullptr, f_dayTime, true) : true;
    double hours;
    if (day) {
        hours = 4.5 + (t / 54000.0) * 15.0;          // 04:30 → 19:30
    } else {
        hours = 19.5 + (t / 32400.0) * 9.0;          // 19:30 → 次日 04:30
    }
    while (hours >= 24.0) hours -= 24.0;
    return hours;
}

void player_stats(int* life, int* life_max, int* mana, int* mana_max, int* defense) {
    int l = 0, lm = 0, m = 0, mm = 0, d = 0;
    if ((gReady || init())) {
        if (il2::Object* p = me()) {
            l = read_i(p, f_statLife, false, 0);
            lm = read_i(p, f_statLifeMax2, false, 0);
            m = read_i(p, f_statMana, false, 0);
            mm = read_i(p, f_statManaMax2, false, 0);
            d = read_i(p, f_statDefense, false, 0);
        }
    }
    if (life) *life = l;
    if (life_max) *life_max = lm;
    if (mana) *mana = m;
    if (mana_max) *mana_max = mm;
    if (defense) *defense = d;
}

bool teleport_to_spawn() {
    if (!gReady && !init()) return false;
    il2::Object* p = me();
    if (!p || (!f_spawnX && !f_spawnX_get) || (!f_spawnY && !f_spawnY_get) || !f_playerPos) {
        mm::logf("修改器：传送失败（玩家或出生点字段没解析到）");
        return false;
    }
    int32_t tx = 0, ty = 0;
    if (f_spawnX) il2::field_static_get_value(f_spawnX, &tx);
    else tx = static_getter_int(f_spawnX_get, 0);
    if (f_spawnY) il2::field_static_get_value(f_spawnY, &ty);
    else ty = static_getter_int(f_spawnY_get, 0);
    // 方块坐标 -> 世界坐标：每格 16 像素
    struct V2 { float x, y; } pos{(float)(tx * 16), (float)(ty * 16)};
    il2::field_set_value(p, f_playerPos, &pos);
    mm::logf("修改器：已传送到出生点（格子 %d,%d）", tx, ty);
    return true;
}

}  // namespace cheat
