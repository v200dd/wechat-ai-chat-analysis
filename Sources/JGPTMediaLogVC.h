#import <UIKit/UIKit.h>

// 画图调用日记：列表只显示每次任务一行，点开看请求 / 返回 / 下载 / 发送。
@interface JGPTMediaLogVC : UITableViewController
@end

@interface JGPTMediaLogDetailVC : UITableViewController
- (instancetype)initWithTask:(NSDictionary *)task;
@end
