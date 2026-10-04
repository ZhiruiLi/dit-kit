//  PageTrim.m —— 工具页：视频裁剪

#import "PageTrim.h"

#pragma mark - 裁剪参数

@implementation DITTrimSpec
- (instancetype)init {
    if ((self = [super init])) {
        _startSec = 0;
        _endSec = 10;
        _fastCopy = YES;
        _quality = 55;
    }
    return self;
}
- (double)duration { return MAX(0.0, _endSec - _startSec); }
@end

NSArray<NSString *> *DITTrimArguments(DITJob *job, DITTrimSpec *spec) {
    NSMutableArray<NSString *> *a = [NSMutableArray array];

    // -ss 放在 -i 之前：先定位再解码，长素材上快很多
    [a addObjectsFromArray:@[@"-ss", [DITEngine timeStringFromSeconds:spec.startSec],
                             @"-i", job.inputPath,
                             @"-t", [DITEngine timeStringFromSeconds:spec.duration]]];

    if (spec.fastCopy) {
        // 流复制：不重编码，速度快到几乎瞬时；起点只能落在关键帧上
        [a addObjectsFromArray:@[@"-c", @"copy"]];
    } else {
        [a addObjectsFromArray:@[@"-c:v", @"hevc_videotoolbox",
                                 @"-q:v", [@(spec.quality) stringValue],
                                 @"-pix_fmt", @"p010le"]];
        NSString *lowExt = [[job.inputPath pathExtension] lowercaseString];
        if ([lowExt isEqualToString:@"mp4"] || [lowExt isEqualToString:@"mov"] ||
            [lowExt isEqualToString:@"m4v"]) {
            [a addObjectsFromArray:@[@"-tag:v", @"hvc1"]];
        }
        // 切点不落在音频帧边界上，音频必须重编码才能对齐
        [a addObjectsFromArray:@[@"-c:a", @"aac", @"-b:a", @"192k"]];
    }
    return a;
}

#pragma mark - 工具页

/// 裁剪范围下方那行提示的常规文案。
/// 抽出来是因为 `updateLengthLabel` 在范围超出源时长时会把它换成警告，
/// 恢复正常时得能原样换回来。
static NSString *DITRangeHintText(void) {
    return @"时间可以写 00:01:30.500，也可以写 90 / 1m30s；改完按回车刷新画面";
}

@interface PageTrim () <NSTextFieldDelegate>
@end

@implementation PageTrim {
    LayoutView *_view;

    NSTextField *_sec1Label, *_sec2Label, *_sec3Label, *_sec4Label, *_sec5Label;
    NSTextField *_srcInfoLabel;

    NSTextField *_startLabel, *_endLabel, *_lenLabel;
    NSTextField *_startField, *_endField;
    NSButton *_fullRangeBtn;
    NSTextField *_rangeHint;

    NSImageView *_startThumb, *_endThumb;
    NSTextField *_startThumbLabel, *_endThumbLabel;

    NSSegmentedControl *_outModeSeg;
    NSTextField *_outField;
    NSButton *_outChooseBtn;
    NSTextField *_outHintLabel;

    NSButton *_fastRadio, *_exactRadio;
    NSSlider *_qualitySlider;
    NSTextField *_qualityValue;
    NSTextField *_modeHint;

    NSTextField *_filesCount;
    NSButton *_addFilesBtn, *_removeSelBtn;
    DITJobTable *_jobTable;
    DITActionBar *_actionBar;

    DITEngine *_engine;
    NSString *_srcPath;          // 第一个源文件（媒体信息与缩略图取样）
    double _srcDuration;
    NSString *_lastOutputDir;
    BOOL _stopping;              // 已点击停止、等引擎收尾；期间不让进度行覆盖提示
    NSInteger _thumbToken;       // 防止旧抽帧结果覆盖新画面
    NSInteger _concurrency;      // 并发数（沿用偏好里的设定）
    NSInteger _conflictIndex;    // 命名冲突策略
}

- (instancetype)init {
    if ((self = [super init])) {
        _view = [[LayoutView alloc] initWithFrame:NSMakeRect(0, 0, 740, 820)];
        __weak PageTrim *ws = self;
        _view.onLayout = ^{ [ws doLayout]; };

        _jobTable = [[DITJobTable alloc] init];
        [self buildControls];
        [self loadDefaults];
        [self refreshSourceInfo];    // 空列表时也要把引导语摆上
        [self refreshAll];
    }
    return self;
}

- (NSView *)view { return _view; }
- (NSString *)pageTitle { return @"视频裁剪"; }
- (BOOL)busy { return _engine.isRunning; }

#pragma mark 构建界面

- (void)buildControls {
    __weak PageTrim *ws = self;

    // 1 · 源视频（拖入统一走下面的列表，这里只报当前取样的那一个）
    _sec1Label = DITSectionLabel(@"1 · 源视频");
    [_view addSubview:_sec1Label];

    _srcInfoLabel = DITLabel(@"", 11, NO);
    [_view addSubview:_srcInfoLabel];

    // 2 · 裁剪范围
    _sec2Label = DITSectionLabel(@"2 · 裁剪范围");
    [_view addSubview:_sec2Label];

    _startLabel = DITLabel(@"起点", 12, NO);
    [_view addSubview:_startLabel];
    _startField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _startField.placeholderString = @"00:00:00.000";
    _startField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    _startField.delegate = self;
    _startField.target = self;
    _startField.action = @selector(rangeEdited);
    [_view addSubview:_startField];

    _endLabel = DITLabel(@"终点", 12, NO);
    [_view addSubview:_endLabel];
    _endField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _endField.placeholderString = @"00:00:10.000";
    _endField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    _endField.delegate = self;
    _endField.target = self;
    _endField.action = @selector(rangeEdited);
    [_view addSubview:_endField];

    _lenLabel = DITLabel(@"", 11, NO);
    // 这行字要和右边的按钮挤在一排，放不下时给省略号，别硬顶过去
    _lenLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_view addSubview:_lenLabel];

    _fullRangeBtn = [[NSButton alloc] initWithFrame:NSZeroRect];
    _fullRangeBtn.title = @"用完整时长";
    _fullRangeBtn.bezelStyle = NSBezelStyleRounded;
    _fullRangeBtn.target = self;
    _fullRangeBtn.action = @selector(useFullRange);
    [_view addSubview:_fullRangeBtn];

    _startThumb = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _startThumb.imageFrameStyle = NSImageFrameGrayBezel;
    _startThumb.imageScaling = NSImageScaleProportionallyUpOrDown;
    _startThumb.imageAlignment = NSImageAlignCenter;
    [_view addSubview:_startThumb];
    _startThumbLabel = DITLabel(@"起点画面", 11, NO);
    _startThumbLabel.alignment = NSTextAlignmentCenter;
    [_view addSubview:_startThumbLabel];

    _endThumb = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _endThumb.imageFrameStyle = NSImageFrameGrayBezel;
    _endThumb.imageScaling = NSImageScaleProportionallyUpOrDown;
    _endThumb.imageAlignment = NSImageAlignCenter;
    [_view addSubview:_endThumb];
    _endThumbLabel = DITLabel(@"终点画面", 11, NO);
    _endThumbLabel.alignment = NSTextAlignmentCenter;
    [_view addSubview:_endThumbLabel];

    _rangeHint = DITLabel(DITRangeHintText(), 11, NO);
    [_view addSubview:_rangeHint];

    // 3 · 输出
    _sec3Label = DITSectionLabel(@"3 · 输出");
    [_view addSubview:_sec3Label];

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
    _outField.placeholderString = @"trimmed";
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

    // 4 · 裁剪方式
    _sec4Label = DITSectionLabel(@"4 · 裁剪方式");
    [_view addSubview:_sec4Label];

    _fastRadio = [[NSButton alloc] initWithFrame:NSZeroRect];
    [_fastRadio setButtonType:NSButtonTypeRadio];
    _fastRadio.title = @"快速（不重编码）";
    _fastRadio.font = [NSFont systemFontOfSize:12];
    _fastRadio.target = self;
    _fastRadio.action = @selector(modeChanged);
    [_view addSubview:_fastRadio];

    _exactRadio = [[NSButton alloc] initWithFrame:NSZeroRect];
    [_exactRadio setButtonType:NSButtonTypeRadio];
    _exactRadio.title = @"精确（重编码）";
    _exactRadio.font = [NSFont systemFontOfSize:12];
    _exactRadio.target = self;
    _exactRadio.action = @selector(modeChanged);
    [_view addSubview:_exactRadio];

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

    _modeHint = DITLabel(@"", 11, NO);
    [_view addSubview:_modeHint];

    // 5 · 待裁剪文件（列表本身就是拖入区）
    _sec5Label = DITSectionLabel(@"5 · 待裁剪文件");
    [_view addSubview:_sec5Label];

    _filesCount = DITLabel(@"", 11, NO);
    _filesCount.alignment = NSTextAlignmentRight;
    [_view addSubview:_filesCount];

    _addFilesBtn = DITButton(@"添加文件…", self, @selector(chooseVideos));
    [_view addSubview:_addFilesBtn];

    _removeSelBtn = DITButton(@"删除选中", self, @selector(deleteSelectedJobs));
    [_view addSubview:_removeSelBtn];

    _jobTable.emptyHint = @"把要裁剪的视频拖到这里";
    _jobTable.emptySubHint = @"支持多选、多目录与整个文件夹；所有文件套用同一段范围";
    _jobTable.onDropPaths = ^(NSArray<NSString *> *paths) { [ws addPaths:paths]; };
    _jobTable.onSelectionChanged = ^{ [ws refreshAll]; };
    _jobTable.onDeleteRequested = ^{ [ws deleteSelectedJobs]; };

    [_view addSubview:_jobTable.scrollView];

    // 底部
    _actionBar = [[DITActionBar alloc] init];
    [_actionBar setStartTitle:@"开始裁剪"];
    [_actionBar addToView:_view];
    _actionBar.onStart = ^{ [ws startTrim]; };
    _actionBar.onStop = ^{ [ws stopTrim]; };
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

    // 1 · 源视频（只有一行信息；拖入统一走下面的列表）
    DITPlaceSection(_sec1Label, &y, x, w);
    DITFrame(_srcInfoLabel, x, y, w, 14);
    y += 14 + 14;

    // 2 · 裁剪范围
    DITPlaceSection(_sec2Label, &y, x, w);
    DITFrame(_startLabel, x, y + 3, 32, 18);
    DITFrame(_startField, x + 36, y, 150, 24);
    DITFrame(_endLabel, x + 200, y + 3, 32, 18);
    DITFrame(_endField, x + 236, y, 150, 24);
    // 「用完整时长」按钮靠右摆，片段长度标签必须在它左边收住 ——
    // 否则「超出源时长」那句提示会被按钮压掉一半
    CGFloat fullBtnW = 110.0, fullBtnX = x + w - fullBtnW, lenX = x + 394;
    DITFrame(_lenLabel, lenX, y + 3, MAX(60.0, fullBtnX - 8 - lenX), 18);
    DITFrame(_fullRangeBtn, fullBtnX, y, fullBtnW, 24);
    y += 24 + 10;

    // 两个画面预览并排
    CGFloat thumbW = MIN(200.0, (w - 12) / 2);
    CGFloat thumbH = round(thumbW * 9.0 / 16.0);
    DITFrame(_startThumb, x, y, thumbW, thumbH);
    DITFrame(_endThumb, x + thumbW + 12, y, thumbW, thumbH);
    y += thumbH + 4;
    DITFrame(_startThumbLabel, x, y, thumbW, 14);
    DITFrame(_endThumbLabel, x + thumbW + 12, y, thumbW, 14);
    y += 14 + 8;

    DITFrame(_rangeHint, x, y, w, 14);
    y += 14 + 14;

    // 3 · 输出
    DITPlaceSection(_sec3Label, &y, x, w);
    DITFrame(_outModeSeg, x, y, 280, 24);
    y += 24 + 8;
    CGFloat btnW = 88;
    DITFrame(_outField, x, y, w - btnW - 8, 24);
    DITFrame(_outChooseBtn, x + w - btnW, y, btnW, 24);
    y += 24 + 4;
    DITFrame(_outHintLabel, x, y, w, 14);
    y += 14 + 14;

    // 4 · 裁剪方式
    DITPlaceSection(_sec4Label, &y, x, w);
    CGFloat cy = y;
    DITFrame(_fastRadio, x, cy, 150, 20);
    DITFrame(_exactRadio, x + 158, cy, 150, 20);
    DITFrame(_qualitySlider, x + 316, cy + 1, 110, 22);
    DITFrame(_qualityValue, x + 432, cy + 2, 28, 18);
    DITFrame(_modeHint, x + 464, cy + 3, w - 464, 16);
    y += 24 + 12;

    // 5 · 文件清单（标题行右边放「添加文件…／删除选中」，计数贴左）
    CGFloat rh = 24.0;
    DITFrame(_sec5Label, x, y + 4, w * 0.5, 16);
    CGFloat bw2 = 92.0, bgap = 8.0;
    DITFrame(_removeSelBtn, x + w - bw2, y, bw2, rh);
    DITFrame(_addFilesBtn, x + w - bw2 * 2 - bgap, y, bw2, rh);
    DITFrame(_filesCount, x + w * 0.5, y + 6, w * 0.5 - bw2 * 2 - bgap - 8, 14);
    y += rh + 8;

    // 底部操作栏
    CGFloat tableBottom = [_actionBar layoutFromBottom:H - PAD x:x width:w];

    [_jobTable layoutColumnsForWidth:w];
    DITFrame(_jobTable.scrollView, x, y, w, MAX(60, tableBottom - y));
}

#pragma mark 偏好

- (void)loadDefaults {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    NSInteger mode = [d integerForKey:@"trim.outMode"];
    _outModeSeg.selectedSegment = (mode == 1) ? 1 : 0;
    NSString *outVal = [d stringForKey:@"trim.outValue"];
    _outField.stringValue = outVal.length ? outVal : @"trimmed";

    NSInteger conf = [d integerForKey:@"trim.conflict"];
    if (conf < 0 || conf > 2) conf = 0;
    _conflictIndex = conf;

    NSInteger conc = [d integerForKey:@"trim.concurrency"];
    if (conc <= 0) conc = 4;
    _concurrency = conc;

    NSInteger q = [d integerForKey:@"trim.quality"];
    if (q <= 0) q = 55;
    _qualitySlider.doubleValue = q;
    _qualityValue.stringValue = [NSString stringWithFormat:@"%ld", (long)q];

    BOOL fast = [d objectForKey:@"trim.fastCopy"] ? [d boolForKey:@"trim.fastCopy"] : YES;
    _fastRadio.state = fast ? NSControlStateValueOn : NSControlStateValueOff;
    _exactRadio.state = fast ? NSControlStateValueOff : NSControlStateValueOn;

    NSString *s = [d stringForKey:@"trim.start"];
    NSString *e = [d stringForKey:@"trim.end"];
    // 自检 / 截图预览时可用环境变量注入起止时间码，避免污染用户偏好
    const char *sEnv = getenv("DITKIT_TRIM_START");
    const char *eEnv = getenv("DITKIT_TRIM_END");
    if (sEnv) s = [NSString stringWithUTF8String:sEnv];
    if (eEnv) e = [NSString stringWithUTF8String:eEnv];
    _startField.stringValue = s.length ? s : @"00:00:00.000";
    _endField.stringValue = e.length ? e : @"00:00:10.000";

    [self outModeChanged];
    [self modeChanged];
    [self updateLengthLabel];
}

- (void)saveDefaults {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:_outModeSeg.selectedSegment forKey:@"trim.outMode"];
    [d setObject:_outField.stringValue forKey:@"trim.outValue"];
    [d setInteger:_conflictIndex forKey:@"trim.conflict"];
    [d setInteger:_concurrency forKey:@"trim.concurrency"];
    [d setInteger:(NSInteger)_qualitySlider.doubleValue forKey:@"trim.quality"];
    [d setBool:(_fastRadio.state == NSControlStateValueOn) forKey:@"trim.fastCopy"];
    [d setObject:_startField.stringValue forKey:@"trim.start"];
    [d setObject:_endField.stringValue forKey:@"trim.end"];
}

#pragma mark 交互

- (void)outModeChanged {
    BOOL absolute = (_outModeSeg.selectedSegment == 1);
    _outChooseBtn.enabled = absolute;
    if (absolute) {
        _outField.placeholderString = @"/Users/you/Movies/trimmed";
        _outHintLabel.stringValue = @"带 ~ 会自动展开；目录不存在会自动创建";
    } else {
        _outField.placeholderString = @"trimmed";
        _outHintLabel.stringValue = @"相对每个源文件所在目录；填 . 表示输出到源文件同目录";
    }
    [self saveDefaults];
}

- (void)modeChanged {
    BOOL fast = (_fastRadio.state == NSControlStateValueOn);
    if (fast) {
        _exactRadio.state = NSControlStateValueOff;
    } else {
        _fastRadio.state = NSControlStateValueOff;
    }
    _qualitySlider.enabled = !fast;
    _qualityValue.textColor = fast ? [NSColor tertiaryLabelColor] : [NSColor secondaryLabelColor];
    _modeHint.stringValue = fast
        ? @"秒级完成，但起点会吸附到最近的关键帧（可能前后差几秒）"
        : @"逐帧重编码，切点精确到帧；音频会重编码为 AAC 192k";
    [self saveDefaults];
}

- (void)qualityChanged {
    _qualityValue.stringValue = [NSString stringWithFormat:@"%ld", (long)_qualitySlider.doubleValue];
    [self saveDefaults];
}

/// 输入框失焦或回车后，重新校验范围并刷新预览
- (void)controlTextDidEndEditing:(NSNotification *)note {
    [self rangeEdited];
}

- (void)rangeEdited {
    [self updateLengthLabel];
    [self saveDefaults];
    [self scheduleThumbnails];
}

- (void)useFullRange {
    if (_srcDuration <= 0) { NSBeep(); return; }
    _startField.stringValue = @"00:00:00.000";
    _endField.stringValue = [DITEngine timeStringFromSeconds:_srcDuration];
    [self rangeEdited];
}

/// 解析当前范围；失败时把错误写进状态栏并返回 NO
- (BOOL)currentRange:(double *)startOut end:(double *)endOut quiet:(BOOL)quiet {
    double s = [DITEngine secondsFromTimeString:_startField.stringValue];
    double e = [DITEngine secondsFromTimeString:_endField.stringValue];
    if (s < 0 || e < 0) {
        if (!quiet) [_actionBar setStatus:@"时间格式看不懂：请用 00:01:30.500 或 90 / 1m30s"];
        return NO;
    }
    if (e <= s) {
        if (!quiet) [_actionBar setStatus:@"终点必须大于起点"];
        return NO;
    }
    if (startOut) *startOut = s;
    if (endOut) *endOut = e;
    return YES;
}

- (void)updateLengthLabel {
    double s = 0, e = 0;
    if (![self currentRange:&s end:&e quiet:YES]) {
        _lenLabel.stringValue = @"范围无效";
        _lenLabel.toolTip = nil;
        _lenLabel.textColor = [NSColor systemRedColor];
        return;
    }
    _lenLabel.textColor = [NSColor secondaryLabelColor];
    _lenLabel.stringValue = [NSString stringWithFormat:@"片段长度 %@",
                             [DITEngine timeStringFromSeconds:e - s]];

    // 「超出源时长」这句放不进长度标签 —— 那一排只给它一百多点宽，右边还杵着
    // 「用完整时长」按钮。所以警告改挂到下面整行宽的提示上，顺手改成橙色让它显眼。
    if (_srcDuration > 0 && e > _srcDuration + 0.05) {
        NSString *src = [DITEngine timeStringFromSeconds:_srcDuration];
        _lenLabel.toolTip = [NSString stringWithFormat:@"终点超出源时长 %@，实际会截断到结尾", src];
        _rangeHint.stringValue = [NSString stringWithFormat:
            @"终点超出源时长 %@，成品会截断到结尾；时间可以写 90 / 1m30s", src];
        _rangeHint.textColor = [NSColor systemOrangeColor];
    } else {
        _lenLabel.toolTip = @"片段长度 = 终点 − 起点";
        _rangeHint.stringValue = DITRangeHintText();
        _rangeHint.textColor = [NSColor secondaryLabelColor];
    }
}

#pragma mark 画面预览

- (void)scheduleThumbnails {
    if (_srcPath.length == 0) {
        _startThumb.image = nil;
        _endThumb.image = nil;
        _startThumbLabel.stringValue = @"起点画面";
        _endThumbLabel.stringValue = @"终点画面";
        return;
    }
    double s = 0, e = 0;
    if (![self currentRange:&s end:&e quiet:YES]) return;

    // 抽帧偏右一点点，避免正好落在黑帧/转场帧上
    _thumbToken++;
    [self extractFrameAt:(s + 0.04) slot:0 token:_thumbToken];
    [self extractFrameAt:MAX(s + 0.04, e - 0.04) slot:1 token:_thumbToken];

    _startThumbLabel.stringValue = [NSString stringWithFormat:@"起点 %@",
                                    [DITEngine timeStringFromSeconds:s]];
    _endThumbLabel.stringValue = [NSString stringWithFormat:@"终点 %@",
                                  [DITEngine timeStringFromSeconds:e]];
}

- (void)extractFrameAt:(double)t slot:(NSInteger)slot token:(NSInteger)token {
    NSString *ffmpeg = [DITEngine resolveTool:@"ffmpeg"];
    if (!ffmpeg) return;
    NSString *input = [_srcPath copy];
    NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"ditkit-thumb-%ld-%ld.png",
                                                (long)slot, (long)token]];
    __weak PageTrim *ws = self;

    // 抽帧是 IO + 解码，放到后台，避免拖住界面
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = ffmpeg;
        task.arguments = @[@"-hide_banner", @"-loglevel", @"error",
                           @"-ss", [NSString stringWithFormat:@"%.3f", MAX(0.0, t)],
                           @"-i", input,
                           @"-frames:v", @"1",
                           @"-vf", @"scale=440:-2",
                           @"-y", out];
        task.standardOutput = [NSPipe pipe];
        task.standardError = [NSPipe pipe];
        task.standardInput = [NSFileHandle fileHandleWithNullDevice];
        NSError *err = nil;
        BOOL ok = [task launchAndReturnError:&err];
        if (ok) [task waitUntilExit];
        if (ok && task.terminationStatus != 0) ok = NO;

        dispatch_async(dispatch_get_main_queue(), ^{
            PageTrim *ss = ws;
            if (!ss) return;
            if (ss->_thumbToken != token) return;   // 已经有更新的请求了
            NSImageView *iv = (slot == 0) ? ss->_startThumb : ss->_endThumb;
            iv.image = ok ? [[NSImage alloc] initWithContentsOfFile:out] : nil;
        });
    });
}

#pragma mark 文件管理

- (void)addInputPaths:(NSArray<NSString *> *)paths {
    [self addPaths:paths];
}

- (void)beginRun {
    [self startTrim];
}

- (void)beginStop {
    [self stopTrim];
}

- (NSString *)statusLine {
    return _actionBar.statusText;
}

- (void)addPaths:(NSArray<NSString *> *)paths {
    if (_engine.isRunning) { NSBeep(); return; }
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

    // 第一个文件用来取媒体信息与画面预览
    [self refreshSourceInfo];
    [_jobTable reloadAll];
    [self refreshAll];
    [self scheduleThumbnails];
}

- (void)refreshSourceInfo {
    DITJob *first = _jobTable.jobs.firstObject;
    if (!first) {
        _srcPath = nil;
        _srcDuration = 0;
        _srcInfoLabel.stringValue = @"还没有选择文件 —— 把视频拖到下面的列表，或点「添加文件…」";
        _srcInfoLabel.textColor = [NSColor tertiaryLabelColor];
        _startThumb.image = nil;
        _endThumb.image = nil;
        _startThumbLabel.stringValue = @"起点画面";
        _endThumbLabel.stringValue = @"终点画面";
        return;
    }
    _srcPath = first.inputPath;
    _srcDuration = [DITEngine probeDuration:_srcPath];
    NSString *summary = [DITEngine probeSummary:_srcPath];

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@", first.displayName];
    if (_srcDuration > 0) {
        [s appendFormat:@"　·　时长 %@", [DITEngine timeStringFromSeconds:_srcDuration]];
    }
    if (summary.length) [s appendFormat:@"　·　%@", summary];
    if (_jobTable.jobs.count > 1) {
        [s appendFormat:@"　·　共 %ld 个文件，预览取第一个",
                       (long)_jobTable.jobs.count];
    }
    _srcInfoLabel.stringValue = s;
    _srcInfoLabel.textColor = [NSColor secondaryLabelColor];

    // 首次拿到时长时，把终点默认值设为 10 秒或整段（取短的那个）
    if (_srcDuration > 0 &&
        [_endField.stringValue isEqualToString:@"00:00:10.000"] &&
        _srcDuration < 10.0) {
        _endField.stringValue = [DITEngine timeStringFromSeconds:_srcDuration];
    }
    [self updateLengthLabel];
}

- (void)chooseVideos {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.message = @"选择要裁剪的视频或文件夹";
    if ([panel runModal] == NSModalResponseOK) {
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSURL *u in panel.URLs) [paths addObject:u.path];
        [self addPaths:paths];
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

- (DITOutputOptions *)buildOptions {
    DITOutputOptions *o = [[DITOutputOptions alloc] init];
    o.outMode = (_outModeSeg.selectedSegment == 1) ? DITOutModeAbsolute : DITOutModeRelativeToSource;
    o.outValue = _outField.stringValue;
    o.maxConcurrent = _concurrency;
    o.conflict = (DITConflictPolicy)_conflictIndex;
    o.suffix = @"_trim";
    return o;
}

- (DITTrimSpec *)buildSpec {
    double s = 0, e = 0;
    if (![self currentRange:&s end:&e quiet:YES]) return nil;
    DITTrimSpec *spec = [[DITTrimSpec alloc] init];
    spec.startSec = s;
    spec.endSec = e;
    spec.fastCopy = (_fastRadio.state == NSControlStateValueOn);
    spec.quality = (NSInteger)_qualitySlider.doubleValue;
    return spec;
}

#pragma mark 任务管理

- (void)clearJobs {
    if (_engine.isRunning) { NSBeep(); return; }
    [_jobTable.jobs removeAllObjects];
    [_jobTable reloadAll];
    [_actionBar setProgress:0];
    [_actionBar setStatus:@"就绪"];
    [self refreshSourceInfo];
    [self refreshAll];
}

- (void)selectAllJobs {
    [_jobTable selectAllJobs];
}

- (void)simulateColumnResize:(NSInteger)index delta:(CGFloat)delta {
    [_jobTable simulateColumnResize:index delta:delta];
}

/// 只把条目从列表里去掉，不动磁盘上的文件
- (void)deleteSelectedJobs {
    if (_engine.isRunning) { NSBeep(); return; }
    NSInteger n = [_jobTable removeSelectedJobs];
    if (n == 0) { NSBeep(); return; }
    [_actionBar setStatus:[NSString stringWithFormat:@"已从列表移除 %ld 个（磁盘上的文件不受影响）",
                           (long)n]];
    // 取样的第一个文件可能正好被删掉了，源信息与画面预览都要跟着刷新
    [self refreshSourceInfo];
    [self scheduleThumbnails];
    [self refreshAll];
}

- (void)startTrim {
    if (_engine.isRunning) return;
    if (_jobTable.jobs.count == 0) {
        NSBeep();
        [_actionBar setStatus:@"还没有拖入视频"];
        return;
    }
    DITTrimSpec *spec = [self buildSpec];
    if (!spec) return;
    if (spec.duration < 0.04) {
        [_actionBar setStatus:@"片段太短了（至少约 1 帧）"];
        return;
    }

    DITOutputOptions *o = [self buildOptions];
    DITEngine *engine = [[DITEngine alloc] initWithJobs:_jobTable.jobs
                                                 output:o
                                       argumentsBuilder:^NSArray<NSString *> *(DITJob *job,
                                                                            NSString *outPath) {
        return DITTrimArguments(job, spec);
    }];

    // 进度要按「片段长度」算，而不是源文件总时长
    engine.expectedDuration = ^double(DITJob *job) { return spec.duration; };

    __weak PageTrim *ws = self;
    engine.onJobUpdate = ^(DITJob *job) { [ws jobUpdated:job]; };
    engine.onFinished = ^{ [ws allFinished]; };

    NSString *err = nil;
    if (![engine startWithError:&err]) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"无法开始裁剪";
        a.informativeText = err ?: @"未知错误";
        a.alertStyle = NSAlertStyleWarning;
        [a runModal];
        return;
    }
    _engine = engine;
    [self refreshAll];
}

- (void)stopTrim {
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
    _jobTable.dropEnabled = !running;
    _addFilesBtn.enabled = !running;
    _removeSelBtn.enabled = !running && _jobTable.hasSelection;
    _outField.enabled = !running;
    _outModeSeg.enabled = !running;
    _outChooseBtn.enabled = !running && (_outModeSeg.selectedSegment == 1);
    _startField.enabled = !running;
    _endField.enabled = !running;
    _fullRangeBtn.enabled = !running && (_srcDuration > 0);
    _fastRadio.enabled = !running;
    _exactRadio.enabled = !running;
    _qualitySlider.enabled = !running && (_fastRadio.state != NSControlStateValueOn);
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
    return @"用法: DITKit --cli --trim --start <起点> --end <终点> [选项] -- <视频文件...>\n"
            "选项:\n"
            "  --start <时间>          片段起点，默认 00:00:00.000\n"
            "  --end <时间>            片段终点（必填）\n"
            "  --fast / --exact        快速流复制（默认）或精确重编码\n"
            "  --quality <10-90>       精确模式下的编码质量，默认 55\n"
            "  --out <绝对目录>        输出到指定目录\n"
            "  --relative <子目录>     输出到每个源文件所在目录的子目录（默认 trimmed）\n"
            "  --jobs <N>              最大并发，默认 4\n"
            "  --conflict <skip|overwrite|rename>  命名冲突策略，默认 skip\n"
            "  --suffix <后缀>         输出文件名后缀，默认 _trim\n"
            "时间可以写 00:01:30.500，也可以写 90 / 1m30s\n";
}

+ (int)runCLI:(NSArray<NSString *> *)argv {
    DITOutputOptions *o = [[DITOutputOptions alloc] init];
    o.suffix = @"_trim";
    o.outValue = @"trimmed";
    DITTrimSpec *spec = [[DITTrimSpec alloc] init];
    spec.endSec = -1;

    NSMutableArray<NSString *> *inputs = [NSMutableArray array];
    BOOL sawDashDash = NO;

    for (NSUInteger i = 0; i < argv.count; i++) {
        NSString *a = argv[i];
        if (sawDashDash) { [inputs addObject:a]; continue; }
        if ([a isEqualToString:@"--"]) { sawDashDash = YES; continue; }
        // --trim 只是 main.m 用来分发到本页的标记（LUT 页同理用 --lut 携带参数），
        // 这里必须显式跳过，否则会掉进下面的「未知选项」分支直接打印用法
        if ([a isEqualToString:@"--trim"]) { continue; }
        if ([a isEqualToString:@"--start"] && i + 1 < argv.count) {
            double v = [DITEngine secondsFromTimeString:argv[++i]];
            if (v < 0) { fprintf(stderr, "起点时间格式看不懂\n"); return 2; }
            spec.startSec = v;
        } else if ([a isEqualToString:@"--end"] && i + 1 < argv.count) {
            double v = [DITEngine secondsFromTimeString:argv[++i]];
            if (v < 0) { fprintf(stderr, "终点时间格式看不懂\n"); return 2; }
            spec.endSec = v;
        } else if ([a isEqualToString:@"--fast"]) {
            spec.fastCopy = YES;
        } else if ([a isEqualToString:@"--exact"]) {
            spec.fastCopy = NO;
        } else if ([a isEqualToString:@"--quality"] && i + 1 < argv.count) {
            spec.quality = [argv[++i] integerValue];
        } else if ([a isEqualToString:@"--out"] && i + 1 < argv.count) {
            o.outValue = argv[++i];
            o.outMode = DITOutModeAbsolute;
        } else if ([a isEqualToString:@"--relative"] && i + 1 < argv.count) {
            o.outValue = argv[++i];
            o.outMode = DITOutModeRelativeToSource;
        } else if ([a isEqualToString:@"--jobs"] && i + 1 < argv.count) {
            o.maxConcurrent = [argv[++i] integerValue];
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

    if (spec.endSec < 0 || inputs.count == 0) {
        fprintf(stderr, "%s", [[self cliUsage] UTF8String]);
        return 2;
    }
    if (spec.endSec <= spec.startSec) {
        fprintf(stderr, "终点必须大于起点\n");
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

    printf("范围  : %s → %s（%s）\n",
           [DITEngine timeStringFromSeconds:spec.startSec].UTF8String,
           [DITEngine timeStringFromSeconds:spec.endSec].UTF8String,
           [DITEngine timeStringFromSeconds:spec.duration].UTF8String);
    printf("方式  : %s\n", spec.fastCopy ? "快速（流复制）" : "精确（重编码）");
    printf("文件数: %ld   并发: %ld\n\n", (long)jobs.count, (long)o.maxConcurrent);

    DITEngine *engine = [[DITEngine alloc] initWithJobs:jobs
                                                 output:o
                                       argumentsBuilder:^NSArray<NSString *> *(DITJob *job,
                                                                            NSString *outPath) {
        return DITTrimArguments(job, spec);
    }];
    engine.expectedDuration = ^double(DITJob *job) { return spec.duration; };

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
