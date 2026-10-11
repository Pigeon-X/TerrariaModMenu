//
// 模拟器宿主 App —— 在 iOS 模拟器里跑插件的渲染层。
//
// 为什么要有它：App Store 的 IPA 是 arm64 **设备**切片，模拟器跑不了，
// 所以"在本地把插件跑起来"只能自己搭一个壳：
//   · 一个普通的 UIKit App，画一块假的"游戏画面"
//   · 用 dlopen 加载同一份 TerrariaModMenu 源码编出来的**模拟器版** dylib
//   · dylib 的构造函数在 MODMENU_SIMHOST 模式下直接启动 Metal 叠加层
//
// 能验证什么：Metal 叠加层能不能挂上、悬浮球能不能点开和拖动、
//             图标纹理、中文字体、按需渲染/分级帧率、触摸穿透。
// 验证不了什么：跟游戏相关的部分（IL2CPP 反射、修改器、读游戏字段）。
//
// 由 scripts/build_simhost.sh 编译并装进模拟器。
//
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

// ---------------------------------------------------------------------------
// 假的「游戏画面」：深蓝天空 + 草地 + 一个"玩家"方块。
// 纯粹是为了能一眼看出叠加层是不是画在这上面。
// ---------------------------------------------------------------------------
@interface FakeGameView : UIView
@end

@implementation FakeGameView

- (void)drawRect:(CGRect)r {
    CGContextRef c = UIGraphicsGetCurrentContext();
    if (!c) return;
    const CGFloat w = r.size.width, h = r.size.height;

    CGContextSetRGBFillColor(c, 0.10f, 0.16f, 0.26f, 1.0f);      // 天空
    CGContextFillRect(c, r);

    CGContextSetRGBFillColor(c, 0.16f, 0.38f, 0.22f, 1.0f);      // 草地
    CGContextFillRect(c, CGRectMake(0, h * 0.68f, w, h * 0.32f));
    CGContextSetRGBFillColor(c, 0.30f, 0.24f, 0.16f, 1.0f);      // 地表
    CGContextFillRect(c, CGRectMake(0, h * 0.68f, w, 16));

    CGContextSetRGBFillColor(c, 0.85f, 0.76f, 0.56f, 1.0f);      // "玩家"
    CGContextFillRect(c, CGRectMake(w * 0.5f - 13, h * 0.68f - 50, 26, 50));
    CGContextSetRGBFillColor(c, 0.55f, 0.42f, 0.28f, 1.0f);      // 头发
    CGContextFillRect(c, CGRectMake(w * 0.5f - 13, h * 0.68f - 50, 26, 12));
}

@end

// ---------------------------------------------------------------------------
static UIViewController* make_root_vc(void) {
    UIViewController* vc = [[UIViewController alloc] init];
    vc.view = [[FakeGameView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    vc.view.backgroundColor = [UIColor blackColor];

    UILabel* label = [[UILabel alloc] init];
    label.text = @"Terraria ModMenu · 模拟器宿主\n点一下左边的紫色球展开菜单";
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor colorWithWhite:0.85f alpha:0.9f];
    label.font = [UIFont systemFontOfSize:15];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [label.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor
                                       constant:24],
    ]];
    return vc;
}

// ---------------------------------------------------------------------------
// 注意：用 SDK 27 编的 App 必须采用 UIScene 生命周期，否则一启动就被 UIKit 拒绝
// （日志里会写 "Application failed to launch: UIScene life cycle is required"）。
// 所以窗口是在 SceneDelegate 里建的，不是在 AppDelegate 里。
// ---------------------------------------------------------------------------
@interface SimSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow* window;
@end

@implementation SimSceneDelegate

- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    self.window.rootViewController = make_root_vc();
    [self.window makeKeyAndVisible];

    // 窗口先立起来，再加载 dylib —— 插件的叠加层要往 keyWindow 上挂。
    NSString* dylib = [[[NSBundle mainBundle] privateFrameworksPath]
        stringByAppendingPathComponent:@"TerrariaModMenu.dylib"];
    NSLog(@"[simhost] 准备加载插件：%@", dylib);
    if (![[NSFileManager defaultManager] fileExistsAtPath:dylib]) {
        NSLog(@"[simhost] 找不到插件 dylib：%@", dylib);
        return;
    }
    void* h = dlopen(dylib.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (h) {
        NSLog(@"[simhost] 插件已加载：%p", h);
    } else {
        const char* err = dlerror();
        NSLog(@"[simhost] 插件加载失败：%s", err ? err : "(无错误信息)");
    }
}

@end

@interface SimAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation SimAppDelegate
@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SimAppDelegate class]));
    }
}
