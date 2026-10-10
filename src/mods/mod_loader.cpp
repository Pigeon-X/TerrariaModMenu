#include "mod_loader.hpp"

#include <dirent.h>
#include <sys/stat.h>

#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>

#import <Foundation/Foundation.h>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

#include "../lua/lua_api.hpp"
#include "../mm_log.hpp"

namespace mods {
namespace {

std::vector<Mod> g_mods;
std::string g_root;

std::string docs_dir() {
    @autoreleasepool {
        NSArray<NSString*>* dirs =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString* docs = dirs.count ? dirs[0] : NSTemporaryDirectory();
        return std::string(docs.UTF8String ?: "/tmp");
    }
}

bool is_dir(const std::string& p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

bool is_file(const std::string& p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

// mod.json 只支持扁平对象：{"name":"x","enabled":true,...}
void parse_mod_json(const std::string& path, Mod& m) {
    std::ifstream in(path);
    if (!in) return;
    std::stringstream ss;
    ss << in.rdbuf();
    const std::string s = ss.str();

    auto read_str = [&](const char* key, std::string& out) {
        std::string pat = std::string("\"") + key + "\"";
        size_t p = s.find(pat);
        if (p == std::string::npos) return;
        size_t q = s.find(':', p + pat.size());
        if (q == std::string::npos) return;
        size_t a = s.find('"', q + 1);
        if (a == std::string::npos) return;
        size_t b = s.find('"', a + 1);
        if (b == std::string::npos) return;
        out = s.substr(a + 1, b - a - 1);
    };
    read_str("version", m.version);
    read_str("author", m.author);
    read_str("description", m.description);
    read_str("entry", m.entry);

    std::string display;
    read_str("name", display);           // mod.json 里的 name 只作展示用
    if (!display.empty()) m.name = display;

    size_t p = s.find("\"enabled\"");
    if (p != std::string::npos) {
        size_t q = s.find(':', p);
        m.enabled = s.find("false", q) != std::string::npos ? false : true;
    }
}

void load_one(Mod& m) {
    m.L = luaapi::create_state(m.name, m.dir);
    if (!m.L) { m.error = "创建 Lua 实例失败"; return; }

    // MOD_DIR
    lua_pushstring(m.L, m.dir.c_str());
    lua_setglobal(m.L, "MOD_DIR");

    const std::string entry = m.dir + "/" + m.entry;
    if (!is_file(entry)) { m.error = "找不到入口脚本 " + m.entry; return; }

    if (!luaapi::run_file(m.L, entry, "main.lua")) { m.error = "脚本执行失败"; return; }
    if (!luaapi::call_global(m.L, "onLoad")) {
        // onLoad 不存在不算错误
    }
    m.loaded = true;
    mm::logf("Mod 已加载：%s%s%s", m.name.c_str(),
             m.version.empty() ? "" : " v", m.version.c_str());
}

}  // namespace

const std::string& root_dir() {
    if (g_root.empty()) g_root = docs_dir() + "/Mods";
    return g_root;
}

void unload_all() {
    for (auto& m : g_mods) {
        if (m.L && m.loaded) luaapi::call_global(m.L, "onUnload");
        if (m.L) luaapi::close_state(m.L);
        m.L = nullptr;
        m.loaded = false;
    }
    g_mods.clear();
}

void reload() {
    const std::string root = root_dir();
    ::mkdir(root.c_str(), 0755);
    mm::logf("扫描 Mods 目录：%s", root.c_str());

    unload_all();

    DIR* d = opendir(root.c_str());
    if (!d) { mm::logf("Mods 目录打不开"); return; }

    struct dirent* e;
    while ((e = readdir(d)) != nullptr) {
        std::string name = e->d_name;
        if (name == "." || name == "..") continue;
        std::string dir = root + "/" + name;
        if (!is_dir(dir)) continue;

        Mod m;
        m.name = name;
        m.dir = dir;
        parse_mod_json(dir + "/mod.json", m);
        if (!m.enabled) {
            mm::logf("Mod 已禁用，跳过：%s", m.name.c_str());
            continue;
        }
        load_one(m);
        g_mods.push_back(std::move(m));
    }
    closedir(d);

    int ok = 0;
    for (auto& m : g_mods) if (m.loaded) ++ok;
    mm::logf("Mod 扫描完成：发现 %zu 个，成功加载 %d 个", g_mods.size(), ok);
}

void tick() {
    for (auto& m : g_mods) {
        if (!m.L || !m.loaded) continue;
        luaapi::tick(m.L);                 // 协程
        luaapi::call_global(m.L, "onUpdate");
    }
}

const std::vector<Mod>& list() { return g_mods; }

}  // namespace mods
