#pragma once
//
// A 档：游戏数据访问层
// 现在做的是「ID -> 名字」：直接调游戏自己的 Lang.GetXxxNameValue(int)，
// 拿到的是游戏内当前语言的名字（所以汉化包生效后这里也是中文）。
// 物品/NPC/Buff 三个生成器先用「名字 + ID」列表，不依赖贴图。
//
#include <string>
#include <vector>

namespace gd {

bool init();                                  // 解析 Lang 类（幂等）
bool ready();

std::string item_name(int id);                // 空串表示没有这个名字
std::string npc_name(int id);
std::string buff_name(int id);

// 一次性扫出全表（首次调用时构建并缓存），返回 [id, 名字] 列表
const std::vector<std::pair<int, std::string>>& item_table();
const std::vector<std::pair<int, std::string>>& npc_table();
const std::vector<std::pair<int, std::string>>& buff_table();

}  // namespace gd
