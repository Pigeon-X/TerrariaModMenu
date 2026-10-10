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

namespace ui {
namespace {

std::mutex g_mutex;
bool g_visible = true;
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

void draw() {
    if (!visible()) {
        // 隐藏时留一个小圆钮，点一下重新打开
        ImGui::SetNextWindowPos(ImVec2(12, 220), ImGuiCond_Always);
        ImGui::SetNextWindowSize(ImVec2(52, 52), ImGuiCond_Always);
        ImGui::Begin("##mm_toggle", nullptr,
                     ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                     ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoMove |
                     ImGuiWindowFlags_NoSavedSettings |
                     ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoNav);
        if (ImGui::Button("M", ImVec2(36, 36))) set_visible(true);
        ImGui::End();
        return;
    }

    ImGui::SetNextWindowSize(ImVec2(560, 420), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(60, 120), ImGuiCond_FirstUseEver);
    if (!ImGui::Begin("Terraria ModMenu", nullptr,
                      ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_MenuBar)) {
        ImGui::End();
        return;
    }

    if (ImGui::BeginMenuBar()) {
        if (ImGui::BeginMenu("菜单")) {
            if (ImGui::MenuItem("隐藏", "三指双击")) set_visible(false);
            ImGui::EndMenu();
        }
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
