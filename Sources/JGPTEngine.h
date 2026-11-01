#import <Foundation/Foundation.h>
#import "JGPTModels.h"

@interface JGPTEngine : NSObject

+ (instancetype)shared;

// 收到消息后触发：判断 + 起草 + 记忆更新（含 #画图 / #视频 指令）
- (void)handleIncoming:(id)msgWrap;
// chatName 是 AsyncOnAddMsg:MsgWrap: 的第一个参数：群聊时是群 ID，
// 私聊时是对方 wxid。传进来才不会把群消息当成私聊处理。
- (void)handleIncoming:(id)msgWrap chatName:(NSString *)chatName;

// 重新生成建议回复
- (void)regenerate:(JGPTJudgeResult *)result completion:(void (^)(JGPTJudgeResult *))completion;

// 发送第 index 条建议
- (BOOL)sendReplyAtIndex:(NSInteger)index of:(JGPTJudgeResult *)result;

// 媒体指令
- (BOOL)handleMediaCommand:(NSString *)text chat:(NSString *)chat replyTo:(NSString *)replyTo;

// 长按单条消息 → 只分析这一条（不自动回复、不受会话开关限制）
- (void)analyzeMessage:(id)msgWrap chat:(NSString *)chat;
// 这条消息是否是手动分析过的（内嵌卡据此显示，不看会话开关）
- (BOOL)isManualMessageKey:(NSString *)key;

// 本地兜底判断
- (JGPTJudgeResult *)localJudge:(NSString *)text chat:(NSString *)chat;

- (JGPTJudgeResult *)cachedResultFor:(NSString *)chat;
// 最近一次分析结果（不管哪个会话），聊天页用来兜底显示
- (JGPTJudgeResult *)latestResult;
- (JGPTJudgeResult *)cachedResultForMessage:(NSString *)messageKey;
- (void)cacheResult:(JGPTJudgeResult *)result;
- (NSString *)lastChatID;

@end
