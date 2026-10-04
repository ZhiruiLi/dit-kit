//
//  Engine.h —— DITKit 通用转换引擎
//
//  这里只放「与具体工具无关」的东西：
//    · DITJob           任务模型
//    · DITOutputOptions 输出路径 / 命名冲突 / 并发数 / 扩展名过滤
//    · DITEngine        并发执行器：调度 ffmpeg 子进程、解析进度、汇报状态
//
//  具体工具（LUT 调色、视频裁剪）通过 argumentsBuilder 回调提供自己的 ffmpeg 参数，
//  所以新增一个工具不需要动这个文件。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DITOutMode) {
    DITOutModeAbsolute = 0,
    DITOutModeRelativeToSource = 1,
};

typedef NS_ENUM(NSInteger, DITConflictPolicy) {
    DITConflictSkip = 0,
    DITConflictOverwrite = 1,
    DITConflictRename = 2,
};

typedef NS_ENUM(NSInteger, DITJobState) {
    DITJobStatePending = 0,
    DITJobStateRunning,
    DITJobStateDone,
    DITJobStateSkipped,
    DITJobStateFailed,
    DITJobStateCancelled,
};

#pragma mark - 任务

@interface DITJob : NSObject
@property (nonatomic, copy) NSString *inputPath;
@property (nonatomic, copy, nullable) NSString *outputPath;
@property (nonatomic, assign) DITJobState state;
@property (nonatomic, assign) double progress;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, copy) NSString *errorText;
@property (nonatomic, copy) NSString *displayName;   // 文件名
@property (nonatomic, copy) NSString *displayFolder; // 所在目录（用于列表副标题）
@end

#pragma mark - 输出策略

@interface DITOutputOptions : NSObject
@property (nonatomic, assign) DITOutMode outMode;
@property (nonatomic, copy) NSString *outValue;      // 绝对路径，或相对于源文件的子目录
@property (nonatomic, copy) NSString *suffix;        // 输出文件名后缀
@property (nonatomic, assign) DITConflictPolicy conflict;
@property (nonatomic, assign) NSInteger maxConcurrent;
@property (nonatomic, copy) NSString *extensionFilter; // 空格分隔的小写扩展名
@end

/// 把任务翻译成 ffmpeg 参数：必须自带 `-i <输入>`，但不要带输出文件名（引擎会补）
typedef NSArray<NSString *> *_Nonnull (^DITArgsBuilder)(DITJob *job, NSString *outputPath);

#pragma mark - 执行器

@interface DITEngine : NSObject

- (instancetype)initWithJobs:(NSArray<DITJob *> *)jobs
                      output:(DITOutputOptions *)output
            argumentsBuilder:(DITArgsBuilder)builder;

/// 工具特有的前置检查；返回非空字符串则中止启动，并把它当作错误展示
@property (nonatomic, copy, nullable) NSString * (^preflight)(void);
/// 预期输出时长（秒），用于换算进度；不设置时回退为 ffmpeg 报告的源时长
@property (nonatomic, copy, nullable) double (^expectedDuration)(DITJob *job);

@property (nonatomic, copy, nullable) void (^onJobUpdate)(DITJob *job);
@property (nonatomic, copy, nullable) void (^onFinished)(void);
@property (nonatomic, readonly, getter=isRunning) BOOL running;

- (BOOL)startWithError:(NSString *_Nullable *_Nullable)error;
- (void)cancel;

#pragma mark 公共工具

/// 在 PATH 与常见安装位置中查找可执行文件
+ (nullable NSString *)resolveTool:(NSString *)name;
/// 单行 filter 内路径转义（ffmpeg filter 语法）
+ (NSString *)escapeFilterValue:(NSString *)value;
/// 收集视频文件（目录会递归展开）；excludeSuffix 用于跳过已处理过的产物
+ (NSArray<NSString *> *)videoFilesFromPaths:(NSArray<NSString *> *)paths
                                      filter:(NSString *)filter
                               excludeSuffix:(nullable NSString *)suffix;

/// 时间码 → 秒。支持 01:30:00.500 / 1:30 / 90 / 90s / 1m30s；解析失败返回 -1
+ (double)secondsFromTimeString:(NSString *)t;
/// 秒 → 00:01:30.500
+ (NSString *)timeStringFromSeconds:(double)s;
/// 用 ffprobe 读取媒体时长（秒），失败返回 0
+ (double)probeDuration:(NSString *)path;
/// 用 ffprobe 读取一行媒体摘要（分辨率 / 帧率 / 编码），失败返回 nil
+ (nullable NSString *)probeSummary:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
