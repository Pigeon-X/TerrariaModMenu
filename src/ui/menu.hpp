#pragma once
//
// 菜单内容。渲染由 imgui_host 负责，这里只管“画面里画什么”。
//
#include <functional>
#include <string>
#include <vector>

namespace ui {

// 菜单整体是否可见
bool visible();
void set_visible(bool v);
void toggle();

// 球形图标纹理（ImTextureID，由 imgui_host 创建后塞进来）
void set_ball_texture(void* tex);

// 往控制台日志里追加一行（线程安全）
void log_line(const std::string& text);

// 注册一个面板（每个 Mod 一个 Tab）。阶段 3 的 Mod 加载器会调用它。
using PanelFn = std::function<void()>;
void add_panel(const std::string& name, PanelFn fn);
void clear_panels(const std::string& name);

// 实际绘制一帧（由 imgui_host 调用）
void draw();

}  // namespace ui
