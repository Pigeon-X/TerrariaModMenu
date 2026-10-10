//
// ImGui + Metal 宿主实现。
//
#include "imgui_host.hpp"

#include <objc/runtime.h>

#include <atomic>
#include <vector>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include "imgui.h"
#include "imgui_impl_metal.h"

#include "../mm_log.hpp"
#include "../ui/menu.hpp"

namespace host {
namespace {

std::atomic<bool> g_started{false};
bool g_imgui_ready = false;
id<MTLDevice> g_device = nil;
double g_last_time = 0;

// 触摸状态（钩 UIWindow sendEvent: 拿到的，单位：物理像素）
std::atomic<bool> g_touching{false};
std::atomic<float> g_touch_x{0};
std::atomic<float> g_touch_y{0};
CGFloat g_scale = 1.0;

// ---------------------------------------------------------------------------
// swizzle 小工具
// ---------------------------------------------------------------------------
template <typename T>
void swizzle(Class cls, SEL sel, IMP new_imp, T* out_old) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    // IMP 不能隐式转成具体函数指针，必须显式转
    if (out_old) *out_old = reinterpret_cast<T>(method_getImplementation(m));
    method_setImplementation(m, new_imp);
}

// 找实现了 presentDrawable: 的 Metal 命令缓冲类。
// 不写死类名（不同 iOS 版本驱动类名不一样），扫一遍运行时。
Class find_command_buffer_class() {
    int count = objc_getClassList(nullptr, 0);
    if (count <= 0) return Nil;
    std::vector<Class> classes(static_cast<size_t>(count));
    objc_getClassList(classes.data(), count);
    for (Class c : classes) {
        const char* name = class_getName(c);
        if (!name || !strstr(name, "CommandBuffer")) continue;
        if (class_getInstanceMethod(c, @selector(presentDrawable:))) return c;
    }
    return Nil;
}

// ---------------------------------------------------------------------------
// 字体
// ---------------------------------------------------------------------------
void setup_fonts(ImGuiIO& io) {
    // 中文界面必须有中文字形，系统里最稳的是苹方
    const char* candidates[] = {
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
    };
    ImFontConfig cfg;
    cfg.FontNo = 0;
    cfg.OversampleH = 1;
    cfg.OversampleV = 1;
    for (const char* path : candidates) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:@(path)]) continue;
        if (io.Fonts->AddFontFromFileTTF(path, 17.0f, &cfg,
                                        io.Fonts->GetGlyphRangesChineseFull()) != nullptr) {
            mm::logf("ImGui 字体：%s", path);
            return;
        }
    }
    mm::logf("ImGui 字体：没找到中文字体，回退默认字体（中文会显示成方块）");
    io.Fonts->AddFontDefault();
}

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------
void init_imgui(id<MTLDevice> device) {
    if (g_imgui_ready) return;
    g_device = device;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;   // 不落 imgui.ini，免得多写文件
    io.LogFilename = nullptr;

    ImGui::StyleColorsDark();
    ImGui::GetStyle().ScaleAllSizes(1.6f);   // 手机上控件太小
    setup_fonts(io);

    if (!ImGui_ImplMetal_Init(device)) {
        mm::logf("ImGui_ImplMetal_Init 失败");
        return;
    }
    g_imgui_ready = true;
    g_last_time = CACurrentMediaTime();
    mm::logf("ImGui 初始化完成（device=%s）", [[device name] UTF8String]);
}

void render_ui(id<MTLCommandBuffer> cb, id<MTLDrawable> drawable) {
    if (!cb) return;
    init_imgui([cb device]);
    if (!g_imgui_ready) return;

    id<CAMetalDrawable> md = (id<CAMetalDrawable>)drawable;
    if (!md || !md.texture) return;

    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)md.texture.width, (float)md.texture.height);
    double now = CACurrentMediaTime();
    float dt = (float)(now - g_last_time);
    g_last_time = now;
    io.DeltaTime = (dt > 0.0f && dt < 0.5f) ? dt : (1.0f / 60.0f);
    io.MousePos = ImVec2(g_touch_x.load(), g_touch_y.load());
    io.MouseDown[0] = g_touching.load();

    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = md.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;    // 保留游戏画面
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();
    ui::draw();
    ImGui::Render();

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    if (enc) {
        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
        [enc endEncoding];
    }
}

// 原始的 -presentDrawable:，由 swizzle 保存
void (*g_orig_present)(id, SEL, id<MTLDrawable>) = nullptr;

void mm_present_drawable(id self, SEL _cmd, id<MTLDrawable> drawable) {
    @autoreleasepool {
        render_ui((__bridge id<MTLCommandBuffer>)self, drawable);
    }
    if (g_orig_present) g_orig_present(self, _cmd, drawable);
}

// ---------------------------------------------------------------------------
// 触摸：勾 UIWindow 的 sendEvent:，喂给 ImGui；点在菜单上就不往下传
// ---------------------------------------------------------------------------
void (*g_orig_send_event)(id, SEL, UIEvent*) = nullptr;

void mm_send_event(UIWindow* self, SEL _cmd, UIEvent* event) {
    BOOL swallow = NO;
    if (ui::visible() && event) {
        for (UITouch* t in [event allTouches]) {
            CGPoint p = [t locationInView:self];
            g_touch_x.store((float)(p.x * g_scale));
            g_touch_y.store((float)(p.y * g_scale));

            switch (t.phase) {
                case UITouchPhaseBegan:
                case UITouchPhaseMoved:
                case UITouchPhaseStationary:
                    g_touching.store(true);
                    break;
                default:
                    g_touching.store(false);
                    break;
            }
            // 用上一帧 ImGui 的判断决定这一下要不要吃掉
            if (t.phase == UITouchPhaseBegan && ImGui::GetCurrentContext() &&
                ImGui::GetIO().WantCaptureMouse) {
                swallow = YES;
            }
        }
    }
    if (!swallow && g_orig_send_event) g_orig_send_event(self, _cmd, event);
}

}  // namespace

bool ready() { return g_imgui_ready; }

bool start() {
    if (g_started.exchange(true)) return true;

    g_scale = [UIScreen mainScreen].scale ?: 1.0;

    Class cb_cls = find_command_buffer_class();
    if (!cb_cls) {
        mm::logf("没找到 Metal 命令缓冲类，界面无法挂载");
        g_started.store(false);
        return false;
    }
    swizzle(cb_cls, @selector(presentDrawable:), (IMP)mm_present_drawable, &g_orig_present);
    mm::logf("Metal 钩子已安装：%s", class_getName(cb_cls));

    swizzle([UIWindow class], @selector(sendEvent:), (IMP)mm_send_event, &g_orig_send_event);
    mm::logf("触摸钩子已安装：UIWindow sendEvent:");

    ui::set_visible(true);
    return true;
}

}  // namespace host
