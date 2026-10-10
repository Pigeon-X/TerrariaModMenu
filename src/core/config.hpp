#pragma once
//
// 配置持久化：把界面/开关状态存到 Documents/ModMenu_config.txt
// 用最简单的 key=value 文本，避免引入 JSON 解析器。
//
#include <string>

namespace cfg {

void load();                                   // 启动时读一次
std::string get(const char* key, const std::string& def = "");
void set(const char* key, const std::string& val);
void set_bool(const char* key, bool v);
bool get_bool(const char* key, bool def = false);
void set_int(const char* key, int v);
int get_int(const char* key, int def = 0);
void set_float(const char* key, float v);
float get_float(const char* key, float def = 0.0f);

void mark_dirty();                             // 标脏
void tick();                                   // 每帧调用；脏了且距上次保存 >2 秒就落盘
void save_now();

}  // namespace cfg
