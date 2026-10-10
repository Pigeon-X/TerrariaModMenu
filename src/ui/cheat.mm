#include "cheat.hpp"

#include <cmath>
#include <cstring>
#include <string>

#include "imgui.h"

#include "../il2cpp_api.hpp"
#include "../mm_log.hpp"
#include "../core/config.hpp"

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
// Main 字段
il2::Field* f_myPlayer; il2::Field* f_playerArr;
il2::Field* f_dayRate; il2::Field* f_time; il2::Field* f_bloodMoon;
il2::Field* f_eclipse; il2::Field* f_rain; il2::Field* f_sandStorm;
il2::Field* f_windSpeed; il2::Field* f_hardMode;
il2::Field* f_mouseX; il2::Field* f_mouseY;

// ---- 开关 ------------------------------------------------------------------
bool c_god = false, c_infMana = false, c_noFall = false, c_water = false;
bool c_lava = false, c_invis = false, c_speed = false, c_fly = false, c_defense = false;
float v_speed = 2.0f;
bool c_day = false, c_night = false, c_freezeTime = false;
bool c_rain = false, c_sand = false, c_wind = false, c_bloodMoon = false, c_eclipse = false;
bool c_hardMode = false;
int  v_itemId = 1, v_itemCount = 99;
char v_itemSearch[64] = "";

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
    f_statLife = F(gPlayer, "statLife");          f_statLifeMax2 = F(gPlayer, "statLifeMax2");
    f_statMana = F(gPlayer, "statMana");          f_statManaMax2 = F(gPlayer, "statManaMax2");
    f_immune = F(gPlayer, "immune");              f_noFallDmg = F(gPlayer, "noFallDmg");
    f_ignoreWater = F(gPlayer, "ignoreWater");    f_fireWalk = F(gPlayer, "fireWalk");
    f_hasMolten = F(gPlayer, "hasMolten");        f_invis = F(gPlayer, "invis");
    f_moveSpeed = F(gPlayer, "moveSpeed");        f_wingTime = F(gPlayer, "wingTime");
    f_wingTimeMax = F(gPlayer, "wingTimeMax");    f_statDefense = F(gPlayer, "statDefense");
    f_endurance = F(gPlayer, "endurance");

    f_myPlayer = F(gMain, "myPlayer");            f_playerArr = F(gMain, "player");
    f_dayRate = F(gMain, "dayRate");              f_time = F(gMain, "time");
    f_bloodMoon = F(gMain, "bloodMoon");          f_eclipse = F(gMain, "eclipse");
    f_rain = F(gMain, "rain");                    f_sandStorm = F(gMain, "sandStorm");
    f_windSpeed = F(gMain, "windSpeedCurrent");   f_hardMode = F(gMain, "hardMode");
    f_mouseX = F(gMain, "mouseX");                f_mouseY = F(gMain, "mouseY");

    int ok = 0, total = 0;
    il2::Field* all[] = {f_statLife, f_statLifeMax2, f_statMana, f_statManaMax2, f_immune,
                         f_noFallDmg, f_ignoreWater, f_fireWalk, f_hasMolten, f_invis,
                         f_moveSpeed, f_wingTime, f_wingTimeMax, f_statDefense, f_endurance,
                         f_myPlayer, f_playerArr, f_dayRate, f_time, f_bloodMoon, f_eclipse,
                         f_rain, f_sandStorm, f_windSpeed, f_hardMode, f_mouseX, f_mouseY};
    for (auto* p : all) { ++total; if (p) ++ok; }
    mm::logf("修改器：字段解析 %d/%d，Item 类 %s", ok, total, gItem ? "有" : "无");
    if (!f_playerArr || !f_myPlayer) { log_missing("Main.player/myPlayer"); return false; }

    gReady = true;
    return true;
}

bool active() {
    return c_god || c_infMana || c_noFall || c_water || c_lava || c_invis || c_speed ||
           c_fly || c_defense || c_day || c_night || c_freezeTime || c_rain || c_sand ||
           c_wind || c_bloodMoon || c_eclipse || c_hardMode;
}

void tick() {
    if (!gReady && !init()) return;
    // 每帧把状态写进配置（cfg::set 只在值变化时标脏，落盘由 cfg::tick 节流）
    cfg::set_bool("cheat.god", c_god);
    cfg::set_bool("cheat.infMana", c_infMana);
    cfg::set_bool("cheat.noFall", c_noFall);
    cfg::set_bool("cheat.water", c_water);
    cfg::set_bool("cheat.lava", c_lava);
    cfg::set_bool("cheat.invis", c_invis);
    cfg::set_bool("cheat.defense", c_defense);
    cfg::set_bool("cheat.speed", c_speed);
    cfg::set_float("cheat.speedVal", v_speed);
    cfg::set_bool("cheat.fly", c_fly);
    cfg::set_bool("world.hardMode", c_hardMode);
    cfg::set_bool("world.bloodMoon", c_bloodMoon);
    cfg::set_bool("world.eclipse", c_eclipse);
    cfg::set_bool("world.rain", c_rain);
    cfg::set_bool("world.sand", c_sand);
    cfg::set_bool("world.wind", c_wind);
    cfg::set_bool("world.day", c_day);
    cfg::set_bool("world.night", c_night);
    cfg::set_bool("world.freeze", c_freezeTime);
    cfg::set_int("item.id", v_itemId);
    cfg::set_int("item.count", v_itemCount);

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
    if (c_lava) { write_b(p, f_fireWalk, false, true); write_b(p, f_hasMolten, false, true); }
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

namespace {

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

}  // namespace

void draw_tab() {
    if (!gReady && !init()) {
        ImGui::TextColored(ImVec4(1, 0.5f, 0.4f, 1), "修改器不可用（IL2CPP 未就绪或类名不匹配）");
        return;
    }
    il2::Object* p = me();
    ImGui::Text("当前玩家：%s", p ? "已锁定" : "未进入世界");
    ImGui::Separator();

    if (ImGui::CollapsingHeader("自身", ImGuiTreeNodeFlags_DefaultOpen)) {
        ImGui::Checkbox("无敌（免疫 + 生命拉满）", &c_god);
        ImGui::Checkbox("无限魔力", &c_infMana);
        ImGui::Checkbox("摔落无伤", &c_noFall);
        ImGui::Checkbox("水下呼吸", &c_water);
        ImGui::Checkbox("岩浆免疫", &c_lava);
        ImGui::Checkbox("隐身", &c_invis);
        ImGui::Checkbox("防御/减伤拉满", &c_defense);
        ImGui::Checkbox("移动速度倍率", &c_speed);
        if (c_speed) ImGui::SliderFloat("速度", &v_speed, 1.0f, 10.0f, "%.1f");
        ImGui::Checkbox("无限飞行时长", &c_fly);
    }
    if (ImGui::CollapsingHeader("世界")) {
        ImGui::Checkbox("困难模式", &c_hardMode);
        ImGui::Checkbox("血月", &c_bloodMoon);
        ImGui::Checkbox("日食", &c_eclipse);
        ImGui::Checkbox("下雨", &c_rain);
        ImGui::SameLine(); ImGui::Checkbox("沙尘暴", &c_sand);
        ImGui::Checkbox("刮风", &c_wind);
        ImGui::Checkbox("时间快进到白天", &c_day);
        ImGui::SameLine(); ImGui::Checkbox("黑夜", &c_night);
        ImGui::Checkbox("冻结时间", &c_freezeTime);
    }
    if (ImGui::CollapsingHeader("物品", ImGuiTreeNodeFlags_DefaultOpen)) {
        ImGui::InputInt("物品 ID", &v_itemId, 1, 10);
        ImGui::InputInt("数量", &v_itemCount, 1, 100);
        if (ImGui::Button("放入背包", ImVec2(160, 0))) give_item(v_itemId, v_itemCount);
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("按 Item ID 直接塞进背包第一个空槽");
    }
}

}  // namespace cheat
