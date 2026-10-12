//
// 修改器的**界面**部分（对齐安卓版那套：卡片式分区 + 胶囊开关）。
//
// 这个文件在**预览器和真机两边都编译**——预览器里看到的就是真机上的那份，
// 所以改完先在预览器验，再上模拟器/真机（交接文档的铁律）。
// 真正读写游戏字段的部分在 cheat.mm（只有真机编）。
//
#include "cheat.hpp"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "cheat_state.hpp"
#include "menu.hpp"          // ui::log_line
#include "widgets.hpp"

#ifdef MODMENU_PREVIEW
#include "preview_stubs.hpp"          // 假的物品表
#else
#include "../core/game_data.hpp"
#endif

namespace cheat {
namespace {

using namespace ui;

// 「时间控制」是三选一，选一个就自动取消另外两个
void pick_time(int which) {
    c_day = (which == 0);
    c_night = (which == 1);
    c_freezeTime = (which == 2);
}

// 一排小按钮（三选一那种）。宽度按文字算——真机字号是预览器的两倍多，
// 写死像素宽度在真机上会被截断。
int seg_button(const char* const* labels, int count, int current) {
    int clicked = -1;
    for (int i = 0; i < count; ++i) {
        if (i) ImGui::SameLine();
        const bool on = (i == current);
        if (on) {
            ImGui::PushStyleColor(ImGuiCol_Button, theme::accent_dim());
            ImGui::PushStyleColor(ImGuiCol_ButtonHovered, theme::accent());
        }
        const float w = ImGui::CalcTextSize(labels[i]).x + ImGui::GetFontSize() * 1.6f;
        if (ImGui::Button(labels[i], ImVec2(w, 0))) clicked = i;
        if (on) ImGui::PopStyleColor(2);
    }
    return clicked;
}

}  // namespace

// ---------------------------------------------------------------------------
// 自身
// ---------------------------------------------------------------------------
void draw_self_page() {
    theme::section_header("自身", "self · 玩家状态与移动");
    ImGui::Spacing();

    // 实时数值 —— 开了开关能当场看见数字变，就不用猜"到底生效没有"
    {
        int life = 0, life_max = 0, mana = 0, mana_max = 0, def = 0;
        player_stats(&life, &life_max, &mana, &mana_max, &def);
        if (theme::begin_card("##card_live", "实时数值", 1)) {
            const bool no_player = (life_max == 0 && mana_max == 0);
            if (no_player) {
                theme::text_dim("读不到玩家数据（还没进地图？）");
            } else {
                ImGui::PushStyleColor(ImGuiCol_Text, theme::accent());
                ImGui::Text("生命 %d / %d", life, life_max);
                ImGui::PopStyleColor();
                ImGui::SameLine();
                ImGui::PushStyleColor(ImGuiCol_Text, theme::accent());
                ImGui::Text("魔力 %d / %d", mana, mana_max);
                ImGui::PopStyleColor();
                ImGui::SameLine();
                ImGui::PushStyleColor(ImGuiCol_Text, theme::accent());
                ImGui::Text("防御 %d", def);
                ImGui::PopStyleColor();
            }
        }
        theme::end_card();
        ImGui::Spacing();
    }

    if (theme::begin_card("##card_status", "玩家状态", 6)) {
        theme::toggle_row("无限生命", &c_god, "免疫伤害 + 血量拉满");
        theme::toggle_row("无限魔力", &c_infMana, "魔力常满");
        theme::toggle_row("防御拉满", &c_defense, "防御 9999 + 减伤 100%");
        theme::toggle_row("隐身", &c_invis, "怪物看不见你");
        theme::toggle_row("无视击退", &c_noKnockback, nullptr);
        theme::toggle_row("快速回血", &c_regen, nullptr);
    }
    theme::end_card();
    ImGui::Spacing();

    if (theme::begin_card("##card_actions", "角色处理", 1)) {
        const float bw = ImGui::GetFontSize() * 9.0f;
        ImGui::PushStyleColor(ImGuiCol_Button, theme::accent_dim());
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, theme::accent());
        if (ImGui::Button("回满生命与魔力", ImVec2(bw, 0))) heal_full();
        ImGui::SameLine();
        if (ImGui::Button("传送到出生点", ImVec2(bw, 0))) teleport_to_spawn();
        ImGui::PopStyleColor(2);
    }
    theme::end_card();
    ImGui::Spacing();

    if (theme::begin_card("##card_move", "移动", 4)) {
        theme::toggle_row("移动加速", &c_speed, "按倍率覆盖 moveSpeed");
        if (c_speed) theme::slider_row("　倍率", &v_speed, 1.0f, 10.0f, "%.1fx");
        theme::toggle_row("无限飞行", &c_fly, "翅膀时间拉满");
        theme::toggle_row("摔落无伤", &c_noFall, nullptr);
    }
    theme::end_card();
    ImGui::Spacing();

    if (theme::begin_card("##card_env", "环境适应", 2)) {
        theme::toggle_row("水下呼吸", &c_water, nullptr);
        theme::toggle_row("岩浆免疫", &c_lava, "fireWalk + hasMolten");
    }
    theme::end_card();
}

// ---------------------------------------------------------------------------
// 世界
// ---------------------------------------------------------------------------
void draw_world_page() {
    theme::section_header("世界", "world · 时间与事件");
    ImGui::Spacing();

    if (theme::begin_card("##card_time", "时间", 5)) {
        static const char* const kTime[] = {"白天快进", "夜晚快进", "冻结时间"};
        const int cur = c_day ? 0 : (c_night ? 1 : (c_freezeTime ? 2 : -1));
        const int hit = seg_button(kTime, 3, cur);
        if (hit >= 0) {
            if (hit == cur) pick_time(-1);      // 再点一次 = 取消
            else pick_time(hit);
        }
        theme::text_dim("流速 dayRate = %+.0f", c_day ? 10.0f : (c_night ? -10.0f : 0.0f));

        // 直接跳到某个时刻（会连 dayTime 一起设，时钟才对）
        const double hh = world_time_of_day();
        if (hh >= 0) {
            const int h = (int)hh;
            const int m = (int)((hh - h) * 60.0 + 0.5);
            theme::text_dim("现在是 %02d:%02d", h, m);
        } else {
            theme::text_dim("现在是 —（还没进地图）");
        }
        static const char* const kPreset[] = {"清晨", "正午", "黄昏", "午夜"};
        const int ph = seg_button(kPreset, 4, -1);
        if (ph >= 0) set_world_time(ph);
    }
    theme::end_card();
    ImGui::Spacing();

    if (theme::begin_card("##card_event", "事件", 6)) {
        theme::toggle_row("血月", &c_bloodMoon, nullptr);
        theme::toggle_row("日食", &c_eclipse, nullptr);
        theme::toggle_row("下雨", &c_rain, nullptr);
        theme::toggle_row("沙尘暴", &c_sand, nullptr);
        theme::toggle_row("刮大风", &c_wind, "windSpeedCurrent = 60");
        theme::toggle_row("困难模式", &c_hardMode, "⚠ 不可逆，慎点");
    }
    theme::end_card();
}

// ---------------------------------------------------------------------------
// 物品（搜索 + 放入背包）
// ---------------------------------------------------------------------------
void draw_item_page() {
    theme::section_header("物品", "item · 搜索并放入背包");
    ImGui::Spacing();

    if (theme::begin_card("##card_give", "直接给物品", 2)) {
        const float in_w = ImGui::GetFontSize() * 3.6f;
        ImGui::SetNextItemWidth(in_w);
        ImGui::InputInt("##iid", &v_itemId, 1, 10);
        ImGui::SameLine();
        ImGui::SetNextItemWidth(in_w);
        ImGui::InputInt("##icnt", &v_itemCount, 1, 100);
        ImGui::SameLine();
        ImGui::PushStyleColor(ImGuiCol_Button, theme::accent_dim());
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, theme::accent());
        const bool hit = ImGui::Button("放入背包");
        ImGui::PopStyleColor(2);
        theme::text_dim("左边是物品 ID，右边是数量");
        if (hit) give_item(v_itemId, v_itemCount);
    }
    theme::end_card();
    ImGui::Spacing();

    const auto& tbl = gd::item_table();

    ImGui::PushStyleColor(ImGuiCol_Text, theme::text_dim());
    ImGui::Text("共 %zu 项 · 点名字直接放进背包", tbl.size());
    ImGui::PopStyleColor();

    ImGui::SetNextItemWidth(-1);
    ImGui::InputTextWithHint("##isearch", "搜索物品名或 ID", v_itemSearch, sizeof(v_itemSearch));
    ImGui::Spacing();

    ImGui::PushStyleColor(ImGuiCol_ChildBg, theme::card_bg());
    ImGui::PushStyleColor(ImGuiCol_Border, theme::card_edge());
    ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding, 8.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_ChildBorderSize, 1.0f);
    ImGui::BeginChild("##ilist", ImVec2(0, 0), ImGuiChildFlags_Border);
    {
        int shown = 0;
        for (const auto& [id, name] : tbl) {
            if (v_itemSearch[0]) {
                char idbuf[16];
                snprintf(idbuf, sizeof(idbuf), "%d", id);
                if (name.find(v_itemSearch) == std::string::npos &&
                    strstr(idbuf, v_itemSearch) == nullptr) {
                    continue;
                }
            }
            char label[160];
            snprintf(label, sizeof(label), "%s##it%d", name.c_str(), id);
            if (ImGui::Selectable(label)) give_item(id, v_itemCount);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip("ID %d · 点击放入背包（数量 %d）", id, v_itemCount);
            }
            if (++shown >= 400) {
                theme::text_dim("…… 还有更多，输入关键字缩小范围");
                break;
            }
        }
        if (shown == 0) theme::text_dim("没有匹配的物品");
    }
    ImGui::EndChild();
    ImGui::PopStyleVar(2);
    ImGui::PopStyleColor(2);
}

// ---------------------------------------------------------------------------
// 实体（NPC）
// ---------------------------------------------------------------------------
void draw_entity_page() {
    theme::section_header("实体", "entity · NPC 与怪物");
    ImGui::Spacing();

    int alive = 0, hostile = 0;
    npc_stats(&alive, &hostile);

    if (theme::begin_card("##card_npc_stat", "当前状态", 2)) {
        ImGui::PushStyleColor(ImGuiCol_Text, theme::text());
        ImGui::Text("存活 NPC %d 个（敌对 %d）", alive, hostile);
        ImGui::PopStyleColor();
        theme::text_dim("只统计处于 active 状态的槽位");
    }
    theme::end_card();
    ImGui::Spacing();

    if (theme::begin_card("##card_npc_kill", "清理", 3)) {
        theme::toggle_row("只清敌对", &e_hostile_only, "不碰 NPC 村民/宠物");
        const float bw = ImGui::GetFontSize() * 7.0f;
        if (ImGui::Button("清除全部", ImVec2(bw, 0))) {
            const int n = kill_npcs(e_hostile_only);
            char msg[96];
            snprintf(msg, sizeof(msg), "已清除 %d 个 NPC", n);
            ui::log_line(msg);
        }
        ImGui::SameLine();
        if (ImGui::Button("秒杀全部", ImVec2(bw, 0))) {
            const int n = strike_npcs(e_hostile_only);
            char msg[96];
            snprintf(msg, sizeof(msg), "已带伤害击杀 %d 个 NPC", n);
            ui::log_line(msg);
        }
        theme::text_dim("清除 = 直接移除（无声消失）　秒杀 = 带伤害击杀（有死亡表现/掉落）");
    }
    theme::end_card();
    ImGui::Spacing();

    if (theme::begin_card("##card_npc_spawn", "生成", 2)) {
        const float in_w = ImGui::GetFontSize() * 3.6f;
        ImGui::SetNextItemWidth(in_w);
        ImGui::InputInt("##npctype", &v_npcType, 1, 10);
        ImGui::SameLine();
        ImGui::SetNextItemWidth(in_w);
        ImGui::InputInt("##npccount", &v_npcCount, 1, 10);
        ImGui::SameLine();
        ImGui::PushStyleColor(ImGuiCol_Button, theme::accent_dim());
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, theme::accent());
        const bool hit = ImGui::Button("生成");
        ImGui::PopStyleColor(2);
        if (hit) spawn_npc(v_npcType, v_npcCount);
        theme::text_dim("左：NPC 类型号（见下表）　右：数量，生成在角色附近");
    }
    theme::end_card();
    ImGui::Spacing();

    const auto& tbl = gd::npc_table();
    ImGui::PushStyleColor(ImGuiCol_Text, theme::text_dim());
    ImGui::Text("共 %zu 种 · 点名字填入类型号", tbl.size());
    ImGui::PopStyleColor();
    ImGui::SetNextItemWidth(-1);
    ImGui::InputTextWithHint("##npcsearch", "搜索 NPC 名或 ID", v_npcSearch, sizeof(v_npcSearch));
    ImGui::Spacing();

    ImGui::PushStyleColor(ImGuiCol_ChildBg, theme::card_bg());
    ImGui::PushStyleColor(ImGuiCol_Border, theme::card_edge());
    ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding, ImGui::GetFontSize() * 0.36f);
    ImGui::PushStyleVar(ImGuiStyleVar_ChildBorderSize, 1.0f);
    ImGui::BeginChild("##npclist", ImVec2(0, 0), ImGuiChildFlags_Border);
    {
        int shown = 0;
        for (const auto& [id, name] : tbl) {
            if (v_npcSearch[0]) {
                char idbuf[16];
                snprintf(idbuf, sizeof(idbuf), "%d", id);
                if (name.find(v_npcSearch) == std::string::npos &&
                    strstr(idbuf, v_npcSearch) == nullptr) continue;
            }
            char label[160];
            snprintf(label, sizeof(label), "%s##npc%d", name.c_str(), id);
            if (ImGui::Selectable(label)) {
                v_npcType = id;
                v_npcCount = 1;
            }
            if (ImGui::IsItemHovered()) ImGui::SetTooltip("ID %d · 点一下填进上面的类型号", id);
            if (++shown >= 400) { theme::text_dim("…… 还有更多，输入关键字缩小范围"); break; }
        }
        if (shown == 0) theme::text_dim("没有匹配的 NPC");
    }
    ImGui::EndChild();
    ImGui::PopStyleVar(2);
    ImGui::PopStyleColor(2);
}

}  // namespace cheat
