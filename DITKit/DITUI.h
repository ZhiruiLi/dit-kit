//
//  DITUI.h —— DITKit 共享界面零件
//
//  把 DropWellView / LayoutView / 控件工厂 / 任务表格 / 底部操作栏 抽出来，
//  让每个工具页（LUT 批量调色、视频裁剪 …）只关心自己特有的控件。
//

#import <Cocoa/Cocoa.h>
#import "Engine.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 拖放区

/// 虚线拖放区：可接住文件/文件夹拖入，也可点击触发选择
@interface DropWellView : NSView
@property (nonatomic, copy) NSString *caption;
@property (nonatomic, copy) NSString *hint;
@property (nonatomic, assign) BOOL highlight;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy, nullable) void (^onPaths)(NSArray<NSString *> *paths);
@property (nonatomic, copy, nullable) void (^onClick)(void);
@end

#pragma mark - 容器

/// 以左上角为原点，尺寸变化时回调重排
@interface LayoutView : NSView
@property (nonatomic, copy, nullable) void (^onLayout)(void);
@end

#pragma mark - 控件工厂

/// 普通文本标签（bold=YES 用主标题样式）
NSTextField *DITLabel(NSString *text, CGFloat size, BOOL bold);
/// 分区标题，如「1 · LUT 文件」
NSTextField *DITSectionLabel(NSString *text);
/// 统一取整摆放，避免亚像素造成的模糊
void DITFrame(NSView *_Nullable v, CGFloat x, CGFloat y, CGFloat w, CGFloat h);
/// 摆放分区标题并把 y 推进到内容起点
void DITPlaceSection(NSTextField *_Nullable label, CGFloat *y, CGFloat x, CGFloat w);

#pragma mark - 任务表格

/// 三列任务表（文件 / 位置 / 状态），各工具页共用
@interface DITJobTable : NSObject
@property (nonatomic, strong, readonly) NSScrollView *scrollView;
@property (nonatomic, strong, readonly) NSMutableArray<DITJob *> *jobs;
- (void)reloadAll;
- (void)reloadRowOfJob:(DITJob *)job;
/// 按容器宽度重算三列列宽（位置列吃掉余量）
- (void)layoutColumnsForWidth:(CGFloat)w;
@end

#pragma mark - 底部操作栏

/// 开始 / 停止 / 清空 / 打开输出目录 + 进度条 + 状态行
@interface DITActionBar : NSObject
@property (nonatomic, copy, nullable) void (^onStart)(void);
@property (nonatomic, copy, nullable) void (^onStop)(void);
@property (nonatomic, copy, nullable) void (^onClear)(void);
@property (nonatomic, copy, nullable) void (^onReveal)(void);

- (void)addToView:(NSView *)superview;
- (void)setStartTitle:(NSString *)title;
- (void)setStatus:(NSString *)status;
- (void)setProgress:(double)progress;
- (void)setRunning:(BOOL)running canStart:(BOOL)canStart;

/// 从容器底部向上排放，返回表格区可用的底部边界
- (CGFloat)layoutFromBottom:(CGFloat)bottom x:(CGFloat)x width:(CGFloat)w;
@end

#pragma mark - 工具页协议

/// 一个工具页（LUT 批量调色、视频裁剪 …）。主窗口只管切换，不关心页里有什么。
@protocol DITToolPage <NSObject>
/// 页面根容器
@property (nonatomic, readonly) NSView *view;
/// 切换控件上显示的名字
@property (nonatomic, readonly) NSString *pageTitle;
/// 是否正在处理任务（切换页、关窗时用得上）
@property (nonatomic, readonly) BOOL busy;
/// 容器尺寸确定后重排内部控件
- (void)layoutInBounds:(NSRect)bounds;
@optional
/// 外部投喂文件（打开文件、自检注入）
- (void)addInputPaths:(NSArray<NSString *> *)paths;
/// 直接开始处理（等价于点「开始」按钮；自检、将来的「拖入即跑」都用它）
- (void)beginRun;
@end

NS_ASSUME_NONNULL_END
