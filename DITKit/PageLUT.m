//  PageLUT.m —— 工具页：LUT 批量调色
//
//  这一页的活儿：把一批视频套同一个 LUT，走硬件编码输出。
//  ffmpeg 参数构造被单独抽成 DITLUTArguments()，所以 GUI 和 --cli 用的是同一份逻辑。

#import "PageLUT.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - ffmpeg 参数

NSArray<NSString *> *DITLUTArguments(DITJob *job, NSString *lutPath, NSInteger quality) {
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    [a addObjectsFromArray:@[@"-i", job.inputPath]];

    NSString *lut = [lutPath stringByExpandingTildeInPath];
    NSString *filter = [NSString stringWithFormat:@"lut3d=file=%@:interp=tetrahedral",
                        [DITEngine escapeFilterValue:lut]];
    [a addObjectsFromArray:@[@"-vf", filter]];

    [a addObjectsFromArray:@[@"-c:v", @"hevc_videotoolbox",
                             @"-q:v", [@(quality) stringValue],
                             @"-pix_fmt", @"p010le"]];

    NSString *lowExt = [[job.inputPath pathExtension] lowercaseString];
    if ([lowExt isEqualToString:@"mp4"] || [lowExt isEqualToString:@"mov"] ||
        [lowExt isEqualToString:@"m4v"]) {
        [a addObjectsFromArray:@[@"-tag:v", @"hvc1"]];
    }
    [a addObjectsFromArray:@[@"-c:a", @"copy"]];
    return a;
}

#pragma mark - LUT 文件名的判定

/// LUT 的合法后缀（ffmpeg 的 lut3d 只吃这几种）
static NSArray<NSString *> *DITLUTExtensions(void) {
    return @[@"cube", @"3dl", @"dat", @"m3d"];
}

/// 按后缀名判断像不像 LUT 文件（不看文件是否存在）
static BOOL DITIsLUTPath(NSString *path) {
    NSString *ext = [[path pathExtension] lowercaseString];
    return ext.length > 0 && [DITLUTExtensions() containsObject:ext];
}

/// 从一批路径里挑出第一个像 LUT 的（大小写不敏感）
static NSString *DITFirstLUTPath(NSArray<NSString *> *paths) {
    for (NSString *p in paths) {
        if (DITIsLUTPath(p)) return p;
    }
    return nil;
}

#pragma mark - 工具页

@implementation PageLUT {
    LayoutView *_view;

    NSTextField *_sec1Label, *_sec2Label, *_sec3Label, *_sec4Label;
    NSTextField *_c1Label, *_c2Label, *_c3Label;
    NSTextField *_qualityHint;
    DropWellView *_lutWell;

    NSSegmentedControl *_outModeSeg;
    NSTextField *_outField;
    NSButton *_outChooseBtn;
    NSTextField *_outHintLabel;

    NSTextField *_concValue;
    NSStepper *_concStepper;
    NSPopUpButton *_conflictPopup;
    NSSlider *_qualitySlider;
    NSTextField *_qualityValue;

    NSTextField *_filesCount;
    NSButton *_addFilesBtn, *_removeSelBtn;
    DITJobTable *_jobTable;
    DITActionBar *_actionBar;

    DITEngine *_engine;
    NSString *_lutPath;
    BOOL _stopping;          // 已点击停止、等引擎收尾；期间不让进度行覆盖提示
    NSString *_lastOutputDir;
}

- (instancetype)init {
    if ((self = [super init])) {
        _view = [[LayoutView alloc] initWithFrame:NSMakeRect(0, 0, 740, 600)];
        __weak PageLUT *ws = self;
        _view.onLayout = ^{ [ws doLayout]; };

        _jobTable = [[DITJobTable alloc] init];
        [self buildControls];
        [self loadDefaults];
        [self refreshAll];
    }
    return self;
}

- (NSView *)view { return _view; }
- (NSString *)pageTitle { return @"LUT 批量调色"; }
- (BOOL)busy { return _engine.isRunning; }

#pragma mark 构建界面

- (void)buildControls {
    __weak PageLUT *ws = self;

    // 1 · LUT 文件
    _sec1Label = DITSectionLabel(@"1 · LUT 文件");
    [_view addSubview:_sec1Label];

    _lutWell = [[DropWellView alloc] initWithFrame:NSZeroRect];
    _lutWell.caption = @"把 .cube 文件拖到这里";
    _lutWell.hint = @"或点击此处选择　·　支持 .cube / .3dl / .dat / .m3d";
    _lutWell.onPaths = ^(NSArray<NSString *> *paths) { [ws setLUTFromPaths:paths]; };
    _lutWell.onClick = ^{ [ws chooseLUT]; };
    // 后缀名不对（比如顺手拖进来一个视频）就当场拒收，并说明原因
    _lutWell.willAcceptPaths = ^BOOL(NSArray<NSString *> *paths) {
        if (DITFirstLUTPath(paths)) return YES;
        [ws reportRejectedLUT:paths];
        return NO;
    };
    [_view addSubview:_lutWell];

    // 2 · 输出目录
    _sec2Label = DITSectionLabel(@"2 · 输出目录");
    [_view addSubview:_sec2Label];

    _outModeSeg = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    _outModeSeg.segmentCount = 2;
    [_outModeSeg setLabel:@"相对源文件" forSegment:0];
    [_outModeSeg setLabel:@"绝对路径" forSegment:1];
    _outModeSeg.selectedSegment = 0;
    _outModeSeg.segmentStyle = NSSegmentStyleRounded;
    _outModeSeg.target = self;
    _outModeSeg.action = @selector(outModeChanged);
    [_view addSubview:_outModeSeg];

    _outField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _outField.placeholderString = @"graded";
    _outField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    _outField.target = self;
    _outField.action = @selector(saveDefaults);
    [_view addSubview:_outField];

    _outChooseBtn = [[NSButton alloc] initWithFrame:NSZeroRect];
    _outChooseBtn.title = @"选择…";
    _outChooseBtn.bezelStyle = NSBezelStyleRounded;
    _outChooseBtn.target = self;
    _outChooseBtn.action = @selector(chooseOutputDir);
    [_view addSubview:_outChooseBtn];

    _outHintLabel = DITLabel(@"", 11, NO);
    [_view addSubview:_outHintLabel];

    // 3 · 转换设置
    _sec3Label = DITSectionLabel(@"3 · 转换设置");
    [_view addSubview:_sec3Label];

    _c1Label = DITLabel(@"最大并发", 12, NO);
    [_view addSubview:_c1Label];

    _concValue = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _concValue.alignment = NSTextAlignmentCenter;
    _concValue.editable = NO;
    _concValue.bezeled = YES;
    _concValue.font = [NSFont systemFontOfSize:12];
    [_view addSubview:_concValue];

    _concStepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
    _concStepper.minValue = 1;
    _concStepper.maxValue = 16;
    _concStepper.increment = 1;
    _concStepper.valueWraps = NO;
    _concStepper.target = self;
    _concStepper.action = @selector(concChanged);
    [_view addSubview:_concStepper];

    _c2Label = DITLabel(@"命名冲突", 12, NO);
    [_view addSubview:_c2Label];

    _conflictPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_conflictPopup addItemsWithTitles:@[@"跳过", @"覆盖", @"自动加序号"]];
    _conflictPopup.font = [NSFont systemFontOfSize:12];
    _conflictPopup.target = self;
    _conflictPopup.action = @selector(saveDefaults);
    [_view addSubview:_conflictPopup];

    _c3Label = DITLabel(@"编码质量", 12, NO);
    [_view addSubview:_c3Label];

    _qualitySlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    _qualitySlider.minValue = 10;
    _qualitySlider.maxValue = 90;
    _qualitySlider.doubleValue = 55;
    _qualitySlider.continuous = YES;
    _qualitySlider.target = self;
    _qualitySlider.action = @selector(qualityChanged);
    [_view addSubview:_qualitySlider];

    _qualityValue = DITLabel(@"55", 12, NO);
    [_view addSubview:_qualityValue];

    _qualityHint = DITLabel(@"越大越清晰", 11, NO);
    [_view addSubview:_qualityHint];

    // 4 · 待转换文件（列表本身就是拖入区）
    _sec4Label = DITSectionLabel(@"4 · 待转换文件");
    [_view addSubview:_sec4Label];

    _filesCount = DITLabel(@"", 11, NO);
    _filesCount.alignment = NSTextAlignmentRight;
    [_view addSubview:_filesCount];

    _addFilesBtn = DITButton(@"添加文件…", self, @selector(chooseVideos));
    [_view addSubview:_addFilesBtn];

    _removeSelBtn = DITButton(@"删除选中", self, @selector(deleteSelectedJobs));
    [_view addSubview:_removeSelBtn];

    _jobTable.emptyHint = @"把视频拖到这里";
    _jobTable.emptySubHint = @"支持多选、多目录，也可以整个文件夹拖进来";
    _jobTable.onDropPaths = ^(NSArray<NSString *> *paths) { [ws addPaths:paths]; };
    _jobTable.onSelectionChanged = ^{ [ws refreshAll]; };
    _jobTable.onDeleteRequested = ^{ [ws deleteSelectedJobs]; };

    [_view addSubview:_jobTable.scrollView];

    // 底部
    _actionBar = [[DITActionBar alloc] init];
    [_actionBar setStartTitle:@"开始转换"];
    [_actionBar addToView:_view];
    _actionBar.onStart = ^{ [ws startConversion]; };
    _actionBar.onStop = ^{ [ws stopConversion]; };
    _actionBar.onClear = ^{ [ws clearJobs]; };
    _actionBar.onReveal = ^{ [ws revealOutput]; };
}

#pragma mark 布局

- (void)layoutInBounds:(NSRect)bounds {
    [self doLayout];
}

- (void)doLayout {
    if (!_view.superview) return;
    NSRect b = _view.bounds;
    CGFloat W = b.size.width;
    CGFloat H = b.size.height;
    const CGFloat PAD = 18.0;
    CGFloat x = PAD;
    CGFloat w = W - PAD * 2;
    CGFloat y = PAD;

    // 1 · LUT
    DITPlaceSection(_sec1Label, &y, x, w);
    DITFrame(_lutWell, x, y, w, 48);
    y += 48 + 14;

    // 2 · 输出
    DITPlaceSection(_sec2Label, &y, x, w);
    DITFrame(_outModeSeg, x, y, 280, 24);
    y += 24 + 8;
    CGFloat btnW = 88;
    DITFrame(_outField, x, y, w - btnW - 8, 24);
    DITFrame(_outChooseBtn, x + w - btnW, y, btnW, 24);
    y += 24 + 4;
    DITFrame(_outHintLabel, x, y, w, 14);
    y += 14 + 14;

    // 3 · 设置
    DITPlaceSection(_sec3Label, &y, x, w);
    CGFloat cy = y;
    DITFrame(_c1Label, x, cy + 2, 56, 18);
    DITFrame(_concValue, x + 58, cy + 1, 40, 21);
    DITFrame(_concStepper, x + 100, cy, 19, 22);
    DITFrame(_c2Label, x + 150, cy + 2, 56, 18);
    DITFrame(_conflictPopup, x + 208, cy, 130, 24);
    DITFrame(_c3Label, x + 366, cy + 2, 56, 18);
    DITFrame(_qualitySlider, x + 424, cy + 1, 110, 22);
    DITFrame(_qualityValue, x + 540, cy + 2, 28, 18);
    DITFrame(_qualityHint, x + 572, cy + 4, 132, 14);
    y += 26 + 14;

    // 4 · 文件（标题行右边放「添加文件…／删除选中」，计数贴左）
    CGFloat rh = 24.0;
    DITFrame(_sec4Label, x, y + 4, w * 0.4, 16);
    CGFloat bw2 = 92.0, bgap = 8.0;
    DITFrame(_removeSelBtn, x + w - bw2, y, bw2, rh);
    DITFrame(_addFilesBtn, x + w - bw2 * 2 - bgap, y, bw2, rh);
    DITFrame(_filesCount, x + w * 0.4, y + 6, w * 0.6 - bw2 * 2 - bgap - 8, 14);
    y += rh + 8;

    // 底部操作栏
    CGFloat tableBottom = [_actionBar layoutFromBottom:H - PAD x:x width:w];

    // 表格填满剩余空间
    [_jobTable layoutColumnsForWidth:w];
    DITFrame(_jobTable.scrollView, x, y, w, MAX(60, tableBottom - y));
}

#pragma mark 偏好

- (void)loadDefaults {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    // 自检 / 截图预览时可用环境变量注入 LUT，避免污染用户偏好
    const char *lutEnv = getenv("DITKIT_LUT");
    NSString *lut = lutEnv ? [NSString stringWithUTF8String:lutEnv] : [d stringForKey:@"lut.lutPath"];
    if (lut.length && [[NSFileManager defaultManager] fileExistsAtPath:lut]) {
        _lutPath = lut;
    } else {
        _lutPath = nil;
    }
    [self applyLUTDisplay];

    NSInteger mode = [d integerForKey:@"lut.outMode"];
    _outModeSeg.selectedSegment = (mode == 1) ? 1 : 0;
    NSString *outVal = [d stringForKey:@"lut.outValue"];
    _outField.stringValue = outVal.length ? outVal : @"graded";

    NSInteger conc = [d integerForKey:@"lut.concurrency"];
    if (conc <= 0) conc = 4;
    _concStepper.integerValue = conc;
    _concValue.stringValue = [NSString stringWithFormat:@"%ld", (long)conc];

    NSInteger conf = [d integerForKey:@"lut.conflict"];
    if (conf < 0 || conf > 2) conf = 0;
    [_conflictPopup selectItemAtIndex:conf];

    NSInteger q = [d integerForKey:@"lut.quality"];
    if (q <= 0) q = 55;
    _qualitySlider.doubleValue = q;
    _qualityValue.stringValue = [NSString stringWithFormat:@"%ld", (long)q];

    [self outModeChanged];
}

- (void)saveDefaults {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (_lutPath.length) {
        [d setObject:_lutPath forKey:@"lut.lutPath"];
    } else {
        [d removeObjectForKey:@"lut.lutPath"];
    }
    [d setInteger:_outModeSeg.selectedSegment forKey:@"lut.outMode"];
    [d setObject:_outField.stringValue forKey:@"lut.outValue"];
    [d setInteger:_concStepper.integerValue forKey:@"lut.concurrency"];
    [d setInteger:_conflictPopup.indexOfSelectedItem forKey:@"lut.conflict"];
    [d setInteger:(NSInteger)_qualitySlider.doubleValue forKey:@"lut.quality"];
}

#pragma mark 交互

- (void)applyLUTDisplay {
    if (_lutPath.length) {
        _lutWell.caption = [_lutPath lastPathComponent];
        _lutWell.hint = _lutPath;
    } else {
        _lutWell.caption = @"把 .cube 文件拖到这里";
        _lutWell.hint = @"或点击此处选择　·　支持 .cube / .3dl / .dat / .m3d";
    }
}

/// 拖进来的东西里一个 LUT 都没有 —— 把第一个不合格的说出来，别让人以为拖成功了
- (void)reportRejectedLUT:(NSArray<NSString *> *)paths {
    NSString *first = paths.firstObject;
    NSString *name = first ? [first lastPathComponent] : @"";
    BOOL isDir = NO;
    BOOL exists = first && [[NSFileManager defaultManager] fileExistsAtPath:first isDirectory:&isDir];
    NSBeep();
    if (first && !exists) {
        [_actionBar setStatus:[NSString stringWithFormat:@"找不到这个文件：%@", name]];
    } else if (isDir) {
        [_actionBar setStatus:@"LUT 需要一个文件，不能是文件夹"];
    } else {
        [_actionBar setStatus:[NSString stringWithFormat:
                               @"「%@」不是 LUT 文件，只接受 .cube / .3dl / .dat / .m3d", name]];
    }
}

- (void)setLUTFromPaths:(NSArray<NSString *> *)paths {
    if (paths.count == 0) return;

    // 一次拖进来多个文件时，挑第一个像 LUT 的
    NSString *candidate = DITFirstLUTPath(paths);
    BOOL isDir = NO;
    if (!candidate || ![[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDir]
        || isDir) {
        [self reportRejectedLUT:paths];
        return;
    }

    _lutPath = candidate;
    [self applyLUTDisplay];
    [self saveDefaults];
    [self refreshAll];
}

/// 自检用：把「拖动进入 → 落点」这两步都走一遍，并把结论打到标准输出
- (BOOL)simulateLUTDrop:(NSArray<NSString *> *)paths {
    BOOL accepted = _lutWell.willAcceptPaths ? _lutWell.willAcceptPaths(paths) : YES;
    NSString *name = paths.count ? [paths.firstObject lastPathComponent] : @"";
    printf("LUT 拖入: %s  %s\n", accepted ? "接受" : "拒绝", name.UTF8String);
    fflush(stdout);
    if (accepted && _lutWell.onPaths) _lutWell.onPaths(paths);
    return accepted;
}

- (void)simulateColumnResize:(NSInteger)index delta:(CGFloat)delta {
    [_jobTable simulateColumnResize:index delta:delta];
}

- (void)chooseLUT {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.message = @"选择 LUT 文件";
    if (@available(macOS 11.0, *)) {
        NSMutableArray<UTType *> *types = [NSMutableArray array];
        for (NSString *ext in @[@"cube", @"3dl", @"dat", @"m3d", @"CUBE"]) {
            UTType *t = [UTType typeWithFilenameExtension:ext];
            if (t) [types addObject:t];
        }
        if (types.count) panel.allowedContentTypes = types;
    }
    if ([panel runModal] == NSModalResponseOK) {
        [self setLUTFromPaths:@[panel.URL.path]];
    }
}

- (void)chooseOutputDir {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = YES;
    panel.message = @"选择输出目录";
    NSString *cur = [_outField.stringValue stringByExpandingTildeInPath];
    if (cur.length && [cur hasPrefix:@"/"]) panel.directoryURL = [NSURL fileURLWithPath:cur];
    if ([panel runModal] == NSModalResponseOK) {
        _outField.stringValue = panel.URL.path;
        [self saveDefaults];
    }
}

- (void)chooseVideos {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.message = @"选择视频文件或文件夹";
    if ([panel runModal] == NSModalResponseOK) {
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSURL *u in panel.URLs) [paths addObject:u.path];
        [self addPaths:paths];
    }
}

- (DITOutputOptions *)buildOptions {
    DITOutputOptions *o = [[DITOutputOptions alloc] init];
    o.outMode = (_outModeSeg.selectedSegment == 1) ? DITOutModeAbsolute : DITOutModeRelativeToSource;
    o.outValue = _outField.stringValue;
    o.maxConcurrent = _concStepper.integerValue;
    o.conflict = (DITConflictPolicy)_conflictPopup.indexOfSelectedItem;
    o.suffix = @"_graded";
    return o;
}

- (void)outModeChanged {
    BOOL absolute = (_outModeSeg.selectedSegment == 1);
    _outChooseBtn.enabled = absolute;
    if (absolute) {
        _outField.placeholderString = @"/Users/you/Movies/graded";
        _outHintLabel.stringValue = @"带 ~ 会自动展开；目录不存在会自动创建";
    } else {
        _outField.placeholderString = @"graded";
        _outHintLabel.stringValue = @"相对每个源文件所在目录；填 . 表示输出到源文件同目录";
    }
    [self saveDefaults];
}

- (void)concChanged {
    _concValue.stringValue = [NSString stringWithFormat:@"%ld", (long)_concStepper.integerValue];
    [self saveDefaults];
}

- (void)qualityChanged {
    _qualityValue.stringValue = [NSString stringWithFormat:@"%ld", (long)_qualitySlider.doubleValue];
    [self saveDefaults];
}

#pragma mark 任务管理

- (void)addInputPaths:(NSArray<NSString *> *)paths {
    [self addPaths:paths];
}

- (void)beginRun {
    [self startConversion];
}

- (void)beginStop {
    [self stopConversion];
}

- (NSString *)statusLine {
    return _actionBar.statusText;
}

- (void)addPaths:(NSArray<NSString *> *)paths {
    if (_engine.isRunning) {
        NSBeep();
        return;
    }
    DITOutputOptions *o = [self buildOptions];
    NSArray<NSString *> *files = [DITEngine videoFilesFromPaths:paths
                                                         filter:o.extensionFilter
                                                  excludeSuffix:o.suffix];

    NSMutableSet<NSString *> *existing = [NSMutableSet set];
    for (DITJob *j in _jobTable.jobs) [existing addObject:j.inputPath];

    NSInteger added = 0;
    for (NSString *f in files) {
        if ([existing containsObject:f]) continue;
        DITJob *job = [[DITJob alloc] init];
        job.inputPath = f;
        job.displayName = [f lastPathComponent];
        job.displayFolder = [[f stringByDeletingLastPathComponent] stringByAbbreviatingWithTildeInPath];
        [_jobTable.jobs addObject:job];
        added++;
    }
    if (added == 0 && files.count == 0) {
        [_actionBar setStatus:@"没有识别到可处理的视频文件（支持 mp4 / mov / mkv / mxf …）"];
    }
    [_jobTable reloadAll];
    [self refreshAll];
}

- (void)clearJobs {
    if (_engine.isRunning) { NSBeep(); return; }
    [_jobTable.jobs removeAllObjects];
    [_jobTable reloadAll];
    [_actionBar setProgress:0];
    [_actionBar setStatus:@"就绪"];
    [self refreshAll];
}

- (void)selectAllJobs {
    [_jobTable selectAllJobs];
}

/// 只把条目从列表里去掉，不动磁盘上的文件
- (void)deleteSelectedJobs {
    if (_engine.isRunning) { NSBeep(); return; }
    NSInteger n = [_jobTable removeSelectedJobs];
    if (n == 0) { NSBeep(); return; }
    [_actionBar setStatus:[NSString stringWithFormat:@"已从列表移除 %ld 个（磁盘上的文件不受影响）",
                           (long)n]];
    [self refreshAll];
}

- (void)startConversion {
    if (_engine.isRunning) return;
    DITOutputOptions *o = [self buildOptions];

    NSString *lut = [_lutPath copy];
    NSInteger quality = (NSInteger)_qualitySlider.doubleValue;
    DITEngine *engine = [[DITEngine alloc] initWithJobs:_jobTable.jobs
                                                 output:o
                                       argumentsBuilder:^NSArray<NSString *> *(DITJob *job,
                                                                            NSString *outPath) {
        return DITLUTArguments(job, lut, quality);
    }];

    __weak PageLUT *ws = self;
    engine.preflight = ^{
        if (lut.length == 0) return @"还没有指定 LUT 文件";
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:lut isDirectory:&isDir] || isDir) {
            return [NSString stringWithFormat:@"LUT 文件不存在：%@", lut];
        }
        return (NSString *)nil;
    };
    engine.onJobUpdate = ^(DITJob *job) { [ws jobUpdated:job]; };
    engine.onFinished = ^{ [ws allFinished]; };

    NSString *err = nil;
    if (![engine startWithError:&err]) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"无法开始转换";
        a.informativeText = err ?: @"未知错误";
        a.alertStyle = NSAlertStyleWarning;
        [a runModal];
        return;
    }
    _engine = engine;
    [self refreshAll];
}

- (void)stopConversion {
    if (_stopping) return;              // 重复点击幂等
    if (!_engine.isRunning) return;
    _stopping = YES;
    [_actionBar setStatus:@"正在停止…"];
    [_actionBar setStopEnabled:NO];     // 已经在停了，别让用户反复点
    [_engine cancel];
}

- (void)jobUpdated:(DITJob *)job {
    if (job.state == DITJobStateDone && job.outputPath.length) {
        _lastOutputDir = [job.outputPath stringByDeletingLastPathComponent];
    }
    [_jobTable reloadRowOfJob:job];
    [self updateProgress];
}

- (void)updateProgress {
    NSArray<DITJob *> *jobs = _jobTable.jobs;
    if (jobs.count == 0) {
        [_actionBar setProgress:0];
        return;
    }
    double sum = 0;
    NSInteger done = 0, failed = 0, skipped = 0, cancelled = 0;
    DITJob *active = nil;
    for (DITJob *j in jobs) {
        sum += j.progress;
        if (j.state == DITJobStateDone) done++;
        else if (j.state == DITJobStateFailed) failed++;
        else if (j.state == DITJobStateSkipped) skipped++;
        else if (j.state == DITJobStateCancelled) cancelled++;
        else if (j.state == DITJobStateRunning) active = j;
    }
    [_actionBar setProgress:sum / (double)jobs.count];

    // 停止过程中只刷新进度条，别用进度行盖掉「正在停止…」
    if (_stopping) return;

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%ld / %ld 完成", (long)done, (long)jobs.count];
    if (failed) [s appendFormat:@"　·　%ld 失败", (long)failed];
    if (skipped) [s appendFormat:@"　·　%ld 跳过", (long)skipped];
    if (cancelled) [s appendFormat:@"　·　%ld 已取消", (long)cancelled];
    if (active) [s appendFormat:@"　·　正在处理 %@", active.displayName];
    [_actionBar setStatus:s];
}

- (void)allFinished {
    _stopping = NO;
    [self updateProgress];

    NSInteger done = 0, failed = 0, skipped = 0, cancelled = 0, pending = 0;
    for (DITJob *j in _jobTable.jobs) {
        if (j.state == DITJobStateDone) done++;
        else if (j.state == DITJobStateFailed) failed++;
        else if (j.state == DITJobStateSkipped) skipped++;
        else if (j.state == DITJobStateCancelled) cancelled++;
        else pending++;   // 正常路径下应为 0；非 0 说明收尾漏了任务，直接暴露出来
    }

    // 被停止过就换成「已停止」的说法，别把取消掉的任务伪装成成功/跳过
    NSMutableString *s = [NSMutableString string];
    BOOL stopped = (cancelled + pending) > 0;
    [s appendFormat:@"%@：成功 %ld", stopped ? @"已停止" : @"全部结束", (long)done];
    if (failed) [s appendFormat:@"　失败 %ld", (long)failed];
    if (skipped) [s appendFormat:@"　跳过 %ld", (long)skipped];
    if (cancelled) [s appendFormat:@"　已取消 %ld", (long)cancelled];
    if (pending) [s appendFormat:@"　未处理 %ld", (long)pending];
    if (failed) [s appendString:@"（鼠标悬停失败行可看原因）"];
    [_actionBar setStatus:s];

    _engine = nil;
    [self refreshAll];
}

- (void)refreshAll {
    BOOL running = _engine.isRunning;
    [_actionBar setRunning:running canStart:(_jobTable.jobs.count > 0)];
    [_actionBar setStopEnabled:running && !_stopping];
    _lutWell.enabled = !running;
    _jobTable.dropEnabled = !running;
    _addFilesBtn.enabled = !running;
    _removeSelBtn.enabled = !running && _jobTable.hasSelection;
    _outField.enabled = !running;
    _outModeSeg.enabled = !running;
    _outChooseBtn.enabled = !running && (_outModeSeg.selectedSegment == 1);
    _conflictPopup.enabled = !running;
    _concStepper.enabled = !running;
    _qualitySlider.enabled = !running;
    _filesCount.stringValue = _jobTable.jobs.count
                                  ? [NSString stringWithFormat:@"已选 %ld 个", (long)_jobTable.jobs.count]
                                  : @"";
}

- (void)revealOutput {
    NSString *dir = _lastOutputDir;
    if (dir.length == 0 && _outModeSeg.selectedSegment == 1) {
        dir = [_outField.stringValue stringByExpandingTildeInPath];
    }
    if (dir.length == 0) { NSBeep(); return; }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
}

#pragma mark - CLI

+ (NSString *)cliUsage {
    return @"用法: DITKit --cli --lut <LUT文件> [选项] -- <视频文件...>\n"
            "选项:\n"
            "  --out <绝对目录>        输出到指定目录\n"
            "  --relative <子目录>     输出到每个源文件所在目录的子目录（默认 graded）\n"
            "  --jobs <N>              最大并发，默认 4\n"
            "  --conflict <skip|overwrite|rename>  命名冲突策略，默认 skip\n"
            "  --quality <10-90>       编码质量，默认 55\n"
            "  --suffix <后缀>         输出文件名后缀，默认 _graded\n";
}

+ (int)runCLI:(NSArray<NSString *> *)argv {
    DITOutputOptions *o = [[DITOutputOptions alloc] init];
    o.suffix = @"_graded";
    o.outValue = @"graded";
    NSMutableArray<NSString *> *inputs = [NSMutableArray array];
    NSString *lutPath = nil;
    NSInteger quality = 55;
    BOOL sawDashDash = NO;

    for (NSUInteger i = 0; i < argv.count; i++) {
        NSString *a = argv[i];
        if (sawDashDash) { [inputs addObject:a]; continue; }
        if ([a isEqualToString:@"--"]) { sawDashDash = YES; continue; }
        if ([a isEqualToString:@"--lut"] && i + 1 < argv.count) {
            lutPath = argv[++i];
        } else if ([a isEqualToString:@"--out"] && i + 1 < argv.count) {
            o.outValue = argv[++i];
            o.outMode = DITOutModeAbsolute;
        } else if ([a isEqualToString:@"--relative"] && i + 1 < argv.count) {
            o.outValue = argv[++i];
            o.outMode = DITOutModeRelativeToSource;
        } else if ([a isEqualToString:@"--jobs"] && i + 1 < argv.count) {
            o.maxConcurrent = [argv[++i] integerValue];
        } else if ([a isEqualToString:@"--quality"] && i + 1 < argv.count) {
            quality = [argv[++i] integerValue];
        } else if ([a isEqualToString:@"--suffix"] && i + 1 < argv.count) {
            o.suffix = argv[++i];
        } else if ([a isEqualToString:@"--conflict"] && i + 1 < argv.count) {
            NSString *v = argv[++i];
            if ([v isEqualToString:@"overwrite"]) o.conflict = DITConflictOverwrite;
            else if ([v isEqualToString:@"rename"]) o.conflict = DITConflictRename;
            else o.conflict = DITConflictSkip;
        } else if ([a hasPrefix:@"-"]) {
            fprintf(stderr, "%s", [[self cliUsage] UTF8String]);
            return 2;
        } else {
            [inputs addObject:a];
        }
    }

    if (lutPath.length == 0 || inputs.count == 0) {
        fprintf(stderr, "%s", [[self cliUsage] UTF8String]);
        return 2;
    }

    NSArray<NSString *> *files = [DITEngine videoFilesFromPaths:inputs
                                                         filter:o.extensionFilter
                                                  excludeSuffix:o.suffix];
    if (files.count == 0) {
        fprintf(stderr, "没有找到可处理的视频文件\n");
        return 2;
    }

    NSMutableArray<DITJob *> *jobs = [NSMutableArray array];
    for (NSString *f in files) {
        DITJob *j = [[DITJob alloc] init];
        j.inputPath = f;
        j.displayName = [f lastPathComponent];
        [jobs addObject:j];
    }

    printf("LUT   : %s\n", lutPath.UTF8String);
    printf("文件数: %ld   并发: %ld\n\n", (long)jobs.count, (long)o.maxConcurrent);

    NSString *lut = [lutPath copy];
    NSInteger q = quality;
    DITEngine *engine = [[DITEngine alloc] initWithJobs:jobs
                                                 output:o
                                       argumentsBuilder:^NSArray<NSString *> *(DITJob *job,
                                                                            NSString *outPath) {
        return DITLUTArguments(job, lut, q);
    }];
    engine.preflight = ^{
        if (lut.length == 0) return @"还没有指定 LUT 文件";
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:lut isDirectory:&isDir] || isDir) {
            return [NSString stringWithFormat:@"LUT 文件不存在：%@", lut];
        }
        return (NSString *)nil;
    };

    __block int failed = 0;
    __block NSInteger finished = 0;
    engine.onJobUpdate = ^(DITJob *job) {
        if (job.state == DITJobStateDone || job.state == DITJobStateFailed ||
            job.state == DITJobStateSkipped) {
            finished++;
            if (job.state == DITJobStateFailed) {
                failed++;
                printf("[失败] %s\n       %s\n", job.displayName.UTF8String,
                       job.errorText.UTF8String);
            } else if (job.state == DITJobStateSkipped) {
                printf("[跳过] %s\n", job.displayName.UTF8String);
            } else {
                printf("[完成] %s  ->  %s\n", job.displayName.UTF8String,
                       job.outputPath.UTF8String);
            }
            fflush(stdout);
        }
    };

    NSString *err = nil;
    if (![engine startWithError:&err]) {
        fprintf(stderr, "错误: %s\n", err.UTF8String);
        return 1;
    }

    while (engine.isRunning) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }
    // 再转一圈，确保终止回调处理完毕
    for (int i = 0; i < 20; i++) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
    }
    printf("\n结束：共 %ld，失败 %d\n", (long)finished, failed);
    return failed == 0 ? 0 : 1;
}

@end
