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
/// 可选的接收判断：返回 NO 时拖放区不亮起、也不接受放下（例如后缀名不对）。
/// 块里可以顺手更新状态行，把拒绝的原因讲清楚。
@property (nonatomic, copy, nullable) BOOL (^willAcceptPaths)(NSArray<NSString *> *paths);
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
/// 次要操作的圆角小按钮（「添加文件…」「删除选中」这类）
NSButton *DITButton(NSString *title, id _Nullable target, SEL _Nullable action);
/// 统一取整摆放，避免亚像素造成的模糊
void DITFrame(NSView *_Nullable v, CGFloat x, CGFloat y, CGFloat w, CGFloat h);
/// 摆放分区标题并把 y 推进到内容起点
void DITPlaceSection(NSTextField *_Nullable label, CGFloat *y, CGFloat x, CGFloat w);

#pragma mark - 任务表格

/// 三列任务表（文件 / 位置 / 状态），各工具页共用。
///
/// 列表本身就是拖入区：整块内容视图（含行下方的空白）都能接住文件，
/// 空列表时在中间显示引导文字。列分隔条可以拖，拖过之后就不再自动分配列宽。
@interface DITJobTable : NSObject
@property (nonatomic, strong, readonly) NSScrollView *scrollView;
@property (nonatomic, strong, readonly) NSMutableArray<DITJob *> *jobs;

/// 空列表时显示在中间的引导（主句 + 可选副句）
@property (nonatomic, copy, nullable) NSString *emptyHint;
@property (nonatomic, copy, nullable) NSString *emptySubHint;

/// 拖入文件/文件夹时回调；paths 没做过滤，由工具页决定怎么处理
@property (nonatomic, copy, nullable) void (^onDropPaths)(NSArray<NSString *> *paths);
/// 处理中要关掉拖入
@property (nonatomic, assign) BOOL dropEnabled;
/// 选中项变化（用来刷新「删除选中」按钮的可用状态）
@property (nonatomic, copy, nullable) void (^onSelectionChanged)(void);
/// 在列表里按了 Delete / Backspace（等价于点「删除选中」）
@property (nonatomic, copy, nullable) void (^onDeleteRequested)(void);

@property (nonatomic, readonly) BOOL hasSelection;
@property (nonatomic, readonly, copy) NSArray<DITJob *> *selectedJobs;
/// 删除选中项，返回实际删掉的条数
- (NSInteger)removeSelectedJobs;
/// 全选（自检与「删除选中」配合用）
- (void)selectAllJobs;

- (void)reloadAll;
- (void)reloadRowOfJob:(DITJob *)job;
/// 按容器宽度重算三列列宽（位置列吃掉余量）；用户拖过分隔条之后不再生效
- (void)layoutColumnsForWidth:(CGFloat)w;

/// 自检用：直接把第 index 列加宽 delta，等价于用户拖了一下分隔条
- (void)simulateColumnResize:(NSInteger)index delta:(CGFloat)delta;
/// 自检/诊断用：当前各列列宽
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *columnWidths;
/// 自检/诊断用：当前各列的 resizingMask（含 NSTableColumnUserResizingMask 才拖得动）
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *columnResizingMasks;
@end

#pragma mark - 底部操作栏

/// 开始 / 停止 / 清空 / 打开输出目录 + 进度条 + 状态行
@interface DITActionBar : NSObject
@property (nonatomic, copy, nullable) void (^onStart)(void);
@property (nonatomic, copy, nullable) void (^onStop)(void);
@property (nonatomic, copy, nullable) void (^onClear)(void);
@property (nonatomic, copy, nullable) void (^onReveal)(void);

/// 状态行当前文字（自检断言用）
@property (nonatomic, readonly, copy) NSString *statusText;

- (void)addToView:(NSView *)superview;
- (void)setStartTitle:(NSString *)title;
- (void)setStatus:(NSString *)status;
- (void)setProgress:(double)progress;
- (void)setRunning:(BOOL)running canStart:(BOOL)canStart;
/// 单独控制「停止」键。停止过程中把它置灰，避免重复点击
- (void)setStopEnabled:(BOOL)enabled;

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
/// 直接停止（等价于点「停止」按钮；主要给自检用）
- (void)beginStop;
/// 全选列表里的条目（自检用）
- (void)selectAllJobs;
/// 删除列表里选中的条目（等价于点「删除选中」按钮；自检用）
- (void)deleteSelectedJobs;
/// 自检用：模拟拖动列表的列分隔条（把第 index 列加宽 delta）
- (void)simulateColumnResize:(NSInteger)index delta:(CGFloat)delta;
/// 状态行当前文字（自检断言用）
- (NSString *)statusLine;
@end

NS_ASSUME_NONNULL_END
