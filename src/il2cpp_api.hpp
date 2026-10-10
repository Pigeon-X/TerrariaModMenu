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

// 取“按名字解析失败的符号”列表（便于排查）
const char* last_missing();

// ---------------------------------------------------------------------------
// 便捷包装（懒加载；符号缺失时安全返回空值）
// ---------------------------------------------------------------------------

#define IL2_WRAP(ret, cname, symbol, params, args)                    \
    inline ret cname params {                                          \
        using F = ret (*) params;                                      \
        static F f = reinterpret_cast<F>(api(symbol));                 \
        return f ? f args : (ret)0;                                    \
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
IL2_WRAP(bool, method_is_static, "il2cpp_method_is_static", (Method* m), (m))
IL2_WRAP(Object*, runtime_invoke, "il2cpp_runtime_invoke",
         (Method* m, void* obj, void** params, void** exc), (m, obj, params, exc))

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

// 属性
IL2_WRAP(Property*, class_get_property_from_name, "il2cpp_class_get_property_from_name",
         (Class* k, const char* name), (k, name))
IL2_WRAP(Method*, property_get_get_method, "il2cpp_property_get_get_method",
         (Property* p), (p))
IL2_WRAP(Method*, property_get_set_method, "il2cpp_property_get_set_method",
         (Property* p), (p))

// 对象 / 字符串 / 数组
IL2_WRAP(Class*, object_get_class, "il2cpp_object_get_class", (Object* o), (o))
IL2_WRAP(Object*, object_new, "il2cpp_object_new", (Class* k), (k))
IL2_WRAP(String*, string_new, "il2cpp_string_new", (const char* s), (s))
IL2_WRAP(Array*, array_new, "il2cpp_array_new", (Class* k, size_t n), (k, n))
IL2_WRAP(uint32_t, array_length, "il2cpp_array_length", (Array* a), (a))
IL2_WRAP(void*, object_unbox, "il2cpp_object_unbox", (Object* o), (o))

#undef IL2_WRAP

// ---------------------------------------------------------------------------
// 运行时工具
// ---------------------------------------------------------------------------

// Il2CppString 布局是稳定的：{ object(16B) | int32 length | char16 chars[] }
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

}  // namespace il2
