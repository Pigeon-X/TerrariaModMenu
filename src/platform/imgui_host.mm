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

#include <dlfcn.h>
#include <mach-o/dyld.h>

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
#include "../ui/cheat.hpp"
#include "../ui/ball_texture.hpp"
#include "../ui/glyph_extra.hpp"

namespace host {
namespace {

std::atomic<bool> g_started{false};
bool g_imgui_ready = false;
double g_last_time = 0;
std::atomic<int> g_render_count{0};
float g_font_px = 48.0f;      // 实际字号（像素），按屏幕缩放算出来
double g_last_present = 0;
constexpr double kIdleInterval = 0.20;   // 空闲时最多 5 帧/秒

// 「待重画」标记。悬浮球是静态图：画面画上去之后就留在叠加层上，
// 只要没变化就没必要每帧清屏重画（全屏 clear + 绘制在真机上很贵）。
// 任何触摸、以及刚启动时置真；画完一帧且手离开了就清掉。
std::atomic<bool> g_dirty{true};


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
        // 界面文案里超出「常用 2500 字」的那些字（如「屏」「渲」「帧」），
        // 不加载会显示成问号。列表由 tools/gen_glyphs.py 从源码生成。
        builder.AddText(glyphs::kExtra);
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
// 叠加层只覆盖 UI 实际占用的矩形（避免全屏清理/绘制，这是性能关键）
float g_rect_x = 0, g_rect_y = 0, g_rect_w = 0, g_rect_h = 0;

void apply_layer_rect(float x, float y, float w, float h) {
    g_rect_x = x; g_rect_y = y; g_rect_w = w; g_rect_h = h;
    CGFloat s = g_scale > 0 ? g_scale : 1.0;
    g_layer.frame = CGRectMake(x / s, y / s, w / s, h / s);
    g_layer.drawableSize = CGSizeMake(w, h);
}

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
    // 先给个很小的初始尺寸；真正的范围由 apply_layer_rect 按 UI 实际占用来定
    g_layer.frame = CGRectMake(0, 0, 64, 64);
    g_layer.drawableSize = CGSizeMake(64, 64);
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
        // 悬浮球和整个控制台**进游戏就能用**（日志/脚本这些跟地图无关）。
        // 「修改器」那几页才需要进地图 —— 那个判断在 menu.mm 里按页做。
        // 防录屏（设置 → 界面 里可以关）：
        // 检测到屏幕录制/投屏时，直接把自己的层藏起来。
        if (ui::hide_on_capture() && [UIScreen mainScreen].isCaptured) {
            if (!g_layer.hidden) { g_layer.hidden = YES; mm::logf("检测到录屏，已隐藏菜单层"); }
            return;
        }
        if (g_layer.hidden) g_layer.hidden = NO;
        // ------------------------------------------------------------------
        // 按需渲染。叠加层是全屏的，每帧 clear + 绘制会实打实吃掉游戏帧率，
        // 所以这里分三档，尽量少画：
        //
        //   菜单开着 / 正在触摸 -> 满帧（跟手优先，手感不能省）
        //   修改器开着但菜单收起 -> 15fps（要每帧写字段，但不需要 60）
        //   什么都不动           -> **一帧都不画**（直接跳过整帧）
        //
        // 最后一档是关键：悬浮球是静态图，画上去之后画面就留在 layer 上了，
        // 没变化时重画纯属浪费（全屏 clear 尤其贵）。所以只在
        // 「有触摸」或「待重画」时才画，画完就把脏标记清掉。
        //   ⚠️ 修改器开着的时候不能跳 —— cheat::tick() 是靠每帧驱动的。
        // ------------------------------------------------------------------
        const double t_now = CACurrentMediaTime();
        const bool touching = g_touching.load();
        const bool menu_open = ui::visible();
        const bool cheats = cheat::active();

        if (!menu_open && !touching && !cheats && !g_dirty.load()) return;

        double interval = 0.0;
        if (!menu_open && !touching) interval = cheats ? (1.0 / 15.0) : 0.0;
        if (interval > 0 && (t_now - g_last_present) < interval) return;

        // 旋转/尺寸变化时把叠加层对齐到整屏
        // （曾试过"只覆盖 UI 实际区域"，但在 Metal 后端上坐标平移没生效，
        //   导致界面被画到可视区外，先回退成全屏。）
        {
            CGSize scr = g_window.bounds.size;
            if (scr.width > 0) {
                float sw = (float)(scr.width * g_scale), sh = (float)(scr.height * g_scale);
                if (fabsf(g_rect_w - sw) > 1.f || fabsf(g_rect_h - sh) > 1.f) {
                    apply_layer_rect(0, 0, sw, sh);
                    mm::logf("叠加层尺寸更新 -> %.0fx%.0f", sw, sh);
                }
            }
        }

        id<CAMetalDrawable> drawable = [g_layer nextDrawable];
        if (!drawable) return;

        init_imgui(g_layer.device);
        if (!g_imgui_ready) return;

        ImGuiIO& io = ImGui::GetIO();
        // 布局仍按「整块屏幕」算，保证界面的绝对坐标是对的
        io.DisplaySize = ImVec2((float)(g_window.bounds.size.width * g_scale),
                                (float)(g_window.bounds.size.height * g_scale));
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
        ImGui::GetIO().FontGlobalScale = ui::ui_scale();   // 必须在 NewFrame 之前
        ImGui::NewFrame();
        mods::tick();
        cheat::tick();
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
        g_last_present = t_now;
        // 手已经离开、菜单也收着 -> 这一帧就是最终画面，之后就不必再画了
        if (!menu_open && !touching) g_dirty.store(false);
    }
}

// ---------------------------------------------------------------------------
// 触摸
// ---------------------------------------------------------------------------
void (*g_orig_send_event)(id, SEL, UIEvent*) = nullptr;

void mm_send_event(UIWindow* self, SEL _cmd, UIEvent* event) {
    BOOL swallow = NO;
    // 一有触摸就立刻恢复满帧渲染（否则拖球会卡）
    if (event && [event allTouches].count) {
        g_last_present = 0;
        g_dirty.store(true);      // 有触摸 -> 必须重画
    }
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

    // 因为我们空闲时**一帧都不画**，画面是留在叠加层上的；
    // 有两种情况系统会把画面弄没/弄错，得手动标脏让它重画一次：
    //   · 切后台再回来（layer 可能被回收）
    //   · 转屏（尺寸变了，球的位置也要跟着重算）
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification*) {
                  g_dirty.store(true);
                  g_last_present = 0;
                }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIDeviceOrientationDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification*) {
                  g_dirty.store(true);
                  g_last_present = 0;
                }];

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
