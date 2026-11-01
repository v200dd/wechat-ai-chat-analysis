#import "JGPTConfig.h"
#import "JGPTCommon.h"

NSString * const JGPTDefaultBase = @"https://api.openai.com/v1";
NSString * const JGPTDefaultModel = @"gpt-4o-mini";
NSString * const JGPTDefaultVideoModel = @"sora-2";
NSString * const JGPTDefaultImageModel = @"gpt-image-1";

static NSString * const kSessionStates = @"xb.session.states";
static NSString * const kSessionIndexes = @"xb.session.indexes";
static NSString * const kUsagePrefix = @"xb.usage.";

@interface JGPTConfig ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@end

@implementation JGPTConfig

+ (instancetype)shared {
    static JGPTConfig *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[JGPTConfig alloc] init];
        [shared loadDefaults];
    });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _defaults = [NSUserDefaults standardUserDefaults];
    }
    return self;
}

- (void)loadDefaults {
    NSDictionary *seed = @{
        @"xb.enabled": @YES,
        @"xb.apiPreset": @(JGPTApiPresetDefault),
        @"xb.customBase": @"",
        @"xb.apiKey": @"",
        @"xb.apiModel": JGPTDefaultModel,
        @"xb.imageModel": JGPTDefaultImageModel,
        @"xb.videoModel": JGPTDefaultVideoModel,
        @"xb.mediaBase": @"",
        @"xb.mediaKey": @"",
        @"xb.videoKey": @"",
        @"xb.ctx": @8,
        @"xb.thinking": @(JGPTThinkingAuto),
        @"xb.judgeEnabled": @YES,
        @"xb.genEnabled": @YES,
        @"xb.realTone": @YES,
        @"xb.tones": @[@"高情商话术"],
        @"xb.autoReply": @NO,
        @"xb.autoReplyIndex": @0,
        @"xb.replyCount": @4,
        @"xb.prefix": @"",
        @"xb.suffix": @"",
        @"xb.groupNoAt": @NO,
        @"xb.quoteMode": @NO,
        @"xb.replyAll": @NO,
        @"xb.memoryEnabled": @YES,
        @"xb.showCard": @NO,
        @"xb.uiVisible": @YES,
    };
    [seed enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if ([self.defaults objectForKey:key] == nil) [self.defaults setObject:obj forKey:key];
    }];

    // 2.6.9：入口默认显示。老版本存的是 NO，这里只迁移一次；
    // 之后用户连点三下隐藏的状态会一直生效。
    if (![self.defaults boolForKey:@"xb.uiVisibleMigrated269"]) {
        [self.defaults setBool:YES forKey:@"xb.uiVisible"];
        [self.defaults setBool:YES forKey:@"xb.uiVisibleMigrated269"];
    }

    // 老版本存过 gpt-4o-mini / 空视频模型，这里迁移一次到新默认值。
    // 用户自己改过的其他模型不动。
    NSString *m = [self.defaults stringForKey:@"xb.apiModel"];
    if (!m.length || [m isEqualToString:@"gpt-4o-mini"])
        [self.defaults setObject:JGPTDefaultModel forKey:@"xb.apiModel"];
    NSString *v = [self.defaults stringForKey:@"xb.videoModel"];
    // 旧的 grok-imagine 系列默认值统一迁移到通用默认模型
    if (!v.length || [v.lowercaseString containsString:@"grok-imagine"] || [v containsString:@"Preview"]) {
        [self.defaults setObject:JGPTDefaultVideoModel forKey:@"xb.videoModel"];
    }
    NSString *im = [self.defaults stringForKey:@"xb.imageModel"];
    if (!im.length) [self.defaults setObject:JGPTDefaultImageModel forKey:@"xb.imageModel"];

    [self.defaults synchronize];
}

#pragma mark - 基础

- (BOOL)enabled { return [self.defaults boolForKey:@"xb.enabled"]; }
- (void)setEnabled:(BOOL)v { [self.defaults setBool:v forKey:@"xb.enabled"]; }

#pragma mark - 接口

- (JGPTApiPreset)apiPreset { return [self.defaults integerForKey:@"xb.apiPreset"]; }
- (void)setApiPreset:(JGPTApiPreset)v { [self.defaults setInteger:v forKey:@"xb.apiPreset"]; }
- (NSString *)customBase { return [self.defaults stringForKey:@"xb.customBase"] ?: @""; }
- (void)setCustomBase:(NSString *)v { [self.defaults setObject:v ?: @"" forKey:@"xb.customBase"]; }
- (NSString *)apiKey { return [self.defaults stringForKey:@"xb.apiKey"] ?: @""; }
- (void)setApiKey:(NSString *)v { [self.defaults setObject:v ?: @"" forKey:@"xb.apiKey"]; }
- (NSString *)apiModel { return [self.defaults stringForKey:@"xb.apiModel"] ?: @""; }
- (void)setApiModel:(NSString *)v { [self.defaults setObject:v ?: @"" forKey:@"xb.apiModel"]; }
- (NSString *)imageModel { return [self.defaults stringForKey:@"xb.imageModel"] ?: @""; }
- (void)setImageModel:(NSString *)v { [self.defaults setObject:v ?: @"" forKey:@"xb.imageModel"]; }
- (NSString *)videoModel { return [self.defaults stringForKey:@"xb.videoModel"] ?: @""; }
- (void)setVideoModel:(NSString *)v { [self.defaults setObject:v ?: @"" forKey:@"xb.videoModel"]; }
- (NSString *)mediaBase { return [self.defaults stringForKey:@"xb.mediaBase"] ?: @""; }
- (void)setMediaBase:(NSString *)v { [self.defaults setObject:v ?: @"" forKey:@"xb.mediaBase"]; }
- (NSString *)mediaKey { return [self.defaults stringForKey:@"xb.mediaKey"] ?: @""; }
- (void)setMediaKey:(NSString *)v { [self.defaults setObject:v ?: @"" forKey:@"xb.mediaKey"]; }
- (NSString *)videoKey { return [self.defaults stringForKey:@"xb.videoKey"] ?: @""; }
- (void)setVideoKey:(NSString *)v { [self.defaults setObject:v ?: @"" forKey:@"xb.videoKey"]; }
- (NSInteger)contextLines { return [self.defaults integerForKey:@"xb.ctx"]; }
- (void)setContextLines:(NSInteger)v { [self.defaults setInteger:v forKey:@"xb.ctx"]; }
- (JGPTThinkingMode)thinkingMode { return [self.defaults integerForKey:@"xb.thinking"]; }
- (void)setThinkingMode:(JGPTThinkingMode)v { [self.defaults setInteger:v forKey:@"xb.thinking"]; }

- (NSString *)resolvedBase {
    switch (self.apiPreset) {
        case JGPTApiPresetCustom: {
            NSString *b = [self.customBase stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            return b.length ? b : JGPTDefaultBase;
        }
        default:
            return JGPTDefaultBase;
    }
}

- (BOOL)currentNeedsKey {
    return YES;
}

- (BOOL)currentSupportsMedia {
    // 所有线路都显示画图 / 视频配置；模型名留空，由用户填或从 /v1/models 选
    return YES;
}

#pragma mark - 行为

- (BOOL)judgeEnabled { return [self.defaults boolForKey:@"xb.judgeEnabled"]; }
- (void)setJudgeEnabled:(BOOL)v { [self.defaults setBool:v forKey:@"xb.judgeEnabled"]; }
- (BOOL)genEnabled { return [self.defaults boolForKey:@"xb.genEnabled"]; }
- (void)setGenEnabled:(BOOL)v { [self.defaults setBool:v forKey:@"xb.genEnabled"]; }
- (BOOL)realTone { return [self.defaults boolForKey:@"xb.realTone"]; }
- (void)setRealTone:(BOOL)v { [self.defaults setBool:v forKey:@"xb.realTone"]; }
- (NSArray<NSString *> *)tones { return [self.defaults arrayForKey:@"xb.tones"] ?: @[]; }
- (void)setTones:(NSArray<NSString *> *)v { [self.defaults setObject:v ?: @[] forKey:@"xb.tones"]; }
- (BOOL)autoReplyEnabled { return [self.defaults boolForKey:@"xb.autoReply"]; }
- (void)setAutoReplyEnabled:(BOOL)v { [self.defaults setBool:v forKey:@"xb.autoReply"]; }
- (NSInteger)autoReplyIndex { return [self.defaults integerForKey:@"xb.autoReplyIndex"]; }
- (void)setAutoReplyIndex:(NSInteger)v { [self.defaults setInteger:v forKey:@"xb.autoReplyIndex"]; }
- (NSString *)msgPrefix { return [self.defaults stringForKey:@"xb.prefix"] ?: @""; }
- (void)setMsgPrefix:(NSString *)v { [self.defaults setObject:v ?: @"" forKey:@"xb.prefix"]; }
- (NSString *)msgSuffix { return [self.defaults stringForKey:@"xb.suffix"] ?: @""; }
- (void)setMsgSuffix:(NSString *)v { [self.defaults setObject:v ?: @"" forKey:@"xb.suffix"]; }
- (BOOL)groupNoAt { return [self.defaults boolForKey:@"xb.groupNoAt"]; }
- (void)setGroupNoAt:(BOOL)v { [self.defaults setBool:v forKey:@"xb.groupNoAt"]; }
- (BOOL)quoteMode { return [self.defaults boolForKey:@"xb.quoteMode"]; }
- (void)setQuoteMode:(BOOL)v { [self.defaults setBool:v forKey:@"xb.quoteMode"]; }
- (BOOL)replyAllFriends { return [self.defaults boolForKey:@"xb.replyAll"]; }
- (void)setReplyAllFriends:(BOOL)v { [self.defaults setBool:v forKey:@"xb.replyAll"]; }
- (BOOL)memoryEnabled { return [self.defaults boolForKey:@"xb.memoryEnabled"]; }
- (void)setMemoryEnabled:(BOOL)v { [self.defaults setBool:v forKey:@"xb.memoryEnabled"]; }
- (NSInteger)replyCount {
    NSInteger n = [self.defaults integerForKey:@"xb.replyCount"];
    if (n < 1 || n > 10) n = 4;
    return n;
}
- (void)setReplyCount:(NSInteger)v {
    if (v < 1) v = 1;
    if (v > 10) v = 10;
    [self.defaults setInteger:v forKey:@"xb.replyCount"];
}
- (BOOL)showCard { return [self.defaults boolForKey:@"xb.showCard"]; }
- (void)setShowCard:(BOOL)v { [self.defaults setBool:v forKey:@"xb.showCard"]; }
- (BOOL)uiVisible {
    if ([self.defaults objectForKey:@"xb.uiVisible"] == nil) return YES;
    return [self.defaults boolForKey:@"xb.uiVisible"];
}
- (void)setUiVisible:(BOOL)v { [self.defaults setBool:v forKey:@"xb.uiVisible"]; }
#pragma mark - 会话

- (NSMutableDictionary *)sessionStates {
    NSDictionary *d = [self.defaults dictionaryForKey:kSessionStates];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

- (BOOL)isSessionOn:(NSString *)wxid {
    if (!wxid.length) return NO;
    return [[self sessionStates][wxid] boolValue];
}

- (void)setSession:(NSString *)wxid on:(BOOL)on {
    if (!wxid.length) return;
    NSMutableDictionary *states = [self sessionStates];
    states[wxid] = @(on);
    [self.defaults setObject:states forKey:kSessionStates];
    [self.defaults synchronize];
}

- (void)clearSession:(NSString *)wxid {
    if (!wxid.length) return;
    NSMutableDictionary *states = [self sessionStates];
    [states removeObjectForKey:wxid];
    [self.defaults setObject:states forKey:kSessionStates];

    NSDictionary *idx = [self.defaults dictionaryForKey:kSessionIndexes];
    if (idx[wxid]) {
        NSMutableDictionary *m = [idx mutableCopy];
        [m removeObjectForKey:wxid];
        [self.defaults setObject:m forKey:kSessionIndexes];
    }
    [self.defaults synchronize];
}

- (NSInteger)autoReplyIndexFor:(NSString *)wxid {
    if (!wxid.length) return self.autoReplyIndex;
    NSDictionary *idx = [self.defaults dictionaryForKey:kSessionIndexes];
    NSNumber *n = idx[wxid];
    return n ? n.integerValue : self.autoReplyIndex;
}

- (void)setAutoReplyIndex:(NSInteger)index for:(NSString *)wxid {
    if (!wxid.length) return;
    NSDictionary *cur = [self.defaults dictionaryForKey:kSessionIndexes];
    NSMutableDictionary *m = cur ? [cur mutableCopy] : [NSMutableDictionary dictionary];
    m[wxid] = @(MAX(0, MIN(index, 3)));
    [self.defaults setObject:m forKey:kSessionIndexes];
    [self.defaults synchronize];
}

#pragma mark - 用量

- (void)addUsage:(NSInteger)tokens lane:(NSString *)lane {
    if (!lane.length || tokens <= 0) return;
    NSString *dayKey = [NSString stringWithFormat:@"%@%@.day", kUsagePrefix, lane];
    NSString *totalKey = [NSString stringWithFormat:@"%@%@.total", kUsagePrefix, lane];
    NSString *stampKey = [NSString stringWithFormat:@"%@%@.stamp", kUsagePrefix, lane];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd";
    NSString *today = [fmt stringFromDate:[NSDate date]];
    if (![[self.defaults stringForKey:stampKey] isEqualToString:today]) {
        [self.defaults setObject:today forKey:stampKey];
        [self.defaults setInteger:0 forKey:dayKey];
    }
    [self.defaults setInteger:[self.defaults integerForKey:dayKey] + tokens forKey:dayKey];
    [self.defaults setInteger:[self.defaults integerForKey:totalKey] + tokens forKey:totalKey];
}

- (NSDictionary *)usageForLane:(NSString *)lane {
    if (!lane.length) return @{};
    NSString *dayKey = [NSString stringWithFormat:@"%@%@.day", kUsagePrefix, lane];
    NSString *totalKey = [NSString stringWithFormat:@"%@%@.total", kUsagePrefix, lane];
    NSString *stampKey = [NSString stringWithFormat:@"%@%@.stamp", kUsagePrefix, lane];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd";
    NSString *today = [fmt stringFromDate:[NSDate date]];
    NSInteger day = [[self.defaults stringForKey:stampKey] isEqualToString:today] ? [self.defaults integerForKey:dayKey] : 0;
    return @{@"today": @(day), @"total": @([self.defaults integerForKey:totalKey])};
}

- (void)clearUsage {
    for (NSString *lane in @[@"chat", @"image", @"video"]) {
        [self.defaults removeObjectForKey:[NSString stringWithFormat:@"%@%@.day", kUsagePrefix, lane]];
        [self.defaults removeObjectForKey:[NSString stringWithFormat:@"%@%@.total", kUsagePrefix, lane]];
    }
    [self.defaults synchronize];
}

- (void)synchronize {
    [self.defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:JGPTConfigChangedNotification object:nil];
}

@end
