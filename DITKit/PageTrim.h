//
//  PageTrim.h —— 工具页：视频裁剪
//
//  切出指定范围内的一段视频并另存。支持两种切法：
//    · 快速：`-c copy` 流复制，秒级完成，但起点会吸附到最近的关键帧
//    · 精确：重编码，帧级精确，耗时与片段长度成正比
//

#import <Cocoa/Cocoa.h>
#import "DITUI.h"

NS_ASSUME_NONNULL_BEGIN

/// 裁剪参数（GUI 与 --cli 共用）
@interface DITTrimSpec : NSObject
@property (nonatomic, assign) double startSec;
@property (nonatomic, assign) double endSec;
@property (nonatomic, assign) BOOL fastCopy;   // YES = 流复制，NO = 重编码
@property (nonatomic, assign) NSInteger quality;
@property (nonatomic, readonly) double duration;
@end

/// 裁剪的 ffmpeg 参数
NSArray<NSString *> *DITTrimArguments(DITJob *job, DITTrimSpec *spec);

@interface PageTrim : NSObject <DITToolPage>
+ (int)runCLI:(NSArray<NSString *> *)args;
+ (NSString *)cliUsage;
@end

NS_ASSUME_NONNULL_END
