//
//  main.m —— DITKit 入口与主窗口
//
//  DITKit 是个视频工具箱：主窗口只负责标题栏、ffmpeg 状态和工具页切换，
//  每个具体功能都是一个独立的 DITToolPage（见 PageLUT.m / PageTrim.m）。
//  要加新工具，写一个新的 Page 类、在这里的 pages 数组里挂上即可。
//

#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import "DITUI.h"
#import "PageLUT.h"
#import "PageTrim.h"

static BOOL gSelfTest = NO;

#pragma mark - 窗口抓图（绕开 macOS 15 的编译期弃用）

// CGWindowListCreateImage 在 macOS 15 的 SDK 里被标记为 obsoleted，
// 直接调用会编译失败；但符号在运行时的 CoreGraphics 里仍然存在。
// 这里用 dlsym 动态解析，编译期不需要声明，运行时能用就用。
typedef CGImageRef (*DITCGWindowListCreateImageFn)(CGRect, CGWindowListOption,
                                                   CGWindowID, CGWindowImageOption);

static DITCGWindowListCreateImageFn DITWindowImageFn(void) {
    static DITCGWindowListCreateImageFn fn = NULL;
    static BOOL probed = NO;
    if (!probed) {
        probed = YES;
        void *h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                         RTLD_LAZY);
        if (h) fn = (DITCGWindowListCreateImageFn)dlsym(h, "CGWindowListCreateImage");
    }
    return fn;
}

/// 抓取指定窗口的位图；不可用时返回 nil（调用方自行回退）
static NSBitmapImageRep *DITCaptureWindow(NSWindow *win) {
    DITCGWindowListCreateImageFn fn = DITWindowImageFn();
    if (!fn || win.windowNumber <= 0) return nil;
    CGImageRef img = fn(CGRectNull, kCGWindowListOptionIncludingWindow,
                        (CGWindowID)win.windowNumber, kCGWindowImageBoundsIgnoreFraming);
    if (!img) return nil;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    CGImageRelease(img);
    return rep;
}

#pragma mark - 主控制器

@interface AppController : NSObject <NSApplicationDelegate>
@end

@implementation AppController {
    NSWindow *_window;
    LayoutView *_root;
    NSTextField *_titleLabel;
    NSTextField *_ffmpegLabel;
    NSSegmentedControl *_pageSwitch;
    NSView *_pageHost;
    NSView *_topBar;
    NSArray<id<DITToolPage>> *_pages;
    NSInteger _currentPage;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self buildMenu];
    [self buildWindow];
    [self doLayout];

    NSString *ff = [DITEngine resolveTool:@"ffmpeg"];
    if (ff) {
        _ffmpegLabel.stringValue = [NSString stringWithFormat:@"ffmpeg: %@", ff];
        _ffmpegLabel.textColor = [NSColor tertiaryLabelColor];
    } else {
        _ffmpegLabel.stringValue = @"未找到 ffmpeg —— 请先执行 brew install ffmpeg";
        _ffmpegLabel.textColor = [NSColor systemRedColor];
    }

    [NSApp activateIgnoringOtherApps:YES];
    [_window makeKeyAndOrderFront:nil];
    // 自检时把窗口编号打出来，方便外部（如 screencapture -l）抓这个窗口
    if (gSelfTest) {
        printf("WINDOW=%ld\n", (long)_window.windowNumber);
        fflush(stdout);
    }

    if (gSelfTest) [self runSelfTest];
}

/// 自检：可选切换页、注入文件、按指定外观渲染截图，然后打印诊断信息退出
- (void)runSelfTest {
    const char *ap = getenv("DITKIT_APPEARANCE");
    if (ap) {
        NSString *name = (strcmp(ap, "light") == 0) ? NSAppearanceNameAqua
                                                    : NSAppearanceNameDarkAqua;
        NSAppearance *a = [NSAppearance appearanceNamed:name];
        if (a) {
            _window.appearance = a;
            _root.appearance = a;
        }
    }

    const char *pageEnv = getenv("DITKIT_PAGE");
    if (pageEnv) {
        NSInteger idx = atoi(pageEnv);
        if (idx >= 0 && idx < (NSInteger)_pages.count) [_pageSwitch setSelectedSegment:idx];
        [self switchPage:nil];
    }

    const char *drop = getenv("DITKIT_DROP");
    if (drop) {
        NSString *s = [NSString stringWithUTF8String:drop];
        id<DITToolPage> page = _pages[(NSUInteger)_currentPage];
        if ([page respondsToSelector:@selector(addInputPaths:)]) {
            [page addInputPaths:[s componentsSeparatedByString:@"|"]];
        }
        [self doLayout];
    }

    if (getenv("DITKIT_AUTOSTART")) {
        id<DITToolPage> page = _pages[(NSUInteger)_currentPage];
        if ([page respondsToSelector:@selector(beginRun)]) [page beginRun];
    }

    // DITKIT_STOP_AFTER 秒后自动点一次「停止」，用于复现/回归停止路径
    const char *stopAfter = getenv("DITKIT_STOP_AFTER");
    if (stopAfter) {
        [NSTimer scheduledTimerWithTimeInterval:atof(stopAfter) repeats:NO block:^(NSTimer *tm) {
            id<DITToolPage> page = self->_pages[(NSUInteger)self->_currentPage];
            if ([page respondsToSelector:@selector(beginStop)]) [page beginStop];
        }];
    }

    NSString *shotPath = nil;
    const char *shot = getenv("DITKIT_SHOT");
    if (shot) shotPath = [NSString stringWithUTF8String:shot];

    const char *delayEnv = getenv("DITKIT_SHOT_DELAY");
    NSTimeInterval delay = delayEnv ? atof(delayEnv) : 1.6;

    [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) {
        if (shotPath.length) [self captureSelf:shotPath];
        [self dumpDiagnostics];
        // DITKIT_LINGER 秒：继续留在屏幕上，方便外部截图或肉眼确认
        const char *linger = getenv("DITKIT_LINGER");
        double wait = linger ? atof(linger) : 0;
        if (wait > 0) {
            printf("保持窗口 %.0f 秒（窗口编号 %ld）\n", wait, (long)_window.windowNumber);
            fflush(stdout);
            [NSTimer scheduledTimerWithTimeInterval:wait repeats:NO block:^(NSTimer *t2) {
                [NSApp terminate:nil];
            }];
        } else {
            [NSApp terminate:nil];
        }
    }];
}

- (void)captureSelf:(NSString *)path {
    // 优先按窗口抓图：cacheDisplayInRect 抓不到 layer-backed 的顶层控件（标题、切换条）
    // DITKIT_SHOT_VIEWCACHE=1 可强制走视图缓存路径，便于对比两种抓图的效果
    NSBitmapImageRep *rep = getenv("DITKIT_SHOT_VIEWCACHE") ? nil : DITCaptureWindow(_window);
    if (rep) {
        printf("抓图方式: 窗口合成 (%ldx%ld)\n", (long)rep.pixelsWide, (long)rep.pixelsHigh);
    } else {
        printf("抓图方式: 视图缓存回退（窗口合成不可用）\n");
        NSRect bounds = _root.bounds;
        rep = [_root bitmapImageRepForCachingDisplayInRect:bounds];
        [_root cacheDisplayInRect:bounds toBitmapImageRep:rep];
    }
    if (!rep) {
        printf("抓图失败: 两种方式都没拿到位图\n");
        return;
    }
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if ([png writeToFile:path atomically:YES]) {
        printf("界面渲染图: %s (%ldx%ld)\n", path.UTF8String,
               (long)rep.pixelsWide, (long)rep.pixelsHigh);
    }
}

- (void)dumpDiagnostics {
    printf("=== 自检 ===\n");
    NSScreen *sc = _window.screen ?: [NSScreen mainScreen];
    NSRect sf = sc.frame, sv = sc.visibleFrame;
    printf("屏幕    : %.0fx%.0f  可见 y=%.0f h=%.0f\n", sf.size.width, sf.size.height,
           sv.origin.y, sv.size.height);
    printf("窗口矩形: x=%.0f y=%.0f w=%.0f h=%.0f\n",
           _window.frame.origin.x, _window.frame.origin.y,
           _window.frame.size.width, _window.frame.size.height);
    printf("窗口    : %.0f x %.0f  可见=%d  编号=%ld\n",
           _window.frame.size.width, _window.frame.size.height,
           _window.isVisible ? 1 : 0, (long)_window.windowNumber);
    printf("内容区  : %.0f x %.0f（flipped=%d）\n",
           _root.bounds.size.width, _root.bounds.size.height, _root.isFlipped ? 1 : 0);
    printf("ffmpeg  : %s\n", _ffmpegLabel.stringValue.UTF8String);
    printf("工具页  : %lu 个\n", (unsigned long)_pages.count);
    for (NSUInteger i = 0; i < _pages.count; i++) {
        id<DITToolPage> p = _pages[i];
        printf("  [%lu] %-16s %s\n", (unsigned long)i, p.pageTitle.UTF8String,
               (NSInteger)i == _currentPage ? "<- 当前" : "");
    }

    // 当前页的运行态：自检用它断言「停止后是否真的收尾了」
    {
        id<DITToolPage> p = _pages[(NSUInteger)_currentPage];
        NSString *st = [p respondsToSelector:@selector(statusLine)] ? [p statusLine] : @"(未实现)";
        printf("运行态  : busy=%d  状态行=%s\n", p.busy ? 1 : 0, st.UTF8String);
    }

    printf("顶层子视图:\n");
    for (NSView *v in _root.subviews) {
        printf("  %-20s x=%4.0f y=%4.0f w=%4.0f h=%4.0f hidden=%d\n",
               NSStringFromClass([v class]).UTF8String,
               v.frame.origin.x, v.frame.origin.y,
               v.frame.size.width, v.frame.size.height, v.hidden ? 1 : 0);
    }

    printf("顶栏控件状态:\n");
    printf("  _root 是窗口内容视图: %d\n", (_window.contentView == _root) ? 1 : 0);
    for (NSView *v in @[_titleLabel, _ffmpegLabel, _pageSwitch, _topBar]) {
        NSRect vis = v.visibleRect;
        printf("  %-20s alpha=%.2f 隐藏祖先=%d layer=%d 外表=%s 可见区=[%.0f,%.0f,%.0f,%.0f]\n",
               NSStringFromClass([v class]).UTF8String,
               v.alphaValue,
               [v isHiddenOrHasHiddenAncestor] ? 1 : 0,
               v.wantsLayer ? 1 : 0,
               v.effectiveAppearance.name.UTF8String,
               vis.origin.x, vis.origin.y, vis.size.width, vis.size.height);
    }

    NSView *pageView = _pages[(NSUInteger)_currentPage].view;
    printf("当前页视图: %s  %.0f x %.0f  子视图 %lu 个\n",
           NSStringFromClass([pageView class]).UTF8String,
           pageView.frame.size.width, pageView.frame.size.height,
           (unsigned long)pageView.subviews.count);

    NSArray<NSView *> *sorted = [pageView.subviews sortedArrayUsingComparator:^NSComparisonResult(
        NSView *a, NSView *b) {
        if (a.frame.origin.y < b.frame.origin.y) return NSOrderedAscending;
        if (a.frame.origin.y > b.frame.origin.y) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    for (NSView *v in sorted) {
        NSString *extra = @"";
        if ([v isKindOfClass:[NSTextField class]]) {
            NSString *s = [(NSTextField *)v stringValue];
            if (s.length > 26) s = [[s substringToIndex:26] stringByAppendingString:@"…"];
            extra = [NSString stringWithFormat:@"  \"%@\"", s];
        } else if ([v isKindOfClass:[DropWellView class]]) {
            extra = [NSString stringWithFormat:@"  [%@]", [(DropWellView *)v caption]];
        } else if ([v isKindOfClass:[NSTableView class]]) {
            extra = [NSString stringWithFormat:@"  cols=%lu rowH=%.0f",
                                               (unsigned long)[(NSTableView *)v numberOfColumns],
                                               [(NSTableView *)v rowHeight]];
        } else if ([v isKindOfClass:[NSButton class]]) {
            extra = [NSString stringWithFormat:@"  \"%@\" state=%ld",
                                               [(NSButton *)v title],
                                               (long)[(NSButton *)v state]];
        }
        printf("  %-22s x=%4.0f y=%4.0f w=%4.0f h=%3.0f%s\n",
               NSStringFromClass([v class]).UTF8String,
               v.frame.origin.x, v.frame.origin.y,
               v.frame.size.width, v.frame.size.height, extra.UTF8String);
    }
    printf("=== 自检结束 ===\n");
    fflush(stdout);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (void)buildMenu {
    NSMenu *menubar = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [menubar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"关于 DITKit" action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"退出" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = menubar;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    id<DITToolPage> page = _pages[(NSUInteger)_currentPage];
    if ([page respondsToSelector:@selector(addInputPaths:)]) {
        [page addInputPaths:filenames];
    }
    [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

#pragma mark 构建窗口

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 740, 850);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                     NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"DITKit";
    _window.minSize = NSMakeSize(700, 760);
    // 窗口底色由窗口负责（内容视图不再自己画背景，见 DITUI.m 的说明）
    _window.backgroundColor = [NSColor windowBackgroundColor];
    [_window center];

    _root = [[LayoutView alloc] initWithFrame:frame];
    __weak AppController *ws = self;
    _root.onLayout = ^{ [ws doLayout]; };
    _window.contentView = _root;

    // 顶栏：标题 + ffmpeg 状态 + 工具页切换
    // 单独放进一个容器视图，而不是直接挂在内容视图上（直接挂会导致控件不被绘制）
    _topBar = [[NSView alloc] initWithFrame:NSZeroRect];
    [_root addSubview:_topBar];

    _titleLabel = DITLabel(@"DITKit", 15, YES);
    [_topBar addSubview:_titleLabel];
    _ffmpegLabel = DITLabel(@"", 11, NO);
    _ffmpegLabel.alignment = NSTextAlignmentRight;
    [_topBar addSubview:_ffmpegLabel];

    // 工具页切换
    _pages = @[[[PageLUT alloc] init], [[PageTrim alloc] init]];
    _pageSwitch = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    _pageSwitch.segmentCount = (NSInteger)_pages.count;
    for (NSUInteger i = 0; i < _pages.count; i++) {
        [_pageSwitch setLabel:_pages[i].pageTitle forSegment:(NSInteger)i];
    }
    _pageSwitch.selectedSegment = 0;
    _pageSwitch.segmentStyle = NSSegmentStyleTexturedRounded;
    _pageSwitch.target = self;
    _pageSwitch.action = @selector(switchPage:);
    [_topBar addSubview:_pageSwitch];

    // 页面容器：所有页都挂进来，用 hidden 控制显示，这样各自的输入状态不会丢
    _pageHost = [[NSView alloc] initWithFrame:NSZeroRect];
    [_root addSubview:_pageHost];
    for (id<DITToolPage> p in _pages) {
        [p.view setHidden:YES];
        [_pageHost addSubview:p.view];
    }
    _currentPage = 0;
    _pages[0].view.hidden = NO;
}

- (void)switchPage:(id)sender {
    NSInteger idx = _pageSwitch.selectedSegment;
    if (idx < 0 || idx >= (NSInteger)_pages.count) return;
    for (NSUInteger i = 0; i < _pages.count; i++) {
        _pages[i].view.hidden = ((NSInteger)i != idx);
    }
    _currentPage = idx;
    [self doLayout];
}

#pragma mark 布局

- (void)doLayout {
    if (!_root || !_pageHost) return;
    NSRect b = _root.bounds;
    CGFloat W = b.size.width;
    CGFloat H = b.size.height;
    const CGFloat PAD = 18.0;
    CGFloat x = PAD;
    CGFloat w = W - PAD * 2;
    CGFloat y = PAD;

    // 顶栏容器：普通 NSView（非翻转），子控件坐标自下而上
    const CGFloat BAR_H = 66.0;
    DITFrame(_topBar, x, y, w, BAR_H);
    DITFrame(_titleLabel, 0, BAR_H - 20, w * 0.5, 20);
    DITFrame(_ffmpegLabel, w * 0.5, BAR_H - 18, w * 0.5, 16);
    CGFloat switchW = MIN(w, 130.0 * (CGFloat)_pages.count);
    DITFrame(_pageSwitch, 0, BAR_H - 56, switchW, 26);
    y += BAR_H + 10;

    DITFrame(_pageHost, x, y, w, MAX(120, H - PAD - y));

    // 页面视图铺满容器，并让它自己重排内部控件
    NSRect host = _pageHost.bounds;
    for (id<DITToolPage> p in _pages) {
        DITFrame(p.view, 0, 0, host.size.width, host.size.height);
        [p layoutInBounds:p.view.bounds];
    }
}

@end

#pragma mark - 命令行

static void PrintUsage(void) {
    fprintf(stderr,
            "DITKit —— 视频工具箱\n\n"
            "  DITKit                                 打开图形界面\n"
            "  DITKit --cli --lut  <LUT> [选项] -- <视频...>    批量套 LUT\n"
            "  DITKit --cli --trim --end <时间> [选项] -- <视频...>   裁剪片段\n\n"
            "LUT 模式:\n%s\n"
            "裁剪模式:\n%s",
            [[PageLUT cliUsage] UTF8String],
            [[PageTrim cliUsage] UTF8String]);
}

static int RunCLI(NSArray<NSString *> *args) {
    BOOL wantsLUT = NO, wantsTrim = NO;
    for (NSString *a in args) {
        if ([a isEqualToString:@"--lut"]) wantsLUT = YES;
        if ([a isEqualToString:@"--trim"]) wantsTrim = YES;
    }
    if (wantsLUT) return [PageLUT runCLI:args];
    if (wantsTrim) return [PageTrim runCLI:args];
    PrintUsage();
    return 2;
}

#pragma mark - 入口

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 2 && strcmp(argv[1], "--cli") == 0) {
            NSMutableArray<NSString *> *args = [NSMutableArray array];
            for (int i = 2; i < argc; i++) {
                [args addObject:[NSString stringWithUTF8String:argv[i]]];
            }
            return RunCLI(args);
        }
        if (argc >= 2 && (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) {
            PrintUsage();
            return 0;
        }
        if (argc >= 2 && strcmp(argv[1], "--selftest") == 0) gSelfTest = YES;
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppController *controller = [[AppController alloc] init];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
