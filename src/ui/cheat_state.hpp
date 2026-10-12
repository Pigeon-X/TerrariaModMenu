#pragma once
//
// 修改器的「开关状态」单独放这里，理由：
//   界面（cheat_ui.mm）要在**预览器和真机两边都编译**，
//   而读写游戏字段那部分（cheat.mm）只能真机编译（要 IL2CPP）。
//   两边共用同一份状态，预览器里看到的界面就是真机那一份。
//
// C++17 的 inline 变量：头文件里直接定义，不用再写 .cpp。
//
namespace cheat {

// ---- 自身 ------------------------------------------------------------------
inline bool c_god = false;          // 无敌（免疫 + 生命拉满）
inline bool c_infMana = false;      // 无限魔力
inline bool c_noFall = false;       // 摔落无伤
inline bool c_water = false;        // 水下呼吸
inline bool c_lava = false;         // 岩浆免疫
inline bool c_invis = false;        // 隐身
inline bool c_defense = false;      // 防御拉满
inline bool c_speed = false;        // 移动加速
inline float v_speed = 2.0f;        // 加速倍率
inline bool c_fly = false;          // 无限飞行
inline bool c_noKnockback = false;  // 无视击退
inline bool c_regen = false;        // 快速回血

// ---- 世界 ------------------------------------------------------------------
inline bool c_hardMode = false;
inline bool c_bloodMoon = false;
inline bool c_eclipse = false;
inline bool c_rain = false;
inline bool c_sand = false;
inline bool c_wind = false;
inline bool c_day = false;
inline bool c_night = false;
inline bool c_freezeTime = false;

// ---- 物品 ------------------------------------------------------------------
inline int  v_itemId = 1;
inline int  v_itemCount = 99;
inline char v_itemSearch[64] = "";

// ---- 实体（NPC）------------------------------------------------------------
inline bool e_hostile_only = true;      // 秒杀时只清敌对
inline int  v_npcType = 1;              // 生成的 NPC 类型号
inline int  v_npcCount = 1;             // 生成数量
inline char v_npcSearch[64] = "";

}  // namespace cheat
