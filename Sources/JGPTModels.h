#import <Foundation/Foundation.h>

@interface JGPTJudgeResult : NSObject

@property (nonatomic, copy) NSString *chatID;
// 这条结果对应的消息 key（引擎去重 / 卡片匹配都用它）
@property (nonatomic, copy) NSString *messageKey;
@property (nonatomic, copy) NSString *sourceText;
@property (nonatomic, copy) NSString *contactName;

@property (nonatomic, copy) NSString *intent;
@property (nonatomic, strong) NSArray<NSDictionary *> *intentOptions;
@property (nonatomic, assign) double risk;
@property (nonatomic, strong) NSArray<NSDictionary *> *riskOptions;
@property (nonatomic, copy) NSString *action;
@property (nonatomic, strong) NSArray<NSDictionary *> *actionOptions;
@property (nonatomic, copy) NSString *strategy;
@property (nonatomic, copy) NSString *mood;
@property (nonatomic, copy) NSString *shouldReply;
@property (nonatomic, strong) NSArray<NSDictionary *> *shouldReplyOptions;
@property (nonatomic, strong) NSArray<NSString *> *blocks;
@property (nonatomic, copy) NSString *humanRead;

@property (nonatomic, strong) NSArray<NSString *> *replies;
@property (nonatomic, strong) NSArray<NSString *> *alternates;
@property (nonatomic, strong) NSDictionary *regenInfo;

@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, assign) BOOL usedLocalJudge;
// 占位结果：真实分析还在流式生成，卡片先立起来显示「分析中…」
@property (nonatomic, assign) BOOL placeholder;
@property (nonatomic, assign) NSTimeInterval createdAt;

- (BOOL)isReady;
- (NSString *)riskLabel;
- (NSString *)summaryLine;
- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)resultWithDictionary:(NSDictionary *)dict;

@end

@interface JGPTMemoryNote : NSObject

@property (nonatomic, copy) NSString *wxid;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *gender;
@property (nonatomic, copy) NSString *relation;
@property (nonatomic, copy) NSString *about;
@property (nonatomic, copy) NSString *between;
@property (nonatomic, copy) NSString *topics;
@property (nonatomic, copy) NSString *recent;
@property (nonatomic, copy) NSString *recentSummary;
@property (nonatomic, copy) NSString *theirState;
@property (nonatomic, copy) NSString *promises;
@property (nonatomic, copy) NSString *portrait;
@property (nonatomic, copy) NSString *myStyle;
@property (nonatomic, assign) NSTimeInterval updatedAt;

- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)noteWithDictionary:(NSDictionary *)dict;
- (NSString *)brief;

@end
