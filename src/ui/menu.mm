//
// 菜单界面：悬浮球 + 主面板。
//
// 面板布局对齐安卓版那套：
//   ┌──────────────────────────────────────────┐
//   │ [◆] Terraria Mod Menu        ●60FPS  [×] │  标题栏
//   ├────────┬─────────────────────────────────┤
//   │ 自身 ● │  自身                            │
//   │ 世界   │  卡片 / 开关 / 滑条               │  左侧导航 + 内容
//   │ 物品   │                                  │
//   ├────────┴─────────────────────────────────┤
//   │ ● 已连接 · 覆盖层运行中                     │  底部状态栏
//   └──────────────────────────────────────────┘
//
// 渲染由 imgui_host（真机）/ preview 的宿主（Mac）负责，这里只管画什么。
//
#include "menu.hpp"

#include <cmath>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "imgui.h"

#ifdef MODMENU_PREVIEW
// 桌面预览模式：数据和日志都换成假的，不依赖 iOS 的 Foundation / IL2CPP
#include "preview_stubs.hpp"
#else
#include "../il2cpp_api.hpp"
#include "../mm_log.hpp"
#include "../mods/mod_loader.hpp"
#endif

#include "cheat.hpp"
#include "cheat_state.hpp"
#include "widgets.hpp"

namespace ui {
namespace {

std::mutex g_mutex;
bool g_visible = true;
void* g_ball_tex = nullptr;
ImVec2 g_ball_pos(60, 200);          // 球的位置（可拖动）
ImVec2 g_ball_drag(0, 0);            // 本次按住累计移动量（用来区分"点"和"拖"）
constexpr float kBallSize = 108.0f;  // 球的显示尺寸（像素）
std::deque<std::string> g_log;
ImVec2 g_win_pos(0, 0);
ImVec2 g_win_size(0, 0);
std::vector<std::pair<std::string, PanelFn>> g_panels;
char g_filter[128] = "";
bool g_auto_scroll = true;
float g_ui_scale = 1.0f;
bool g_hide_on_capture = true;       // 检测到录屏时隐藏界面（设置里可关）

int g_page = 0;                      // 左侧导航当前页

// ---- 左侧导航 --------------------------------------------------------------
constexpr int kNavCount = 9;
const char* const kNav[kNavCount] = {
    "自身", "世界", "实体", "物品", "多选", "网络", "日志", "脚本", "设置",
};

// ---------------------------------------------------------------------------
// 各个页面
// ---------------------------------------------------------------------------

void draw_log_page() {
    theme::section_header("日志", "实时输出");
    ImGui::Spacing();

    ImGui::SetNextItemWidth(-160);
    ImGui::InputTextWithHint("##filter", "过滤…", g_filter, sizeof(g_filter));
    ImGui::SameLine();
    ImGui::Checkbox("自动滚动", &g_auto_scroll);
    ImGui::SameLine();
    if (ImGui::Button("清空")) {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_log.clear();
    }

    ImGui::PushStyleColor(ImGuiCol_ChildBg, theme::card_bg());
    ImGui::PushStyleColor(ImGuiCol_Border, theme::card_edge());
    ImGui::BeginChild("##log", ImVec2(0, 0), ImGuiChildFlags_Border);
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
    ImGui::PopStyleColor(2);
}

void draw_mods_page() {
    theme::section_header("脚本", "Lua Mod 管理");
    ImGui::Spacing();

    static bool enable_scripts = true;
    if (theme::begin_card("##scripts", "脚本功能", 2)) {
        theme::toggle_row("启用脚本功能", &enable_scripts, nullptr);
        theme::text_dim("Mod 目录：%s", mods::root_dir().c_str());
    }
    theme::end_card();
    ImGui::Spacing();

    if (ImGui::Button("重新扫描")) mods::reload();
    ImGui::SameLine();
    ImGui::TextDisabled("共 %zu 个", mods::list().size());

    ImGui::PushStyleColor(ImGuiCol_ChildBg, theme::card_bg());
    ImGui::PushStyleColor(ImGuiCol_Border, theme::card_edge());
    ImGui::BeginChild("##mods", ImVec2(0, 0), ImGuiChildFlags_Border);
    for (const auto& m : mods::list()) {
        ImGui::PushStyleColor(ImGuiCol_Text, m.loaded ? theme::ok_green() : theme::danger());
        ImGui::TextUnformatted("●");
        ImGui::PopStyleColor();
        ImGui::SameLine();
        ImGui::Text("%s v%s by %s", m.name.c_str(), m.version.c_str(), m.author.c_str());
        if (!m.description.empty()) {
            ImGui::Indent(20);
            theme::text_wrapped_dim(m.description.c_str());
            ImGui::Unindent(20);
        }
        if (!m.loaded && !m.error.empty()) {
            ImGui::Indent(20);
            ImGui::PushStyleColor(ImGuiCol_Text, theme::danger());
            ImGui::Text("加载失败：%s", m.error.c_str());
            ImGui::PopStyleColor();
            ImGui::Unindent(20);
        }
    }
    ImGui::EndChild();
    ImGui::PopStyleColor(2);
}

void draw_settings_page() {
    theme::section_header("设置", "界面与状态");
    ImGui::Spacing();

    if (theme::begin_card("##ui", "界面", 3)) {
        theme::slider_row("整体缩放", &g_ui_scale, 0.7f, 1.8f, "%.2fx");
        theme::toggle_row("录屏时隐藏界面", &g_hide_on_capture, "自动藏起来");
    }
    theme::end_card();
    ImGui::Spacing();

    if (theme::begin_card("##status", "状态", 2)) {
#ifdef MODMENU_PREVIEW
        theme::text_dim("预览模式：数据是假的，只用来调界面");
        static bool stub_ok = true;
        theme::toggle_row("IL2CPP 按名解析", &stub_ok, "就绪");
#else
        const bool ok = il2::ready();
        ImGui::PushStyleColor(ImGuiCol_Text, ok ? theme::ok_green() : theme::danger());
        ImGui::Text("%s IL2CPP 按名解析", ok ? "●" : "●");
        ImGui::PopStyleColor();
        ImGui::SameLine();
        ImGui::Text("已解析符号 %d 个", il2::symbol_count());
        const char* missing = il2::last_missing();
        if (missing && *missing) theme::text_dim("最后未解析：%s", missing);
#endif
    }
    theme::end_card();
}

void draw_placeholder(const char* title, const char* note) {
    theme::section_header(title, "开发中");
    ImGui::Spacing();
    if (theme::begin_card("##todo", nullptr, 3)) {
        theme::text_wrapped_dim(note);
    }
    theme::end_card();
}

// 修改器那几页在主菜单里没意义：读不到玩家/世界数据
void draw_need_world(const char* page_name) {
    theme::section_header(page_name, "修改器");
    ImGui::Spacing();
    if (theme::begin_card("##needworld", nullptr, 3)) {
        ImGui::PushStyleColor(ImGuiCol_Text, theme::accent());
        ImGui::TextUnformatted("进入地图后才能使用");
        ImGui::PopStyleColor();
        theme::text_wrapped_dim(
            "这一页是直接读写游戏里的玩家/世界数据的，主菜单里还没有这些东西。\n"
            "读档进地图之后回到这里，控制项就会出现。");
    }
    theme::end_card();
}

// ---- 标题栏 ----------------------------------------------------------------
void draw_header() {
    const float bs = ImGui::GetFrameHeight() * 0.92f;

    // 左边那个方块图标
    {
        const ImVec2 p = ImGui::GetCursorScreenPos();
        ImDrawList* dl = ImGui::GetWindowDrawList();
        dl->AddRectFilled(p, ImVec2(p.x + bs, p.y + bs), IM_COL32(122, 92, 240, 255), 6.0f);
        const char* up = "^";
        const ImVec2 ts = ImGui::CalcTextSize(up);
        dl->AddText(ImVec2(p.x + (bs - ts.x) * 0.5f, p.y + (bs - ts.y) * 0.5f),
                    IM_COL32(255, 255, 255, 255), up);
        ImGui::Dummy(ImVec2(bs, bs));
    }

    ImGui::SameLine();
    ImGui::AlignTextToFramePadding();
    ImGui::PushStyleColor(ImGuiCol_Text, theme::text());
    ImGui::TextUnformatted("Terraria Mod Menu");
    ImGui::PopStyleColor();

    // 右边：FPS + 关闭
    {
        char fps[32];
        snprintf(fps, sizeof(fps), "%.0f FPS", ImGui::GetIO().Framerate);
        const float fps_w = ImGui::CalcTextSize(fps).x + ImGui::GetFrameHeight() * 0.9f;
        const float x = ImGui::GetWindowWidth() - ImGui::GetStyle().WindowPadding.x
                        - (bs * 1.6f) - fps_w;
        if (x > ImGui::GetCursorPosX()) ImGui::SameLine(x);
        else ImGui::SameLine();
        ImGui::AlignTextToFramePadding();
        ImGui::PushStyleColor(ImGuiCol_Text, ImGui::GetIO().Framerate > 50.0f
                                                 ? theme::ok_green() : theme::text_dim());
        ImGui::Text("%s", fps);
        ImGui::PopStyleColor();

        ImGui::SameLine();
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0, 0, 0, 0));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, theme::danger());
        ImGui::PushStyleColor(ImGuiCol_ButtonActive, theme::danger());
        if (ImGui::Button("×##close", ImVec2(bs, bs))) set_visible(false);
        ImGui::PopStyleColor(3);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("收起成悬浮球");
    }
}

}  // namespace

bool visible() { return g_visible; }

void set_visible(bool v) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_visible = v;
}

void toggle() { set_visible(!visible()); }

void log_line(const std::string& text) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_log.push_back(text);
    while (g_log.size() > 2000) g_log.pop_front();
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

void set_ball_texture(void* tex) { g_ball_tex = tex; }

float ui_scale() { return g_ui_scale; }

bool hide_on_capture() { return g_hide_on_capture; }
void set_hide_on_capture(bool v) { g_hide_on_capture = v; }

void bounds(float* x, float* y, float* w, float* h) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_visible) {
        *x = g_ball_pos.x; *y = g_ball_pos.y;
        *w = kBallSize;    *h = kBallSize;
        return;
    }
    *x = g_win_pos.x; *y = g_win_pos.y; *w = g_win_size.x; *h = g_win_size.y;
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

        if (g_ball_tex) {
            // 不要用 ImageButton：ImGui 会先画一个按钮底色框，看起来就是方块。
            // 这里只画图片本身（带 alpha），点击区用 InvisibleButton 拿。
            ImVec2 p = ImGui::GetCursorScreenPos();
            ImGui::InvisibleButton("##ball", ImVec2(kBallSize, kBallSize));
            ImGui::GetWindowDrawList()->AddImage(
                (ImTextureID)g_ball_tex, p,
                ImVec2(p.x + kBallSize, p.y + kBallSize),
                ImVec2(0, 0), ImVec2(1, 1), IM_COL32(255, 255, 255, 255));
        } else {
            ImGui::Button("M", ImVec2(kBallSize, kBallSize));
        }

        // 关键：区分"点一下"和"拖一下"。
        // 原来在按下时就展开，导致一拖就弹窗；现在改成**松手时且几乎没移动**才算点击。
        if (ImGui::IsItemActivated()) {
            g_ball_drag = ImVec2(0, 0);
        }
        if (ImGui::IsItemActive() && ImGui::IsMouseDragging(0)) {
            ImVec2 d = ImGui::GetIO().MouseDelta;
            g_ball_pos.x += d.x;
            g_ball_pos.y += d.y;
            g_ball_drag.x += fabsf(d.x);
            g_ball_drag.y += fabsf(d.y);
            ImVec2 disp = ImGui::GetIO().DisplaySize;
            if (g_ball_pos.x < 0) g_ball_pos.x = 0;
            if (g_ball_pos.y < 0) g_ball_pos.y = 0;
            if (g_ball_pos.x > disp.x - kBallSize) g_ball_pos.x = disp.x - kBallSize;
            if (g_ball_pos.y > disp.y - kBallSize) g_ball_pos.y = disp.y - kBallSize;
        }
        // 松手了，而且几乎没拖动 -> 才算"点击"。
        // 阈值按球的尺寸算：原来写死 16px，在 3x 屏上只有 5pt，
        // 手指稍微抖一下就点不开。改成球径的 30%（真机约 10pt），
        // 滑动仍然完全不会误展开。
        const float tap_slop = kBallSize * 0.30f;
        if (ImGui::IsItemDeactivated() && g_ball_drag.x < tap_slop && g_ball_drag.y < tap_slop) {
            set_visible(true);
        }

        ImGui::End();
        ImGui::PopStyleVar();
        return;
    }

    // ---- 展开状态：主面板 ----
    theme::push_all();

    // 尺寸跟着屏幕走：游戏是横屏（iPhone 上约 2622×1206 物理像素），
    // 面板写死尺寸的话在横屏里会小得没法用。
    {
        const ImVec2 disp = ImGui::GetIO().DisplaySize;
        const float w = fminf(disp.x * 0.66f, 1560.0f);
        const float h = fminf(disp.y * 0.80f, 900.0f);
        ImGui::SetNextWindowSize(ImVec2(w, h), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowPos(ImVec2((disp.x - w) * 0.5f, (disp.y - h) * 0.5f),
                                ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSizeConstraints(ImVec2(fminf(disp.x * 0.5f, 620.0f), 380.0f),
                                            ImVec2(disp.x, disp.y));
    }
    if (!ImGui::Begin("Terraria Mod Menu", nullptr,
                      ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoTitleBar)) {
        ImGui::End();
        theme::pop_all();
        return;
    }

    draw_header();
    ImGui::Separator();

    // 中间：左边导航 + 右边内容
    const float footer_h = ImGui::GetFrameHeightWithSpacing() + 4.0f;
    const float mid_h = ImGui::GetContentRegionAvail().y - footer_h;

    ImGui::PushStyleColor(ImGuiCol_ChildBg, theme::sidebar_bg());
    ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding, 8.0f);
    // 侧栏宽度跟着字号走（真机字号是预览器的两倍多）
    const float nav_w = ImGui::GetFontSize() * 5.6f;
    ImGui::BeginChild("##nav", ImVec2(nav_w, mid_h), ImGuiChildFlags_Border);
    {
        ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(4, 4));
        for (int i = 0; i < kNavCount; ++i) {
            if (theme::nav_item(kNav[i], g_page == i)) g_page = i;
        }
        ImGui::PopStyleVar();
    }
    ImGui::EndChild();
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();

    ImGui::SameLine();
    ImGui::BeginChild("##content", ImVec2(0, mid_h), ImGuiChildFlags_None);
    {
        // 「修改器」那几页（自身/世界/实体/物品）**要进了地图才有意义** ——
        // 主菜单里读不到玩家和世界数据，先给个提示。
        // 其余页面（多选/网络/日志/脚本/设置）进游戏就能用。
        if (g_page <= 3 && !cheat::in_world()) {
            draw_need_world(kNav[g_page]);
        } else switch (g_page) {
            case 0: cheat::draw_self_page(); break;
            case 1: cheat::draw_world_page(); break;
            case 2: cheat::draw_entity_page(); break;
            case 3: cheat::draw_item_page(); break;
            case 4: draw_placeholder("多选", "批量操作（多人模式）。");
                    break;
            case 5: draw_placeholder("网络", "抓包：hook NetMessage 收发。属于 B 档。"); break;
            case 6: draw_log_page(); break;
            case 7: draw_mods_page(); break;
            default: draw_settings_page(); break;
        }
    }
    ImGui::EndChild();

    // 底部状态栏
    ImGui::Separator();
    ImGui::PushStyleColor(ImGuiCol_Text, theme::ok_green());
    ImGui::TextUnformatted("●");
    ImGui::PopStyleColor();
    ImGui::SameLine();
    theme::text_dim("已连接 · 覆盖层运行中");

    ImGui::End();

    // 记下这一帧窗口实际占用的位置和大小，给渲染层缩范围用
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_win_pos = ImGui::GetWindowPos();
        g_win_size = ImGui::GetWindowSize();
    }

    theme::pop_all();
}

}  // namespace ui
