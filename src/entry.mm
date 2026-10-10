//
// 入口：等 UnityFramework 起来 -> 解析 IL2CPP API -> 自检 -> （后续）装渲染钩子、
//       启动 Lua 宿主与 Mod 加载器。
//
#include <unistd.h>

#import <Foundation/Foundation.h>

#include "il2cpp_api.hpp"
#include "mm_log.hpp"
#include "mods/mod_loader.hpp"
#include "platform/imgui_host.hpp"
#include "ui/menu.hpp"

namespace {

// 等 UnityFramework 加载并完成 il2cpp 初始化。最多等 ~60 秒。
bool wait_for_il2cpp() {
    for (int i = 0; i < 600; ++i) {
        if (il2::init()) return true;
        usleep(100 * 1000);
    }
    return false;
}

// 准备好 App 沙盒里的 Mods 目录
void prepare_mods_dir() {
    @autoreleasepool {
        NSArray<NSString*>* dirs =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString* docs = dirs.count ? dirs[0] : NSTemporaryDirectory();
        NSString* mods = [docs stringByAppendingPathComponent:@"Mods"];
        [[NSFileManager defaultManager] createDirectoryAtPath:mods
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
        mm::logf("Mods 目录：%s", mods.UTF8String ?: "?");
    }
}

// 自检：用 IL2CPP 反射真真切切地拿到游戏里的类型。
// 这一段跑通，就说明“按名字解析 + 反射”这条通用链路是活的。
void self_test() {
    il2::Domain* domain = il2::domain_get();
    if (!domain) {
        mm::logf("自检失败：il2cpp_domain_get 为空");
        return;
    }
    il2::thread_attach(domain);
    mm::logf("自检：len(符号)=%d，domain=%p", il2::symbol_count(), domain);

    il2::Assembly* asm_ = il2::domain_assembly_open(domain, "Assembly-CSharp");
    if (!asm_) {
        mm::logf("自检失败：找不到程序集 Assembly-CSharp");
        return;
    }
    il2::Image* image = il2::assembly_get_image(asm_);
    const char* image_name = il2::image_get_name(image);
    mm::logf("自检：镜像 = %s", image_name ? image_name : "?");

    il2::Class* main_cls = il2::class_from_name(image, "Terraria", "Main");
    if (!main_cls) {
        mm::logf("自检失败：Terraria.Main 没找到");
        return;
    }
    mm::logf("自检：类 %s.%s 命中",
             il2::class_get_namespace(main_cls) ? il2::class_get_namespace(main_cls) : "",
             il2::class_get_name(main_cls) ? il2::class_get_name(main_cls) : "?");

    // 静态字段（举例）：dayRate
    il2::Field* day_rate = il2::class_get_field_from_name(main_cls, "dayRate");
    if (day_rate) {
        float v = 0;
        il2::field_static_get_value(day_rate, &v);
        mm::logf("自检：Main.dayRate = %.4f（字段偏移 0x%x）", v, il2::field_get_offset(day_rate));
    } else {
        mm::logf("自检：Main.dayRate 未找到（字段名可能变了，不影响解析层）");
    }

    // 属性（举例）：gameMenu
    il2::Property* game_menu = il2::class_get_property_from_name(main_cls, "gameMenu");
    if (game_menu) {
        il2::Method* getter = il2::property_get_get_method(game_menu);
        mm::logf("自检：Main.gameMenu getter = %p，原生地址 = %p",
                 getter, il2::method_pointer(getter));
    } else {
        mm::logf("自检：Main.gameMenu 属性未找到");
    }

    // 顺便报一下有多少 il2cpp API 没解析到，方便判断包是否被改过
    const char* missing = il2::last_missing();
    if (missing && *missing) {
        mm::logf("自检：最后一个未解析符号 = %s", missing);
    }
    mm::logf("自检完成：按名解析 + 反射链路 OK");
}

}  // namespace

__attribute__((constructor))
static void modmenu_entry() {
    // 日志同时进菜单控制台
    mm::set_sink([](const std::string& line) { ui::log_line(line); });

    mm::logf("==== TerrariaModMenu 载入 (built %s %s) ====", __DATE__, __TIME__);
    prepare_mods_dir();

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!wait_for_il2cpp()) {
            mm::logf("等待 IL2CPP 超时：UnityFramework 没加载，或符号表被剥离");
            return;
        }
        mm::logf("UnityFramework 就绪，符号数 = %d", il2::symbol_count());
        self_test();

        // 阶段 2：Metal + ImGui 界面（钩子必须在主线程装）
        dispatch_async(dispatch_get_main_queue(), ^{
            if (host::start()) {
                mm::logf("界面已启动：左上角会多一个悬浮窗");
            } else {
                mm::logf("界面启动失败，详见上面的日志");
            }

            // 阶段 3：扫描并加载 Mod（需要 IL2CPP 已就绪）
            mods::reload();
        });
    });
}
