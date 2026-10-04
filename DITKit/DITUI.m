//  DITUI.m —— DITKit 共享界面零件的实现

#import "DITUI.h"

#pragma mark - 公共小工具

/// 从拖放剪贴板里取出文件路径（只要文件 URL）
static NSArray<NSString *> *DITFilePathsFromPasteboard(NSPasteboard *pb) {
    if (!pb) return @[];
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[[NSURL class]]
                                              options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSURL *u in urls) {
        if (u.path.length) [out addObject:u.path];
    }
    return out;
}

/// 在视图中央画「主句 + 副句」两行居中文字。
/// 按视图自身的翻转方向摆放，所以翻转容器和非翻转容器里都能画正。
static void DITDrawHintText(NSView *v, NSString *caption, NSString *hint,
                            NSDictionary *captionAttrs, NSDictionary *hintAttrs) {
    NSString *c = caption ?: @"";
    NSString *h = hint ?: @"";
    if (c.length == 0) return;

    NSSize cs = [c sizeWithAttributes:captionAttrs];
    NSSize hs = h.length ? [h sizeWithAttributes:hintAttrs] : NSZeroSize;
    CGFloat gap = h.length ? 3.0 : 0.0;
    CGFloat blockH = cs.height + (h.length ? hs.height + gap : 0.0);
    CGFloat midX = NSMidX(v.bounds);
    CGFloat base = NSMidY(v.bounds) - blockH / 2.0;

    // drawAtPoint: 的点在非翻转坐标系里是文字左下角、在翻转坐标系里是左上角
    if (v.isFlipped) {
        [c drawAtPoint:NSMakePoint(midX - cs.width / 2.0, base) withAttributes:captionAttrs];
        if (h.length) {
            [h drawAtPoint:NSMakePoint(midX - hs.width / 2.0, base + cs.height + gap)
            withAttributes:hintAttrs];
        }
    } else {
        if (h.length) {
            [h drawAtPoint:NSMakePoint(midX - hs.width / 2.0, base) withAttributes:hintAttrs];
            [c drawAtPoint:NSMakePoint(midX - cs.width / 2.0, base + hs.height + gap)
            withAttributes:captionAttrs];
        } else {
            [c drawAtPoint:NSMakePoint(midX - cs.width / 2.0, base) withAttributes:captionAttrs];
        }
    }
}

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

- (NSArray<NSString *> *)filePathsFromPasteboard:(NSPasteboard *)pb {
    return DITFilePathsFromPasteboard(pb);
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if (!self.enabled) return NSDragOperationNone;
    NSArray<NSString *> *paths = [self filePathsFromPasteboard:[sender draggingPasteboard]];
    if (paths.count == 0) return NSDragOperationNone;
    // 后缀名不对就直接亮「禁止」光标，别等放下之后才报错
    if (self.willAcceptPaths && !self.willAcceptPaths(paths)) return NSDragOperationNone;
    self.highlight = YES;
    return NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    self.highlight = NO;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    if (!self.enabled) return NO;
    NSArray<NSString *> *paths = [self filePathsFromPasteboard:[sender draggingPasteboard]];
    if (paths.count == 0) return NO;
    if (self.willAcceptPaths && !self.willAcceptPaths(paths)) return NO;
    return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.highlight = NO;
    NSArray<NSString *> *paths = [self filePathsFromPasteboard:[sender draggingPasteboard]];
    if (paths.count == 0 || !self.enabled) return NO;
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
    DITDrawHintText(self, self.caption, self.hint, captionAttrs, hintAttrs);
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

NSButton *DITButton(NSString *title, id target, SEL action) {
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    b.title = title;
    b.bezelStyle = NSBezelStyleRounded;
    b.font = [NSFont systemFontOfSize:12];
    b.target = target;
    b.action = action;
    return b;
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

/// 列表的内容视图。列表底色本来就由它画，所以空列表的引导文字也画在这里；
/// 它还盖住整个列表可视区（行数不足时下方的空白也在其中），
/// 因此把拖放接在这里，比接在行数会变化的表格上更完整。
@interface DITJobClipView : NSClipView
@property (nonatomic, copy, nullable) NSString *hint;
@property (nonatomic, copy, nullable) NSString *subHint;
@property (nonatomic, assign) BOOL dropEnabled;
@property (nonatomic, copy, nullable) void (^onDropPaths)(NSArray<NSString *> *paths);
@end

@implementation DITJobClipView {
    BOOL _highlight;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        _dropEnabled = YES;
    }
    return self;
}

- (void)setHint:(NSString *)hint {
    _hint = [hint copy];
    self.needsDisplay = YES;
}

- (void)setSubHint:(NSString *)subHint {
    _subHint = [subHint copy];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    if (_highlight) {
        NSRect r = NSInsetRect(self.bounds, 1.5, 1.5);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6 yRadius:6];
        p.lineWidth = 2.0;
        [[NSColor controlAccentColor] setStroke];
        [p stroke];
    }

    if (_hint.length == 0) return;
    NSDictionary *captionAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13.0],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };
    NSDictionary *hintAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.0],
        NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]
    };
    DITDrawHintText(self, _hint, _subHint, captionAttrs, hintAttrs);
}

#pragma mark 拖放

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if (!self.dropEnabled) return NSDragOperationNone;
    if (DITFilePathsFromPasteboard([sender draggingPasteboard]).count == 0) {
        return NSDragOperationNone;
    }
    _highlight = YES;
    self.needsDisplay = YES;
    return NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    _highlight = NO;
    self.needsDisplay = YES;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    if (!self.dropEnabled) return NO;
    return DITFilePathsFromPasteboard([sender draggingPasteboard]).count > 0;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    _highlight = NO;
    self.needsDisplay = YES;
    if (!self.dropEnabled) return NO;
    NSArray<NSString *> *paths = DITFilePathsFromPasteboard([sender draggingPasteboard]);
    if (paths.count == 0) return NO;
    if (self.onDropPaths) self.onDropPaths(paths);
    return YES;
}

@end

/// 表格本身只多一件事：把 Delete / Backspace 交给工具页的「删除选中」。
@interface DITJobTableView : NSTableView
@property (nonatomic, copy, nullable) void (^onDeleteKey)(void);
@end

@implementation DITJobTableView

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    unichar c = chars.length ? [chars characterAtIndex:0] : 0;
    BOOL isDelete = (c == NSDeleteCharacter || c == NSBackspaceCharacter ||
                     c == NSDeleteFunctionKey);
    if (isDelete && self.onDeleteKey) {
        self.onDeleteKey();
        return;
    }
    [super keyDown:event];
}

@end

/// 斑马纹只给自己的那一行画。
/// 不用 `NSTableView.usesAlternatingRowBackgroundColors`，是因为它铺的是整张表的
/// 可视区 —— 空列表（或只有两三行）时，下面那片空白会被排满看不见的「行」，
/// 一眼看过去像是塞了一堆空条目，引导文字也被压在条纹边界上。
@interface DITJobRowView : NSTableRowView
/// 这一行要不要铺斑马纹。由 delegate 在行视图刚加进来时告知 —— NSTableRowView
/// 没有暴露 row，自己算不出奇偶。
@property (nonatomic, assign) BOOL striped;
@end

@implementation DITJobRowView

- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [super drawBackgroundInRect:dirtyRect];
    if (!_striped) return;
    // 这个数组的第 0 个就是普通行底色，第 1 个才是条纹色
    NSArray<NSColor *> *cols = [NSColor alternatingContentBackgroundColors];
    if (cols.count < 2) return;
    [cols[1] setFill];
    NSRectFillUsingOperation(dirtyRect, NSCompositingOperationSourceOver);
}

@end

@interface DITJobTable () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *table;
@end

@implementation DITJobTable {
    DITJobClipView *_clip;
    BOOL _columnsUserAdjusted;          // 用户拖过分隔条之后就不再自动分配列宽
    NSArray<NSNumber *> *_lastAssigned; // 上一次由我们设定的列宽，用来识别用户拖动
}

- (instancetype)init {
    if ((self = [super init])) {
        _jobs = [NSMutableArray array];
        _dropEnabled = YES;
        __weak DITJobTable *ws = self;

        DITJobTableView *table = [[DITJobTableView alloc] initWithFrame:NSZeroRect];
        table.onDeleteKey = ^{
            if (ws.onDeleteRequested) ws.onDeleteRequested();
        };
        _table = table;
        _table.dataSource = self;
        _table.delegate = self;
        _table.rowHeight = 22;
        // 斑马纹自己画（见 DITJobRowView），别让表格把空白区也铺上条纹
        _table.usesAlternatingRowBackgroundColors = NO;
        _table.allowsMultipleSelection = YES;
        // 只允许拖列宽，不允许拖着列跑位（列的位置由布局决定）
        _table.allowsColumnResizing = YES;
        _table.allowsColumnReordering = NO;
        // 列宽是我们自己分配的（见 layoutColumnsForWidth:），
        // 所以关掉 AppKit 的自动分配，免得它把用户拖出来的宽度又抹平
        _table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
        _table.headerView = [[NSTableHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 100, 22)];

        NSArray *colDefs = @[@[@"文件", @260.0], @[@"位置", @240.0], @[@"状态", @150.0]];
        for (NSArray *def in colDefs) {
            NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:def[0]];
            col.title = def[0];
            col.width = [def[1] doubleValue];
            // 三列都允许用户拖分隔条调整；位置列额外参与窗口缩放时的余量分配
            col.resizingMask = NSTableColumnUserResizingMask;
            [_table addTableColumn:col];
        }
        _table.tableColumns[1].resizingMask |= NSTableColumnAutoresizingMask;

        _clip = [[DITJobClipView alloc] initWithFrame:NSZeroRect];
        _clip.onDropPaths = ^(NSArray<NSString *> *paths) {
            if (ws.onDropPaths) ws.onDropPaths(paths);
        };

        _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _scrollView.contentView = _clip;      // 要在设 documentView 之前换掉内容视图
        _scrollView.documentView = _table;
        _scrollView.hasVerticalScroller = YES;
        // 横向滚动条只在用户把列拖宽之后才需要（见 layoutColumnsForWidth:），
        // 平时列宽是按容器算的，不打开它就不会出现多余的滚动条
        _scrollView.hasHorizontalScroller = NO;
        _scrollView.borderType = NSBezelBorder;
        _scrollView.autohidesScrollers = YES;
    }
    return self;
}

#pragma mark 空状态与拖入开关

- (void)setEmptyHint:(NSString *)emptyHint {
    _emptyHint = [emptyHint copy];
    [self syncEmptyHint];
}

- (void)setEmptySubHint:(NSString *)emptySubHint {
    _emptySubHint = [emptySubHint copy];
    [self syncEmptyHint];
}

- (void)setDropEnabled:(BOOL)dropEnabled {
    _dropEnabled = dropEnabled;
    _clip.dropEnabled = dropEnabled;
}

/// 只有空列表时才显示引导文字，有内容就把它收掉
- (void)syncEmptyHint {
    BOOL empty = (_jobs.count == 0);
    _clip.hint = empty ? _emptyHint : nil;
    _clip.subHint = empty ? _emptySubHint : nil;
}

#pragma mark 选中与删除

- (BOOL)hasSelection {
    return _table.selectedRowIndexes.count > 0;
}

- (NSArray<DITJob *> *)selectedJobs {
    NSMutableArray<DITJob *> *out = [NSMutableArray array];
    NSUInteger idx = [_table.selectedRowIndexes firstIndex];
    while (idx != NSNotFound) {
        if (idx < _jobs.count) [out addObject:_jobs[idx]];
        idx = [_table.selectedRowIndexes indexGreaterThanIndex:idx];
    }
    return out;
}

- (void)selectAllJobs {
    [_table selectAll:nil];
}

- (NSInteger)removeSelectedJobs {
    NSIndexSet *sel = _table.selectedRowIndexes;
    if (sel.count == 0) return 0;
    NSInteger n = (NSInteger)sel.count;
    [_jobs removeObjectsAtIndexes:sel];
    [_table deselectAll:nil];
    [_table reloadData];
    [self syncEmptyHint];
    if (self.onSelectionChanged) self.onSelectionChanged();
    return n;
}

- (void)reloadAll {
    [_table reloadData];
    [self syncEmptyHint];
}

- (void)reloadRowOfJob:(DITJob *)job {
    NSInteger row = [_jobs indexOfObjectIdenticalTo:job];
    if (row == NSNotFound) return;
    [_table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                     columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 3)]];
}

/// 按容器宽度重新分配三列宽度（文件列与状态列按比例，位置列吃掉余量）。
/// 一旦发现列宽不是我们上次设的值，就认定用户拖过分隔条，从此不再插手。
- (void)layoutColumnsForWidth:(CGFloat)w {
    NSArray<NSTableColumn *> *cols = _table.tableColumns;
    if (cols.count != 3) return;

    if (!_columnsUserAdjusted && _lastAssigned.count == 3) {
        for (NSUInteger i = 0; i < 3; i++) {
            if (fabs(cols[i].width - _lastAssigned[i].doubleValue) > 1.0) {
                _columnsUserAdjusted = YES;
                break;
            }
        }
    }
    if (_columnsUserAdjusted) {
        // 用户调过的列宽加起来可能超过可视宽度，这时才需要横向滚动条
        _scrollView.hasHorizontalScroller = YES;
        return;
    }

    // 减去列间距，避免总宽比可视宽度多出几个像素、白冒一条横向滚动条
    CGFloat tw = w - 8;
    cols[0].width = MAX(150.0, tw * 0.34);
    cols[2].width = MAX(120.0, tw * 0.22);
    cols[1].width = MAX(120.0, tw - cols[0].width - cols[2].width - 3);
    _lastAssigned = @[@(cols[0].width), @(cols[1].width), @(cols[2].width)];
}

#pragma mark 自检与诊断

- (void)simulateColumnResize:(NSInteger)index delta:(CGFloat)delta {
    NSArray<NSTableColumn *> *cols = _table.tableColumns;
    if (index < 0 || index >= (NSInteger)cols.count) return;
    NSTableColumn *c = cols[(NSUInteger)index];
    c.width = MAX(40.0, c.width + delta);
}

- (NSArray<NSNumber *> *)columnWidths {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    for (NSTableColumn *c in _table.tableColumns) [out addObject:@(c.width)];
    return out;
}

- (NSArray<NSNumber *> *)columnResizingMasks {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    for (NSTableColumn *c in _table.tableColumns) [out addObject:@((NSUInteger)c.resizingMask)];
    return out;
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

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (self.onSelectionChanged) self.onSelectionChanged();
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [[DITJobRowView alloc] initWithFrame:NSZeroRect];
}

- (void)tableView:(NSTableView *)tableView
   didAddRowView:(NSTableRowView *)rowView
          forRow:(NSInteger)row {
    if ([rowView isKindOfClass:[DITJobRowView class]]) {
        ((DITJobRowView *)rowView).striped = (row % 2 == 1);
    }
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

- (NSString *)statusText {
    return _statusLabel.stringValue ?: @"";
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

- (void)setStopEnabled:(BOOL)enabled {
    [_stopBtn setEnabled:enabled];
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
