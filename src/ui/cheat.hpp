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
void draw_entity_page();   // 实体：NPC 列表 / 生成 / 秒杀

// ---- 实体（NPC）后端 -------------------------------------------------------
// 统计存活 NPC：alive = 总数，hostile = 敌对数量（friendly == false）
int  npc_stats(int* alive, int* hostile);
// 秒杀掉所有 NPC（hostile_only = 只杀敌对）。返回处理了几个
int  kill_npcs(bool hostile_only);
// 在玩家附近生成 count 个 type 号 NPC。返回成功几个
int  spawn_npc(int type, int count);

// ---- 动作类（点一下就生效，不是开关）--------------------------------------
// 把生命和魔力补满
void heal_full();
// 设置世界时间：0=清晨 1=正午 2=黄昏 3=午夜（会连 dayTime 一起设，时钟才对）
void set_world_time(int preset);
// 读当前游戏内时刻，返回 0..24 的小时（拿不到返回 -1）
double world_time_of_day();

// 读玩家当前数值（生命/魔力/防御）。拿不到就把它们置 0。
// 界面用它做**实时显示** —— 开了开关能当场看见数字变化，就知道生效没有。
void player_stats(int* life, int* life_max, int* mana, int* mana_max, int* defense);

// 传送到世界出生点。返回是否成功
bool teleport_to_spawn();

// 配置持久化（C 档）
void load_state();

// A 档：物品生成器（搜索 + 点击放入背包）
void draw_item_page();

// 直接给物品（放进背包第一个空槽）
void give_item(int id, int count);

}  // namespace cheat
