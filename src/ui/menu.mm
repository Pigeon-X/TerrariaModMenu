//
// 菜单界面：紫色赛博风（侧边栏导航 + 分区子标签 + 卡片面板）
//
#include "menu.hpp"

#include <cmath>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "imgui.h"

#ifdef MODMENU_PREVIEW
#include "preview_stubs.hpp"
#else
#include "../il2cpp_api.hpp"
#include "../mm_log.hpp"
#include "../mods/mod_loader.hpp"
#include "cheat.hpp"
#endif

namespace ui {
namespace {

std::mutex g_mutex;
bool g_visible = true;
void* g_ball_tex = nullptr;
ImVec2 g_ball_pos(60, 200);
ImVec2 g_ball_drag(0, 0);
constexpr float kBallSize = 108.0f;
std::deque<std::string> g_log;
std::vector<std::pair<std::string, PanelFn>> g_panels;
char g_filter[128] = "";
bool g_auto_scroll = true;
bool g_only_errors = false;
ImVec2 g_win_pos(0, 0);
ImVec2 g_win_size(0, 0);
float g_ui_scale = 1.0f;
int  g_page = 0;
bool g_script_enabled = true;

// ---- 主题：深紫底 + 紫色高亮 ----
const ImVec4 kPurple  = ImVec4(0.55f, 0.36f, 0.98f, 1.00f);
const ImVec4 kPurpleD = ImVec4(0.30f, 0.18f, 0.60f, 1.00f);

void apply_theme() {
    ImGuiStyle& s = ImGui::GetStyle();
    s.WindowRounding = 14; s.ChildRounding = 10; s.FrameRounding = 7;
    s.GrabRounding = 7; s.PopupRounding = 10; s.ScrollbarRounding = 7;
    s.WindowBorderSize = 0; s.ChildBorderSize = 1; s.FramePadding = ImVec2(10, 6);
    s.ItemSpacing = ImVec2(8, 8);
    ImVec4* c = s.Colors;
    c[ImGuiCol_WindowBg]        = ImVec4(0.07f, 0.06f, 0.13f, 0.97f);
    c[ImGuiCol_ChildBg]         = ImVec4(0.11f, 0.09f, 0.19f, 0.85f);
    c[ImGuiCol_Border]          = ImVec4(0.35f, 0.26f, 0.70f, 0.35f);
    c[ImGuiCol_Text]            = ImVec4(0.92f, 0.90f, 1.00f, 1.00f);
    c[ImGuiCol_TextDisabled]    = ImVec4(0.62f, 0.58f, 0.78f, 1.00f);
    c[ImGuiCol_Button]          = ImVec4(0.30f, 0.20f, 0.58f, 0.70f);
    c[ImGuiCol_ButtonHovered]   = ImVec4(0.44f, 0.30f, 0.85f, 0.85f);
    c[ImGuiCol_ButtonActive]    = ImVec4(0.55f, 0.36f, 0.98f, 1.00f);
    c[ImGuiCol_FrameBg]         = ImVec4(0.15f, 0.12f, 0.26f, 1.00f);
    c[ImGuiCol_FrameBgHovered]  = ImVec4(0.24f, 0.18f, 0.44f, 1.00f);
    c[ImGuiCol_FrameBgActive]   = ImVec4(0.30f, 0.22f, 0.56f, 1.00f);
    c[ImGuiCol_CheckMark]       = kPurple;
    c[ImGuiCol_SliderGrab]      = kPurple;
    c[ImGuiCol_SliderGrabActive]= ImVec4(0.72f, 0.55f, 1.00f, 1.00f);
    c[ImGuiCol_Header]          = ImVec4(0.30f, 0.20f, 0.58f, 0.65f);
    c[ImGuiCol_HeaderHovered]   = ImVec4(0.42f, 0.28f, 0.80f, 0.80f);
    c[ImGuiCol_HeaderActive]    = kPurpleD;
    c[ImGuiCol_Separator]       = ImVec4(0.35f, 0.26f, 0.70f, 0.45f);
    c[ImGuiCol_ScrollbarBg]     = ImVec4(0.10f, 0.08f, 0.18f, 0.60f);
    c[ImGuiCol_ScrollbarGrab]   = ImVec4(0.38f, 0.28f, 0.72f, 0.80f);
    c[ImGuiCol_PopupBg]         = ImVec4(0.10f, 0.08f, 0.18f, 0.98f);
}

// ---- 卡片容器 ----
bool begin_card(const char* id, const char* title, float w = 0.0f) {
    if (w <= 0) w = ImGui::GetContentRegionAvail().x;
    ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.10f, 0.08f, 0.18f, 0.90f));
    ImGui::BeginChild(id, ImVec2(w, 0), true);
    ImGui::PushStyleColor(ImGuiCol_Text, kPurple);
    ImGui::TextUnformatted(title);
    ImGui::PopStyleColor();
    ImGui::Separator();
    return true;
}
void end_card() { ImGui::EndChild(); ImGui::PopStyleColor(); }

// ---- 侧边栏 ----
struct NavItem { const char* label; int page; bool header; };
NavItem g_nav[] = {
    {"功能",        -1, true},
    {"主要",         0, false},
    {"世界",         1, false},
    {"实体",         2, false},
    {"物品",         3, false},
    {"杂项",         4, false},
    {"网络",         5, false},
    {"设置",         6, false},
    {"视觉",         7, true},
    {"ESP / HUD",    8, false},
    {"控制台",      10, true},
    {"日志",        10, false},
    {"脚本",        11, true},
    {"Lua Mod",     11, false},
};

void draw_sidebar(float w) {
    ImGui::BeginChild("##nav", ImVec2(w, 0), true);
    for (auto& it : g_nav) {
        if (it.header) {
            ImGui::Spacing();
            ImGui::PushStyleColor(ImGuiCol_Text, kPurple);
            ImGui::TextUnformatted(it.label);
            ImGui::PopStyleColor();
            continue;
        }
        ImGui::Indent(14);
        if (g_page == it.page) ImGui::PushStyleColor(ImGuiCol_Header, kPurpleD);
        if (ImGui::Selectable(it.label, g_page == it.page)) g_page = it.page;
        if (g_page == it.page) ImGui::PopStyleColor();
        ImGui::Unindent(14);
    }
    ImGui::EndChild();
}

// ---- 各页 ----
void draw_console_page() {
    if (ImGui::BeginTabBar("##console_tabs")) {
        if (ImGui::BeginTabItem("日志")) {
            begin_card("##card_log", "运行日志");
            ImGui::Checkbox("自动滚动", &g_auto_scroll);
            ImGui::SameLine(); ImGui::Checkbox("仅显示错误", &g_only_errors);
            ImGui::SameLine();
            if (ImGui::Button("清空")) {
                std::lock_guard<std::mutex> lock(g_mutex);
                g_log.clear();
            }
            ImGui::SameLine();
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                ImGui::TextDisabled("共 %zu 条", g_log.size());
            }
            ImGui::Separator();
            ImGui::BeginChild("##loglist", ImVec2(0, 0));
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                for (const auto& line : g_log) {
                    if (g_only_errors && line.find("错误") == std::string::npos &&
                        line.find("失败") == std::string::npos) continue;
                    ImGui::TextUnformatted(line.c_str());
                }
                if (g_auto_scroll && ImGui::GetScrollY() >= ImGui::GetScrollMaxY() - 1.0f)
                    ImGui::SetScrollHereY(1.0f);
            }
            ImGui::EndChild();
            end_card();
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("状态")) {
            begin_card("##card_st", "运行状态");
#ifndef MODMENU_PREVIEW
            ImGui::Text("IL2CPP 按名解析：%s", il2::ready() ? "就绪" : "未就绪");
            ImGui::Text("已解析符号：%d", il2::symbol_count());
            const char* missing = il2::last_missing();
            if (missing && *missing) ImGui::TextWrapped("最后未解析：%s", missing);
            ImGui::TextWrapped("Mods 目录：%s", mods::root_dir().c_str());
#else
            ImGui::Text("IL2CPP：预览模式（假数据）");
#endif
            ImGui::TextWrapped("日志文件：Documents/TerrariaModMenu.log");
            end_card();
            ImGui::EndTabItem();
        }
        ImGui::EndTabBar();
    }
}

void draw_script_page() {
    if (ImGui::BeginTabBar("##script_tabs")) {
        if (ImGui::BeginTabItem("脚本")) {
            begin_card("##card_script", "脚本功能");
            ImGui::Checkbox("启用脚本功能", &g_script_enabled);
#ifndef MODMENU_PREVIEW
            ImGui::TextDisabled("Mod 目录：%s", mods::root_dir().c_str());
            ImGui::Separator();
            if (ImGui::Button("重新扫描")) mods::reload();
            ImGui::SameLine();
            if (ImGui::Button("全部重载")) mods::reload();
            ImGui::Separator();
            const auto& list = mods::list();
            if (list.empty()) {
                ImGui::TextWrapped("Mods 目录为空。把 Mod 文件夹放进上面的目录，再点「重新扫描」。");
            }
            for (const auto& m : list) {
                ImGui::PushID(m.name.c_str());
                ImGui::TextColored(m.loaded ? ImVec4(0.5f, 1, 0.5f, 1) : ImVec4(1, 0.5f, 0.4f, 1),
                                   "● %s", m.name.c_str());
                ImGui::SameLine(); ImGui::TextDisabled("v%s", m.version.c_str());
                if (!m.description.empty()) ImGui::TextWrapped("    %s", m.description.c_str());
                if (!m.loaded && !m.error.empty())
                    ImGui::TextColored(ImVec4(1, 0.4f, 0.4f, 1), "    加载失败：%s", m.error.c_str());
                ImGui::PopID();
            }
#else
            ImGui::TextDisabled("预览模式：这里显示假 Mod 列表");
            for (const auto& m : mods::list()) ImGui::Text("● %s v%s", m.name.c_str(), m.version.c_str());
#endif
            end_card();
            ImGui::EndTabItem();
        }

        // 每个 Mod 一个标签页
        std::vector<std::pair<std::string, PanelFn>> snapshot;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            snapshot = g_panels;
        }
        for (auto& [name, fn] : snapshot) {
            if (ImGui::BeginTabItem(name.c_str())) {
                if (fn) { try { fn(); } catch (...) { ImGui::TextDisabled("面板出错"); } }
                ImGui::EndTabItem();
            }
        }
        ImGui::EndTabBar();
    }
}

void draw_placeholder(const char* what) {
    begin_card("##card_todo", what);
    ImGui::TextDisabled("这一组还没做（属于 C 档：图标生成器 / ESP）。");
    ImGui::TextDisabled("A+B 档的框架和开关类功能已经就位。");
    end_card();
}

void draw_settings_page() {
    if (ImGui::BeginTabBar("##set_tabs")) {
        if (ImGui::BeginTabItem("界面")) {
            begin_card("##card_ui", "界面");
            ImGui::SliderFloat("整体 UI 缩放", &g_ui_scale, 0.7f, 1.6f, "%.2fx");
            ImGui::TextDisabled("缩放整个界面的字体与控件尺寸");
            ImGui::Checkbox("显示热键 UI（DevTools）", &g_script_enabled);
            end_card();
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("安全")) {
            begin_card("##card_safe", "安全");
            static bool norec = false;
            ImGui::Checkbox("防录屏（隐藏屏幕捕获）", &norec);
            ImGui::TextDisabled("（该项需要在渲染层实现，暂为占位）");
            end_card();
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("脚本")) {
            begin_card("##card_setscript", "脚本");
            ImGui::Checkbox("启用脚本功能", &g_script_enabled);
            end_card();
            ImGui::EndTabItem();
        }
        ImGui::EndTabBar();
    }
}

void draw_content() {
    switch (g_page) {
        case 0:
#ifndef MODMENU_PREVIEW
            if (ImGui::BeginTabBar("##main_tabs")) {
                if (ImGui::BeginTabItem("玩家作弊")) {
                    begin_card("##card_cheat", "玩家作弊");
                    cheat::draw_tab();
                    end_card();
                    ImGui::EndTabItem();
                }
                if (ImGui::BeginTabItem("自动钓鱼")) { draw_placeholder("自动钓鱼"); ImGui::EndTabItem(); }
                if (ImGui::BeginTabItem("Buff 生成")) { draw_placeholder("Buff 生成"); ImGui::EndTabItem(); }
                ImGui::EndTabBar();
            }
#else
            draw_placeholder("玩家作弊（预览模式）");
#endif
            break;
        case 1: draw_placeholder("世界"); break;
        case 2: draw_placeholder("实体"); break;
        case 3: draw_placeholder("物品"); break;
        case 4: draw_placeholder("杂项"); break;
        case 5: draw_placeholder("网络"); break;
        case 6: draw_settings_page(); break;
        case 7: case 8: draw_placeholder("视觉 / ESP / HUD"); break;
        case 10: draw_console_page(); break;
        case 11: draw_script_page(); break;
        default: draw_placeholder("未实现"); break;
    }
}

void draw_header_bar() {
    const float fh = ImGui::GetFrameHeight();
    ImGui::PushStyleColor(ImGuiCol_Text, kPurple);
    ImGui::TextUnformatted("Terraria Mod Menu");
    ImGui::PopStyleColor();
    if (ImGui::IsItemActive() && ImGui::IsMouseDragging(0)) {
        ImVec2 d = ImGui::GetIO().MouseDelta;
        ImVec2 p = ImGui::GetWindowPos();
        ImGui::SetWindowPos(ImVec2(p.x + d.x, p.y + d.y));
    }
    // FPS（右上角偏左）
    char fps[32];
    snprintf(fps, sizeof(fps), "%.0f FPS", ImGui::GetIO().Framerate);
    float fw = ImGui::CalcTextSize(fps).x;
    float bx = ImGui::GetWindowWidth() - ImGui::GetStyle().WindowPadding.x - fh * 0.85f - fw - 24;
    ImGui::SameLine(bx > ImGui::GetCursorPosX() ? bx : ImGui::GetCursorPosX());
    ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.6f, 1.0f), "%s", fps);
    // ✕
    float x = ImGui::GetWindowWidth() - ImGui::GetStyle().WindowPadding.x - fh * 0.85f;
    if (x > ImGui::GetCursorPosX()) {
        ImGui::SameLine(x);
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.55f, 0.14f, 0.30f, 0.9f));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.85f, 0.22f, 0.42f, 1.0f));
        if (ImGui::Button("×", ImVec2(fh * 0.85f, fh * 0.85f))) set_visible(false);
        ImGui::PopStyleColor(2);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("收起成悬浮球");
    }
    ImGui::Separator();
}

void draw_footer_bar() {
    ImGui::Separator();
    ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.6f, 1.0f), "● 已连接");
    ImGui::SameLine(); ImGui::TextDisabled("· 覆盖层运行中");
}

}  // namespace

bool visible() { std::lock_guard<std::mutex> lock(g_mutex); return g_visible; }
void set_visible(bool v) { std::lock_guard<std::mutex> lock(g_mutex); g_visible = v; }
void toggle() { std::lock_guard<std::mutex> lock(g_mutex); g_visible = !g_visible; }

void log_line(const std::string& text) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_log.push_back(text);
    if (g_log.size() > 2000) g_log.pop_front();
}
void add_panel(const std::string& name, PanelFn fn) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_panels.emplace_back(name, std::move(fn));
}
void clear_panels(const std::string& name) {
    std::lock_guard<std::mutex> lock(g_mutex);
    for (auto it = g_panels.begin(); it != g_panels.end();) {
        if (it->first == name) it = g_panels.erase(it); else ++it;
    }
}
void set_ball_texture(void* tex) { std::lock_guard<std::mutex> lock(g_mutex); g_ball_tex = tex; }

void bounds(float* x, float* y, float* w, float* h) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_visible) { *x = g_ball_pos.x; *y = g_ball_pos.y; *w = kBallSize; *h = kBallSize; return; }
    *x = g_win_pos.x; *y = g_win_pos.y; *w = g_win_size.x; *h = g_win_size.y;
}

void draw() {
    if (!visible()) {
        // ---- 收起状态：圆球 ----
        ImGui::SetNextWindowPos(g_ball_pos, ImGuiCond_Always);
        ImGui::SetNextWindowSize(ImVec2(kBallSize, kBallSize), ImGuiCond_Always);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
        ImGui::Begin("##mm_ball", nullptr,
                     ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                     ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoMove |
                     ImGuiWindowFlags_NoBackground | ImGuiWindowFlags_NoSavedSettings |
                     ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoNav);
        if (g_ball_tex) {
            ImVec2 p = ImGui::GetCursorScreenPos();
            ImGui::InvisibleButton("##ball", ImVec2(kBallSize, kBallSize));
            ImGui::GetWindowDrawList()->AddImage(
                (ImTextureID)g_ball_tex, p, ImVec2(p.x + kBallSize, p.y + kBallSize),
                ImVec2(0, 0), ImVec2(1, 1), IM_COL32(255, 255, 255, 255));
        } else {
            ImGui::Button("M", ImVec2(kBallSize, kBallSize));
        }
        if (ImGui::IsItemActivated()) g_ball_drag = ImVec2(0, 0);
        if (ImGui::IsItemActive() && ImGui::IsMouseDragging(0)) {
            ImVec2 d = ImGui::GetIO().MouseDelta;
            g_ball_pos.x += d.x; g_ball_pos.y += d.y;
            g_ball_drag.x += fabsf(d.x); g_ball_drag.y += fabsf(d.y);
            ImVec2 disp = ImGui::GetIO().DisplaySize;
            if (g_ball_pos.x < 0) g_ball_pos.x = 0;
            if (g_ball_pos.y < 0) g_ball_pos.y = 0;
            if (g_ball_pos.x > disp.x - kBallSize) g_ball_pos.x = disp.x - kBallSize;
            if (g_ball_pos.y > disp.y - kBallSize) g_ball_pos.y = disp.y - kBallSize;
        }
        if (ImGui::IsItemDeactivated() && g_ball_drag.x < 16.0f && g_ball_drag.y < 16.0f)
            set_visible(true);
        ImGui::End();
        ImGui::PopStyleVar();
        return;
    }

    // ---- 展开状态 ----
    apply_theme();
    ImGui::GetIO().FontGlobalScale = g_ui_scale;
    ImGui::SetNextWindowSize(ImVec2(980, 700), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(40, 120), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSizeConstraints(ImVec2(560, 380), ImVec2(FLT_MAX, FLT_MAX));
    if (!ImGui::Begin("Terraria Mod Menu", nullptr,
                      ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoTitleBar)) {
        ImGui::End();
        return;
    }

    draw_header_bar();

    // 侧边栏 + 内容区
    const float nav_w = ImGui::GetFontSize() * 8.0f;
    draw_sidebar(nav_w);
    ImGui::SameLine();
    ImGui::BeginChild("##content", ImVec2(0, -ImGui::GetFrameHeightWithSpacing() - 6), false);
    draw_content();
    ImGui::EndChild();

    draw_footer_bar();

    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_win_pos = ImGui::GetWindowPos();
        g_win_size = ImGui::GetWindowSize();
    }
    ImGui::End();
}

}  // namespace ui
