#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef void (^JGPTCompletion)(NSDictionary *json, NSString *raw, NSError *error);
typedef void (^JGPTMediaCompletion)(NSArray<NSString *> *urls, NSString *text, NSError *error);

@interface JGPTClient : NSObject

+ (instancetype)shared;

// 对话（OpenAI 兼容 /chat/completions）
- (void)chatWithSystem:(NSString *)system
                  user:(NSString *)user
              laneName:(NSString *)lane
            completion:(JGPTCompletion)completion;

// 判官用低温版。temperature < 0 时不带这个字段
// （部分推理模型会直接 400 拒掉 temperature）。
- (void)chatWithSystem:(NSString *)system
                  user:(NSString *)user
              laneName:(NSString *)lane
           temperature:(double)temperature
             maxTokens:(NSInteger)maxTokens
            completion:(JGPTCompletion)completion;

// 画图（/v1/images/generations，图生图 /v1/images/edits）
- (void)generateImage:(NSString *)prompt
            reference:(UIImage *)reference
           completion:(JGPTMediaCompletion)completion;

// 视频（/v1/videos/generations + /v1/videos/{request_id} 轮询）
- (void)generateVideo:(NSString *)prompt
           completion:(JGPTMediaCompletion)completion;

// 拉模型列表（/v1/models）
- (void)fetchModelsWithCompletion:(void (^)(NSArray<NSString *> *ids, NSError *error))completion;
// 画图分组单独地址/Key 拉模型
- (void)fetchVideoModelsWithCompletion:(void (^)(NSArray<NSString *> *, NSError *))completion;
- (void)fetchMediaModelsWithCompletion:(void (^)(NSArray<NSString *> *ids, NSError *error))completion;

+ (NSDictionary *)parseJSONLoose:(NSString *)text;
+ (NSString *)extractMessageContent:(NSDictionary *)json;
// 流式 JSON 还没写完时，取出某个字符串字段已经到达的部分
// （用于让「读心」边生成边显示，而不是等整段 JSON 收完）。
+ (NSString *)partialJSONStringForKey:(NSString *)key inText:(NSString *)text;

@end
