//
// 桌面预览器（macOS 版）：在 Mac 上直接跑菜单 UI，鼠标操作。
//
// 和 preview/main.cpp（Windows / DX11）等价，复用**完全相同**的
// src/ui/menu.mm（用 -DMODMENU_PREVIEW 编进去，数据是假的）。
// 作用就是交接文档里的那条铁律：**大改动先在预览器里验证，再上真机**。
//
// 后端：Cocoa + Metal（全是系统框架，不需要 GLFW/SDL 之类的第三方依赖）
//
// 两种模式：
//   1) 交互：直接跑，开一个窗口，鼠标点着调
//        ./build/TerrariaModMenu-Preview-mac
//   2) 截图：渲染 N 帧后存 PNG 退出，用来做前后对比 / 给文档配图
//        ./build/TerrariaModMenu-Preview-mac --shot out.png --frames 3
//
// 常用参数：
//   --shot <png>     截图模式
//   --size WxH       窗口/截图画布尺寸（默认 1280x800）
//   --frames N       截图前先跑几帧（ImGui 需要几帧才能把布局稳定下来，默认 3）
//   --ball           只显示悬浮球（游戏里刚进游戏的初始态）
//   --not-in-world   模拟"还在主菜单"，看修改器那几页的"进入地图后才能使用"提示
//   --click X,Y      截图前在该坐标点一下（可重复），用来把某个标签页点出来
//
#import <Foundation/Foundation.h>

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "imgui.h"
#include "imgui_impl_metal.h"
#include "imgui_impl_osx.h"

#include "../src/ui/menu.hpp"
#include "../src/ui/ball_texture.hpp"
#include "../src/ui/glyph_extra.hpp"
#include "../src/ui/preview_stubs.hpp"

// ---------------------------------------------------------------------------
// 共用：字体 / 悬浮球纹理 —— 逻辑和 src/platform/imgui_host.mm 保持一致，
// 这样预览器里看到的字和球，跟真机上就是同一套。
// ---------------------------------------------------------------------------

// ARC 下必须自己保活，否则纹理会被释放
static id<MTLTexture> g_ball_obj = nil;

static std::vector<std::string> font_candidates() {
    return {
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/LanguageSupport/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/Supplemental/Songti.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/Library/Fonts/Arial Unicode.ttf",
    };
}

static void setup_fonts(ImGuiIO& io, float font_px) {
    // 和真机一致：绝不用 GetGlyphRangesChineseFull()（图集太大，真机会被 watchdog 杀）
    static ImVector<ImWchar> ranges;
    if (ranges.empty()) {
        ImFontGlyphRangesBuilder builder;
        builder.AddRanges(io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
        builder.AddRanges(io.Fonts->GetGlyphRangesDefault());
        builder.AddText("✕×●○✔");
        builder.AddText(glyphs::kExtra);   // 界面里的非常用字，见 tools/gen_glyphs.py
        builder.BuildRanges(&ranges);
    }

    for (const auto& path : font_candidates()) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:@(path.c_str())]) continue;
        for (int idx = 0; idx < 2; ++idx) {          // .ttc 是字体集合，只试 0/1
            io.Fonts->Clear();
            ImFontConfig cfg;
            cfg.FontNo = idx;
            cfg.OversampleH = 1;
            cfg.OversampleV = 1;
            ImFont* f = io.Fonts->AddFontFromFileTTF(path.c_str(), font_px, &cfg, ranges.Data);
            if (!f) break;
            io.Fonts->Build();
            // 字形要等 Build 之后才有；拿「中」当判定标准
            if (f->FindGlyphNoFallback((ImWchar)0x4E2D) != nullptr) {
                printf("[预览器] 字体：%s（FontNo=%d）\n", path.c_str(), idx);
                return;
            }
        }
    }
    printf("[预览器] 字体：全部失败，回退默认字体（中文会变问号）\n");
    io.Fonts->Clear();
    io.Fonts->AddFontDefault();
}

static ImTextureID create_ball_texture(id<MTLDevice> device) {
    const char* hex = ui::ball_texture_hex();
    const int size = ui::kBallTextureSize;
    const size_t want = (size_t)size * size * 4;
    const size_t n = strlen(hex) / 2;
    if (n != want) {
        printf("[预览器] 球形图标数据长度不对：%zu != %zu\n", n, want);
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

// 造几条假日志，方便看日志页的排版（和 Windows 版一致）
static void seed_fake_data(id<MTLDevice> device) {
    ui::log_line("预览器已启动 —— 这里的数据都是假的，只用来调 UI");
    ui::log_line("[示例Mod] 找到类：Terraria.Main");
    ui::log_line("Mod 已加载：示例Mod v1.0");
    ui::log_line("Mod 扫描完成：发现 3 个，成功加载 2 个");
    ui::set_ball_texture((void*)create_ball_texture(device));
}

static void setup_style(ImGuiIO& io) {
    io.IniFilename = nullptr;
    ImGui::StyleColorsDark();
    ImGui::GetStyle().ScaleAllSizes(1.0f);
}

// ---------------------------------------------------------------------------
// 截图模式：离屏渲染到一张纹理，读回来存 PNG
// ---------------------------------------------------------------------------
static int run_shot(const std::string& out_path, int w, int h, int frames, bool ball_only,
                    const std::vector<std::pair<int, int>>& clicks) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        fprintf(stderr, "这台机器没有可用的 Metal 设备\n");
        return 1;
    }
    id<MTLCommandQueue> queue = [device newCommandQueue];

    MTLTextureDescriptor* td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device newTextureWithDescriptor:td];

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    setup_style(io);
    ImGui_ImplMetal_Init(device);
    setup_fonts(io, 32.0f);
    seed_fake_data(device);
    ui::set_visible(!ball_only);

    // 离屏模式下没有窗口，直接用画布尺寸喂给 ImGui
    io.DisplaySize = ImVec2((float)w, (float)h);
    io.DisplayFramebufferScale = ImVec2(1.0f, 1.0f);
    io.DeltaTime = 1.0f / 60.0f;

    auto render_once = [&]() {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        // 深蓝底色，假装是游戏画面
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.10, 0.16, 0.26, 1.0);

        ImGui_ImplMetal_NewFrame(rp);
        io.FontGlobalScale = ui::ui_scale();   // 必须早于 NewFrame()
        ImGui::NewFrame();
        ui::draw();
        ImGui::Render();

        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
    };

    // 先空跑几帧：ImGui 的布局（尤其 TabBar / 表格）要几帧才稳定
    if (frames < 1) frames = 1;
    for (int i = 0; i < frames; ++i) render_once();

    // 需要的话，模拟点击把某个标签页点出来
    for (const auto& c : clicks) {
        io.AddMousePosEvent((float)c.first, (float)c.second);
        render_once();
        io.AddMouseButtonEvent(0, true);
        render_once();
        io.AddMouseButtonEvent(0, false);
        render_once();
        // 把指针挪到角落，免得 hover 高亮留在截图里
        io.AddMousePosEvent((float)(w - 4), (float)(h - 4));
        render_once();
    }
    // 再跑一帧，确保最终画面就是点完之后的样子
    render_once();

    // 读回来
    const NSUInteger bytes_per_row = (NSUInteger)w * 4;
    id<MTLBuffer> readback = [device newBufferWithLength:bytes_per_row * (NSUInteger)h
                                                options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:target
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                 toBuffer:readback
        destinationOffset:0
   destinationBytesPerRow:bytes_per_row
 destinationBytesPerImage:bytes_per_row * (NSUInteger)h];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    // RGBA8Unorm 的内存布局就是 R,G,B,A，所以按 32Big + PremultipliedLast 解释
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate([readback contents], (size_t)w, (size_t)h, 8,
                                             bytes_per_row, cs,
                                             kCGImageAlphaPremultipliedLast |
                                                 kCGBitmapByteOrder32Big);
    if (!ctx) {
        fprintf(stderr, "CGBitmapContextCreate 失败\n");
        return 1;
    }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:@(out_path.c_str())];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (!dst) {
        fprintf(stderr, "写不出 PNG：%s\n", out_path.c_str());
        return 1;
    }
    CGImageDestinationAddImage(dst, img, NULL);
    bool ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);

    ImGui_ImplMetal_Shutdown();
    ImGui::DestroyContext();

    if (!ok) {
        fprintf(stderr, "PNG 落盘失败：%s\n", out_path.c_str());
        return 1;
    }
    printf("[预览器] 已保存截图：%s（%dx%d）\n", out_path.c_str(), w, h);
    return 0;
}

// ---------------------------------------------------------------------------
// 交互模式：Cocoa 窗口 + MTKView
// ---------------------------------------------------------------------------
@interface PreviewView : MTKView <MTKViewDelegate>
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@end

@interface PreviewAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow* window;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@end

@implementation PreviewView

- (void)drawInMTKView:(MTKView*)view {
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize.x = view.bounds.size.width;
    io.DisplaySize.y = view.bounds.size.height;
    CGFloat scale = view.window.screen.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
    io.DisplayFramebufferScale = ImVec2((float)scale, (float)scale);

    id<MTLCommandBuffer> cb = [self.queue commandBuffer];
    MTLRenderPassDescriptor* rp = view.currentRenderPassDescriptor;
    if (rp == nil) {
        [cb commit];
        return;
    }
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.10, 0.16, 0.26, 1.0);

    ImGui_ImplMetal_NewFrame(rp);
    ImGui_ImplOSX_NewFrame(view);
    io.FontGlobalScale = ui::ui_scale();
    ImGui::NewFrame();
    ui::draw();
    ImGui::Render();

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];
    [cb presentDrawable:view.currentDrawable];
    [cb commit];
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {}

@end

@implementation PreviewAppDelegate

- (instancetype)initWithSize:(NSSize)size title:(NSString*)title {
    if (self = [super init]) {
        _device = MTLCreateSystemDefaultDevice();
        if (!_device) {
            fprintf(stderr, "这台机器没有可用的 Metal 设备\n");
            return self;
        }
        _queue = [_device newCommandQueue];

        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO& io = ImGui::GetIO();
        setup_style(io);
        ImGui_ImplMetal_Init(_device);
        setup_fonts(io, 22.0f);   // 桌面窗口用系统字号，比真机的 48px 正常多了
        seed_fake_data(_device);

        PreviewView* view = [[PreviewView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)
                                                        device:_device];
        view.delegate = view;
        view.queue = _queue;
        view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;

        _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                             styleMask:(NSWindowStyleMaskTitled |
                                                        NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskResizable |
                                                        NSWindowStyleMaskMiniaturizable)
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
        _window.title = title;
        _window.contentView = view;
        [_window center];
    }
    return self;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender { return YES; }

@end

// ---------------------------------------------------------------------------
static void usage(const char* argv0) {
    printf("用法：%s [--shot 输出.png] [--size 1280x800] [--frames 3] [--ball] [--click X,Y]\n",
           argv0);
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        std::string shot;
        int w = 1280, h = 800, frames = 3;
        bool ball_only = false;
        std::vector<std::pair<int, int>> clicks;

        for (int i = 1; i < argc; ++i) {
            std::string a = argv[i];
            if (a == "--shot" && i + 1 < argc) {
                shot = argv[++i];
            } else if (a == "--size" && i + 1 < argc) {
                if (sscanf(argv[++i], "%dx%d", &w, &h) != 2) w = 1280, h = 800;
            } else if (a == "--frames" && i + 1 < argc) {
                frames = atoi(argv[++i]);
            } else if (a == "--click" && i + 1 < argc) {
                int x = 0, y = 0;
                if (sscanf(argv[++i], "%d,%d", &x, &y) == 2) clicks.emplace_back(x, y);
            } else if (a == "--ball") {
                ball_only = true;
            } else if (a == "--not-in-world") {
                cheat::g_stub_in_world = false;
            } else if (a == "-h" || a == "--help") {
                usage(argv[0]);
                return 0;
            } else {
                fprintf(stderr, "未知参数：%s\n", a.c_str());
                usage(argv[0]);
                return 2;
            }
        }

        if (!shot.empty()) return run_shot(shot, w, h, frames, ball_only, clicks);

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        PreviewAppDelegate* del =
            [[PreviewAppDelegate alloc] initWithSize:NSMakeSize(w, h)
                                              title:@"Terraria ModMenu Preview (macOS)"];
        [NSApp setDelegate:del];
        [del.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
    }
    return 0;
}
