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

// 是否已经进入地图（世界里）。主菜单里返回 false —— 渲染层据此决定
// 悬浮球要不要显示（没进地图就完全不显示）。
bool in_world();

// 画「修改器」标签页
void draw_tab();

// 修改器的分页（新版界面按安卓那套拆成左侧导航的几页）
void draw_self_page();     // 自身：玩家状态 / 战斗 / 移动
void draw_world_page();    // 世界：时间 / 事件

// 配置持久化（C 档）
void load_state();

// A 档：物品生成器（搜索 + 点击放入背包）
void draw_item_page();

// 直接给物品（放进背包第一个空槽）
void give_item(int id, int count);

}  // namespace cheat
