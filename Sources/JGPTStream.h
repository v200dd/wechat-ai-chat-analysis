#import <Foundation/Foundation.h>

typedef void (^JGPTStreamDelta)(NSString *delta, NSString *accumulated);
typedef void (^JGPTStreamDone)(NSString *accumulated, NSError *error);

// OpenAI 兼容的 SSE 流式对话（stream:true）。
// 只解析 choices[0].delta.content，其它事件忽略。
@interface JGPTStream : NSObject

+ (instancetype)startWithSystem:(NSString *)system
                           user:(NSString *)user
                       laneName:(NSString *)lane
                        onDelta:(JGPTStreamDelta)onDelta
                       onFinish:(JGPTStreamDone)onFinish;

// 判官那一路要低温、限长，避免模型写飞了 JSON 解析不出来。
+ (instancetype)startWithSystem:(NSString *)system
                           user:(NSString *)user
                       laneName:(NSString *)lane
                    temperature:(double)temperature
                      maxTokens:(NSInteger)maxTokens
                        onDelta:(JGPTStreamDelta)onDelta
                       onFinish:(JGPTStreamDone)onFinish;

- (void)cancel;

@end
