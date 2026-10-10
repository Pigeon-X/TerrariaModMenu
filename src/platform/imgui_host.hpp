#pragma once
//
// ImGui 渲染宿主：在 Unity 的 Metal 渲染循环里叠一层界面。
//
// 思路：勾住 Metal 命令缓冲的 -presentDrawable:，在“马上就要上屏”的那一刻，
// 往同一个命令缓冲里再开一个 render pass（loadAction = Load，保留游戏画面），
// 把 ImGui 画上去，然后才调用原来的 presentDrawable。
//
namespace host {

// 安装钩子并开始渲染。幂等；需要等 IL2CPP 就绪、且在主线程调用。
bool start();

// ImGui 是否已经真正初始化（渲染过一次）
bool ready();

}  // namespace host
