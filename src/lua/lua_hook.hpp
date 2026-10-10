#pragma once
//
// Native.Hook 引擎
// ---------------------------------------------------------------------------
// 做法：不动机器码，直接改写托管方法 MethodInfo 里的 methodPointer 字段，
//       指向我们自己的跳板函数；跳板里转成 Lua 回调，需要时再调回原函数。
//
// 跳板不是手写汇编，而是**编译期模板生成的**一堆入口函数，
// 每个「槽位 + 参数个数」组合一个，靠模板参数在编译期确定身份。
//
// 限制（当前版本）：只支持「全部参数都是整数/指针/字符串/布尔」的方法；
//       含 float/double 参数的方法会被拒绝安装（而不是装错导致崩溃）。
//
struct lua_State;

namespace il2 {
using Method = void;
}

namespace luahook {

struct Spec {
    void* original = nullptr;     // 原 methodPointer
    int mode = 0;                 // 0 = orig, 1 = prepost
    int native_argc = 0;          // 含 this（实例方法）
    bool is_static = true;
    int ref_fn = 0;               // orig 模式回调（未使用时 <=0）
    int ref_prefix = 0;
    int ref_postfix = 0;
};

// 该方法能不能被当前引擎 hook（参数/返回值类型是否受支持）
bool signature_supported(il2::Method* m, const char** why);

// 安装一个 hook，返回句柄（>=0）或 -1
int install(il2::Method* m, lua_State* L, Spec spec);

// 移除单个 hook（恢复原函数）
void remove_handle(int handle, lua_State* L);

// 恢复某个 Lua 实例装过的所有 hook（Mod 卸载时调用）
void release_state(lua_State* L);

// Native.Orig —— 由 lua_api 注册为全局
int l_orig(lua_State* L);
// Native.SetArg
int l_setarg(lua_State* L);

}  // namespace luahook
