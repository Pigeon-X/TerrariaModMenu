#pragma once
//
// 内置修改器（不依赖 Lua）
// 全部靠「按名反射」读写 Terraria 的字段实现，字段名已离线核对过。
//
namespace cheat {

// 解析类/字段（幂等）。返回当前是否可用（IL2CPP 就绪 + 关键类找到了）
bool init();

// 每帧应用一次已开启的功能（由渲染层调用，菜单收起时也生效）
void tick();

// 是否有任何功能开着（开着就让渲染层保持满帧）
bool active();

// 画「修改器」标签页
void draw_tab();

// 配置持久化（C 档）
void load_state();

}  // namespace cheat
