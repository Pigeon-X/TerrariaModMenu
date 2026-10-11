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

    if (theme::begin_card("##card_status", "玩家状态", 4)) {
        theme::toggle_row("无限生命", &c_god, "免疫伤害 + 血量拉满");
        theme::toggle_row("无限魔力", &c_infMana, "魔力常满");
        theme::toggle_row("防御拉满", &c_defense, "防御 9999 + 减伤 100%");
        theme::toggle_row("隐身", &c_invis, "怪物看不见你");
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

    if (theme::begin_card("##card_time", "时间", 2)) {
        static const char* const kTime[] = {"白天快进", "夜晚快进", "冻结时间"};
        const int cur = c_day ? 0 : (c_night ? 1 : (c_freezeTime ? 2 : -1));
        const int hit = seg_button(kTime, 3, cur);
        if (hit >= 0) {
            if (hit == cur) pick_time(-1);      // 再点一次 = 取消
            else pick_time(hit);
        }
        theme::text_dim("dayRate = %+.0f", c_day ? 10.0f : (c_night ? -10.0f : 0.0f));
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

}  // namespace cheat
