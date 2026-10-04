//  Engine.m —— DITKit 通用转换引擎的实现

#import "Engine.h"
#import <signal.h>   // kill / SIGKILL：停止流程的信号升级兜底

#pragma mark - 任务

@implementation DITJob
- (instancetype)init {
    if ((self = [super init])) {
        _state = DITJobStatePending;
        _statusText = @"等待中";
        _errorText = @"";
        _progress = 0;
        _displayName = @"";
        _displayFolder = @"";
        _inputPath = @"";
    }
    return self;
}
@end

#pragma mark - 输出策略

@implementation DITOutputOptions
- (instancetype)init {
    if ((self = [super init])) {
        _outMode = DITOutModeRelativeToSource;
        _outValue = @"out";
        _maxConcurrent = 4;
        _conflict = DITConflictSkip;
        _suffix = @"_out";
        _extensionFilter = @"mp4 mov m4v mkv avi mxf mp4v hevc ts";
    }
    return self;
}
@end

#pragma mark - 内部任务盒子

@interface DITTaskBox : NSObject
@property (nonatomic, strong) DITJob *job;
@property (nonatomic, strong) NSTask *task;
@property (nonatomic, strong) NSPipe *outPipe;
@property (nonatomic, strong) NSPipe *errPipe;
@property (nonatomic, strong) NSMutableString *errBuf;
@property (nonatomic, assign) double durationSec;   // ffmpeg 报告的源时长
@property (nonatomic, assign) double expectedSec;   // 工具声明的预期输出时长
@property (nonatomic, assign) BOOL sawDuration;
@property (nonatomic, assign) BOOL sawProgressLine;
@end

@implementation DITTaskBox
- (instancetype)init {
    if ((self = [super init])) {
        _errBuf = [NSMutableString string];
    }
    return self;
}
@end

#pragma mark - 引擎

@interface DITEngine ()
+ (NSSet<NSString *> *)extensionSetFromFilter:(NSString *)filter;
+ (BOOL)isSkippable:(NSString *)path suffix:(nullable NSString *)suffix;
+ (NSString *)tailOf:(NSString *)s lines:(NSInteger)n;
+ (double)fpsFromRational:(NSString *)rational;
@end

@implementation DITEngine {
    DITOutputOptions *_output;
    NSArray<DITJob *> *_jobs;
    NSMutableArray<DITJob *> *_queue;
    NSMutableSet<DITTaskBox *> *_active;
    DITArgsBuilder _builder;
    NSString *_ffmpeg;
    BOOL _running;
    BOOL _cancelled;
}

#pragma mark 工具查找

+ (NSString *)resolveTool:(NSString *)name {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *cands = [NSMutableArray array];

    NSString *envPath = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
    for (NSString *dir in [envPath componentsSeparatedByString:@":"]) {
        if (dir.length) [cands addObject:[dir stringByAppendingPathComponent:name]];
    }
    for (NSString *dir in @[@"/opt/homebrew/bin", @"/usr/local/bin", @"/usr/bin", @"/bin"]) {
        [cands addObject:[dir stringByAppendingPathComponent:name]];
    }
    NSString *res = [[NSBundle mainBundle] resourcePath];
    if (res) [cands addObject:[res stringByAppendingPathComponent:name]];

    for (NSString *p in cands) {
        if ([fm isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

+ (NSString *)escapeFilterValue:(NSString *)value {
    NSMutableString *m = [value mutableCopy];
    [m replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"'" withString:@"\\'" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@":" withString:@"\\:" options:0 range:NSMakeRange(0, m.length)];
    return [NSString stringWithFormat:@"'%@'", m];
}

+ (NSSet<NSString *> *)extensionSetFromFilter:(NSString *)filter {
    NSMutableSet *set = [NSMutableSet set];
    NSArray *parts = [filter componentsSeparatedByCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *p in parts) {
        NSString *t = [p lowercaseString];
        if (t.length) [set addObject:t];
    }
    if (set.count == 0) {
        [set addObjectsFromArray:@[@"mp4", @"mov", @"m4v", @"mkv", @"avi", @"mxf"]];
    }
    return set;
}

+ (NSArray<NSString *> *)videoFilesFromPaths:(NSArray<NSString *> *)paths
                                      filter:(NSString *)filter
                               excludeSuffix:(NSString *)suffix {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSSet *exts = [self extensionSetFromFilter:filter];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (NSString *p in paths) {
        NSString *abs = [p stringByStandardizingPath];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:abs isDirectory:&isDir]) continue;

        if (isDir) {
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:abs];
            for (NSString *rel in en) {
                NSString *full = [abs stringByAppendingPathComponent:rel];
                BOOL d = NO;
                if (![fm fileExistsAtPath:full isDirectory:&d] || d) continue;
                if ([self isSkippable:full suffix:suffix]) continue;
                if ([exts containsObject:[[full pathExtension] lowercaseString]] &&
                    ![seen containsObject:full]) {
                    [seen addObject:full];
                    [out addObject:full];
                }
            }
        } else {
            if (![self isSkippable:abs suffix:suffix] &&
                [exts containsObject:[[abs pathExtension] lowercaseString]] &&
                ![seen containsObject:abs]) {
                [seen addObject:abs];
                [out addObject:abs];
            }
        }
    }
    [out sortUsingSelector:@selector(localizedStandardCompare:)];
    return out;
}

/// 隐藏文件、以及文件名已经带输出后缀的产物，都不再作为输入
+ (BOOL)isSkippable:(NSString *)path suffix:(NSString *)suffix {
    NSString *name = [path lastPathComponent];
    if ([name hasPrefix:@"."]) return YES;
    for (NSString *comp in [path pathComponents]) {
        if ([comp hasPrefix:@"."]) return YES;
    }
    // suffix 为空时 hasSuffix: 恒为真，必须先挡掉
    if (suffix.length == 0) return NO;

    NSString *stem = [name stringByDeletingPathExtension];
    if ([stem hasSuffix:suffix]) return YES;

    // 命名冲突选「重命名」时产物形如 <名字><后缀> (1).mp4，
    // 只认 _graded 结尾会把它们当成新素材再处理一遍，所以这里一并识别
    NSRange r = [stem rangeOfString:[suffix stringByAppendingString:@" ("]
                            options:NSBackwardsSearch];
    if (r.location == NSNotFound) return NO;
    NSString *tail = [stem substringFromIndex:r.location + suffix.length];
    if (tail.length < 4 || ![tail hasPrefix:@" ("] || ![tail hasSuffix:@")"]) return NO;
    NSString *digits = [tail substringWithRange:NSMakeRange(2, tail.length - 3)];
    if (digits.length == 0) return NO;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [digits rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

#pragma mark 生命周期

- (instancetype)initWithJobs:(NSArray<DITJob *> *)jobs
                      output:(DITOutputOptions *)output
            argumentsBuilder:(DITArgsBuilder)builder {
    if ((self = [super init])) {
        _output = output;
        _builder = [builder copy];
        _jobs = [jobs copy];
        _queue = [NSMutableArray arrayWithArray:_jobs];
        _active = [NSMutableSet set];
    }
    return self;
}

- (BOOL)isRunning { return _running; }

- (BOOL)startWithError:(NSString **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 工具特有的前置检查（LUT 是否存在、时间范围是否合法 …）
    if (self.preflight) {
        NSString *msg = self.preflight();
        if (msg.length) {
            if (error) *error = msg;
            return NO;
        }
    }
    if (!_builder) {
        if (error) *error = @"内部错误：没有为这个工具提供 ffmpeg 参数";
        return NO;
    }
    if (_jobs.count == 0) {
        if (error) *error = @"还没有拖入任何视频文件";
        return NO;
    }
    _ffmpeg = [DITEngine resolveTool:@"ffmpeg"];
    if (!_ffmpeg) {
        if (error) *error = @"找不到 ffmpeg，请先执行：brew install ffmpeg";
        return NO;
    }
    if (_output.outMode == DITOutModeAbsolute) {
        NSString *dir = [_output.outValue stringByExpandingTildeInPath];
        if (dir.length == 0) {
            if (error) *error = @"指定绝对路径模式下，输出目录不能为空";
            return NO;
        }
        NSError *e = nil;
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&e]) {
            if (error) *error = [NSString stringWithFormat:@"无法创建输出目录：%@", e.localizedDescription];
            return NO;
        }
    }

    _cancelled = NO;
    _running = YES;
    [self pump];
    return YES;
}

- (void)cancel {
    if (!_running) return;
    _cancelled = YES;

    // 1) 正在跑的：发 SIGTERM（ffmpeg 实测 0.25s 内就退出）
    NSArray<DITTaskBox *> *active = [_active copy];
    for (DITTaskBox *box in active) {
        if (box.task.isRunning) [box.task terminate];
    }

    // 2) 还在排队的：直接判为已取消并把队列清空。
    //    这一步不能省 —— pump 的调度循环带 `!_cancelled` 守卫，
    //    而收尾条件是 `_active.count == 0 && _queue.count == 0`。
    //    只打标记不清队列的话，队列永远不会被消费，收尾条件永不成立，
    //    onFinished 不触发，界面就永久停在「正在停止…」。
    if (_queue.count) {
        for (DITJob *job in _queue) {
            job.state = DITJobStateCancelled;
            job.statusText = @"已取消";
            [self notify:job];
        }
        [_queue removeAllObjects];
    }

    // 3) 兜底：SIGTERM 之后若还有任务赖着不走，1.5 秒后升级成 SIGKILL。
    //    硬编（Videotoolbox）偶尔会卡在驱动里不响应信号，没有这层「停止」会假死。
    if (active.count) {
        __weak DITEngine *ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DITEngine *ss = ws;
            if (!ss) return;
            for (DITTaskBox *box in [ss->_active copy]) {
                if (box.task.isRunning) kill(box.task.processIdentifier, SIGKILL);
            }
        });
    }

    // 4) 此刻若已无活跃任务，pump 会立刻收尾；否则等最后一个终止回调再收尾
    [self pump];
}

#pragma mark 调度

- (void)notify:(DITJob *)job {
    if (self.onJobUpdate) self.onJobUpdate(job);
}

- (void)pump {
    NSInteger maxC = MAX(1, _output.maxConcurrent);

    if (_cancelled) {
        // 双保险：正常路径下 cancel 已经清空队列，这里再兜一次，
        // 保证「取消后队列必为空」这个不变量在任何调用路径下都成立。
        while (_queue.count > 0) {
            DITJob *job = _queue.firstObject;
            [_queue removeObjectAtIndex:0];
            job.state = DITJobStateCancelled;
            job.statusText = @"已取消";
            [self notify:job];
        }
    } else {
        while (_active.count < (NSUInteger)maxC && _queue.count > 0) {
            DITJob *job = _queue.firstObject;
            [_queue removeObjectAtIndex:0];
            [self launchJob:job];
        }
    }

    // 收尾条件：既没有在跑的，也没有排队的
    if (_active.count == 0 && _queue.count == 0) {
        if (_running) {
            _running = NO;
            if (self.onFinished) self.onFinished();
        }
    }
}

- (void)launchJob:(DITJob *)job {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *inPath = job.inputPath;
    NSString *srcDir = [inPath stringByDeletingLastPathComponent];

    // 输出目录
    NSString *dir;
    if (_output.outMode == DITOutModeAbsolute) {
        dir = [_output.outValue stringByExpandingTildeInPath];
    } else {
        NSString *rel = _output.outValue;
        if (rel.length == 0 || [rel isEqualToString:@"."] || [rel isEqualToString:@"./"]) {
            dir = srcDir;
        } else {
            dir = [srcDir stringByAppendingPathComponent:rel];
        }
    }

    NSString *stem = [[inPath lastPathComponent] stringByDeletingPathExtension];
    NSString *ext = [inPath pathExtension];
    NSString *name = [NSString stringWithFormat:@"%@%@.%@", stem, _output.suffix, ext];
    NSString *outPath = [dir stringByAppendingPathComponent:name];

    // 命名冲突
    if (_output.conflict == DITConflictRename) {
        int n = 1;
        while ([fm fileExistsAtPath:outPath]) {
            name = [NSString stringWithFormat:@"%@%@ (%d).%@", stem, _output.suffix, n++, ext];
            outPath = [dir stringByAppendingPathComponent:name];
        }
    } else if (_output.conflict == DITConflictSkip && [fm fileExistsAtPath:outPath]) {
        job.outputPath = outPath;
        job.state = DITJobStateSkipped;
        job.progress = 1.0;
        job.statusText = @"已存在，跳过";
        [self notify:job];
        return;
    }

    // 防止覆盖源文件
    if ([[outPath stringByStandardizingPath] isEqualToString:[inPath stringByStandardizingPath]]) {
        job.state = DITJobStateFailed;
        job.statusText = @"失败";
        job.errorText = @"输出路径与源文件相同：后缀不能为空，或请更换输出目录";
        [self notify:job];
        return;
    }

    NSError *e = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&e]) {
        job.state = DITJobStateFailed;
        job.statusText = @"失败";
        job.errorText = [NSString stringWithFormat:@"无法创建目录 %@：%@", dir, e.localizedDescription];
        [self notify:job];
        return;
    }

    // 通用前缀 + 由工具页提供的参数（含 -i）+ 输出文件
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    [args addObjectsFromArray:@[@"-hide_banner", @"-nostdin", @"-nostats",
                                @"-progress", @"pipe:1"]];
    [args addObject:(_output.conflict == DITConflictOverwrite ? @"-y" : @"-n")];
    [args addObjectsFromArray:_builder(job, outPath)];
    [args addObject:outPath];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = _ffmpeg;
    task.arguments = args;

    DITTaskBox *box = [[DITTaskBox alloc] init];
    box.job = job;
    box.task = task;
    box.outPipe = [NSPipe pipe];
    box.errPipe = [NSPipe pipe];
    if (self.expectedDuration) box.expectedSec = self.expectedDuration(job);
    task.standardOutput = box.outPipe;
    task.standardError = box.errPipe;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];

    job.outputPath = outPath;
    job.state = DITJobStateRunning;
    job.statusText = @"处理中 0%";
    job.progress = 0;

    __weak DITEngine *ws = self;
    __weak DITTaskBox *wbox = box;

    box.outPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *fh) {
        NSData *d = fh.availableData;
        if (d.length == 0) return;
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (!s) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            DITTaskBox *b = wbox;
            DITEngine *ss = ws;
            if (b && ss) [ss consumeProgress:s box:b];
        });
    };

    box.errPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *fh) {
        NSData *d = fh.availableData;
        if (d.length == 0) return;
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (!s) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            DITTaskBox *b = wbox;
            DITEngine *ss = ws;
            if (b && ss) [ss consumeStderr:s box:b];
        });
    };

    task.terminationHandler = ^(NSTask *t) {
        DITTaskBox *tb = wbox;
        if (!tb) return;
        tb.outPipe.fileHandleForReading.readabilityHandler = nil;
        tb.errPipe.fileHandleForReading.readabilityHandler = nil;
        NSData *restOut = [tb.outPipe.fileHandleForReading readDataToEndOfFile];
        NSData *restErr = [tb.errPipe.fileHandleForReading readDataToEndOfFile];
        NSString *so = [[NSString alloc] initWithData:restOut encoding:NSUTF8StringEncoding];
        NSString *se = [[NSString alloc] initWithData:restErr encoding:NSUTF8StringEncoding];
        int status = t.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            DITTaskBox *b = wbox;
            DITEngine *ss = ws;
            if (!b || !ss) return;
            if (so.length) [ss consumeProgress:so box:b];
            if (se.length) [ss consumeStderr:se box:b];
            [ss finishBox:b status:status];
        });
    };

    [_active addObject:box];
    [self notify:job];

    NSError *launchErr = nil;
    if (![task launchAndReturnError:&launchErr]) {
        box.outPipe.fileHandleForReading.readabilityHandler = nil;
        box.errPipe.fileHandleForReading.readabilityHandler = nil;
        [_active removeObject:box];
        job.state = DITJobStateFailed;
        job.statusText = @"失败";
        job.errorText = [NSString stringWithFormat:@"无法启动 ffmpeg：%@", launchErr.localizedDescription];
        [self notify:job];
    }
}

#pragma mark 输出解析

- (void)consumeProgress:(NSString *)text box:(DITTaskBox *)box {
    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        if ([line hasPrefix:@"out_time_us="]) {
            double us = [[line substringFromIndex:12] doubleValue];
            box.sawProgressLine = YES;
            [self applyTime:us / 1e6 box:box];
        } else if ([line hasPrefix:@"out_time="]) {
            NSString *t = [line substringFromIndex:9];
            box.sawProgressLine = YES;
            double sec = [DITEngine secondsFromTimeString:t];
            if (sec >= 0) [self applyTime:sec box:box];
        } else if ([line hasPrefix:@"progress=end"]) {
            box.job.progress = 1.0;
        }
    }
}

- (void)consumeStderr:(NSString *)text box:(DITTaskBox *)box {
    [box.errBuf appendString:text];
    if (box.errBuf.length > 8000) {
        [box.errBuf deleteCharactersInRange:NSMakeRange(0, box.errBuf.length - 8000)];
    }
    if (!box.sawDuration) {
        NSRange r = [box.errBuf rangeOfString:@"Duration: "];
        if (r.location != NSNotFound) {
            NSString *rest = [box.errBuf substringFromIndex:NSMaxRange(r)];
            NSRange end = [rest rangeOfCharacterFromSet:
                           [NSCharacterSet characterSetWithCharactersInString:@",\n"]];
            NSString *t = (end.location == NSNotFound) ? rest : [rest substringToIndex:end.location];
            double d = [DITEngine secondsFromTimeString:t];
            if (d > 0) {
                box.durationSec = d;
                box.sawDuration = YES;
            }
        }
    }
}

- (void)applyTime:(double)sec box:(DITTaskBox *)box {
    DITJob *job = box.job;
    double total = box.expectedSec > 0.01 ? box.expectedSec : box.durationSec;
    if (total > 0.01) {
        job.progress = MIN(1.0, MAX(0.0, sec / total));
    } else {
        job.progress = MIN(0.98, job.progress + 0.002);
    }
    job.statusText = [NSString stringWithFormat:@"处理中 %.0f%%", job.progress * 100];
    [self notify:job];
}

#pragma mark 时间码

+ (double)secondsFromTimeString:(NSString *)t {
    NSString *raw = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) return -1;

    // 时间码写法：HH:MM:SS.mmm / MM:SS.mmm
    if ([raw containsString:@":"]) {
        NSArray<NSString *> *parts = [raw componentsSeparatedByString:@":"];
        if (parts.count > 3) return -1;
        double total = 0;
        for (NSString *p in parts) {
            NSString *q = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSScanner *sc = [NSScanner scannerWithString:q];
            double v = 0;
            if (q.length == 0 || ![sc scanDouble:&v] || !sc.isAtEnd) return -1;
            total = total * 60 + v;
        }
        return total;
    }

    // 带单位写法：1h30m / 90s / 1.5m / 90
    double total = 0;
    NSScanner *sc = [NSScanner scannerWithString:[raw lowercaseString]];
    while (!sc.isAtEnd) {
        double v = 0;
        if (![sc scanDouble:&v]) return -1;
        NSString *unit = @"";
        [sc scanCharactersFromSet:[NSCharacterSet lowercaseLetterCharacterSet] intoString:&unit];
        if (unit.length == 0) {
            total += v;                       // 无单位按秒
        } else if ([unit hasPrefix:@"h"]) {
            total += v * 3600;
        } else if ([unit hasPrefix:@"m"]) {
            total += v * 60;
        } else if ([unit hasPrefix:@"s"]) {
            total += v;
        } else {
            return -1;
        }
    }
    return total;
}

+ (NSString *)timeStringFromSeconds:(double)s {
    if (s < 0 || !isfinite(s)) s = 0;
    long total = (long)floor(s);
    long ms = (long)llround((s - (double)total) * 1000.0);
    if (ms >= 1000) { ms -= 1000; total += 1; }
    long h = total / 3600, m = (total % 3600) / 60, sec = total % 60;
    return [NSString stringWithFormat:@"%02ld:%02ld:%02ld.%03ld", h, m, sec, ms];
}

#pragma mark 媒体探测

+ (double)probeDuration:(NSString *)path {
    NSString *ffprobe = [self resolveTool:@"ffprobe"];
    if (!ffprobe) return 0;
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = ffprobe;
    t.arguments = @[@"-v", @"error", @"-show_entries", @"format=duration",
                    @"-of", @"default=nw=1:nk=1", path];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError = [NSPipe pipe];
    t.standardInput = [NSFileHandle fileHandleWithNullDevice];
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) return 0;
    NSData *d = [p.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    double v = [s doubleValue];
    return (isfinite(v) && v > 0) ? v : 0;
}

+ (NSString *)probeSummary:(NSString *)path {
    NSString *ffprobe = [self resolveTool:@"ffprobe"];
    if (!ffprobe) return nil;
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = ffprobe;
    t.arguments = @[@"-v", @"error", @"-select_streams", @"v:0",
                    @"-show_entries", @"stream=codec_name,width,height,r_frame_rate",
                    @"-of", @"default=nw=1", path];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError = [NSPipe pipe];
    t.standardInput = [NSFileHandle fileHandleWithNullDevice];
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) return nil;
    NSData *d = [p.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s.length) return nil;

    NSMutableDictionary<NSString *, NSString *> *kv = [NSMutableDictionary dictionary];
    for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        kv[[line substringToIndex:eq.location]] = [line substringFromIndex:NSMaxRange(eq)];
    }

    NSMutableArray<NSString *> *bits = [NSMutableArray array];
    NSInteger w = [kv[@"width"] integerValue];
    NSInteger h = [kv[@"height"] integerValue];
    if (w > 0 && h > 0) [bits addObject:[NSString stringWithFormat:@"%ld×%ld", (long)w, (long)h]];
    double fps = [self fpsFromRational:kv[@"r_frame_rate"]];
    if (fps > 0) [bits addObject:[NSString stringWithFormat:@"%.2f fps", fps]];
    if (kv[@"codec_name"].length) [bits addObject:kv[@"codec_name"]];
    return bits.count ? [bits componentsJoinedByString:@" · "] : nil;
}

+ (double)fpsFromRational:(NSString *)rational {
    if (!rational.length) return 0;
    NSArray *parts = [rational componentsSeparatedByString:@"/"];
    if (parts.count == 2) {
        double num = [parts[0] doubleValue], den = [parts[1] doubleValue];
        return (den > 0) ? num / den : 0;
    }
    return [rational doubleValue];
}

#pragma mark 收尾

- (void)finishBox:(DITTaskBox *)box status:(int)status {
    DITJob *job = box.job;
    [_active removeObject:box];

    if (_cancelled) {
        job.state = DITJobStateCancelled;
        job.statusText = @"已取消";
    } else if (status == 0) {
        job.state = DITJobStateDone;
        job.progress = 1.0;
        job.statusText = @"完成";
    } else {
        job.state = DITJobStateFailed;
        job.statusText = [NSString stringWithFormat:@"失败 (ffmpeg 退出码 %d)", status];
        job.errorText = [DITEngine tailOf:box.errBuf lines:12];
    }
    [self notify:job];
    [self pump];
}

+ (NSString *)tailOf:(NSString *)s lines:(NSInteger)n {
    NSArray *all = [s componentsSeparatedByString:@"\n"];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *l in all) {
        if (l.length) [keep addObject:l];
    }
    NSInteger start = MAX(0, (NSInteger)keep.count - n);
    return [[keep subarrayWithRange:NSMakeRange(start, keep.count - start)]
            componentsJoinedByString:@"\n"];
}

@end
