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

// 当前 UI 实际占用的矩形（像素坐标）—— 渲染层只覆盖这一块，避免全屏开销
void bounds(float* x, float* y, float* w, float* h);

// 用户在「设置 → 界面」里调的整体缩放（渲染层在 NewFrame 之前应用）
float ui_scale();

// 防录屏：检测到录屏/投屏时要不要把界面藏起来（默认开，设置里可关）
bool hide_on_capture();
void set_hide_on_capture(bool v);

// 把插件日志 POST 到电脑上的小站（真机专用，用来远程看日志）。
// 结果会写回日志本身，所以下一次上传就能看到上一次的成败。
void upload_log_to(const char* url);

// 往控制台日志里追加一行（线程安全）
void log_line(const std::string& text);

// 注册一个面板（每个 Mod 一个 Tab）。阶段 3 的 Mod 加载器会调用它。
using PanelFn = std::function<void()>;
void add_panel(const std::string& name, PanelFn fn);
void clear_panels(const std::string& name);

// 实际绘制一帧（由 imgui_host 调用）
void draw();

}  // namespace ui
