#import <UIKit/UIKit.h>

// 聊天页内嵌分析卡：像参考项目那样，直接长在消息气泡下面，
// 通过 hook BaseChatViewModel.rowHeight + TextMessageCellView.layoutSubviews 实现。
@interface JGPTInlineCard : NSObject

+ (void)install;
// 新结果到达 / 会话切换后，让聊天列表重新计算行高
+ (void)refreshVisibleChatList;
// 该消息是否已有可显示的分析
+ (BOOL)hasCardForMessageKey:(NSString *)key;

@end
