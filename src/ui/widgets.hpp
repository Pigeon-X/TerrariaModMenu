#pragma once
//
// 菜单用的一套共用控件（暗紫赛博风，对齐安卓版那套外观）。
//
// 全部是头文件里的 inline 函数，预览器（Mac）和真机（iOS）编译的是同一份，
// 所以"预览器里看着对"就等于"真机上就是那样"。
//
// ⚠️ ImGui 的 PushStyleColor / PushStyleVar 必须**严格配对**，
//    多了少了都会污染颜色栈，整个界面配色就乱了（交接文档 5.11 记过这个坑）。
//    这里每个函数都是"push 几层就 pop 几层"，成对写在同一处。
//
#include <cstdarg>
#include <cstdio>
#include <cstring>

#include "imgui.h"

namespace ui {
namespace theme {

// ---- 颜色 ------------------------------------------------------------------
inline ImVec4 panel_bg()    { return ImVec4(0.043f, 0.035f, 0.102f, 0.95f); }
inline ImVec4 panel_edge()  { return ImVec4(0.42f,  0.32f,  0.95f,  0.55f); }
inline ImVec4 header_bg()   { return ImVec4(0.09f,  0.07f,  0.21f,  0.98f); }
inline ImVec4 sidebar_bg()  { return ImVec4(0.055f, 0.045f, 0.125f, 0.95f); }
inline ImVec4 card_bg()     { return ImVec4(0.075f, 0.066f, 0.15f,  0.90f); }
inline ImVec4 card_edge()   { return ImVec4(0.30f,  0.26f,  0.55f,  0.55f); }
inline ImVec4 accent()      { return ImVec4(0.55f,  0.42f,  1.00f,  1.00f); }
inline ImVec4 accent_dim()  { return ImVec4(0.35f,  0.27f,  0.72f,  1.00f); }
inline ImVec4 text()        { return ImVec4(0.88f,  0.88f,  0.96f,  1.00f); }
inline ImVec4 text_dim()    { return ImVec4(0.55f,  0.55f,  0.70f,  1.00f); }
inline ImVec4 ok_green()    { return ImVec4(0.35f,  0.85f,  0.55f,  1.00f); }
inline ImVec4 danger()      { return ImVec4(0.75f,  0.22f,  0.28f,  1.00f); }

// ---- 文字 ------------------------------------------------------------------
inline void text_dim(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    ImGui::PushStyleColor(ImGuiCol_Text, text_dim());
    ImGui::TextV(fmt, ap);
    ImGui::PopStyleColor();
    va_end(ap);
}

inline void text_wrapped_dim(const char* msg) {
    ImGui::PushStyleColor(ImGuiCol_Text, text_dim());
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextUnformatted(msg);
    ImGui::PopTextWrapPos();
    ImGui::PopStyleColor();
}

// 分区标题：主标题 + 右侧小字副标题（对齐安卓版的「脚本 / Lua Mod 管理」那种）
inline void section_header(const char* title, const char* sub) {
    ImGui::PushStyleColor(ImGuiCol_Text, text());
    ImGui::TextUnformatted(title);
    ImGui::PopStyleColor();
    if (sub && *sub) {
        ImGui::SameLine();
        ImGui::PushStyleColor(ImGuiCol_Text, text_dim());
        ImGui::TextUnformatted(sub);
        ImGui::PopStyleColor();
    }
}

// ---- 开关（iOS 那种胶囊滑块，ImGui 自带没有）--------------------------------
// 返回 true 表示这一帧被点过
inline bool switch_widget(const char* id, bool* v) {
    const float h = ImGui::GetFrameHeight() * 0.78f;
    const float w = h * 1.85f;
    const ImVec2 p = ImGui::GetCursorScreenPos();

    ImGui::InvisibleButton(id, ImVec2(w, h));
    bool changed = false;
    if (ImGui::IsItemClicked()) {
        *v = !*v;
        changed = true;
    }

    ImDrawList* dl = ImGui::GetWindowDrawList();
    const float r = h * 0.5f;
    const ImU32 bg = *v ? ImGui::GetColorU32(accent_dim()) : IM_COL32(58, 58, 78, 255);
    dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h), bg, r);
    if (ImGui::IsItemHovered())
        dl->AddRect(p, ImVec2(p.x + w, p.y + h), ImGui::GetColorU32(accent()), r, 0, 1.5f);
    const float kx = *v ? (p.x + w - r) : (p.x + r);
    dl->AddCircleFilled(ImVec2(kx, p.y + r), r - 1.5f, IM_COL32(236, 236, 245, 255));
    return changed;
}

// 一行：左边文字（可带说明），右边开关
inline bool toggle_row(const char* label, bool* v, const char* desc = nullptr) {
    const float sw = ImGui::GetFrameHeight() * 0.78f * 1.85f;
    ImGui::PushStyleColor(ImGuiCol_Text, text());
    ImGui::AlignTextToFramePadding();
    ImGui::TextUnformatted(label);
    ImGui::PopStyleColor();
    if (desc && *desc) {
        ImGui::SameLine();
        ImGui::PushStyleColor(ImGuiCol_Text, text_dim());
        ImGui::TextUnformatted(desc);
        ImGui::PopStyleColor();
    }
    const float x = ImGui::GetWindowWidth() - ImGui::GetStyle().WindowPadding.x - sw;
    if (x > ImGui::GetCursorPosX()) {
        ImGui::SameLine(x);
        ImGui::SetCursorPosY(ImGui::GetCursorPosY() + ImGui::GetStyle().ItemSpacing.y * 0.5f);
    } else {
        ImGui::SameLine();
    }
    char id[128];
    snprintf(id, sizeof(id), "##sw_%s", label);
    return switch_widget(id, v);
}

// 一行：左边文字，右边滑条（用来调倍率/数量）
inline bool slider_row(const char* label, float* v, float lo, float hi, const char* fmt = "%.1f") {
    ImGui::PushStyleColor(ImGuiCol_Text, text());
    ImGui::AlignTextToFramePadding();
    ImGui::TextUnformatted(label);
    ImGui::PopStyleColor();
    const float w = ImGui::GetContentRegionAvail().x * 0.62f;
    const float x = ImGui::GetWindowWidth() - ImGui::GetStyle().WindowPadding.x - w;
    if (x > ImGui::GetCursorPosX()) ImGui::SameLine(x);
    else ImGui::SameLine();
    ImGui::SetNextItemWidth(w);
    char id[128];
    snprintf(id, sizeof(id), "##sl_%s", label);
    return ImGui::SliderFloat(id, v, lo, hi, fmt);
}

// ---- 卡片 ------------------------------------------------------------------
// 高度按行数算：ImGui 的 BeginChild 给 0 高度会"撑满剩余空间"，
// 卡片就会长得很难看，所以这里显式算高。
//   rows > 0  按行数定高
//   rows < 0  撑满剩余（列表类用这个）
//   rows == 0 只有一个标题
// 用法：if (begin_card("##c1", "玩家状态", 4)) { ... } end_card();
inline bool begin_card(const char* id, const char* title, int rows = 0) {
    const float row_h = ImGui::GetFrameHeightWithSpacing();
    float h;
    if (rows < 0) {
        h = 0.0f;                                   // 0 = 撑满剩余
    } else {
        h = (title && *title ? row_h : 0.0f) + (float)rows * row_h + 12.0f;
    }
    ImGui::PushStyleColor(ImGuiCol_ChildBg, card_bg());
    ImGui::PushStyleColor(ImGuiCol_Border, card_edge());
    const float fs = ImGui::GetFontSize();
    ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding, fs * 0.36f);
    ImGui::PushStyleVar(ImGuiStyleVar_ChildBorderSize, 1.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(fs * 0.50f, fs * 0.36f));
    ImGui::BeginChild(id, ImVec2(0, h), ImGuiChildFlags_Border);
    if (title && *title) {
        ImGui::PushStyleColor(ImGuiCol_Text, accent());
        ImGui::TextUnformatted(title);
        ImGui::PopStyleColor();
        ImGui::Separator();
    }
    return true;
}

inline void end_card() {
    ImGui::EndChild();
    ImGui::PopStyleVar(3);
    ImGui::PopStyleColor(2);
}

// ---- 侧栏导航项 ------------------------------------------------------------
// 返回 true = 这一帧被点中
inline bool nav_item(const char* label, bool selected) {
    const float h = ImGui::GetFrameHeight();
    const ImVec2 p = ImGui::GetCursorScreenPos();
    const float w = ImGui::GetContentRegionAvail().x;
    char id[128];
    snprintf(id, sizeof(id), "##nav_%s", label);
    ImGui::InvisibleButton(id, ImVec2(w, h));
    const bool clicked = ImGui::IsItemClicked();

    ImDrawList* dl = ImGui::GetWindowDrawList();
    if (selected) {
        dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h), IM_COL32(68, 52, 138, 230), 6.0f);
        dl->AddRectFilled(p, ImVec2(p.x + 3, p.y + h), ImGui::GetColorU32(accent()), 2.0f);
    } else if (ImGui::IsItemHovered()) {
        dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h), IM_COL32(48, 42, 88, 150), 6.0f);
    }
    const ImU32 col = selected ? IM_COL32(236, 236, 248, 255) : IM_COL32(160, 158, 190, 255);
    dl->AddText(ImVec2(p.x + ImGui::GetFontSize() * 0.55f,
                       p.y + (h - ImGui::GetTextLineHeight()) * 0.5f), col, label);
    return clicked;
}

// ---- 整套主题样式 ----------------------------------------------------------
// 一次性 push/pop 全部配色和圆角。**必须成对调用**（push_all / pop_all 各一次），
// 数量在这里写死并对齐，避免到处散着写导致颜色栈失衡。
inline void push_all() {
    // 尺寸一律按字号算：真机字号是 48px（16pt × 3x），预览器只有 22px。
    // 写死像素的话两边必有一边难看 —— 而且真机渲染层虽然 ScaleAllSizes 过一遍，
    // 我们这里 push 的会把它覆盖掉，所以必须自己乘。
    const float fs = ImGui::GetFontSize();
    ImGui::PushStyleColor(ImGuiCol_WindowBg, panel_bg());                         // 1
    ImGui::PushStyleColor(ImGuiCol_Border, panel_edge());                         // 2
    ImGui::PushStyleColor(ImGuiCol_Text, text());                                 // 3
    ImGui::PushStyleColor(ImGuiCol_TextDisabled, text_dim());                     // 4
    ImGui::PushStyleColor(ImGuiCol_FrameBg, ImVec4(0.10f, 0.09f, 0.19f, 1.0f));   // 5
    ImGui::PushStyleColor(ImGuiCol_FrameBgHovered, ImVec4(0.16f, 0.14f, 0.30f, 1.0f)); // 6
    ImGui::PushStyleColor(ImGuiCol_FrameBgActive, ImVec4(0.20f, 0.17f, 0.38f, 1.0f));  // 7
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.17f, 0.15f, 0.32f, 1.0f));    // 8
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.30f, 0.24f, 0.60f, 1.0f)); // 9
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, accent_dim());                   // 10
    ImGui::PushStyleColor(ImGuiCol_Header, ImVec4(0.22f, 0.18f, 0.42f, 1.0f));    // 11
    ImGui::PushStyleColor(ImGuiCol_HeaderHovered, ImVec4(0.30f, 0.24f, 0.60f, 1.0f)); // 12
    ImGui::PushStyleColor(ImGuiCol_HeaderActive, accent_dim());                   // 13
    ImGui::PushStyleColor(ImGuiCol_Separator, card_edge());                       // 14
    ImGui::PushStyleColor(ImGuiCol_ScrollbarBg, ImVec4(0, 0, 0, 0));              // 15
    ImGui::PushStyleColor(ImGuiCol_ScrollbarGrab, ImVec4(0.28f, 0.24f, 0.50f, 0.8f)); // 16
    ImGui::PushStyleColor(ImGuiCol_SliderGrab, accent_dim());                     // 17
    ImGui::PushStyleColor(ImGuiCol_SliderGrabActive, accent());                   // 18
    ImGui::PushStyleColor(ImGuiCol_CheckMark, accent());                          // 19
    ImGui::PushStyleColor(ImGuiCol_PopupBg, ImVec4(0.07f, 0.06f, 0.14f, 0.98f)); // 20
    ImGui::PushStyleColor(ImGuiCol_TextSelectedBg, accent_dim());                 // 21

    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, fs * 0.45f);                // 1
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1.0f);                    // 2
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, fs * 0.30f);                 // 3
    ImGui::PushStyleVar(ImGuiStyleVar_GrabRounding, fs * 0.30f);                  // 4
    ImGui::PushStyleVar(ImGuiStyleVar_ScrollbarRounding, fs * 0.30f);             // 5
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(fs * 0.55f, fs * 0.40f)); // 6
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(fs * 0.52f, fs * 0.28f));  // 7
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(fs * 0.40f, fs * 0.30f));   // 8
}

inline void pop_all() {
    ImGui::PopStyleVar(8);
    ImGui::PopStyleColor(21);
}

}  // namespace theme
}  // namespace ui
