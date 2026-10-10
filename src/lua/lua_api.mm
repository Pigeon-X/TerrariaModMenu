//
// 每个 Mod 一个 lua_State：注册全局 API（Log / require / Runtime / UI / Native）。
//
#include "lua_api.hpp"

#include <cmath>
#include <cstring>
#include <ctime>
#include <time.h>
#include <string>
#include <vector>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

#include "../il2cpp_api.hpp"
#include "../mm_log.hpp"
#include "../ui/menu.hpp"
#include "imgui.h"          // UI.* 直接画 ImGui 控件
#include "lua_hook.hpp"

namespace luaapi {
namespace {

// Il2CppTypeEnum（只用到这些）
enum {
    T_END = 0x00, T_VOID = 0x01, T_BOOLEAN = 0x02, T_CHAR = 0x03,
    T_I1 = 0x04, T_U1 = 0x05, T_I2 = 0x06, T_U2 = 0x07,
    T_I4 = 0x08, T_U4 = 0x09, T_I8 = 0x0a, T_U8 = 0x0b,
    T_R4 = 0x0c, T_R8 = 0x0d, T_STRING = 0x0e, T_PTR = 0x0f, T_BYREF = 0x10,
    T_VALUETYPE = 0x11, T_CLASS = 0x12, T_ARRAY = 0x14, T_OBJECT = 0x1c, T_SZARRAY = 0x1d,
};

struct Coroutine {
    int ref = LUA_NOREF;      // 线程对象在 registry 里的引用
    double wake = 0.0;        // 到这个时间点再恢复
    bool dead = false;
};

struct ModState {
    std::string name;
    std::string dir;
    std::vector<Coroutine> cos;
    int panel_refs = 0;
};

ModState* state_of(lua_State* L) {
    lua_pushliteral(L, "mm_mod");
    lua_rawget(L, LUA_REGISTRYINDEX);
    auto* ms = static_cast<ModState*>(lua_touserdata(L, -1));
    lua_pop(L, 1);
    return ms;
}

// 元表名 / userdata 类型（提前声明：下面的 UI 区块之后要用到）
const char* MT_METHOD = "mm.NativeMethod";
struct LuaMethod { il2::Method* m; };

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------
void mod_log(ModState* ms, const std::string& line) {
    mm::logf("[%s] %s", ms ? ms->name.c_str() : "?", line.c_str());
    if (!ms) return;
    FILE* f = fopen((ms->dir + "/log.txt").c_str(), "a");
    if (f) {
        time_t now = time(nullptr);
        char ts[32];
        strftime(ts, sizeof(ts), "%H:%M:%S", localtime(&now));
        fprintf(f, "[%s] %s\n", ts, line.c_str());
        fclose(f);
    }
}

int l_log(lua_State* L) {
    ModState* ms = state_of(L);
    int n = lua_gettop(L);
    std::string s;
    for (int i = 1; i <= n; ++i) {
        if (i > 1) s += " ";
        size_t len = 0;
        const char* p = luaL_tolstring(L, i, &len);   // 任何类型都能转成字符串
        s.append(p, len);
        lua_pop(L, 1);
    }
    // 忽略 LogLevel / LogSink 位标志参数（阶段 4 再细化分级）
    mod_log(ms, s);
    return 0;
}

// ---------------------------------------------------------------------------
// require：从 Mod 目录加载，带缓存
// ---------------------------------------------------------------------------
int l_require(lua_State* L) {
    ModState* ms = state_of(L);
    const char* name = luaL_checkstring(L, 1);

    lua_pushliteral(L, "mm_loaded");
    lua_rawget(L, LUA_REGISTRYINDEX);
    lua_getfield(L, -1, name);
    if (!lua_isnil(L, -1)) return 1;          // 已缓存
    lua_pop(L, 2);

    std::string rel(name);
    for (auto& c : rel) if (c == '.') c = '/';

    std::string path = ms->dir + "/" + rel + ".lua";
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) path = ms->dir + "/" + rel + "/init.lua";

    if (luaL_loadfile(L, path.c_str()) != LUA_OK) {
        mod_log(ms, std::string("require 失败: ") + lua_tostring(L, -1));
        return lua_error(L);
    }
    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        mod_log(ms, std::string("require 执行出错: ") + lua_tostring(L, -1));
        return lua_error(L);
    }
    if (lua_isnil(L, -1)) { lua_pop(L, 1); lua_pushboolean(L, 1); }

    // 缓存
    lua_pushliteral(L, "mm_loaded");
    lua_rawget(L, LUA_REGISTRYINDEX);
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, name);
    lua_pop(L, 1);
    return 1;
}

// ---------------------------------------------------------------------------
// 协程调度（Runtime.Spawn / Wait / Yield）
// ---------------------------------------------------------------------------
double now_seconds() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

void resume_coroutine(lua_State* L, ModState* ms, size_t idx) {
    Coroutine& co = ms->cos[idx];
    lua_rawgeti(L, LUA_REGISTRYINDEX, co.ref);
    lua_State* th = lua_tothread(L, -1);
    if (!th) { lua_pop(L, 1); co.dead = true; return; }
    int nres = 0;
    int status = lua_resume(th, L, 0, &nres);      // Lua 5.4 是 4 个参数
    if (status == LUA_YIELD) {
        double wait = (nres >= 1 && lua_isnumber(th, -1)) ? lua_tonumber(th, -1) : 0.0;
        if (wait < 0) wait = 0;
        co.wake = now_seconds() + wait;
        lua_settop(th, 0);
    } else {
        if (status != LUA_OK) {
            const char* err = lua_tostring(th, -1);
            mod_log(ms, std::string("协程出错: ") + (err ? err : "?"));
        }
        lua_settop(th, 0);
        co.dead = true;
    }
    lua_settop(L, 0);
}

int l_spawn(lua_State* L) {
    ModState* ms = state_of(L);
    luaL_checktype(L, 1, LUA_TFUNCTION);
    int nargs = lua_gettop(L) - 1;

    lua_State* co = lua_newthread(L);                 // stack: [fn, args..., co]
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);         // 弹出 co 并引用

    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);           // 再把 co 压回来
    lua_pushvalue(L, 1);                              // fn
    for (int i = 0; i < nargs; ++i) lua_pushvalue(L, 2 + i);
    lua_xmove(L, co, nargs + 1);                      // fn + args 搬到 co 的栈上
    lua_pop(L, 1);                                    // 弹掉 co

    ms->cos.push_back({ref, 0.0, false});
    size_t idx = ms->cos.size() - 1;

    int nres = 0;
    int status = lua_resume(co, L, nargs, &nres);
    if (status == LUA_YIELD) {
        double wait = (nres >= 1 && lua_isnumber(co, -1)) ? lua_tonumber(co, -1) : 0.0;
        ms->cos[idx].wake = now_seconds() + (wait > 0 ? wait : 0);
        lua_settop(co, 0);
    } else {
        if (status != LUA_OK) {
            const char* err = lua_tostring(co, -1);
            mod_log(ms, std::string("协程出错: ") + (err ? err : "?"));
        }
        lua_settop(co, 0);
        ms->cos[idx].dead = true;
    }
    return 0;
}

int l_wait(lua_State* L) {
    double sec = luaL_optnumber(L, 1, 0.0);
    lua_pushnumber(L, sec);
    return lua_yield(L, 1);
}

int l_yield(lua_State* L) {
    lua_pushnumber(L, 0.0);
    return lua_yield(L, 1);
}

int l_now(lua_State* L) {
    lua_pushnumber(L, now_seconds());
    return 1;
}

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------
int ui_text(lua_State* L) {
    int n = lua_gettop(L);
    std::string s;
    for (int i = 1; i <= n; ++i) {
        if (i > 1) s += " ";
        size_t len = 0;
        const char* p = luaL_tolstring(L, i, &len);
        s.append(p, len);
        lua_pop(L, 1);
    }
    ImGui::TextUnformatted(s.c_str());
    return 0;
}

int ui_text_colored(lua_State* L) {
    std::string s = luaL_checkstring(L, 1);
    float r = (float)luaL_optnumber(L, 2, 1.0);
    float g = (float)luaL_optnumber(L, 3, 1.0);
    float b = (float)luaL_optnumber(L, 4, 1.0);
    float a = (float)luaL_optnumber(L, 5, 1.0);
    ImGui::TextColored(ImVec4(r, g, b, a), "%s", s.c_str());
    return 0;
}

int ui_separator(lua_State*) { ImGui::Separator(); return 0; }
int ui_same_line(lua_State*) { ImGui::SameLine(); return 0; }
int ui_spacing(lua_State*) { ImGui::Spacing(); return 0; }

int ui_button(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    float w = (float)luaL_optnumber(L, 2, 0);
    float h = (float)luaL_optnumber(L, 3, 0);
    lua_pushboolean(L, w > 0 && h > 0 ? ImGui::Button(label, ImVec2(w, h)) : ImGui::Button(label));
    return 1;
}

int ui_checkbox(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    bool v = lua_toboolean(L, 2);
    if (ImGui::Checkbox(label, &v)) {
        lua_pushboolean(L, v);
        return 1;
    }
    lua_pushboolean(L, v);
    return 1;
}

int ui_slider_int(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    int v = (int)luaL_checkinteger(L, 2);
    int lo = (int)luaL_checkinteger(L, 3);
    int hi = (int)luaL_checkinteger(L, 4);
    ImGui::SliderInt(label, &v, lo, hi);
    lua_pushinteger(L, v);
    return 1;
}

int ui_slider_float(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    float v = (float)luaL_checknumber(L, 2);
    float lo = (float)luaL_checknumber(L, 3);
    float hi = (float)luaL_checknumber(L, 4);
    const char* fmt = luaL_optstring(L, 5, "%.3f");
    ImGui::SliderFloat(label, &v, lo, hi, fmt);
    lua_pushnumber(L, v);
    return 1;
}

int ui_tooltip(lua_State* L) {
    ImGui::SetTooltip("%s", luaL_checkstring(L, 1));
    return 0;
}

int ui_bullet(lua_State* L) {
    ImGui::BulletText("%s", luaL_checkstring(L, 1));
    return 0;
}

// ---- 补一批 mod 常用的控件 ------------------------------------------------
int ui_text_wrapped(lua_State* L) {
    ImGui::TextWrapped("%s", luaL_checkstring(L, 1));
    return 0;
}
int ui_text_disabled(lua_State* L) {
    ImGui::TextDisabled("%s", luaL_checkstring(L, 1));
    return 0;
}
int ui_label_text(lua_State* L) {
    ImGui::LabelText(luaL_checkstring(L, 1), "%s", luaL_checkstring(L, 2));
    return 0;
}
int ui_separator_text(lua_State* L) {
    ImGui::SeparatorText(luaL_checkstring(L, 1));
    return 0;
}
int ui_newline(lua_State*) { ImGui::NewLine(); return 0; }
int ui_indent(lua_State* L) { ImGui::Indent((float)luaL_optnumber(L, 1, 0)); return 0; }
int ui_unindent(lua_State* L) { ImGui::Unindent((float)luaL_optnumber(L, 1, 0)); return 0; }
int ui_dummy(lua_State* L) { ImGui::Dummy(ImVec2((float)luaL_checknumber(L,1), (float)luaL_checknumber(L,2))); return 0; }
int ui_set_next_item_width(lua_State* L) { ImGui::SetNextItemWidth((float)luaL_checknumber(L, 1)); return 0; }
int ui_push_id(lua_State* L) { ImGui::PushID(luaL_checkstring(L, 1)); return 0; }
int ui_pop_id(lua_State*) { ImGui::PopID(); return 0; }
int ui_begin_group(lua_State*) { ImGui::BeginGroup(); return 0; }
int ui_end_group(lua_State*) { ImGui::EndGroup(); return 0; }
int ui_small_button(lua_State* L) { lua_pushboolean(L, ImGui::SmallButton(luaL_checkstring(L, 1))); return 1; }
int ui_progress_bar(lua_State* L) {
    ImGui::ProgressBar((float)luaL_checknumber(L, 1));
    return 0;
}
int ui_is_item_hovered(lua_State* L) { lua_pushboolean(L, ImGui::IsItemHovered()); return 1; }
int ui_is_item_clicked(lua_State* L) { lua_pushboolean(L, ImGui::IsItemClicked((int)luaL_optinteger(L, 1, 0))); return 1; }

int ui_input_text(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    const char* cur = luaL_optstring(L, 2, "");
    char buf[512];
    snprintf(buf, sizeof(buf), "%s", cur);
    if (ImGui::InputText(label, buf, sizeof(buf))) { lua_pushstring(L, buf); return 1; }
    lua_pushstring(L, buf);
    return 1;
}
int ui_input_text_hint(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    const char* hint = luaL_checkstring(L, 2);
    const char* cur = luaL_optstring(L, 3, "");
    char buf[512];
    snprintf(buf, sizeof(buf), "%s", cur);
    if (ImGui::InputTextWithHint(label, hint, buf, sizeof(buf))) { lua_pushstring(L, buf); return 1; }
    lua_pushstring(L, buf);
    return 1;
}
int ui_input_int(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    int v = (int)luaL_optinteger(L, 2, 0);
    int step = (int)luaL_optinteger(L, 3, 1);
    ImGui::InputInt(label, &v, step);
    lua_pushinteger(L, v);
    return 1;
}
int ui_drag_int(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    int v = (int)luaL_checkinteger(L, 2);
    float speed = (float)luaL_optnumber(L, 3, 1.0);
    ImGui::DragInt(label, &v, speed);
    lua_pushinteger(L, v);
    return 1;
}
int ui_drag_float(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    float v = (float)luaL_checknumber(L, 2);
    float speed = (float)luaL_optnumber(L, 3, 1.0f);
    ImGui::DragFloat(label, &v, speed);
    lua_pushnumber(L, v);
    return 1;
}
int ui_checkbox_flags(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    int v = (int)luaL_checkinteger(L, 2);
    int flags = (int)luaL_checkinteger(L, 3);
    bool changed = ImGui::CheckboxFlags(label, &v, flags);
    lua_pushinteger(L, v);
    lua_pushboolean(L, changed);
    return 2;
}
int ui_color_edit3(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    float c[3] = {(float)luaL_checknumber(L,2), (float)luaL_checknumber(L,3), (float)luaL_checknumber(L,4)};
    bool changed = ImGui::ColorEdit3(label, c);
    lua_pushnumber(L, c[0]); lua_pushnumber(L, c[1]); lua_pushnumber(L, c[2]);
    lua_pushboolean(L, changed);
    return 4;
}
int ui_color_swatch(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    ImVec4 col((float)luaL_optnumber(L,2,1), (float)luaL_optnumber(L,3,1),
               (float)luaL_optnumber(L,4,1), (float)luaL_optnumber(L,5,1));
    ImGui::ColorButton(label, col);
    lua_pushnumber(L, col.x); lua_pushnumber(L, col.y);
    lua_pushnumber(L, col.z); lua_pushnumber(L, col.w);
    lua_pushboolean(L, false);
    return 5;
}
int ui_combo(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    int cur = (int)luaL_optinteger(L, 2, 0);
    luaL_checktype(L, 3, LUA_TTABLE);
    int n = (int)lua_rawlen(L, 3);
    std::vector<std::string> items;
    items.reserve(n);
    for (int i = 1; i <= n; ++i) {
        lua_rawgeti(L, 3, i);
        items.emplace_back(lua_tostring(L, -1) ? lua_tostring(L, -1) : "");
        lua_pop(L, 1);
    }
    const char* preview = (cur >= 0 && cur < n) ? items[cur].c_str() : "";
    if (ImGui::BeginCombo(label, preview)) {
        for (int i = 0; i < n; ++i) {
            bool sel = (i == cur);
            if (ImGui::Selectable(items[i].c_str(), sel)) cur = i;
            if (sel) ImGui::SetItemDefaultFocus();
        }
        ImGui::EndCombo();
    }
    lua_pushinteger(L, cur);
    return 1;
}
int ui_radio_button(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    if (lua_type(L, 3) == LUA_TNUMBER) {
        int v = (int)luaL_checkinteger(L, 2);
        int want = (int)luaL_checkinteger(L, 3);
        if (ImGui::RadioButton(label, v == want)) lua_pushinteger(L, want);
        else lua_pushinteger(L, v);
    } else {
        bool active = lua_toboolean(L, 2);
        if (ImGui::RadioButton(label, active)) lua_pushinteger(L, 1);
        else lua_pushinteger(L, 0);
    }
    return 1;
}
int ui_selectable(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    bool sel = lua_toboolean(L, 2);
    int flags = (int)luaL_optinteger(L, 3, 0);
    bool pressed = ImGui::Selectable(label, &sel, (ImGuiSelectableFlags)flags);
    lua_pushboolean(L, sel);
    lua_pushboolean(L, pressed);
    return 2;
}
int ui_tree_node(lua_State* L) {
    lua_pushboolean(L, ImGui::TreeNode(luaL_checkstring(L, 1)));
    return 1;
}
int ui_tree_pop(lua_State*) { ImGui::TreePop(); return 0; }
int ui_collapsing_header(lua_State* L) {
    lua_pushboolean(L, ImGui::CollapsingHeader(luaL_checkstring(L, 1)));
    return 1;
}
int ui_begin_child(lua_State* L) {
    const char* id = luaL_checkstring(L, 1);
    float w = (float)luaL_optnumber(L, 2, 0);
    float h = (float)luaL_optnumber(L, 3, 0);
    lua_pushboolean(L, ImGui::BeginChild(id, ImVec2(w, h)));
    return 1;
}
int ui_end_child(lua_State*) { ImGui::EndChild(); return 0; }

// ---- 表格 / 选项卡 / 弹窗 -------------------------------------------------
int ui_begin_table(lua_State* L) {
    const char* id = luaL_checkstring(L, 1);
    int cols = (int)luaL_checkinteger(L, 2);
    int flags = (int)luaL_optinteger(L, 3, 0);
    lua_pushboolean(L, ImGui::BeginTable(id, cols, (ImGuiTableFlags)flags));
    return 1;
}
int ui_table_setup_column(lua_State* L) {
    ImGui::TableSetupColumn(luaL_checkstring(L, 1));
    return 0;
}
int ui_table_headers_row(lua_State*) { ImGui::TableHeadersRow(); return 0; }
int ui_table_next_row(lua_State*) { ImGui::TableNextRow(); return 0; }
int ui_table_next_column(lua_State* L) { lua_pushboolean(L, ImGui::TableNextColumn()); return 1; }
int ui_end_table(lua_State*) { ImGui::EndTable(); return 0; }

int ui_begin_tab_bar(lua_State* L) {
    lua_pushboolean(L, ImGui::BeginTabBar(luaL_checkstring(L, 1)));
    return 1;
}
int ui_begin_tab_item(lua_State* L) {
    bool open = ImGui::BeginTabItem(luaL_checkstring(L, 1));
    lua_pushboolean(L, open);
    lua_pushboolean(L, true);
    return 2;
}
int ui_end_tab_item(lua_State*) { ImGui::EndTabItem(); return 0; }
int ui_end_tab_bar(lua_State*) { ImGui::EndTabBar(); return 0; }

int ui_open_popup(lua_State* L) { ImGui::OpenPopup(luaL_checkstring(L, 1)); return 0; }
int ui_begin_popup(lua_State* L) { lua_pushboolean(L, ImGui::BeginPopup(luaL_checkstring(L, 1))); return 1; }
int ui_begin_popup_modal(lua_State* L) {
    bool open = lua_toboolean(L, 2);
    bool ok = ImGui::BeginPopupModal(luaL_checkstring(L, 1), &open);
    lua_pushboolean(L, ok);
    lua_pushboolean(L, open);
    return 2;
}
int ui_end_popup(lua_State*) { ImGui::EndPopup(); return 0; }
int ui_close_current_popup(lua_State*) { ImGui::CloseCurrentPopup(); return 0; }

int ui_toast(lua_State* L) {
    // 简化实现：直接写进控制台日志（真正的 Toast 需要 overlay 队列）
    ui::log_line(std::string("[提示] ") + luaL_checkstring(L, 1));
    return 0;
}

// 左侧标签 + 右侧彩色值的「信息行」
int ui_info_row(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    const char* value = luaL_optstring(L, 2, "");
    float r = (float)luaL_optnumber(L, 3, 1.0);
    float g = (float)luaL_optnumber(L, 4, 1.0);
    float b = (float)luaL_optnumber(L, 5, 1.0);
    ImGui::TextDisabled("%s", label);
    ImGui::SameLine(150);
    ImGui::TextColored(ImVec4(r, g, b, 1.0f), "%s", value);
    return 0;
}

// 胶囊样式的开关
int ui_chip(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    bool active = lua_toboolean(L, 2);
    ImGui::PushStyleColor(ImGuiCol_Button,
        active ? ImVec4(0.26f, 0.59f, 0.98f, 1.0f) : ImVec4(0.20f, 0.20f, 0.24f, 1.0f));
    bool pressed = ImGui::Button(label, ImVec2(0, 28));
    ImGui::PopStyleColor();
    lua_pushboolean(L, pressed ? !active : active);
    return 1;
}

int native_hook(lua_State* L) {
    ModState* ms = state_of(L);
    auto* lm = static_cast<LuaMethod*>(luaL_checkudata(L, 1, MT_METHOD));
    if (!lm || !lm->m) { mod_log(ms, "Hook：第一个参数不是有效方法"); lua_pushnil(L); return 1; }

    const char* why = nullptr;
    if (!luahook::signature_supported(lm->m, &why)) {
        mod_log(ms, std::string("Hook 被拒绝：") + (why ? why : "签名不支持"));
        lua_pushnil(L);
        return 1;
    }

    luahook::Spec spec;
    spec.is_static = il2::method_is_static(lm->m);
    spec.original = il2::method_pointer(lm->m);
    if (!spec.original) { mod_log(ms, "Hook 被拒绝：拿不到原函数地址"); lua_pushnil(L); return 1; }

    if (lua_isfunction(L, 2)) {
        spec.mode = 0;
        lua_pushvalue(L, 2);
        spec.ref_fn = luaL_ref(L, LUA_REGISTRYINDEX);
    } else if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "mode");
        const char* mode = lua_isstring(L, -1) ? lua_tostring(L, -1) : nullptr;
        spec.mode = (mode && strcmp(mode, "prepost") == 0) ? 1 : 0;
        lua_pop(L, 1);
        auto grab = [&](const char* key) -> int {
            lua_getfield(L, 2, key);
            int r = 0;
            if (lua_isfunction(L, -1)) r = luaL_ref(L, LUA_REGISTRYINDEX);
            else lua_pop(L, 1);
            return r;
        };
        spec.ref_fn = grab("fn");
        spec.ref_prefix = grab("prefix");
        spec.ref_postfix = grab("postfix");
    } else {
        mod_log(ms, "Hook：第二个参数既不是函数也不是表");
        lua_pushnil(L);
        return 1;
    }

    int handle = luahook::install(lm->m, L, spec);
    if (handle < 0) { lua_pushnil(L); return 1; }

    lua_newtable(L);
    lua_pushinteger(L, handle);
    lua_setfield(L, -2, "slot");
    lua_pushinteger(L, handle);
    lua_pushcclosure(L, [](lua_State* L2) -> int {
        int h = (int)lua_tointeger(L2, lua_upvalueindex(1));
        luahook::remove_handle(h, L2);
        return 0;
    }, 1);
    lua_setfield(L, -2, "remove");
    return 1;
}

// ---------------------------------------------------------------------------
// Native：按名反射
// ---------------------------------------------------------------------------
const char* MT_CLASS = "mm.NativeClass";
const char* MT_FIELD = "mm.NativeField";
const char* MT_OBJECT = "mm.NativeObject";

struct LuaClass { il2::Class* k; };
struct LuaField { il2::Field* f; };
struct LuaObject { uint32_t handle; };   // gchandle，防 GC 回收

il2::Class* check_class(lua_State* L, int idx) {
    auto* c = static_cast<LuaClass*>(luaL_testudata(L, idx, MT_CLASS));
    return c ? c->k : nullptr;
}

il2::Object* to_object(lua_State* L, int idx) {
    if (lua_isnil(L, idx)) return nullptr;
    auto* o = static_cast<LuaObject*>(luaL_testudata(L, idx, MT_OBJECT));
    if (!o || !o->handle) return nullptr;
    return il2::gchandle_get_target(o->handle);
}

// 把托管对象压成 Lua userdata（null -> nil）
void push_object(lua_State* L, il2::Object* obj) {
    if (!obj) { lua_pushnil(L); return; }
    auto* o = static_cast<LuaObject*>(lua_newuserdatauv(L, sizeof(LuaObject), 0));
    o->handle = il2::gchandle_new(obj, false);
    luaL_setmetatable(L, MT_OBJECT);
}

int object_gc(lua_State* L) {
    auto* o = static_cast<LuaObject*>(luaL_checkudata(L, 1, MT_OBJECT));
    if (o->handle) { il2::gchandle_free(o->handle); o->handle = 0; }
    return 0;
}

int object_tostring(lua_State* L) {
    il2::Object* o = to_object(L, 1);
    if (!o) { lua_pushliteral(L, "nil"); return 1; }
    il2::Class* k = il2::object_get_class(o);
    lua_pushfstring(L, "NativeObject<%s>",
                    k && il2::class_get_name(k) ? il2::class_get_name(k) : "?");
    return 1;
}

int object_invoke(lua_State* L);

int object_index(lua_State* L) {
    const char* key = lua_tostring(L, 2);
    if (key && strcmp(key, "invoke") == 0) { lua_pushcfunction(L, object_invoke); return 1; }
    lua_pushnil(L);
    return 1;
}

// ---- 方法调用 -------------------------------------------------------------
struct ArgSlot { alignas(16) unsigned char buf[16]; };

void marshal_arg(lua_State* L, int idx, il2::Type* t, ArgSlot& slot, void** out,
                 std::vector<uint32_t>* keep) {
    int tt = t ? il2::type_get_type(t) : T_OBJECT;
    memset(slot.buf, 0, sizeof(slot.buf));
    switch (tt) {
        case T_BOOLEAN: { bool v = lua_toboolean(L, idx) != 0; memcpy(slot.buf, &v, 1); break; }
        case T_I1: case T_U1: { int8_t v = (int8_t)lua_tointeger(L, idx); memcpy(slot.buf, &v, 1); break; }
        case T_I2: case T_U2: { int16_t v = (int16_t)lua_tointeger(L, idx); memcpy(slot.buf, &v, 2); break; }
        case T_I4: case T_U4: { int32_t v = (int32_t)lua_tointeger(L, idx); memcpy(slot.buf, &v, 4); break; }
        case T_I8: case T_U8: { int64_t v = (int64_t)lua_tointeger(L, idx); memcpy(slot.buf, &v, 8); break; }
        case T_R4: { float v = (float)lua_tonumber(L, idx); memcpy(slot.buf, &v, 4); break; }
        case T_R8: { double v = lua_tonumber(L, idx); memcpy(slot.buf, &v, 8); break; }
        case T_STRING: {
            const char* s = lua_tostring(L, idx);
            il2::String* str = s ? il2::string_new(s) : nullptr;
            // 托管字符串必须挂 GC 句柄，否则 invoke 期间可能被回收
            if (str && keep) keep->push_back(il2::gchandle_new(str, false));
            memcpy(slot.buf, &str, sizeof(str));
            break;
        }
        default: {
            il2::Object* o = to_object(L, idx);
            memcpy(slot.buf, &o, sizeof(o));
            break;
        }
    }
    *out = slot.buf;
}

void push_return(lua_State* L, il2::Type* rt, il2::Object* ret) {
    if (!ret) { lua_pushnil(L); return; }
    int tt = rt ? il2::type_get_type(rt) : T_OBJECT;
    if (tt == T_STRING) {
        lua_pushstring(L, il2::to_utf8(reinterpret_cast<il2::String*>(ret)).c_str());
        return;
    }
    if (tt == T_BOOLEAN || tt == T_I1 || tt == T_U1 || tt == T_I2 || tt == T_U2 ||
        tt == T_I4 || tt == T_U4 || tt == T_I8 || tt == T_U8 ||
        tt == T_R4 || tt == T_R8 || tt == T_CHAR || tt == T_VALUETYPE) {
        void* p = il2::object_unbox(ret);
        if (!p) { push_object(L, ret); return; }
        switch (tt) {
            case T_BOOLEAN: lua_pushboolean(L, *reinterpret_cast<uint8_t*>(p) != 0); return;
            case T_R4: lua_pushnumber(L, *reinterpret_cast<float*>(p)); return;
            case T_R8: lua_pushnumber(L, *reinterpret_cast<double*>(p)); return;
            case T_I8: case T_U8: lua_pushinteger(L, *reinterpret_cast<int64_t*>(p)); return;
            case T_VALUETYPE: lua_pushinteger(L, *reinterpret_cast<int32_t*>(p)); return;
            default: lua_pushinteger(L, *reinterpret_cast<int32_t*>(p)); return;
        }
    }
    push_object(L, ret);
}

// 真正执行一次方法：lua 栈 [1]=method, [2]=obj(可空), [3..]=参数
int do_invoke(lua_State* L) {
    ModState* ms = state_of(L);
    auto* lm = static_cast<LuaMethod*>(luaL_checkudata(L, 1, MT_METHOD));
    if (!lm->m || !il2::ready()) { mod_log(ms, "invoke: IL2CPP 未就绪"); lua_pushnil(L); return 1; }

    bool is_static = il2::method_is_static(lm->m);
    il2::Object* self = nullptr;
    int first_arg = 2;
    if (!is_static) {
        self = to_object(L, 2);
        if (!self) { mod_log(ms, "invoke: 实例方法但第一个参数不是对象"); lua_pushnil(L); return 1; }
        first_arg = 3;
    }

    uint32_t argc = il2::method_get_param_count(lm->m);
    std::vector<ArgSlot> slots(argc ? argc : 1);
    std::vector<void*> args(argc ? argc : 1, nullptr);
    std::vector<uint32_t> keep;
    for (uint32_t i = 0; i < argc; ++i) {
        il2::Type* t = il2::method_get_param(lm->m, i);
        marshal_arg(L, first_arg + (int)i, t, slots[i], &args[i], &keep);
    }

    void* exc = nullptr;
    il2::Object* ret = il2::runtime_invoke(lm->m, self, args.data(), &exc);
    for (uint32_t h : keep) il2::gchandle_free(h);
    if (exc) { mod_log(ms, "invoke: 托管侧抛异常"); lua_pushnil(L); return 1; }
    push_return(L, il2::method_get_return_type(lm->m), ret);
    return 1;
}

int method_gc(lua_State*) { return 0; }

int method_index(lua_State* L) {
    const char* key = lua_tostring(L, 2);
    auto* lm = static_cast<LuaMethod*>(luaL_checkudata(L, 1, MT_METHOD));
    if (!key) { lua_pushnil(L); return 1; }
    if (strcmp(key, "invoke") == 0) { lua_pushcfunction(L, do_invoke); return 1; }
    if (strcmp(key, "name") == 0) {
        lua_pushcfunction(L, [](lua_State* L2) {
            auto* m = static_cast<LuaMethod*>(luaL_checkudata(L2, 1, MT_METHOD));
            lua_pushstring(L2, il2::method_get_name(m->m));
            return 1;
        });
        return 1;
    }
    if (strcmp(key, "paramCount") == 0) {
        lua_pushcfunction(L, [](lua_State* L2) {
            auto* m = static_cast<LuaMethod*>(luaL_checkudata(L2, 1, MT_METHOD));
            lua_pushinteger(L2, il2::method_get_param_count(m->m));
            return 1;
        });
        return 1;
    }
    lua_pushnil(L);
    return 1;
}

// ---- 字段 -----------------------------------------------------------------
int field_call(lua_State* L) {          // f(obj) 等价 f:get(obj)
    auto* lf = static_cast<LuaField*>(luaL_checkudata(L, 1, MT_FIELD));
    if (!lf->f) { lua_pushnil(L); return 1; }
    il2::Class* k = nullptr;
    il2::Object* obj = to_object(L, 2);
    if (obj) k = il2::object_get_class(obj);
    if (!obj) {                       // 静态字段
        // 先按 4 字节整数返回（最常见），失败则原样返回 8 字节
        uint64_t raw = 0;
        il2::field_static_get_value(lf->f, &raw);
        lua_pushinteger(L, (lua_Integer)raw);
        return 1;
    }
    (void)k;
    uint64_t raw = 0;
    il2::field_get_value(obj, lf->f, &raw);
    lua_pushinteger(L, (lua_Integer)raw);
    return 1;
}

int field_index(lua_State* L) {
    const char* key = lua_tostring(L, 2);
    if (!key) { lua_pushnil(L); return 1; }
    if (strcmp(key, "get") == 0) { lua_pushcfunction(L, field_call); return 1; }
    if (strcmp(key, "set") == 0) {
        lua_pushcfunction(L, [](lua_State* L2) {
            auto* lf = static_cast<LuaField*>(luaL_checkudata(L2, 1, MT_FIELD));
            il2::Object* obj = to_object(L2, 2);
            int vidx = obj ? 3 : 2;
            int64_t v = (int64_t)luaL_checkinteger(L2, vidx);
            if (obj) il2::field_set_value(obj, lf->f, &v);
            else il2::field_static_set_value(lf->f, &v);
            return 0;
        });
        return 1;
    }
    if (strcmp(key, "name") == 0) {
        lua_pushcfunction(L, [](lua_State* L2) {
            auto* lf = static_cast<LuaField*>(luaL_checkudata(L2, 1, MT_FIELD));
            const char* nm = lf->f ? il2::field_get_name(lf->f) : nullptr;
            lua_pushstring(L2, nm ? nm : "?");
            return 1;
        });
        return 1;
    }
    lua_pushnil(L);
    return 1;
}

int field_gc(lua_State*) { return 0; }

// ---- 类 -------------------------------------------------------------------
int class_method(lua_State* L) {
    il2::Class* k = check_class(L, 1);
    const char* name = luaL_checkstring(L, 2);
    int argc = (int)luaL_optinteger(L, 3, -1);
    if (!k) { lua_pushnil(L); return 1; }
    il2::Method* m = il2::class_get_method_from_name(k, name, argc);
    if (!m) { lua_pushnil(L); return 1; }
    auto* lm = static_cast<LuaMethod*>(lua_newuserdatauv(L, sizeof(LuaMethod), 0));
    lm->m = m;
    luaL_setmetatable(L, MT_METHOD);
    return 1;
}

int class_field(lua_State* L) {
    il2::Class* k = check_class(L, 1);
    const char* name = luaL_checkstring(L, 2);
    if (!k) { lua_pushnil(L); return 1; }
    il2::Field* f = il2::class_get_field_from_name(k, name);
    if (!f) { lua_pushnil(L); return 1; }
    auto* lf = static_cast<LuaField*>(lua_newuserdatauv(L, sizeof(LuaField), 0));
    lf->f = f;
    luaL_setmetatable(L, MT_FIELD);
    return 1;
}

int class_new(lua_State* L) {
    il2::Class* k = check_class(L, 1);
    if (!k) { lua_pushnil(L); return 1; }
    il2::Object* o = il2::object_new(k);
    push_object(L, o);
    return 1;
}

int class_index(lua_State* L) {
    const char* key = lua_tostring(L, 2);
    if (!key) { lua_pushnil(L); return 1; }
    if (strcmp(key, "method") == 0) { lua_pushcfunction(L, class_method); return 1; }
    if (strcmp(key, "field") == 0) { lua_pushcfunction(L, class_field); return 1; }
    if (strcmp(key, "new") == 0) { lua_pushcfunction(L, class_new); return 1; }
    if (strcmp(key, "name") == 0) {
        lua_pushcfunction(L, [](lua_State* L2) {
            il2::Class* k = check_class(L2, 1);
            const char* nm = k ? il2::class_get_name(k) : nullptr;
            lua_pushstring(L2, nm ? nm : "?");
            return 1;
        });
        return 1;
    }
    if (strcmp(key, "fullName") == 0) {
        lua_pushcfunction(L, [](lua_State* L2) {
            il2::Class* k = check_class(L2, 1);
            const char* ns = k ? il2::class_get_namespace(k) : nullptr;
            const char* nm = k ? il2::class_get_name(k) : nullptr;
            lua_pushfstring(L2, "%s.%s", ns ? ns : "", nm ? nm : "?");
            return 1;
        });
        return 1;
    }
    if (strcmp(key, "parent") == 0) {
        il2::Class* k = check_class(L, 1);
        il2::Class* p = k ? il2::class_get_parent(k) : nullptr;
        if (!p) { lua_pushnil(L); return 1; }
        auto* lc = static_cast<LuaClass*>(lua_newuserdatauv(L, sizeof(LuaClass), 0));
        lc->k = p;
        luaL_setmetatable(L, MT_CLASS);
        return 1;
    }
    lua_pushnil(L);
    return 1;
}

int class_tostring(lua_State* L) {
    il2::Class* k = check_class(L, 1);
    lua_pushfstring(L, "NativeClass<%s>", k && il2::class_get_name(k) ? il2::class_get_name(k) : "?");
    return 1;
}

int native_class(lua_State* L) {
    const char* ns = nullptr;
    const char* name = nullptr;
    if (lua_gettop(L) >= 2) {
        ns = luaL_checkstring(L, 1);
        name = luaL_checkstring(L, 2);
    } else {
        const char* full = luaL_checkstring(L, 1);
        static thread_local std::string nsbuf, namebuf;
        nsbuf.clear(); namebuf.clear();
        const char* dot = strrchr(full, '.');
        if (dot) { nsbuf.assign(full, dot - full); namebuf = dot + 1; }
        else { namebuf = full; }
        ns = nsbuf.c_str(); name = namebuf.c_str();
    }
    if (!il2::ready()) { lua_pushnil(L); return 1; }

    il2::Domain* d = il2::domain_get();
    il2::Assembly* asm_ = il2::domain_assembly_open(d, "Assembly-CSharp");
    il2::Image* img = asm_ ? il2::assembly_get_image(asm_) : nullptr;
    il2::Class* k = img ? il2::class_from_name(img, ns, name) : nullptr;
    if (!k) { lua_pushnil(L); return 1; }

    auto* lc = static_cast<LuaClass*>(lua_newuserdatauv(L, sizeof(LuaClass), 0));
    lc->k = k;
    luaL_setmetatable(L, MT_CLASS);
    return 1;
}

int object_invoke(lua_State* L) {
    // obj:invoke("Name", ...) -> 先找方法再调
    il2::Object* o = to_object(L, 1);
    const char* name = luaL_checkstring(L, 2);
    if (!o) { lua_pushnil(L); return 1; }
    il2::Class* k = il2::object_get_class(o);
    int argc = lua_gettop(L) - 2;
    il2::Method* m = il2::class_get_method_from_name(k, name, argc);
    if (!m) { lua_pushnil(L); return 1; }
    lua_pushvalue(L, 1);                     // self
    for (int i = 0; i < argc; ++i) lua_pushvalue(L, 3 + i);
    // 复用 do_invoke 的封送逻辑：手动来一遍
    std::vector<ArgSlot> slots(argc ? argc : 1);
    std::vector<void*> args(argc ? argc : 1, nullptr);
    std::vector<uint32_t> keep;
    for (int i = 0; i < argc; ++i) {
        marshal_arg(L, 3 + i, il2::method_get_param(m, (uint32_t)i), slots[i], &args[i], &keep);
    }
    void* exc = nullptr;
    il2::Object* ret = il2::runtime_invoke(m, o, args.data(), &exc);
    for (uint32_t h : keep) il2::gchandle_free(h);
    if (exc) { lua_pushnil(L); return 1; }
    push_return(L, il2::method_get_return_type(m), ret);
    return 1;
}

// ---- Native.UI ------------------------------------------------------------
int native_ui(lua_State* L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_pushvalue(L, 1);
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);
    ModState* ms = state_of(L);
    std::string name = ms ? ms->name : "mod";

    lua_State* co = L;
    ui::add_panel(name, [co, ref, ms]() {
        lua_rawgeti(co, LUA_REGISTRYINDEX, ref);
        if (lua_pcall(co, 0, 0, 0) != LUA_OK) {
            mod_log(ms, std::string("UI 面板出错: ") + lua_tostring(co, -1));
            lua_pop(co, 1);
        }
    });
    if (ms) ms->panel_refs++;
    return 0;
}

// ---------------------------------------------------------------------------
void register_api(lua_State* L) {
    // Log / print
    lua_pushcfunction(L, l_log);  lua_setglobal(L, "Log");
    lua_pushcfunction(L, l_log);  lua_setglobal(L, "print");
    lua_pushcfunction(L, l_log);  lua_setglobal(L, "LogInfo");
    lua_pushcfunction(L, l_log);  lua_setglobal(L, "LogError");

    // require
    lua_pushcfunction(L, l_require); lua_setglobal(L, "require");
    lua_pushliteral(L, "mm_loaded");
    lua_newtable(L);
    lua_rawset(L, LUA_REGISTRYINDEX);

    // LUA_VERSION
    lua_pushstring(L, LUA_VERSION_MAJOR "." LUA_VERSION_MINOR "." LUA_VERSION_RELEASE);
    lua_setglobal(L, "LUA_VERSION");

    // LogLevel / LogSink（占位，阶段 4 细化）
    lua_newtable(L);
    lua_pushinteger(L, 0x1); lua_setfield(L, -2, "Info");
    lua_pushinteger(L, 0x4); lua_setfield(L, -2, "Warn");
    lua_pushinteger(L, 0x8); lua_setfield(L, -2, "Error");
    lua_setglobal(L, "LogLevel");
    lua_newtable(L);
    lua_pushinteger(L, 0x100); lua_setfield(L, -2, "Console");
    lua_pushinteger(L, 0x200); lua_setfield(L, -2, "File");
    lua_setglobal(L, "LogSink");

    // Runtime
    lua_newtable(L);
    lua_pushcfunction(L, l_spawn); lua_setfield(L, -2, "Spawn");
    lua_pushcfunction(L, l_wait);  lua_setfield(L, -2, "Wait");
    lua_pushcfunction(L, l_yield); lua_setfield(L, -2, "Yield");
    lua_pushcfunction(L, l_now);   lua_setfield(L, -2, "Now");
    lua_pushcfunction(L, l_log);   lua_setfield(L, -2, "Log");
    lua_pushcfunction(L, [](lua_State* L2) {
        auto* ms = state_of(L2);
        if (ms) mod_log(ms, std::string("面包屑: ") + luaL_optstring(L2, 1, ""));
        return 0;
    });
    lua_setfield(L, -2, "Breadcrumb");
    lua_pushcfunction(L, [](lua_State* L2) { lua_pushboolean(L2, 1); return 1; });
    lua_setfield(L, -2, "IsMainThread");
    lua_setglobal(L, "Runtime");

    // UI
    lua_newtable(L);
    lua_pushcfunction(L, ui_text);        lua_setfield(L, -2, "Text");
    lua_pushcfunction(L, ui_text_colored);lua_setfield(L, -2, "TextColored");
    lua_pushcfunction(L, ui_separator);   lua_setfield(L, -2, "Separator");
    lua_pushcfunction(L, ui_same_line);   lua_setfield(L, -2, "SameLine");
    lua_pushcfunction(L, ui_spacing);     lua_setfield(L, -2, "Spacing");
    lua_pushcfunction(L, ui_button);      lua_setfield(L, -2, "Button");
    lua_pushcfunction(L, ui_checkbox);    lua_setfield(L, -2, "Checkbox");
    lua_pushcfunction(L, ui_checkbox);    lua_setfield(L, -2, "Toggle");
    lua_pushcfunction(L, ui_slider_int);  lua_setfield(L, -2, "SliderInt");
    lua_pushcfunction(L, ui_slider_float);lua_setfield(L, -2, "SliderFloat");
    lua_pushcfunction(L, ui_tooltip);     lua_setfield(L, -2, "SetTooltip");
    lua_pushcfunction(L, ui_bullet);      lua_setfield(L, -2, "BulletText");
    lua_pushcfunction(L, ui_text_wrapped);lua_setfield(L, -2, "TextWrapped");
    lua_pushcfunction(L, ui_text_disabled);lua_setfield(L, -2, "TextDisabled");
    lua_pushcfunction(L, ui_label_text);  lua_setfield(L, -2, "LabelText");
    lua_pushcfunction(L, ui_separator_text);lua_setfield(L, -2, "SeparatorText");
    lua_pushcfunction(L, ui_newline);     lua_setfield(L, -2, "NewLine");
    lua_pushcfunction(L, ui_indent);      lua_setfield(L, -2, "Indent");
    lua_pushcfunction(L, ui_unindent);    lua_setfield(L, -2, "Unindent");
    lua_pushcfunction(L, ui_dummy);       lua_setfield(L, -2, "Dummy");
    lua_pushcfunction(L, ui_set_next_item_width); lua_setfield(L, -2, "SetNextItemWidth");
    lua_pushcfunction(L, ui_push_id);     lua_setfield(L, -2, "PushID");
    lua_pushcfunction(L, ui_pop_id);      lua_setfield(L, -2, "PopID");
    lua_pushcfunction(L, ui_begin_group); lua_setfield(L, -2, "BeginGroup");
    lua_pushcfunction(L, ui_end_group);   lua_setfield(L, -2, "EndGroup");
    lua_pushcfunction(L, ui_small_button);lua_setfield(L, -2, "SmallButton");
    lua_pushcfunction(L, ui_progress_bar);lua_setfield(L, -2, "ProgressBar");
    lua_pushcfunction(L, ui_is_item_hovered); lua_setfield(L, -2, "IsItemHovered");
    lua_pushcfunction(L, ui_is_item_clicked); lua_setfield(L, -2, "IsItemClicked");
    lua_pushcfunction(L, ui_input_text);  lua_setfield(L, -2, "InputText");
    lua_pushcfunction(L, ui_input_text_hint); lua_setfield(L, -2, "InputTextWithHint");
    lua_pushcfunction(L, ui_input_int);   lua_setfield(L, -2, "InputInt");
    lua_pushcfunction(L, ui_drag_int);    lua_setfield(L, -2, "DragInt");
    lua_pushcfunction(L, ui_drag_float);  lua_setfield(L, -2, "DragFloat");
    lua_pushcfunction(L, ui_checkbox_flags); lua_setfield(L, -2, "CheckboxFlags");
    lua_pushcfunction(L, ui_color_edit3); lua_setfield(L, -2, "ColorEdit3");
    lua_pushcfunction(L, ui_color_swatch);lua_setfield(L, -2, "ColorSwatch");
    lua_pushcfunction(L, ui_combo);       lua_setfield(L, -2, "Combo");
    lua_pushcfunction(L, ui_radio_button);lua_setfield(L, -2, "RadioButton");
    lua_pushcfunction(L, ui_selectable);  lua_setfield(L, -2, "Selectable");
    lua_pushcfunction(L, ui_tree_node);   lua_setfield(L, -2, "TreeNode");
    lua_pushcfunction(L, ui_tree_pop);    lua_setfield(L, -2, "TreePop");
    lua_pushcfunction(L, ui_collapsing_header); lua_setfield(L, -2, "CollapsingHeader");
    lua_pushcfunction(L, ui_begin_child); lua_setfield(L, -2, "BeginChild");
    lua_pushcfunction(L, ui_end_child);   lua_setfield(L, -2, "EndChild");
    lua_pushcfunction(L, ui_begin_table); lua_setfield(L, -2, "BeginTable");
    lua_pushcfunction(L, ui_table_setup_column); lua_setfield(L, -2, "TableSetupColumn");
    lua_pushcfunction(L, ui_table_headers_row); lua_setfield(L, -2, "TableHeadersRow");
    lua_pushcfunction(L, ui_table_next_row); lua_setfield(L, -2, "TableNextRow");
    lua_pushcfunction(L, ui_table_next_column); lua_setfield(L, -2, "TableNextColumn");
    lua_pushcfunction(L, ui_end_table);   lua_setfield(L, -2, "EndTable");
    lua_pushcfunction(L, ui_begin_tab_bar); lua_setfield(L, -2, "BeginTabBar");
    lua_pushcfunction(L, ui_begin_tab_item); lua_setfield(L, -2, "BeginTabItem");
    lua_pushcfunction(L, ui_end_tab_item);lua_setfield(L, -2, "EndTabItem");
    lua_pushcfunction(L, ui_end_tab_bar); lua_setfield(L, -2, "EndTabBar");
    lua_pushcfunction(L, ui_open_popup);  lua_setfield(L, -2, "OpenPopup");
    lua_pushcfunction(L, ui_begin_popup); lua_setfield(L, -2, "BeginPopup");
    lua_pushcfunction(L, ui_begin_popup_modal); lua_setfield(L, -2, "BeginPopupModal");
    lua_pushcfunction(L, ui_end_popup);   lua_setfield(L, -2, "EndPopup");
    lua_pushcfunction(L, ui_close_current_popup); lua_setfield(L, -2, "CloseCurrentPopup");
    lua_pushcfunction(L, ui_toast);       lua_setfield(L, -2, "Toast");
    lua_pushcfunction(L, ui_info_row);    lua_setfield(L, -2, "InfoRow");
    lua_pushcfunction(L, ui_chip);        lua_setfield(L, -2, "Chip");

    // UI.Flags：常用 ImGui 位标志
    lua_newtable(L);
    lua_newtable(L);
    lua_pushinteger(L, ImGuiTableFlags_Borders);            lua_setfield(L, -2, "Borders");
    lua_pushinteger(L, ImGuiTableFlags_RowBg);              lua_setfield(L, -2, "RowBg");
    lua_pushinteger(L, ImGuiTableFlags_SizingStretchSame);  lua_setfield(L, -2, "SizingStretchSame");
    lua_setfield(L, -2, "Table");
    lua_newtable(L);
    lua_pushinteger(L, ImGuiTableColumnFlags_WidthFixed);   lua_setfield(L, -2, "WidthFixed");
    lua_setfield(L, -2, "TableColumn");
    lua_newtable(L);
    lua_pushinteger(L, ImGuiWindowFlags_NoMove);            lua_setfield(L, -2, "NoMove");
    lua_pushinteger(L, ImGuiWindowFlags_NoResize);          lua_setfield(L, -2, "NoResize");
    lua_pushinteger(L, ImGuiWindowFlags_NoTitleBar);        lua_setfield(L, -2, "NoTitleBar");
    lua_setfield(L, -2, "Window");
    lua_newtable(L);
    lua_pushinteger(L, ImGuiSelectableFlags_AllowDoubleClick); lua_setfield(L, -2, "AllowDoubleClick");
    lua_setfield(L, -2, "Selectable");
    lua_setfield(L, -2, "Flags");
    lua_setglobal(L, "UI");

    // Native
    lua_newtable(L);
    lua_pushcfunction(L, native_class); lua_setfield(L, -2, "Class");
    lua_pushcfunction(L, native_ui);    lua_setfield(L, -2, "UI");
    lua_pushcfunction(L, l_log);        lua_setfield(L, -2, "Log");
    lua_pushcfunction(L, native_hook);  lua_setfield(L, -2, "Hook");
    lua_pushcfunction(L, luahook::l_orig);   lua_setfield(L, -2, "Orig");
    lua_pushcfunction(L, luahook::l_setarg); lua_setfield(L, -2, "SetArg");
    lua_setglobal(L, "Native");

    // 元表
    luaL_newmetatable(L, MT_CLASS);
    lua_pushcfunction(L, class_index); lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, class_tostring); lua_setfield(L, -2, "__tostring");
    lua_pop(L, 1);

    luaL_newmetatable(L, MT_METHOD);
    lua_pushcfunction(L, method_index); lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, do_invoke);    lua_setfield(L, -2, "__call");
    lua_pushcfunction(L, method_gc);    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    luaL_newmetatable(L, MT_FIELD);
    lua_pushcfunction(L, field_index); lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, field_call);  lua_setfield(L, -2, "__call");
    lua_pushcfunction(L, field_gc);    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    luaL_newmetatable(L, MT_OBJECT);
    lua_pushcfunction(L, object_index);  lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, object_tostring); lua_setfield(L, -2, "__tostring");
    lua_pushcfunction(L, object_gc);     lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);
}

}  // namespace

// ---------------------------------------------------------------------------
lua_State* create_state(const std::string& mod_name, const std::string& mod_dir) {
    lua_State* L = luaL_newstate();
    if (!L) return nullptr;
    luaL_openlibs(L);

    auto* ms = static_cast<ModState*>(lua_newuserdatauv(L, sizeof(ModState), 0));
    new (ms) ModState();
    ms->name = mod_name;
    ms->dir = mod_dir;
    lua_pushliteral(L, "mm_mod");
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
    lua_pop(L, 1);

    register_api(L);
    return L;
}

void close_state(lua_State* L) {
    if (!L) return;
    luahook::release_state(L);          // 先把 Hook 还原，再关 Lua
    auto* ms = state_of(L);
    if (ms) {
        for (auto& co : ms->cos) {
            if (co.ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, co.ref);
        }
        ui::clear_panels(ms->name);
        ms->~ModState();
    }
    lua_close(L);
}

bool run_file(lua_State* L, const std::string& path, const char* what) {
    if (luaL_loadfile(L, path.c_str()) != LUA_OK) {
        mod_log(state_of(L), std::string(what) + " 加载失败: " + lua_tostring(L, -1));
        lua_pop(L, 1);
        return false;
    }
    if (lua_pcall(L, 0, LUA_MULTRET, 0) != LUA_OK) {
        mod_log(state_of(L), std::string(what) + " 执行出错: " + lua_tostring(L, -1));
        lua_pop(L, 1);
        return false;
    }
    return true;
}

bool call_global(lua_State* L, const char* fn) {
    lua_getglobal(L, fn);
    if (!lua_isfunction(L, -1)) { lua_pop(L, 1); return false; }
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        mod_log(state_of(L), std::string(fn) + " 出错: " + lua_tostring(L, -1));
        lua_pop(L, 1);
        return false;
    }
    return true;
}

void tick(lua_State* L) {
    if (!L) return;
    auto* ms = state_of(L);
    if (!ms) return;
    double now = now_seconds();
    for (size_t i = 0; i < ms->cos.size(); ++i) {
        if (!ms->cos[i].dead && ms->cos[i].wake <= now) {
            resume_coroutine(L, ms, i);
        }
    }
    // 清掉结束的
    for (auto it = ms->cos.begin(); it != ms->cos.end();) {
        if (it->dead) {
            if (it->ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, it->ref);
            it = ms->cos.erase(it);
        } else {
            ++it;
        }
    }
}

int panel_count(lua_State* L) {
    auto* ms = state_of(L);
    return ms ? ms->panel_refs : 0;
}

}  // namespace luaapi
