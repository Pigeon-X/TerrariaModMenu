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

// 取当前玩家对象（Main.player[Main.myPlayer]）
il2::Object* me() {
    if (!gReady || !f_myPlayer || !f_playerArr) return nullptr;
    int32_t idx = 0;
    il2::field_static_get_value(f_myPlayer, &idx);
    void* arr = nullptr;
    il2::field_static_get_value(f_playerArr, &arr);
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
    f_rain = F(gMain, "rain");                    f_sandStorm = F(gMain, "sandStorm");
    f_windSpeed = F(gMain, "windSpeedCurrent");   f_hardMode = F(gMain, "hardMode");
    f_mouseX = F(gMain, "mouseX");                f_mouseY = F(gMain, "mouseY");
    f_gameMenu = F(gMain, "gameMenu");

    // 名字和指针成对存一份：没解析到的直接把**名字**打进日志，
    // 真机跑一次就知道哪个字段跟这个游戏版本对不上（不用靠猜）。
    struct FieldRef { const char* name; il2::Field* f; };
    const FieldRef all[] = {
        {"statLife", f_statLife},       {"statLifeMax2", f_statLifeMax2},
        {"statMana", f_statMana},       {"statManaMax2", f_statManaMax2},
        {"immune", f_immune},           {"noFallDmg", f_noFallDmg},
        {"ignoreWater", f_ignoreWater}, {"fireWalk", f_fireWalk},
        {"lavaImmune", f_lavaImmune},   {"invis", f_invis},
        {"moveSpeed", f_moveSpeed},     {"wingTime", f_wingTime},
        {"wingTimeMax", f_wingTimeMax}, {"statDefense", f_statDefense},
        {"endurance", f_endurance},     {"myPlayer", f_myPlayer},
        {"Main.player", f_playerArr},   {"dayRate", f_dayRate},
        {"time", f_time},               {"bloodMoon", f_bloodMoon},
        {"eclipse", f_eclipse},         {"rain", f_rain},
        {"sandStorm", f_sandStorm},     {"windSpeedCurrent", f_windSpeed},
        {"hardMode", f_hardMode},       {"gameMenu", f_gameMenu},
    };
    int ok = 0, total = 0;
    std::string miss;
    for (const auto& e : all) {
        ++total;
        if (e.f) { ++ok; continue; }
        if (!miss.empty()) miss += ", ";
        miss += e.name;
    }
    if (miss.empty()) mm::logf("修改器：字段解析 %d/%d 全部命中", ok, total);
    else mm::logf("修改器：字段解析 %d/%d，没解析到：%s", ok, total, miss.c_str());
    if (!f_playerArr || !f_myPlayer) { log_missing("Main.player/myPlayer"); return false; }

    gReady = true;
    return true;
}

bool active() {
    return c_god || c_infMana || c_noFall || c_water || c_lava || c_invis || c_speed ||
           c_fly || c_defense || c_day || c_night || c_freezeTime || c_rain || c_sand ||
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
    if (!f_gameMenu) return true;    // 字段没解析到就别拦，宁可显示出来
    uint8_t v = 0;
    il2::field_static_get_value(f_gameMenu, &v);
    return v == 0;                   // gameMenu = true 表示还在主菜单
}

void tick() {
    if (!gReady && !init()) return;
    // C 档的配置写入暂时停用（二分排查闪退）
    if (!active()) return;
    il2::Object* p = me();
    if (!p) return;

    if (c_god) {
        write_b(p, f_immune, false, true);
        int32_t mx = read_i(p, f_statLifeMax2, false, 100);
        write_i(p, f_statLife, false, mx);
    }
    if (c_infMana) {
        int32_t mx = read_i(p, f_statManaMax2, false, 20);
        write_i(p, f_statMana, false, mx);
    }
    if (c_noFall) write_b(p, f_noFallDmg, false, true);
    if (c_water) write_b(p, f_ignoreWater, false, true);
    if (c_lava) {
        // 走岩浆 + 免疫：两个字段能中哪个就写哪个（都写也不冲突）
        write_b(p, f_fireWalk, false, true);
        write_b(p, f_lavaImmune, false, true);
        write_b(p, f_hasMolten, false, true);
    }
    if (c_invis) write_b(p, f_invis, false, true);
    if (c_speed) write_f(p, f_moveSpeed, false, v_speed);
    if (c_fly) {
        float mx = read_f(p, f_wingTimeMax, false, 0);
        if (mx <= 0) mx = 300.0f;
        write_f(p, f_wingTime, false, mx);
    }
    if (c_defense) { write_i(p, f_statDefense, false, 9999); write_f(p, f_endurance, false, 1.0f); }

    // 世界（这些是 Main 的静态字段）
    if (c_hardMode) write_b(nullptr, f_hardMode, true, true);
    if (c_bloodMoon) write_b(nullptr, f_bloodMoon, true, true);
    if (c_eclipse) write_b(nullptr, f_eclipse, true, true);
    if (c_rain) write_f(nullptr, f_rain, true, 1.0f);
    if (c_sand) write_f(nullptr, f_sandStorm, true, 1.0f);
    if (c_wind) write_f(nullptr, f_windSpeed, true, 60.0f);
    if (c_day) write_f(nullptr, f_dayRate, true, 10.0f);      // 时间快进到白天
    if (c_night) write_f(nullptr, f_dayRate, true, -10.0f);
    if (c_freezeTime) write_f(nullptr, f_dayRate, true, 0.0f);
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

}  // namespace cheat
