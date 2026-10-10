//
// 菜单界面：一个悬浮窗 + 控制台日志 + 若干 Mod 面板 Tab。
//
#include "menu.hpp"

#include <deque>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "imgui.h"

#include "../il2cpp_api.hpp"
#include "../mm_log.hpp"
#include "../mods/mod_loader.hpp"

namespace ui {
namespace {

std::mutex g_mutex;
bool g_visible = true;
void* g_ball_tex = nullptr;
ImVec2 g_ball_pos(60, 200);          // 球的位置（可拖动）
constexpr float kBallSize = 150.0f;  // 球的显示尺寸（像素）
std::deque<std::string> g_log;
std::vector<std::pair<std::string, PanelFn>> g_panels;
char g_filter[128] = "";
bool g_auto_scroll = true;

void draw_log_tab() {
    ImGui::InputTextWithHint("##filter", "过滤…", g_filter, sizeof(g_filter));
    ImGui::SameLine();
    ImGui::Checkbox("自动滚动", &g_auto_scroll);
    ImGui::Separator();

    ImGui::BeginChild("##log", ImVec2(0, -ImGui::GetFrameHeightWithSpacing()));
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        for (const auto& line : g_log) {
            if (g_filter[0] && line.find(g_filter) == std::string::npos) continue;
            ImGui::TextUnformatted(line.c_str());
        }
        if (g_auto_scroll && ImGui::GetScrollY() >= ImGui::GetScrollMaxY() - 1.0f) {
            ImGui::SetScrollHereY(1.0f);
        }
    }
    ImGui::EndChild();
}

void draw_status_tab() {
    ImGui::Text("IL2CPP 按名解析：%s", il2::ready() ? "就绪" : "未就绪");
    ImGui::Text("已解析符号：%d", il2::symbol_count());
    const char* missing = il2::last_missing();
    if (missing && *missing) {
        ImGui::TextWrapped("最后未解析的符号：%s", missing);
    }
    ImGui::Separator();
    ImGui::TextWrapped("Mods 目录：Documents/Mods/");
    ImGui::TextWrapped("日志文件：Documents/TerrariaModMenu.log");
}

void draw_mods_tab() {
    const auto& list = mods::list();
    ImGui::Text("Mods 目录：%s", mods::root_dir().c_str());
    if (ImGui::Button("重新扫描")) mods::reload();
    ImGui::Separator();

    if (list.empty()) {
        ImGui::TextWrapped(
            "还没有 Mod。\n"
            "往 Documents/Mods/<任意名字>/ 里放 main.lua（可选 mod.json），"
            "然后点上面的「重新扫描」，或者重启游戏。");
        return;
    }

    for (const auto& m : list) {
        ImGui::PushID(m.name.c_str());
        if (m.loaded) ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.4f, 1.0f), "● %s", m.name.c_str());
        else ImGui::TextColored(ImVec4(1.0f, 0.5f, 0.4f, 1.0f), "● %s", m.name.c_str());
        ImGui::SameLine();
        if (!m.version.empty()) { ImGui::TextDisabled("v%s", m.version.c_str()); ImGui::SameLine(); }
        if (!m.author.empty()) ImGui::TextDisabled("by %s", m.author.c_str());

        if (!m.description.empty()) ImGui::TextWrapped("   %s", m.description.c_str());
        if (!m.loaded && !m.error.empty()) {
            ImGui::TextColored(ImVec4(1.0f, 0.4f, 0.4f, 1.0f), "   加载失败：%s", m.error.c_str());
        }
        ImGui::PopID();
    }
}

}  // namespace

bool visible() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_visible;
}

void set_visible(bool v) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_visible = v;
}

void toggle() {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_visible = !g_visible;
}

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
        if (it->first == name) it = g_panels.erase(it);
        else ++it;
    }
}

void set_ball_texture(void* tex) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_ball_tex = tex;
}

void draw() {
    if (!visible()) {
        // ---- 收起状态：一个圆球，点一下展开，按住可以拖 ----
        ImGui::SetNextWindowPos(g_ball_pos, ImGuiCond_Always);
        ImGui::SetNextWindowSize(ImVec2(kBallSize, kBallSize), ImGuiCond_Always);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
        ImGui::Begin("##mm_ball", nullptr,
                     ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                     ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoMove |
                     ImGuiWindowFlags_NoBackground | ImGuiWindowFlags_NoSavedSettings |
                     ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoNav);

        bool clicked = false;
        if (g_ball_tex) {
            clicked = ImGui::ImageButton("##ball", (ImTextureID)g_ball_tex,
                                         ImVec2(kBallSize, kBallSize),
                                         ImVec2(0, 0), ImVec2(1, 1),
                                         ImVec4(0, 0, 0, 0), ImVec4(1, 1, 1, 1));
        } else {
            clicked = ImGui::Button("M", ImVec2(kBallSize, kBallSize));
        }
        // 拖动球体（把鼠标位移累加到位置）
        if (ImGui::IsItemActive() && ImGui::IsMouseDragging(0)) {
            ImVec2 d = ImGui::GetIO().MouseDelta;
            g_ball_pos.x += d.x;
            g_ball_pos.y += d.y;
            ImVec2 disp = ImGui::GetIO().DisplaySize;
            if (g_ball_pos.x < 0) g_ball_pos.x = 0;
            if (g_ball_pos.y < 0) g_ball_pos.y = 0;
            if (g_ball_pos.x > disp.x - kBallSize) g_ball_pos.x = disp.x - kBallSize;
            if (g_ball_pos.y > disp.y - kBallSize) g_ball_pos.y = disp.y - kBallSize;
        }
        if (clicked) set_visible(true);

        ImGui::End();
        ImGui::PopStyleVar();
        return;
    }

    ImGui::SetNextWindowSize(ImVec2(980, 700), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(60, 140), ImGuiCond_FirstUseEver);
    // 可缩放：给个下限，避免拖没了
    ImGui::SetNextWindowSizeConstraints(ImVec2(560, 380), ImVec2(FLT_MAX, FLT_MAX));
    if (!ImGui::Begin("Terraria ModMenu", nullptr,
                      ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_MenuBar)) {
        ImGui::End();
        return;
    }

    if (ImGui::BeginMenuBar()) {
        if (ImGui::BeginMenu("菜单")) {
            if (ImGui::MenuItem("收起成球")) set_visible(false);
            ImGui::EndMenu();
        }
        // 右对齐的 ❌：收起回球状态
        float btn_w = ImGui::CalcTextSize("✕ 收起").x + ImGui::GetStyle().FramePadding.x * 2;
        ImGui::SameLine(ImGui::GetWindowWidth() - btn_w - 12.0f);
        if (ImGui::Button("✕ 收起")) set_visible(false);
        ImGui::EndMenuBar();
    }

    if (ImGui::BeginTabBar("##tabs")) {
        if (ImGui::BeginTabItem("日志")) {
            draw_log_tab();
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("状态")) {
            draw_status_tab();
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("Mods")) {
            draw_mods_tab();
            ImGui::EndTabItem();
        }

        // Mod 面板
        std::vector<std::pair<std::string, PanelFn>> snapshot;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            snapshot = g_panels;
        }
        for (auto& [name, fn] : snapshot) {
            if (ImGui::BeginTabItem(name.c_str())) {
                if (fn) {
                    // 面板内部出错不能把整帧带崩
                    try { fn(); } catch (...) { ImGui::TextDisabled("面板出错"); }
                } else {
                    ImGui::TextDisabled("（空面板）");
                }
                ImGui::EndTabItem();
            }
        }
        ImGui::EndTabBar();
    }

    ImGui::End();
}

}  // namespace ui
