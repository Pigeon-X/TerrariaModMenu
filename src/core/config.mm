#include "config.hpp"

#include <cstdio>
#include <cstdlib>
#include <unordered_map>

#import <Foundation/Foundation.h>

#include "../mm_log.hpp"

namespace cfg {
namespace {

std::unordered_map<std::string, std::string> g_kv;
bool g_dirty = false;
double g_last_save = 0;

std::string path() {
    @autoreleasepool {
        NSArray<NSString*>* dirs =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString* docs = dirs.count ? dirs[0] : NSTemporaryDirectory();
        NSString* p = [docs stringByAppendingPathComponent:@"ModMenu_config.txt"];
        return std::string(p.UTF8String ?: "/tmp/ModMenu_config.txt");
    }
}

double now() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

}  // namespace

void load() {
    g_kv.clear();
    FILE* f = fopen(path().c_str(), "r");
    if (!f) { mm::logf("配置：首次运行，暂无配置文件"); return; }
    char line[512];
    int n = 0;
    while (fgets(line, sizeof(line), f)) {
        char* eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        std::string k = line;
        std::string v = eq + 1;
        while (!v.empty() && (v.back() == '\n' || v.back() == '\r')) v.pop_back();
        if (!k.empty()) { g_kv[k] = v; ++n; }
    }
    fclose(f);
    mm::logf("配置：已读取 %d 项", n);
}

std::string get(const char* key, const std::string& def) {
    auto it = g_kv.find(key);
    return it == g_kv.end() ? def : it->second;
}
void set(const char* key, const std::string& val) {
    if (g_kv[key] != val) { g_kv[key] = val; g_dirty = true; }
}
void set_bool(const char* key, bool v) { set(key, v ? "1" : "0"); }
bool get_bool(const char* key, bool def) { return get(key, def ? "1" : "0") == "1"; }
void set_int(const char* key, int v) { set(key, std::to_string(v)); }
int get_int(const char* key, int def) { return atoi(get(key, std::to_string(def)).c_str()); }
void set_float(const char* key, float v) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%.4f", v);
    set(key, buf);
}
float get_float(const char* key, float def) {
    return strtof(get(key, std::to_string(def)).c_str(), nullptr);
}

void mark_dirty() { g_dirty = true; }

void save_now() {
    FILE* f = fopen(path().c_str(), "w");
    if (!f) { mm::logf("配置：写不进去 %s", path().c_str()); return; }
    for (auto& kv : g_kv) fprintf(f, "%s=%s\n", kv.first.c_str(), kv.second.c_str());
    fclose(f);
    g_dirty = false;
    g_last_save = now();
}

void tick() {
    if (!g_dirty) return;
    // 节流：拖窗口/拖球时会疯狂改值，最多 2 秒写一次
    if (now() - g_last_save > 2.0) save_now();
}

}  // namespace cfg
