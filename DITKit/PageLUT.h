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
/// 自检用：模拟把一批路径拖进 LUT 拖放区（先过接收判断，再走落点处理）。
/// 返回是否被接收，并把结论打到标准输出，方便用例断言。
- (BOOL)simulateLUTDrop:(NSArray<NSString *> *)paths;
@end

NS_ASSUME_NONNULL_END
