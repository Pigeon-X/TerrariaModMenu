#include "lua_hook.hpp"

#include <mutex>
#include <vector>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

#include "../il2cpp_api.hpp"
#include "../mm_log.hpp"

namespace luahook {
namespace {

constexpr int MAX_SLOTS = 32;
constexpr int MAX_ARGS = 8;

enum { MODE_ORIG = 0, MODE_PREPOST = 1 };

struct HookRecord {
    bool active = false;
    lua_State* L = nullptr;
    il2::Method* method = nullptr;
    void* original = nullptr;
    int mode = MODE_ORIG;
    int native_argc = 0;
    bool is_static = true;
    int ref_fn = 0, ref_prefix = 0, ref_postfix = 0;
    bool in_callback = false;
    // 本次调用的实参（供 Native.Orig / SetArg 用），首元素可能是 this
    uintptr_t args[MAX_ARGS] = {0};
};

HookRecord g_records[MAX_SLOTS];
std::mutex g_lock;

struct Invocation {
    HookRecord* rec = nullptr;
    uintptr_t* args = nullptr;
    uintptr_t result = 0;
    bool called_orig = false;
};
thread_local Invocation* g_inv = nullptr;

// ---------------------------------------------------------------------------
// 调原函数
// ---------------------------------------------------------------------------
uintptr_t call_original(const HookRecord& rec, uintptr_t* a) {
    if (!rec.original) return 0;
    switch (rec.native_argc) {
        case 0: return reinterpret_cast<uintptr_t (*)()>(rec.original)();
        case 1: return reinterpret_cast<uintptr_t (*)(uintptr_t)>(rec.original)(a[0]);
        case 2: return reinterpret_cast<uintptr_t (*)(uintptr_t, uintptr_t)>(rec.original)(a[0], a[1]);
        case 3: return reinterpret_cast<uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t)>(
                    rec.original)(a[0], a[1], a[2]);
        case 4: return reinterpret_cast<uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t)>(
                    rec.original)(a[0], a[1], a[2], a[3]);
        case 5: return reinterpret_cast<uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t)>(
                    rec.original)(a[0], a[1], a[2], a[3], a[4]);
        case 6: return reinterpret_cast<uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t)>(
                    rec.original)(a[0], a[1], a[2], a[3], a[4], a[5]);
        case 7: return reinterpret_cast<uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t,
                                                      uintptr_t, uintptr_t, uintptr_t)>(
                    rec.original)(a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
        case 8: return reinterpret_cast<uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t,
                                                      uintptr_t, uintptr_t, uintptr_t, uintptr_t)>(
                    rec.original)(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
        default: return 0;
    }
}

// ---------------------------------------------------------------------------
// 参数编组：托管实参 -> Lua
// ---------------------------------------------------------------------------
void push_args(lua_State* L, const HookRecord& rec, uintptr_t* a) {
    int first = rec.is_static ? 0 : 1;
    int param_count = rec.native_argc - first;
    for (int i = 0; i < param_count; ++i) {
        il2::Type* t = il2::method_get_param(rec.method, (uint32_t)i);
        int tt = t ? il2::type_get_type(t) : 0x1c;     // 默认当引用类型
        uintptr_t raw = a[first + i];
        switch (tt) {
            case 0x02: lua_pushboolean(L, raw != 0); break;          // bool
            case 0x0e: {                                             // string
                if (raw) lua_pushstring(L,
                    il2::to_utf8(reinterpret_cast<il2::String*>(raw)).c_str());
                else lua_pushnil(L);
                break;
            }
            default: lua_pushinteger(L, (lua_Integer)raw); break;    // 整数 / 引用（原样传）
        }
    }
}

int arg_offset(const HookRecord& rec) { return rec.is_static ? 0 : 1; }

// ---------------------------------------------------------------------------
// 跳板派发
// ---------------------------------------------------------------------------
uintptr_t dispatch(int slot, uintptr_t* args) {
    HookRecord& rec = g_records[slot];
    if (!rec.active) return 0;

    // 回调里又调到同一个被 hook 的函数 -> 直接走原函数，防止无限递归
    if (rec.in_callback) return call_original(rec, args);

    for (int i = 0; i < MAX_ARGS; ++i) rec.args[i] = args ? args[i] : 0;

    Invocation inv;
    inv.rec = &rec;
    inv.args = rec.args;
    Invocation* prev = g_inv;
    g_inv = &inv;
    rec.in_callback = true;

    lua_State* L = rec.L;
    int base = lua_gettop(L);
    uintptr_t result = 0;

    if (rec.mode == MODE_ORIG) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, rec.ref_fn);
        if (rec.is_static) {
            push_args(L, rec, rec.args);
        } else {
            lua_pushinteger(L, (lua_Integer)rec.args[0]);   // this
            push_args(L, rec, rec.args);
        }
        if (lua_pcall(L, rec.native_argc, 1, 0) == LUA_OK) {
            if (inv.called_orig) {
                result = inv.result;
            } else if (lua_isnumber(L, -1)) {
                result = (uintptr_t)lua_tointeger(L, -1);   // 回调直接给返回值 = 覆写
            }
            // 没传返回值也没调 Orig -> 跳过原函数，返回 0
        } else {
            mm::logf("hook 回调出错: %s", lua_tostring(L, -1));
        }
    } else {
        // prepost
        bool skip = false;
        if (rec.ref_prefix > 0) {
            lua_rawgeti(L, LUA_REGISTRYINDEX, rec.ref_prefix);
            if (!rec.is_static) lua_pushinteger(L, (lua_Integer)rec.args[0]);
            push_args(L, rec, rec.args);
            if (lua_pcall(L, rec.native_argc, 1, 0) == LUA_OK) {
                skip = lua_toboolean(L, -1) != 0;
            } else {
                mm::logf("hook prefix 出错: %s", lua_tostring(L, -1));
            }
            lua_settop(L, base);
        }

        if (!skip) {
            result = call_original(rec, rec.args);
            inv.result = result;
        }

        if (rec.ref_postfix > 0) {
            lua_rawgeti(L, LUA_REGISTRYINDEX, rec.ref_postfix);
            if (!rec.is_static) lua_pushinteger(L, (lua_Integer)rec.args[0]);
            push_args(L, rec, rec.args);
            lua_pushinteger(L, (lua_Integer)result);
            if (lua_pcall(L, rec.native_argc + 1, 1, 0) == LUA_OK) {
                if (lua_isnumber(L, -1)) result = (uintptr_t)lua_tointeger(L, -1);
            } else {
                mm::logf("hook postfix 出错: %s", lua_tostring(L, -1));
            }
        }
    }

    lua_settop(L, base);
    rec.in_callback = false;
    g_inv = prev;
    return result;
}

// ---------------------------------------------------------------------------
// 编译期生成跳板：每个 (槽位, 参数个数) 一个入口
// ---------------------------------------------------------------------------
template <int Slot>
struct Thunks {
    static uintptr_t f0() { return dispatch(Slot, nullptr); }
    static uintptr_t f1(uintptr_t a0) { uintptr_t v[8] = {a0}; return dispatch(Slot, v); }
    static uintptr_t f2(uintptr_t a0, uintptr_t a1) { uintptr_t v[8] = {a0, a1}; return dispatch(Slot, v); }
    static uintptr_t f3(uintptr_t a0, uintptr_t a1, uintptr_t a2) { uintptr_t v[8] = {a0, a1, a2}; return dispatch(Slot, v); }
    static uintptr_t f4(uintptr_t a0, uintptr_t a1, uintptr_t a2, uintptr_t a3) { uintptr_t v[8] = {a0, a1, a2, a3}; return dispatch(Slot, v); }
    static uintptr_t f5(uintptr_t a0, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4) { uintptr_t v[8] = {a0, a1, a2, a3, a4}; return dispatch(Slot, v); }
    static uintptr_t f6(uintptr_t a0, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5) { uintptr_t v[8] = {a0, a1, a2, a3, a4, a5}; return dispatch(Slot, v); }
    static uintptr_t f7(uintptr_t a0, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5, uintptr_t a6) { uintptr_t v[8] = {a0, a1, a2, a3, a4, a5, a6}; return dispatch(Slot, v); }
    static uintptr_t f8(uintptr_t a0, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5, uintptr_t a6, uintptr_t a7) { uintptr_t v[8] = {a0, a1, a2, a3, a4, a5, a6, a7}; return dispatch(Slot, v); }
};

void* g_thunks[MAX_SLOTS][MAX_ARGS + 1];

template <int Slot> struct FillOne {
    static void apply() {
        g_thunks[Slot][0] = reinterpret_cast<void*>(&Thunks<Slot>::f0);
        g_thunks[Slot][1] = reinterpret_cast<void*>(&Thunks<Slot>::f1);
        g_thunks[Slot][2] = reinterpret_cast<void*>(&Thunks<Slot>::f2);
        g_thunks[Slot][3] = reinterpret_cast<void*>(&Thunks<Slot>::f3);
        g_thunks[Slot][4] = reinterpret_cast<void*>(&Thunks<Slot>::f4);
        g_thunks[Slot][5] = reinterpret_cast<void*>(&Thunks<Slot>::f5);
        g_thunks[Slot][6] = reinterpret_cast<void*>(&Thunks<Slot>::f6);
        g_thunks[Slot][7] = reinterpret_cast<void*>(&Thunks<Slot>::f7);
        g_thunks[Slot][8] = reinterpret_cast<void*>(&Thunks<Slot>::f8);
    }
};

template <int Slot, int End> struct FillAll {
    static void go() { FillOne<Slot>::apply(); FillAll<Slot + 1, End>::go(); }
};
template <int End> struct FillAll<End, End> { static void go() {} };

struct ThunkTableInit {
    ThunkTableInit() { FillAll<0, MAX_SLOTS>::go(); }
};
ThunkTableInit g_init;

}  // namespace

// ---------------------------------------------------------------------------
// 支持性判断
// ---------------------------------------------------------------------------
bool signature_supported(il2::Method* m, const char** why) {
    if (!m) { if (why) *why = "方法为空"; return false; }
    uint32_t n = il2::method_get_param_count(m);
    for (uint32_t i = 0; i < n; ++i) {
        il2::Type* t = il2::method_get_param(m, i);
        int tt = t ? il2::type_get_type(t) : 0x1c;
        if (tt == 0x0c || tt == 0x0d) {                 // R4 / R8
            if (why) *why = "有 float/double 参数（当前引擎不支持，需浮点跳板）";
            return false;
        }
    }
    if (n + 1 > MAX_ARGS) { if (why) *why = "参数太多"; return false; }
    return true;
}

int install(il2::Method* m, lua_State* L, Spec spec) {
    if (!m || !L) return -1;
    int argc = spec.is_static ? (int)il2::method_get_param_count(m)
                              : (int)il2::method_get_param_count(m) + 1;
    if (argc > MAX_ARGS) { mm::logf("Hook 失败：参数个数 %d 超过上限 %d", argc, MAX_ARGS); return -1; }

    std::lock_guard<std::mutex> lock(g_lock);
    for (int slot = 0; slot < MAX_SLOTS; ++slot) {
        if (g_records[slot].active) continue;
        HookRecord& rec = g_records[slot];
        rec = HookRecord();
        rec.active = true;
        rec.L = L;
        rec.method = m;
        rec.original = spec.original;
        rec.mode = spec.mode;
        rec.native_argc = argc;
        rec.is_static = spec.is_static;
        rec.ref_fn = spec.ref_fn;
        rec.ref_prefix = spec.ref_prefix;
        rec.ref_postfix = spec.ref_postfix;

        if (!il2::set_method_pointer(m, g_thunks[slot][argc])) {
            rec.active = false;
            mm::logf("Hook 失败：写不回 methodPointer");
            return -1;
        }
        mm::logf("Hook 装好：slot=%d argc=%d mode=%s", slot, argc,
                 spec.mode == MODE_ORIG ? "orig" : "prepost");
        return slot;
    }
    mm::logf("Hook 失败：槽位用满（上限 %d）", MAX_SLOTS);
    return -1;
}

void remove_handle(int handle, lua_State* L) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (handle < 0 || handle >= MAX_SLOTS) return;
    HookRecord& rec = g_records[handle];
    if (!rec.active) return;
    if (rec.method && rec.original) il2::set_method_pointer(rec.method, rec.original);
    auto unref = [&](int& r) { if (r > 0) { luaL_unref(L, LUA_REGISTRYINDEX, r); r = 0; } };
    unref(rec.ref_fn); unref(rec.ref_prefix); unref(rec.ref_postfix);
    rec.active = false;
}

void release_state(lua_State* L) {
    for (int i = 0; i < MAX_SLOTS; ++i) {
        if (g_records[i].active && g_records[i].L == L) remove_handle(i, L);
    }
}

// ---------------------------------------------------------------------------
// Native.Orig / Native.SetArg
// ---------------------------------------------------------------------------
int l_orig(lua_State* L) {
    if (!g_inv || !g_inv->rec) { lua_pushnil(L); return 1; }
    HookRecord& rec = *g_inv->rec;

    // 传了实参就替换（第一个为 nil 表示沿用原 this）
    int n = lua_gettop(L);
    if (n > 0) {
        int k = 0;
        for (int i = 1; i <= n && k < MAX_ARGS; ++i) {
            if (i == 1 && lua_isnil(L, 1)) {
                if (!rec.is_static) rec.args[k++] = rec.args[0];   // 保持 this
                continue;
            }
            rec.args[k++] = (uintptr_t)lua_tointeger(L, i);
        }
    }
    g_inv->result = call_original(rec, rec.args);
    g_inv->called_orig = true;
    lua_pushinteger(L, (lua_Integer)g_inv->result);
    return 1;
}

int l_setarg(lua_State* L) {
    if (!g_inv || !g_inv->rec) return 0;
    int idx = (int)luaL_checkinteger(L, 1);      // 从 1 起、不含 this
    HookRecord& rec = *g_inv->rec;
    int off = arg_offset(rec);
    int pos = off + idx - 1;
    if (pos < 0 || pos >= rec.native_argc || pos >= MAX_ARGS) return 0;
    if (lua_isboolean(L, 2)) rec.args[pos] = lua_toboolean(L, 2) ? 1 : 0;
    else rec.args[pos] = (uintptr_t)lua_tointeger(L, 2);
    return 0;
}

}  // namespace luahook
