#import <UIKit/UIKit.h>
#import "JGPTModels.h"

@interface JGPTAssistantPanel : UIView

+ (instancetype)sharedPanel;

- (void)showResult:(JGPTJudgeResult *)result inView:(UIView *)view;
// 只负责清理：早期版本挂在导航栏右上角的 🤖 要从所有页面摘干净。
// 2.6.5 起聊天页不再有右上角按钮，入口只有标题下那行状态字。
- (void)detachNavBarButton;
- (void)hide;

@property (nonatomic, copy) NSString *currentChat;

@end
