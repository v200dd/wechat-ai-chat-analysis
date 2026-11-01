#import <Foundation/Foundation.h>

// 画图 / 视频调用日记（只在 App 内看，不写文件、不导出）。
// 记录：请求端点、模型、返回码、耗时、拿到几条结果、下载字节数、发送结果。
FOUNDATION_EXPORT NSString * const JGPTMediaLogChangedNotification;

@interface JGPTMediaLog : NSObject

// 一次 #画图 / #视频 记为一条任务。任务开始前调用，之后所有 logStage
// 都归到这一条下面，列表里只显示一行，点开才看得到每一步。
+ (void)beginTask:(NSString *)title;
+ (void)endTask;

+ (void)logStage:(NSString *)stage
              ok:(BOOL)ok
            text:(NSString *)text
          detail:(NSString *)detail;

// 原始明细（按时间倒序）
+ (NSArray<NSDictionary *> *)entries;
// 按任务合并：每项 {title, t, ok, count, summary, entries}
+ (NSArray<NSDictionary *> *)tasks;
+ (void)clear;

@end
