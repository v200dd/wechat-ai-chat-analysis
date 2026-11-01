#import <UIKit/UIKit.h>

@interface JGPTChatCard : NSObject
+ (void)install;
+ (void)tick;
+ (void)hideAllBars;
+ (void)hideBar;
+ (void)showResultCardForChat:(NSString *)chat;
+ (void)showSessionSheetForChat:(NSString *)chat hostVC:(UIViewController *)hostVC;
// 由聊天页 viewDidLoad 钩子直接调用：把入口条挂到聊天页自己身上
+ (void)mountOnChatController:(UIViewController *)vc;
// 连点三下顶部备注名字：显示 / 隐藏聊天页入口（导航栏下方状态行）
+ (void)toggleUI;
@end
