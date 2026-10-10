//
// ImGui + Metal 宿主
// ---------------------------------------------------------------------------
// 之前试过钩游戏自己的 Metal present 方法，但实测（iOS 1.4.5.8.1 / A15）：
//   游戏确实在用 Metal（CAMetalLayer nextDrawable 会被调用），
//   但从不调用 -presentDrawable: / -presentDrawable:afterMinimumDuration:，
//   所以钩子一次都没触发，界面出不来。
//
// 改成**完全不依赖游戏内部**的做法：
//   自己在窗口上叠一层透明的 CAMetalLayer，用自己的 CADisplayLink 驱动渲染。
//   游戏怎么画都跟我们无关，我们只管在自己的层上画菜单。
//
#include "imgui_host.hpp"

#include <objc/runtime.h>

#include <atomic>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include "imgui.h"
#include "imgui_impl_metal.h"

#include "../mm_log.hpp"
#include "../mods/mod_loader.hpp"
#include "../ui/menu.hpp"

namespace host {
namespace {

std::atomic<bool> g_started{false};
bool g_imgui_ready = false;
double g_last_time = 0;
std::atomic<int> g_render_count{0};

CAMetalLayer* g_layer = nil;
id<MTLCommandQueue> g_queue = nil;
UIWindow* g_window = nil;
CGFloat g_scale = 1.0;

// 触摸状态（钩 UIWindow sendEvent: 拿到的，单位：物理像素）
std::atomic<bool> g_touching{false};
std::atomic<float> g_touch_x{0};
std::atomic<float> g_touch_y{0};

// ---------------------------------------------------------------------------
// 字体
// ---------------------------------------------------------------------------
void setup_fonts(ImGuiIO& io) {
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

void init_imgui(id<MTLDevice> device) {
    if (g_imgui_ready) return;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;

    ImGui::StyleColorsDark();
    ImGui::GetStyle().ScaleAllSizes(1.8f);   // 手机上控件太小
    setup_fonts(io);

    if (!ImGui_ImplMetal_Init(device)) {
        mm::logf("ImGui_ImplMetal_Init 失败");
        return;
    }
    g_imgui_ready = true;
    g_last_time = CACurrentMediaTime();
    mm::logf("ImGui 初始化完成（device=%s）", [[device name] UTF8String]);
}

// ---------------------------------------------------------------------------
// 叠加层
// ---------------------------------------------------------------------------
UIWindow* pick_window() {
    UIWindow* fallback = nil;
    for (UIWindow* w in [UIApplication sharedApplication].windows) {
        if (!fallback) fallback = w;
        if (w.isKeyWindow) return w;
    }
    return fallback;
}

bool setup_overlay() {
    g_window = pick_window();
    if (!g_window) { mm::logf("叠加层：拿不到窗口，放弃"); return false; }
    g_scale = g_window.screen.scale ?: 3.0;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { mm::logf("叠加层：拿不到 Metal 设备"); return false; }

    g_layer = [CAMetalLayer layer];
    g_layer.device = device;
    g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    g_layer.framebufferOnly = NO;
    g_layer.opaque = NO;
    g_layer.backgroundColor = [UIColor clearColor].CGColor;
    g_layer.contentsScale = g_scale;
    g_layer.frame = g_window.bounds;
    g_layer.drawableSize = CGSizeMake(g_window.bounds.size.width * g_scale,
                                      g_window.bounds.size.height * g_scale);
    g_layer.zPosition = 10000;              // 压在最上面

    [g_window.layer addSublayer:g_layer];
    g_queue = [device newCommandQueue];

    mm::logf("叠加层已挂上：frame=%.0fx%.0f drawable=%.0fx%.0f 缩放=%.1f 父层=%s",
             g_layer.frame.size.width, g_layer.frame.size.height,
             g_layer.drawableSize.width, g_layer.drawableSize.height,
             (double)g_scale,
             g_layer.superlayer ? "有" : "无");
    return g_queue != nil;
}

void render_overlay() {
    if (!g_layer || !g_queue) return;
    @autoreleasepool {
        // 旋转/尺寸变化时同步
        CGSize bounds = g_window.bounds.size;
        if (bounds.width > 0 && !CGSizeEqualToSize(g_layer.frame.size, bounds)) {
            g_layer.frame = g_window.bounds;
            g_layer.drawableSize = CGSizeMake(bounds.width * g_scale, bounds.height * g_scale);
            mm::logf("叠加层尺寸更新 -> %.0fx%.0f", bounds.width, bounds.height);
        }

        id<CAMetalDrawable> drawable = [g_layer nextDrawable];
        if (!drawable) return;

        init_imgui(g_layer.device);
        if (!g_imgui_ready) return;

        ImGuiIO& io = ImGui::GetIO();
        io.DisplaySize = ImVec2((float)g_layer.drawableSize.width,
                                (float)g_layer.drawableSize.height);
        double now = CACurrentMediaTime();
        float dt = (float)(now - g_last_time);
        g_last_time = now;
        io.DeltaTime = (dt > 0.0f && dt < 0.5f) ? dt : (1.0f / 60.0f);
        io.MousePos = ImVec2(g_touch_x.load(), g_touch_y.load());
        io.MouseDown[0] = g_touching.load();

        MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = drawable.texture;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);   // 全透明
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

        ImGui_ImplMetal_NewFrame(rpd);
        ImGui::NewFrame();
        mods::tick();
        ui::draw();
        ImGui::Render();

        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
        [enc endEncoding];
        [cb presentDrawable:drawable];
        [cb commit];

        if (++g_render_count == 1) {
            mm::logf("诊断：叠加层第一次渲染成功（%dx%d，像素格式 %lu）",
                     (int)drawable.texture.width, (int)drawable.texture.height,
                     (unsigned long)drawable.texture.pixelFormat);
        }
    }
}

// ---------------------------------------------------------------------------
// 触摸
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
            if (t.phase == UITouchPhaseBegan && ImGui::GetCurrentContext() &&
                ImGui::GetIO().WantCaptureMouse) {
                swallow = YES;
            }
        }
    }
    if (!swallow && g_orig_send_event) g_orig_send_event(self, _cmd, event);
}

template <typename T>
void swizzle(Class cls, SEL sel, IMP new_imp, T* out_old) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (out_old) *out_old = reinterpret_cast<T>(method_getImplementation(m));
    method_setImplementation(m, new_imp);
}

}  // namespace

void start_display_link();
void start_display_link() {
    static CADisplayLink* link = nil;
    static id target = nil;
    if (link) return;
    target = [NSClassFromString(@"MMDisplayLinkTarget") new];
    link = [CADisplayLink displayLinkWithTarget:target selector:NSSelectorFromString(@"tick:")];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    mm::logf("显示链接已启动（CADisplayLink）");
}

bool ready() { return g_imgui_ready; }

bool start() {
    if (g_started.exchange(true)) return true;

    if (!setup_overlay()) {
        g_started.store(false);
        return false;
    }

    swizzle([UIWindow class], @selector(sendEvent:), (IMP)mm_send_event, &g_orig_send_event);
    mm::logf("  钩 UIWindow sendEvent:  %s", g_orig_send_event ? "OK" : "该方法不存在");

    ui::set_visible(true);
    start_display_link();

    // 8 秒后给个明确结论
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        int n = g_render_count.load();
        if (n == 0) {
            mm::logf("警告：8 秒内叠加层一次都没画出来（nextDrawable 拿不到？）");
        } else {
            mm::logf("诊断：8 秒内叠加层画了 %d 帧，菜单应该在屏幕上", n);
        }
    });
    return true;
}

}  // namespace host

// ---------------------------------------------------------------------------
// CADisplayLink 需要一个 ObjC 对象当 target
// ---------------------------------------------------------------------------
@interface MMDisplayLinkTarget : NSObject
- (void)tick:(CADisplayLink*)link;
@end

@implementation MMDisplayLinkTarget
- (void)tick:(CADisplayLink*)link {
    (void)link;
    host::render_overlay();
}
@end
