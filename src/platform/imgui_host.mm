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
#include <cstring>
#include <vector>

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
#include "../ui/ball_texture.hpp"

namespace host {
namespace {

std::atomic<bool> g_started{false};
bool g_imgui_ready = false;
double g_last_time = 0;
std::atomic<int> g_render_count{0};
float g_font_px = 48.0f;      // 实际字号（像素），按屏幕缩放算出来

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
// 收集候选字体：先试常见路径，再扫系统字体目录里名字带中文关键字的下标
std::vector<std::string> font_candidates() {
    std::vector<std::string> out;
    const char* known[] = {
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/LanguageSupport/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/STHeiti Medium.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/NotoSansCJK.ttc",
        "/System/Library/Fonts/NotoSansCJK-Regular.ttc",
        "/System/Library/Fonts/Core/PingFang.ttc",
        "/System/Library/Fonts/AppFonts/PingFang.ttc",
    };
    for (const char* p : known) out.emplace_back(p);

    @autoreleasepool {
        NSArray<NSString*>* dirs = @[
            @"/System/Library/Fonts",
            @"/System/Library/Fonts/LanguageSupport",
            @"/System/Library/Fonts/Core",
            @"/System/Library/Fonts/AppFonts",
            @"/System/Library/Fonts/CoreAddition",
            @"/System/Library/Fonts/Supplemental",
        ];
        NSArray<NSString*>* keys = @[
            @"PingFang", @"Hei", @"Hiragino", @"Song", @"Noto", @"Kai", @"Fallback", @"STHeiti",
        ];
        NSFileManager* fm = [NSFileManager defaultManager];
        for (NSString* d in dirs) {
            NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:d error:nil];
            for (NSString* f in files) {
                NSString* low = f.lowercaseString;
                if (!([low hasSuffix:@".ttf"] || [low hasSuffix:@".ttc"] || [low hasSuffix:@".otf"]))
                    continue;
                for (NSString* k in keys) {
                    if ([f containsString:k]) {
                        out.push_back(std::string(d.UTF8String) + "/" + f.UTF8String);
                        break;
                    }
                }
            }
        }
    }
    return out;
}

void setup_fonts(ImGuiIO& io) {
    // 注意：不要用 GetGlyphRangesChineseFull()！
    // 全量中文约 2 万字，图集极大，在渲染回调里建会被 watchdog 杀掉。
    // 「常用简体中文」约 2500 字，菜单够用。
    static ImVector<ImWchar> ranges;
    if (ranges.empty()) {
        ImFontGlyphRangesBuilder builder;
        builder.AddRanges(io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
        builder.AddRanges(io.Fonts->GetGlyphRangesDefault());
        builder.AddText("✕×●○✔");          // 图标用到的几个符号
        builder.BuildRanges(&ranges);
    }
    mm::logf("ImGui 字体：字形范围共 %d 个码点", (int)ranges.Size);

    auto cands = font_candidates();
    mm::logf("ImGui 字体：候选 %zu 个", cands.size());
    int tried = 0;
    const int kMaxTry = 6;               // 别扫太多，避免长时间占用主线程
    for (const auto& path : cands) {
        if (tried >= kMaxTry) break;
        @autoreleasepool {
            if (![[NSFileManager defaultManager] fileExistsAtPath:@(path.c_str())]) continue;
        }
        ++tried;
        // .ttc 是字体集合；只试下标 0 和 1（再大容易踩 stbtt 的断言）
        for (int idx = 0; idx < 2; ++idx) {
            // 关键：字形要等 Build 之后才有，所以每个候选都建一次图集再判定
            io.Fonts->Clear();
            ImFontConfig cfg;
            cfg.FontNo = idx;
            cfg.OversampleH = 1;
            cfg.OversampleV = 1;
            ImFont* f = io.Fonts->AddFontFromFileTTF(path.c_str(), g_font_px, &cfg, ranges.Data);
            if (!f) break;                          // 文件本身打不开，换下一个候选
            io.Fonts->Build();
            if (f->FindGlyphNoFallback((ImWchar)0x4E2D) != nullptr) {
                mm::logf("ImGui 字体：✓ %s（FontNo=%d）", path.c_str(), idx);
                return;
            }
        }
        mm::logf("ImGui 字体：✗ %s", path.c_str());
    }
    mm::logf("ImGui 字体：全部失败（存在但打不开的有 %d 个），回退默认字体，中文会变成问号",
             tried);
    io.Fonts->Clear();
    io.Fonts->AddFontDefault();
}

// ARC 下必须自己保活，否则纹理会被释放
id<MTLTexture> g_ball_obj = nil;

// 把嵌入的十六进制 RGBA 解出来，建成一张 Metal 纹理
ImTextureID create_ball_texture(id<MTLDevice> device) {
    const char* hex = ui::ball_texture_hex();
    const int size = ui::kBallTextureSize;
    const size_t want = (size_t)size * size * 4;
    const size_t n = strlen(hex) / 2;
    if (n != want) {
        mm::logf("球形图标数据长度不对：%zu != %zu", n, want);
        return nullptr;
    }
    std::vector<unsigned char> px(n);
    auto hv = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return 0;
    };
    for (size_t i = 0; i < n; ++i) {
        px[i] = (unsigned char)((hv(hex[i * 2]) << 4) | hv(hex[i * 2 + 1]));
    }

    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:size
                                                          height:size
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
    if (!tex) return nullptr;
    [tex replaceRegion:MTLRegionMake2D(0, 0, size, size)
           mipmapLevel:0
             withBytes:px.data()
           bytesPerRow:size * 4];
    g_ball_obj = tex;
    return (ImTextureID)(__bridge void*)tex;
}

void init_imgui(id<MTLDevice> device) {
    if (g_imgui_ready) return;
    mm::logf("ImGui 初始化：CreateContext ...");

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;

    ImGui::StyleColorsDark();
    // 坐标系是物理像素，字号必须按屏幕缩放来定，
    // 否则 17px 在 3x 屏上只有 5.7pt —— 小得看不清。
    const float font_px = g_font_px;
    ImGui::GetStyle().ScaleAllSizes(font_px / 13.0f);   // ImGui 默认风格是按 13px 字号设计的
    setup_fonts(io);

    // 显式建图集，并把耗时打出来（放这里比放在渲染回调里安全）
    double t0 = CACurrentMediaTime();
    if (!io.Fonts->IsBuilt()) io.Fonts->Build();
    mm::logf("ImGui 图集已生成，耗时 %.0f ms", (CACurrentMediaTime() - t0) * 1000.0);

    if (!ImGui_ImplMetal_Init(device)) {
        mm::logf("ImGui_ImplMetal_Init 失败");
        return;
    }

    // 球形图标：把嵌入的 RGBA 数据建成一张 Metal 纹理交给 UI
    if (auto* ball = create_ball_texture(device)) {
        ui::set_ball_texture((void*)ball);
        mm::logf("球形图标纹理已创建 %dx%d", ui::kBallTextureSize, ui::kBallTextureSize);
    } else {
        mm::logf("球形图标纹理创建失败，收起状态会退化成 M 按钮");
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
    g_font_px = 16.0f * (float)g_scale;      // 16pt 换算成像素

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
    // 注意：这里不能判断 ui::visible()！
    // 球（收起）状态下也必须把触摸喂给 ImGui，否则球点不开、也拖不动。
    if (event) {
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

    // 安全开关：Documents/ModMenu_norender 存在时，只加载 dylib、不挂任何渲染，
    // 用来排查"是不是渲染层把游戏搞崩了"。
    @autoreleasepool {
        NSString* docs = [NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString* flag = [docs stringByAppendingPathComponent:@"ModMenu_norender"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:flag]) {
            mm::logf("检测到 ModMenu_norender，跳过渲染层（安全模式）");
            g_started.store(false);
            return false;
        }
    }

    mm::logf("开始挂载渲染层 ...");
    if (!setup_overlay()) {
        g_started.store(false);
        return false;
    }

    swizzle([UIWindow class], @selector(sendEvent:), (IMP)mm_send_event, &g_orig_send_event);
    mm::logf("  钩 UIWindow sendEvent:  %s", g_orig_send_event ? "OK" : "该方法不存在");

    // 趁现在（不在渲染回调里）把 ImGui 和图集建好
    init_imgui(g_layer.device);
    if (!g_imgui_ready) {
        mm::logf("ImGui 初始化失败，不启动渲染");
        g_started.store(false);
        return false;
    }

    ui::set_visible(false);      // 首次进入直接是悬浮球，玩家自己点开
    start_display_link();
    mm::logf("渲染层挂载完成，等第一帧 ...");

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
