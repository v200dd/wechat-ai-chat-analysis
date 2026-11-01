#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, JGPTApiPreset) {
    JGPTApiPresetDefault = 0,   // 默认：https://api.openai.com/v1（需自备 Key）
    JGPTApiPresetCustom  = 2,   // 自定义
};

typedef NS_ENUM(NSInteger, JGPTThinkingMode) {
    JGPTThinkingAuto = 0,
    JGPTThinkingNone,
    JGPTThinkingBailian,
    JGPTThinkingGLM,
    JGPTThinkingOpenAI,
    JGPTThinkingOpenRouter,
    JGPTThinkingGemini,
    JGPTThinkingVLLM,
};

FOUNDATION_EXPORT NSString * const JGPTDefaultBase;
FOUNDATION_EXPORT NSString * const JGPTDefaultModel;
FOUNDATION_EXPORT NSString * const JGPTDefaultVideoModel;
FOUNDATION_EXPORT NSString * const JGPTDefaultImageModel;

@interface JGPTConfig : NSObject

+ (instancetype)shared;

// 总开关
@property (nonatomic, assign) BOOL enabled;

// 接口（对话 / 判断 / 画图 / 视频 共用一套地址与 Key）
@property (nonatomic, assign) JGPTApiPreset apiPreset;
@property (nonatomic, copy) NSString *customBase;
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, copy) NSString *apiModel;
@property (nonatomic, copy) NSString *imageModel;
@property (nonatomic, copy) NSString *videoModel;
// 画图 / 视频单独分组：留空则复用主接口地址与主 Key
@property (nonatomic, copy) NSString *mediaBase;
@property (nonatomic, copy) NSString *mediaKey;
// 视频单独分组：独立 Key（留空则回落到画图 Key / 主 Key）
@property (nonatomic, copy) NSString *videoKey;
@property (nonatomic, assign) NSInteger contextLines;
@property (nonatomic, assign) JGPTThinkingMode thinkingMode;

- (NSString *)resolvedBase;
// 当前线路是否需要 Key / 是否支持画图视频
- (BOOL)currentNeedsKey;
- (BOOL)currentSupportsMedia;

// 行为
@property (nonatomic, assign) BOOL judgeEnabled;
@property (nonatomic, assign) BOOL genEnabled;
@property (nonatomic, assign) BOOL realTone;
@property (nonatomic, copy) NSArray<NSString *> *tones;
@property (nonatomic, assign) BOOL autoReplyEnabled;
@property (nonatomic, assign) NSInteger autoReplyIndex;
// 建议回复出现多少条（1~10，默认 4）
@property (nonatomic, assign) NSInteger replyCount;
@property (nonatomic, copy) NSString *msgPrefix;
@property (nonatomic, copy) NSString *msgSuffix;
@property (nonatomic, assign) BOOL groupNoAt;
@property (nonatomic, assign) BOOL quoteMode;
@property (nonatomic, assign) BOOL replyAllFriends;
@property (nonatomic, assign) BOOL memoryEnabled;
// 聊天页是否自动浮出分析卡（已废弃：现在卡片内嵌在消息下面）
@property (nonatomic, assign) BOOL showCard;
// 聊天页顶部入口（导航栏下方状态行）是否显示。
// 默认隐藏，连点顶部备注名字三下切换。
@property (nonatomic, assign) BOOL uiVisible;


// 会话级开关
- (BOOL)isSessionOn:(NSString *)wxid;
- (void)setSession:(NSString *)wxid on:(BOOL)on;
- (void)clearSession:(NSString *)wxid;

// 每个联系人单独选「自动发第几条」
- (NSInteger)autoReplyIndexFor:(NSString *)wxid;
- (void)setAutoReplyIndex:(NSInteger)index for:(NSString *)wxid;

// 用量
- (void)addUsage:(NSInteger)tokens lane:(NSString *)lane;
- (NSDictionary *)usageForLane:(NSString *)lane;
- (void)clearUsage;

- (void)synchronize;
@end
