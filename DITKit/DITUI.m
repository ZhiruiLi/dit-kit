//  DITUI.m —— DITKit 共享界面零件的实现

#import "DITUI.h"

#pragma mark - 拖放区

@implementation DropWellView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        _caption = @"";
        _hint = @"";
        _enabled = YES;
    }
    return self;
}

- (BOOL)isFlipped { return NO; }

- (void)setCaption:(NSString *)caption {
    _caption = [caption copy];
    self.needsDisplay = YES;
}

- (void)setHint:(NSString *)hint {
    _hint = [hint copy];
    self.needsDisplay = YES;
}

- (void)setHighlight:(BOOL)highlight {
    _highlight = highlight;
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) return;
    if (self.onClick) self.onClick();
}

- (NSArray<NSURL *> *)fileURLsFromPasteboard:(NSPasteboard *)pb {
    NSArray *urls = [pb readObjectsForClasses:@[[NSURL class]]
                                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSMutableArray *out = [NSMutableArray array];
    for (NSURL *u in urls) {
        if (u.path) [out addObject:u];
    }
    return out;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if (!self.enabled) return NSDragOperationNone;
    if ([self fileURLsFromPasteboard:[sender draggingPasteboard]].count == 0) return NSDragOperationNone;
    self.highlight = YES;
    return NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    self.highlight = NO;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    if (!self.enabled) return NO;
    return [self fileURLsFromPasteboard:[sender draggingPasteboard]].count > 0;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.highlight = NO;
    NSArray<NSURL *> *urls = [self fileURLsFromPasteboard:[sender draggingPasteboard]];
    if (urls.count == 0) return NO;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *u in urls) [paths addObject:u.path];
    if (self.onPaths) self.onPaths(paths);
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect r = NSInsetRect(self.bounds, 1.0, 1.0);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8];

    if (self.highlight) {
        [[[NSColor controlAccentColor] colorWithAlphaComponent:0.14] setFill];
    } else {
        [[NSColor controlBackgroundColor] setFill];
    }
    [p fill];

    NSColor *stroke = self.highlight ? [NSColor controlAccentColor] : [NSColor separatorColor];
    [stroke setStroke];
    p.lineWidth = 1.0;
    CGFloat dash[2] = {5.0, 4.0};
    [p setLineDash:dash count:2 phase:0];
    [p stroke];
    [p setLineDash:NULL count:0 phase:0];

    NSDictionary *captionAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13.0],
        NSForegroundColorAttributeName: self.highlight ? [NSColor controlAccentColor]
                                                       : [NSColor labelColor]
    };
    NSDictionary *hintAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.0],
        NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]
    };
    NSString *c = self.caption ?: @"";
    NSString *h = self.hint ?: @"";
    NSSize cs = [c sizeWithAttributes:captionAttrs];
    NSSize hs = [h sizeWithAttributes:hintAttrs];
    CGFloat totalH = cs.height + (h.length ? hs.height + 3 : 0);
    CGFloat top = NSMidY(self.bounds) - totalH / 2.0;
    if (h.length) {
        [c drawAtPoint:NSMakePoint(NSMidX(self.bounds) - cs.width / 2.0, top + hs.height + 3)
        withAttributes:captionAttrs];
        [h drawAtPoint:NSMakePoint(NSMidX(self.bounds) - hs.width / 2.0, top)
        withAttributes:hintAttrs];
    } else {
        [c drawAtPoint:NSMakePoint(NSMidX(self.bounds) - cs.width / 2.0, top)
        withAttributes:captionAttrs];
    }
}

@end

#pragma mark - 容器

// LayoutView 只负责「翻转坐标 + 布局回调」，不画背景。
//
// 坑：早先在这里 fill 整个 bounds 画窗口底色，结果父视图的全量重绘会把
// 还没来得及重绘的子控件整片擦掉（顶栏的标题与页切换器就这么消失的）。
// 窗口底色本来就由 NSWindow.backgroundColor 负责，不需要内容视图再画一遍。
@implementation LayoutView
- (BOOL)isFlipped { return YES; }
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    if (self.onLayout) self.onLayout();
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.onLayout) self.onLayout();
}
@end

#pragma mark - 控件工厂

NSTextField *DITLabel(NSString *text, CGFloat size, BOOL bold) {
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSZeroRect];
    f.stringValue = text;
    f.editable = NO;
    f.selectable = NO;
    f.bezeled = NO;
    f.drawsBackground = NO;
    f.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    f.textColor = bold ? [NSColor labelColor] : [NSColor secondaryLabelColor];
    f.autoresizingMask = NSViewNotSizable;
    return f;
}

NSTextField *DITSectionLabel(NSString *text) {
    return DITLabel(text, 12, YES);
}

void DITFrame(NSView *v, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    if (!v) return;
    v.frame = NSMakeRect(round(x), round(y), round(MAX(1, w)), round(MAX(1, h)));
}

void DITPlaceSection(NSTextField *label, CGFloat *y, CGFloat x, CGFloat w) {
    if (label) DITFrame(label, x, *y, w, 16);
    *y += 16 + 6;
}

#pragma mark - 任务表格

@interface DITJobTable () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *table;
@end

@implementation DITJobTable

- (instancetype)init {
    if ((self = [super init])) {
        _jobs = [NSMutableArray array];

        _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
        _table.dataSource = self;
        _table.delegate = self;
        _table.rowHeight = 22;
        _table.usesAlternatingRowBackgroundColors = YES;
        _table.allowsMultipleSelection = YES;
        _table.headerView = [[NSTableHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 100, 22)];

        NSArray *colDefs = @[@[@"文件", @260.0, @(NSTableColumnNoResizing)],
                             @[@"位置", @240.0, @(NSTableColumnAutoresizingMask)],
                             @[@"状态", @150.0, @(NSTableColumnNoResizing)]];
        for (NSArray *def in colDefs) {
            NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:def[0]];
            col.title = def[0];
            col.width = [def[1] doubleValue];
            col.resizingMask = (NSTableColumnResizingOptions)[def[2] integerValue];
            [_table addTableColumn:col];
        }

        _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _scrollView.documentView = _table;
        _scrollView.hasVerticalScroller = YES;
        _scrollView.borderType = NSBezelBorder;
        _scrollView.autohidesScrollers = YES;
    }
    return self;
}

- (void)reloadAll { [_table reloadData]; }

- (void)reloadRowOfJob:(DITJob *)job {
    NSInteger row = [_jobs indexOfObjectIdenticalTo:job];
    if (row == NSNotFound) return;
    [_table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                     columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 3)]];
}

/// 按容器宽度重新分配三列宽度（文件列与状态列固定比例，位置列吃掉余量）
- (void)layoutColumnsForWidth:(CGFloat)w {
    CGFloat tw = w - 4;
    NSArray<NSTableColumn *> *cols = _table.tableColumns;
    if (cols.count != 3) return;
    cols[0].width = MAX(150.0, tw * 0.34);
    cols[2].width = MAX(120.0, tw * 0.22);
    cols[1].width = MAX(120.0, tw - cols[0].width - cols[2].width - 3);
}

#pragma mark 数据源

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_jobs.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_jobs.count) return nil;
    DITJob *job = _jobs[(NSUInteger)row];
    NSString *ident = tableColumn.identifier;
    NSTableCellView *cell = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 22)];
        cell.identifier = ident;
        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(2, 1, tableColumn.width - 4, 20)];
        tf.bordered = NO;
        tf.drawsBackground = NO;
        tf.editable = NO;
        tf.selectable = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        tf.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        tf.font = [NSFont systemFontOfSize:12];
        [cell addSubview:tf];
        cell.textField = tf;
    }

    NSString *text = @"";
    NSColor *color = [NSColor labelColor];
    if ([ident isEqualToString:@"文件"]) {
        text = job.displayName;
    } else if ([ident isEqualToString:@"位置"]) {
        text = job.displayFolder;
        color = [NSColor secondaryLabelColor];
    } else {
        text = job.statusText;
        switch (job.state) {
            case DITJobStateDone: color = [NSColor systemGreenColor]; break;
            case DITJobStateFailed: color = [NSColor systemRedColor]; break;
            case DITJobStateSkipped: color = [NSColor systemOrangeColor]; break;
            case DITJobStateRunning: color = [NSColor controlAccentColor]; break;
            case DITJobStateCancelled: color = [NSColor secondaryLabelColor]; break;
            default: color = [NSColor tertiaryLabelColor]; break;
        }
    }
    cell.textField.stringValue = text;
    cell.textField.textColor = color;
    cell.toolTip = job.errorText.length ? job.errorText : job.inputPath;
    return cell;
}

@end

#pragma mark - 底部操作栏

@implementation DITActionBar {
    NSProgressIndicator *_progress;
    NSTextField *_statusLabel;
    NSButton *_startBtn;
    NSButton *_stopBtn;
    NSButton *_clearBtn;
    NSButton *_revealBtn;
    BOOL _running;
    BOOL _canStart;
}

- (instancetype)init {
    if ((self = [super init])) {
        _progress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
        _progress.style = NSProgressIndicatorStyleBar;
        _progress.indeterminate = NO;
        _progress.minValue = 0;
        _progress.maxValue = 1;
        _progress.doubleValue = 0;

        _statusLabel = DITLabel(@"就绪", 12, NO);

        _startBtn = [[NSButton alloc] initWithFrame:NSZeroRect];
        _startBtn.title = @"开始转换";
        _startBtn.bezelStyle = NSBezelStyleRounded;
        _startBtn.keyEquivalent = @"\r";
        _startBtn.target = self;
        _startBtn.action = @selector(startClicked);

        _stopBtn = [[NSButton alloc] initWithFrame:NSZeroRect];
        _stopBtn.title = @"停止";
        _stopBtn.bezelStyle = NSBezelStyleRounded;
        _stopBtn.target = self;
        _stopBtn.action = @selector(stopClicked);

        _clearBtn = [[NSButton alloc] initWithFrame:NSZeroRect];
        _clearBtn.title = @"清空列表";
        _clearBtn.bezelStyle = NSBezelStyleRounded;
        _clearBtn.target = self;
        _clearBtn.action = @selector(clearClicked);

        _revealBtn = [[NSButton alloc] initWithFrame:NSZeroRect];
        _revealBtn.title = @"打开输出目录";
        _revealBtn.bezelStyle = NSBezelStyleRounded;
        _revealBtn.target = self;
        _revealBtn.action = @selector(revealClicked);
    }
    return self;
}

- (void)addToView:(NSView *)superview {
    for (NSView *v in @[_progress, _statusLabel, _startBtn, _stopBtn, _clearBtn, _revealBtn]) {
        [superview addSubview:v];
    }
}

- (void)startClicked { if (self.onStart) self.onStart(); }
- (void)stopClicked { if (self.onStop) self.onStop(); }
- (void)clearClicked { if (self.onClear) self.onClear(); }
- (void)revealClicked { if (self.onReveal) self.onReveal(); }

- (void)setStartTitle:(NSString *)title {
    _startBtn.title = title;
}

- (void)setStatus:(NSString *)status {
    _statusLabel.stringValue = status;
}

- (void)setProgress:(double)progress {
    [_progress setDoubleValue:progress];
}

- (void)setRunning:(BOOL)running canStart:(BOOL)canStart {
    _running = running;
    _canStart = canStart;
    [_startBtn setEnabled:(!running && canStart)];
    [_stopBtn setEnabled:running];
    [_clearBtn setEnabled:!running];
}

- (CGFloat)layoutFromBottom:(CGFloat)bottom x:(CGFloat)x width:(CGFloat)w {
    DITFrame(_startBtn, x, bottom - 30, 110, 30);
    DITFrame(_stopBtn, x + 118, bottom - 30, 80, 30);
    DITFrame(_clearBtn, x + 206, bottom - 30, 100, 30);
    DITFrame(_revealBtn, x + 314, bottom - 30, 120, 30);
    DITFrame(_progress, x, bottom - 30 - 10 - 14, w, 14);
    DITFrame(_statusLabel, x, bottom - 30 - 10 - 14 - 22, w, 18);
    return bottom - 30 - 10 - 14 - 22 - 8;
}

@end
