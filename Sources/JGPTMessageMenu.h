#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// 长按单条文字消息 → 菜单里多一项「🤖 分析」。
// 只分析这一条，不自动回复，也不受会话总开关影响。
//
// 注入点对齐 wxtts 的做法：不改 operationMenuItems 的返回值
// （改了会让菜单数据源和布局数量对不上，菜单会闪一下就消失），
// 而是在 MMMenuContentView 真正构建菜单时，往最后一行追加一项。
@interface JGPTMessageMenu : NSObject
+ (void)install;
@end
