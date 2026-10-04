//
//  PageLUT.h —— 工具页：LUT 批量调色
//

#import <Cocoa/Cocoa.h>
#import "DITUI.h"

NS_ASSUME_NONNULL_BEGIN

/// LUT 批处理的 ffmpeg 参数（GUI 与 --cli 共用）
NSArray<NSString *> *DITLUTArguments(DITJob *job, NSString *lutPath, NSInteger quality);

@interface PageLUT : NSObject <DITToolPage>
/// --cli 模式入口，返回进程退出码
+ (int)runCLI:(NSArray<NSString *> *)args;
/// --cli 的用法说明
+ (NSString *)cliUsage;
@end

NS_ASSUME_NONNULL_END
