#pragma once
//
// IL2CPP API 的“按名字解析”层（通用版核心）
// ---------------------------------------------------------------
// 这套 iOS 包没有把 il2cpp_* 导出到 dyld 导出表，dlsym() 拿不到；
// 但 UnityFramework 的 Mach-O 符号表**没被剥离**，所以我们自己解析
// LC_SYMTAB，按名字找到那些 8 字节跳转桩，再验证它确实可执行。
//
// 全程不依赖任何硬编码偏移 —— 游戏更新后符号名不变就照常能用。
//

#include <cstddef>
#include <cstdint>
#include <string>

namespace il2 {

using Domain   = void;
using Assembly = void;
using Image    = void;
using Class    = void;
using Method   = void;
using Field    = void;
using Property = void;
using Object   = void;
using String   = void;
using Array    = void;
using Type     = void;

// 初始化：定位 UnityFramework 镜像并解析符号表。成功返回 true（幂等）。
bool init();

// 是否已就绪
bool ready();

// 按名字取一个 il2cpp 函数的可调用地址；找不到返回 nullptr。
void* api(const char* name);

// 诊断：已解析到的符号数量
int symbol_count();

// 诊断：已加载镜像的简报（排查“找不到 UnityFramework”用）
std::string images_report();

// 取“按名字解析失败的符号”列表（便于排查）
const char* last_missing();

// ---------------------------------------------------------------------------
// 便捷包装（懒加载；符号缺失时安全返回空值）
// ---------------------------------------------------------------------------

#define IL2_WRAP(ret, cname, symbol, params, args)                    \
    inline ret cname params {                                          \
        using F = ret (*) params;                                      \
        static F mm_resolved = reinterpret_cast<F>(api(symbol));       \
        return mm_resolved ? mm_resolved args : (ret)0;                \
    }

// 域 / 线程
IL2_WRAP(Domain*, domain_get, "il2cpp_domain_get", (), ())
IL2_WRAP(void*,   thread_attach, "il2cpp_thread_attach", (Domain* d), (d))

// 程序集 / 镜像
IL2_WRAP(Assembly*, domain_assembly_open, "il2cpp_domain_assembly_open",
         (Domain* d, const char* name), (d, name))
IL2_WRAP(Image*, assembly_get_image, "il2cpp_assembly_get_image", (Assembly* a), (a))
IL2_WRAP(const char*, image_get_name, "il2cpp_image_get_name", (Image* i), (i))

// 类
IL2_WRAP(Class*, class_from_name, "il2cpp_class_from_name",
         (Image* i, const char* ns, const char* name), (i, ns, name))
IL2_WRAP(const char*, class_get_name, "il2cpp_class_get_name", (Class* k), (k))
IL2_WRAP(const char*, class_get_namespace, "il2cpp_class_get_namespace", (Class* k), (k))
IL2_WRAP(Class*, class_get_parent, "il2cpp_class_get_parent", (Class* k), (k))
IL2_WRAP(uint32_t, class_get_flags, "il2cpp_class_get_flags", (Class* k), (k))
IL2_WRAP(bool, class_is_valuetype, "il2cpp_class_is_valuetype", (Class* k), (k))
IL2_WRAP(bool, class_is_enum, "il2cpp_class_is_enum", (Class* k), (k))
IL2_WRAP(bool, class_is_assignable_from, "il2cpp_class_is_assignable_from",
         (Class* k, Class* o), (k, o))
IL2_WRAP(Image*, class_get_image, "il2cpp_class_get_image", (Class* k), (k))

// 方法
IL2_WRAP(Method*, class_get_method_from_name, "il2cpp_class_get_method_from_name",
         (Class* k, const char* name, int argc), (k, name, argc))
IL2_WRAP(const char*, method_get_name, "il2cpp_method_get_name", (Method* m), (m))
IL2_WRAP(uint32_t, method_get_param_count, "il2cpp_method_get_param_count",
         (Method* m), (m))
IL2_WRAP(Class*, method_get_class, "il2cpp_method_get_class", (Method* m), (m))
IL2_WRAP(Type*, method_get_return_type, "il2cpp_method_get_return_type", (Method* m), (m))
// 注意：IL2CPP 没有 il2cpp_method_is_static 这个符号（实测该包里不存在），
// 正确做法是取 flags 再自己判 METHOD_ATTRIBUTE_STATIC。
IL2_WRAP(uint32_t, method_get_flags, "il2cpp_method_get_flags",
         (Method* m, uint32_t* iflags), (m, iflags))
IL2_WRAP(Object*, runtime_invoke, "il2cpp_runtime_invoke",
         (Method* m, void* obj, void** params, void** exc), (m, obj, params, exc))
IL2_WRAP(Type*, method_get_param, "il2cpp_method_get_param",
         (Method* m, uint32_t index), (m, index))

// 类型信息（参数封送要用）
IL2_WRAP(int, type_get_type, "il2cpp_type_get_type", (Type* t), (t))

// il2cpp_type_get_type 返回的 Il2CppTypeEnum（只列我们用得到的）
enum TypeKind {
    TK_END = 0x00, TK_VOID = 0x01, TK_BOOL = 0x02, TK_CHAR = 0x03,
    TK_I1 = 0x04, TK_U1 = 0x05, TK_I2 = 0x06, TK_U2 = 0x07,
    TK_I4 = 0x08, TK_U4 = 0x09, TK_I8 = 0x0A, TK_U8 = 0x0B,
    TK_R4 = 0x0C, TK_R8 = 0x0D, TK_STRING = 0x0E, TK_PTR = 0x0F,
    TK_VALUETYPE = 0x11, TK_CLASS = 0x12, TK_ARRAY = 0x14,
    TK_OBJECT = 0x1C, TK_SZARRAY = 0x1D,
};

// 给日志用：把类型枚举变成短名
inline const char* type_kind_name(int k) {
    switch (k) {
        case TK_BOOL: return "bool";
        case TK_U1:   return "u8";
        case TK_I2:   return "i16";
        case TK_I4:   return "i32";
        case TK_U4:   return "u32";
        case TK_I8:   return "i64";
        case TK_R4:   return "f32";
        case TK_R8:   return "f64";
        case TK_STRING: return "str";
        case TK_CLASS:  return "class";
        case TK_VALUETYPE: return "struct";
        case TK_SZARRAY: case TK_ARRAY: return "array";
        default: return "?";
    }
}
IL2_WRAP(const char*, type_get_name, "il2cpp_type_get_name", (Type* t), (t))
IL2_WRAP(Class*, class_get_element_class, "il2cpp_class_get_element_class", (Class* k), (k))
IL2_WRAP(int32_t, class_array_element_size, "il2cpp_class_array_element_size", (Class* k), (k))
IL2_WRAP(uint32_t, class_value_size, "il2cpp_class_value_size",
         (Class* k, uint32_t* align), (k, align))

// 字段
IL2_WRAP(Field*, class_get_field_from_name, "il2cpp_class_get_field_from_name",
         (Class* k, const char* name), (k, name))
IL2_WRAP(const char*, field_get_name, "il2cpp_field_get_name", (Field* f), (f))
IL2_WRAP(Type*, field_get_type, "il2cpp_field_get_type", (Field* f), (f))
IL2_WRAP(uint32_t, field_get_offset, "il2cpp_field_get_offset", (Field* f), (f))
IL2_WRAP(bool, field_is_static, "il2cpp_field_is_literal", (Field* f), (f))
IL2_WRAP(void, field_get_value, "il2cpp_field_get_value",
         (Object* o, Field* f, void* out), (o, f, out))
IL2_WRAP(void, field_set_value, "il2cpp_field_set_value",
         (Object* o, Field* f, void* in), (o, f, in))
IL2_WRAP(void, field_static_get_value, "il2cpp_field_static_get_value",
         (Field* f, void* out), (f, out))
IL2_WRAP(void, field_static_set_value, "il2cpp_field_static_set_value",
         (Field* f, void* in), (f, in))
IL2_WRAP(uint32_t, field_get_flags, "il2cpp_field_get_flags", (Field* f), (f))

// 遍历
IL2_WRAP(Field*, class_get_fields, "il2cpp_class_get_fields",
         (Class* k, void** iter), (k, iter))
IL2_WRAP(Method*, class_get_methods, "il2cpp_class_get_methods",
         (Class* k, void** iter), (k, iter))
IL2_WRAP(Property*, class_get_properties, "il2cpp_class_get_properties",
         (Class* k, void** iter), (k, iter))

// 属性
IL2_WRAP(Property*, class_get_property_from_name, "il2cpp_class_get_property_from_name",
         (Class* k, const char* name), (k, name))
IL2_WRAP(Method*, property_get_get_method, "il2cpp_property_get_get_method",
         (Property* p), (p))
IL2_WRAP(Method*, property_get_set_method, "il2cpp_property_get_set_method",
         (Property* p), (p))
IL2_WRAP(const char*, property_get_name, "il2cpp_property_get_name", (Property* p), (p))

// 对象 / 字符串 / 数组
IL2_WRAP(Class*, object_get_class, "il2cpp_object_get_class", (Object* o), (o))
IL2_WRAP(Object*, object_new, "il2cpp_object_new", (Class* k), (k))
IL2_WRAP(String*, string_new, "il2cpp_string_new", (const char* s), (s))
IL2_WRAP(Array*, array_new, "il2cpp_array_new", (Class* k, size_t n), (k, n))
IL2_WRAP(uint32_t, array_length, "il2cpp_array_length", (Array* a), (a))
IL2_WRAP(void*, object_unbox, "il2cpp_object_unbox", (Object* o), (o))
IL2_WRAP(void*, thread_current, "il2cpp_thread_current", (), ())

// GC 句柄：跨帧持有托管对象必须靠它，否则会被 GC 回收
IL2_WRAP(uint32_t, gchandle_new, "il2cpp_gchandle_new", (Object* o, bool pinned), (o, pinned))
IL2_WRAP(Object*, gchandle_get_target, "il2cpp_gchandle_get_target", (uint32_t h), (h))
IL2_WRAP(void, gchandle_free, "il2cpp_gchandle_free", (uint32_t h), (h))

#undef IL2_WRAP

// ---------------------------------------------------------------------------
// 运行时工具
// ---------------------------------------------------------------------------

// Il2CppString 布局是稳定的：{ object(16B) | int32 length | char16 chars[] }
// 托管方法是否 static（METHOD_ATTRIBUTE_STATIC = 0x0010）
inline bool method_is_static(Method* m) {
    if (!m) return false;
    uint32_t iflags = 0;
    return (method_get_flags(m, &iflags) & 0x0010u) != 0;
}

inline int32_t string_length(String* s) {
    return s ? *reinterpret_cast<int32_t*>(reinterpret_cast<char*>(s) + 16) : 0;
}

inline const uint16_t* string_chars(String* s) {
    return s ? reinterpret_cast<const uint16_t*>(reinterpret_cast<char*>(s) + 20) : nullptr;
}

// UTF-8 -> Il2CppString，再按 UTF-16 读回来；找不到 string_new 时返回空串。
std::string to_utf8(String* s);

// 取某个托管方法的原生代码地址（用于 Hook）。
// 通用版：读 MethodInfo 首个字段（methodPointer），并做合法性校验；
// 校验不通过时返回 nullptr（交给专用版的偏移表处理）。
void* method_pointer(Method* m);

// 把托管方法的原生代码指针改写到新函数（Hook 用）。
// 成功返回 true。实现上就是找到 method_pointer 读的那个字段再写回去。
bool set_method_pointer(Method* m, void* fn);

}  // namespace il2
