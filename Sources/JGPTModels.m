#import "JGPTModels.h"

@implementation JGPTJudgeResult

- (instancetype)init {
    if (self = [super init]) {
        _createdAt = [[NSDate date] timeIntervalSince1970];
        _blocks = @[];
        _replies = @[];
        _alternates = @[];
        _intentOptions = @[];
        _riskOptions = @[];
        _actionOptions = @[];
        _shouldReplyOptions = @[];
        _status = @"pending";
    }
    return self;
}

- (BOOL)isReady {
    // 占位结果也是一份可显示的状态（卡片先立起来，写「正在分析…」，
    // 随后同一个对象被流式内容填满），否则第一条消息会等到全部写完才出现。
    if (self.placeholder) return YES;
    return self.humanRead.length > 0 || self.replies.count > 0;
}

- (NSString *)riskLabel {
    double r = self.risk;
    if (r <= 1.5) return @"几乎无风险";
    if (r <= 3.5) return @"轻微";
    if (r <= 5.5) return @"需要留意";
    if (r <= 7.5) return @"偏敏感";
    if (r <= 9.0) return @"高风险";
    return @"极易踩雷";
}

- (NSString *)summaryLine {
    NSMutableArray *parts = [NSMutableArray array];
    if (self.intent.length) [parts addObject:[NSString stringWithFormat:@"意图 %@", self.intent]];
    if (self.risk > 0) [parts addObject:[NSString stringWithFormat:@"风险 %.0f/10", self.risk]];
    if (self.action.length) [parts addObject:self.action];
    return [parts componentsJoinedByString:@" · "];
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    void (^put)(NSString *, id) = ^(NSString *k, id v) { if (v) d[k] = v; };
    put(@"chatID", self.chatID);
    put(@"messageKey", self.messageKey);
    put(@"sourceText", self.sourceText);
    put(@"contactName", self.contactName);
    put(@"intent", self.intent);
    put(@"intentOptions", self.intentOptions);
    put(@"risk", @(self.risk));
    put(@"riskOptions", self.riskOptions);
    put(@"action", self.action);
    put(@"actionOptions", self.actionOptions);
    put(@"strategy", self.strategy);
    put(@"mood", self.mood);
    put(@"shouldReply", self.shouldReply);
    put(@"shouldReplyOptions", self.shouldReplyOptions);
    put(@"blocks", self.blocks);
    put(@"humanRead", self.humanRead);
    put(@"replies", self.replies);
    put(@"alternates", self.alternates);
    put(@"regenInfo", self.regenInfo);
    put(@"status", self.status);
    put(@"detail", self.detail);
    put(@"usedLocalJudge", @(self.usedLocalJudge));
    put(@"placeholder", @(self.placeholder));
    put(@"createdAt", @(self.createdAt));
    return d;
}

+ (instancetype)resultWithDictionary:(NSDictionary *)dict {
    JGPTJudgeResult *r = [[JGPTJudgeResult alloc] init];
    if (![dict isKindOfClass:[NSDictionary class]]) return r;
    id (^get)(NSString *) = ^id(NSString *k) { id v = dict[k]; return v == [NSNull null] ? nil : v; };
    r.chatID = get(@"chatID");
    r.messageKey = get(@"messageKey");
    r.sourceText = get(@"sourceText");
    r.contactName = get(@"contactName");
    r.intent = get(@"intent");
    r.intentOptions = get(@"intentOptions") ?: @[];
    r.risk = [get(@"risk") doubleValue];
    r.riskOptions = get(@"riskOptions") ?: @[];
    r.action = get(@"action");
    r.actionOptions = get(@"actionOptions") ?: @[];
    r.strategy = get(@"strategy");
    r.mood = get(@"mood");
    r.shouldReply = get(@"shouldReply");
    r.shouldReplyOptions = get(@"shouldReplyOptions") ?: @[];
    r.blocks = get(@"blocks") ?: @[];
    r.humanRead = get(@"humanRead");
    r.replies = get(@"replies") ?: @[];
    r.alternates = get(@"alternates") ?: @[];
    r.regenInfo = get(@"regenInfo");
    r.status = get(@"status") ?: @"ok";
    r.detail = get(@"detail");
    r.usedLocalJudge = [get(@"usedLocalJudge") boolValue];
    r.placeholder = [get(@"placeholder") boolValue];
    r.createdAt = [get(@"createdAt") doubleValue] ?: [[NSDate date] timeIntervalSince1970];
    return r;
}

@end

@implementation JGPTMemoryNote

- (instancetype)init {
    if (self = [super init]) {
        _updatedAt = [[NSDate date] timeIntervalSince1970];
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    void (^put)(NSString *, id) = ^(NSString *k, id v) { if (v) d[k] = v; };
    put(@"wxid", self.wxid);
    put(@"displayName", self.displayName);
    put(@"gender", self.gender);
    put(@"relation", self.relation);
    put(@"about", self.about);
    put(@"between", self.between);
    put(@"topics", self.topics);
    put(@"recent", self.recent);
    put(@"recentSummary", self.recentSummary);
    put(@"theirState", self.theirState);
    put(@"promises", self.promises);
    put(@"portrait", self.portrait);
    put(@"myStyle", self.myStyle);
    put(@"updatedAt", @(self.updatedAt));
    return d;
}

+ (instancetype)noteWithDictionary:(NSDictionary *)dict {
    JGPTMemoryNote *n = [[JGPTMemoryNote alloc] init];
    if (![dict isKindOfClass:[NSDictionary class]]) return n;
    n.wxid = dict[@"wxid"];
    n.displayName = dict[@"displayName"];
    n.gender = dict[@"gender"];
    n.relation = dict[@"relation"];
    n.about = dict[@"about"];
    n.between = dict[@"between"];
    n.topics = dict[@"topics"];
    n.recent = dict[@"recent"];
    n.recentSummary = dict[@"recentSummary"];
    n.theirState = dict[@"theirState"];
    n.promises = dict[@"promises"];
    n.portrait = dict[@"portrait"];
    n.myStyle = dict[@"myStyle"];
    n.updatedAt = [dict[@"updatedAt"] doubleValue];
    return n;
}

- (NSString *)brief {
    NSMutableArray *parts = [NSMutableArray array];
    if (self.relation.length) [parts addObject:[NSString stringWithFormat:@"关系：%@", self.relation]];
    if (self.about.length) [parts addObject:[NSString stringWithFormat:@"TA：%@", self.about]];
    if (self.between.length) [parts addObject:[NSString stringWithFormat:@"我们：%@", self.between]];
    if (self.theirState.length) [parts addObject:[NSString stringWithFormat:@"近况：%@", self.theirState]];
    if (self.promises.length) [parts addObject:[NSString stringWithFormat:@"待办：%@", self.promises]];
    if (self.myStyle.length) [parts addObject:[NSString stringWithFormat:@"我的说话习惯：%@", self.myStyle]];
    if (self.recentSummary.length) [parts addObject:[NSString stringWithFormat:@"近期：%@", self.recentSummary]];
    return [parts componentsJoinedByString:@"\n"];
}

@end
