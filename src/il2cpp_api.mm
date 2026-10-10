//
// IL2CPP 按名解析的实现：直接解析 UnityFramework 的 Mach-O 符号表。
//
#include "il2cpp_api.hpp"

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>

#include "mm_log.hpp"

namespace il2 {
namespace {

struct ImageInfo {
    bool found = false;
    const mach_header_64* header = nullptr;
    intptr_t slide = 0;
    // __TEXT 段范围（含 slide），用于校验取到的“函数”是否真的可执行
    uintptr_t text_begin = 0;
    uintptr_t text_end = 0;
    std::string path;
};

std::mutex g_mutex;
ImageInfo g_image;
std::unordered_map<std::string, uintptr_t> g_syms;
bool g_ready = false;
std::string g_last_missing;

// 找 UnityFramework 的镜像；找不到返回 false（调用方稍后重试）
bool locate_image() {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const char* name = _dyld_get_image_name(i);
        if (!name) continue;
        if (!strstr(name, "UnityFramework")) continue;

        g_image.path = name;
        g_image.header = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(i));
        g_image.slide = _dyld_get_image_vmaddr_slide(i);
        g_image.found = g_image.header != nullptr;
        return g_image.found;
    }
    return false;
}

// 找 __TEXT 段范围
void scan_text_segment() {
    const mach_header_64* h = g_image.header;
    if (!h) return;
    const uint8_t* p = reinterpret_cast<const uint8_t*>(h) + sizeof(mach_header_64);
    for (uint32_t i = 0; i < h->ncmds; ++i) {
        const load_command* lc = reinterpret_cast<const load_command*>(p);
        if (lc->cmd == LC_SEGMENT_64) {
            const segment_command_64* seg = reinterpret_cast<const segment_command_64*>(lc);
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                g_image.text_begin = static_cast<uintptr_t>(seg->vmaddr + g_image.slide);
                g_image.text_end = g_image.text_begin + static_cast<uintptr_t>(seg->vmsize);
                return;
            }
        }
        p += lc->cmdsize;
    }
}

// 解析 LC_SYMTAB，把符号名 -> 运行时地址 收进表里
bool parse_symbols() {
    const mach_header_64* h = g_image.header;
    if (!h) return false;

    const symtab_command* symtab = nullptr;
    const uint8_t* p = reinterpret_cast<const uint8_t*>(h) + sizeof(mach_header_64);
    for (uint32_t i = 0; i < h->ncmds; ++i) {
        const load_command* lc = reinterpret_cast<const load_command*>(p);
        if (lc->cmd == LC_SYMTAB) {
            symtab = reinterpret_cast<const symtab_command*>(lc);
            break;
        }
        p += lc->cmdsize;
    }
    if (!symtab || symtab->nsyms == 0) return false;

    const char* base = reinterpret_cast<const char*>(h);
    const nlist_64* syms = reinterpret_cast<const nlist_64*>(base + symtab->symoff);
    const char* strtab = base + symtab->stroff;

    g_syms.reserve(symtab->nsyms * 2);
    for (uint32_t i = 0; i < symtab->nsyms; ++i) {
        const nlist_64& s = syms[i];
        // macOS/iOS 的 nlist_64 把 n_strx 放在 union 里，必须写 n_un.n_strx
        if (s.n_un.n_strx == 0 || s.n_value == 0) continue;
        // 只收本段内定义、且不是未定义/调试类的符号
        if ((s.n_type & N_TYPE) != N_SECT) continue;

        const char* raw = strtab + s.n_un.n_strx;
        if (raw[0] == '\0') continue;

        // 去掉 Mach-O 的前导下划线：_il2cpp_class_from_name -> il2cpp_class_from_name
        std::string name = raw[0] == '_' ? std::string(raw + 1) : std::string(raw);
        uintptr_t addr = static_cast<uintptr_t>(s.n_value) + static_cast<uintptr_t>(g_image.slide);

        // 同名先到先得（符号表里一般不会重复）
        g_syms.emplace(std::move(name), addr);
    }
    return !g_syms.empty();
}

inline bool in_text(uintptr_t a) {
    return g_image.text_begin && a >= g_image.text_begin && a < g_image.text_end;
}

// 判断一段地址是不是“可调用的函数入口”：
//   · 是一段 ARM64 跳转桩（B/BL）—— Unity 把 il2cpp API 做成 8 字节 thunk
//   · 或者首 8 字节是指向 __TEXT 的指针（另一种布局）
uintptr_t make_callable(uintptr_t addr) {
    if (!addr) return 0;

    // 1) 直接就是跳转桩
    if (in_text(addr)) {
        uint32_t insn = *reinterpret_cast<const uint32_t*>(addr);
        // B  : 000101 imm26
        // BL : 100101 imm26
        if ((insn & 0x7C000000u) == 0x14000000u) return addr;
    }

    // 2) 是个指针变量，指向 __TEXT
    uintptr_t deref = *reinterpret_cast<const uintptr_t*>(addr);
    if (in_text(deref)) return deref;

    // 3) 兜底：地址本身在 __TEXT 里，直接用
    if (in_text(addr)) return addr;

    return 0;
}

}  // namespace

bool init() {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_ready) return true;
    if (!g_image.found && !locate_image()) return false;

    scan_text_segment();
    if (!parse_symbols()) return false;

    g_ready = true;
    mm::logf("IL2CPP 符号表已解析：%zu 个符号，镜像=%s", g_syms.size(), g_image.path.c_str());
    return true;
}

bool ready() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_ready;
}

int symbol_count() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return static_cast<int>(g_syms.size());
}

const char* last_missing() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_last_missing.c_str();
}

std::string images_report() {
    std::string out;
    uint32_t count = _dyld_image_count();
    out += "dyld 镜像共 " + std::to_string(count) + " 个";
    if (g_image.found) {
        out += "；UnityFramework = " + g_image.path;
    } else {
        out += "；没找到含 'UnityFramework' 的镜像。前几个镜像是：";
        for (uint32_t i = 0; i < count && i < 12; ++i) {
            const char* n = _dyld_get_image_name(i);
            if (!n) continue;
            const char* slash = strrchr(n, '/');
            out += " [";
            out += slash ? slash + 1 : n;
            out += "]";
        }
    }
    return out;
}

void* api(const char* name) {
    if (!name) return nullptr;
    if (!ready()) {
        if (!init()) return nullptr;
    }

    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_syms.find(name);
    if (it == g_syms.end()) {
        g_last_missing = name;
        return nullptr;
    }
    uintptr_t fn = make_callable(it->second);
    if (!fn) {
        g_last_missing = std::string(name) + " (地址不可执行)";
        return nullptr;
    }
    return reinterpret_cast<void*>(fn);
}

std::string to_utf8(String* s) {
    if (!s) return {};
    const int32_t len = string_length(s);
    const uint16_t* chars = string_chars(s);
    if (len <= 0 || !chars) return {};

    // UTF-16 -> UTF-8
    std::string out;
    out.reserve(static_cast<size_t>(len) * 3);
    for (int32_t i = 0; i < len; ++i) {
        uint32_t cp = chars[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < len) {
            uint32_t lo = chars[i + 1];
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                ++i;
            }
        }
        if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }
    return out;
}

void* method_pointer(Method* m) {
    if (!m || !ready()) return nullptr;
    // 通用版：MethodInfo 的首字段长期都是 methodPointer；
    // 读出来后必须落在 UnityFramework 的 __TEXT 里，否则认为布局不符。
    for (size_t off : {size_t(0), size_t(8)}) {
        uintptr_t v = *reinterpret_cast<const uintptr_t*>(reinterpret_cast<const char*>(m) + off);
        if (in_text(v)) return reinterpret_cast<void*>(v);
    }
    return nullptr;
}

}  // namespace il2
