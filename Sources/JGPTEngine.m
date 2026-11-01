#import "JGPTEngine.h"
#import "JGPTConfig.h"
#import "JGPTClient.h"
#import "JGPTStream.h"
#import "JGPTPrompts.h"
#import "JGPTMemoryStore.h"
#import "JGPTWeChat.h"
#import "JGPTCommon.h"
#import "JGPTInlineCard.h"
#import "JGPTMediaLog.h"

@interface JGPTEngine ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, JGPTJudgeResult *> *cache;
// 手动长按分析过的消息（会话开关关着也要显示卡片）
@property (nonatomic, strong) NSMutableSet<NSString *> *manualKeys;
@property (nonatomic, strong) NSMutableDictionary<NSString *, JGPTJudgeResult *> *messageCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *lastIncoming;
@property (nonatomic, strong) NSMutableSet<NSString *> *seen;
// 流式过程中节流刷新（每个 token 都刷新列表会卡、也会把列表顶来顶去）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *publishTimes;
@property (nonatomic, strong) NSRecursiveLock *lock;
@property (nonatomic, copy) NSString *lastChat;
- (void)lockAndStore:(JGPTJudgeResult *)result key:(NSString *)key;
@end

static NSString *XMChatOfWrapLocal(id wrap) {
    JGPTWeChat *w = [JGPTWeChat shared];
    NSString *from = [w fromOf:wrap];
    NSString *to = [w toOf:wrap];
    if ([w isGroupMessage:wrap]) {
        if ([from hasSuffix:@"@chatroom"]) return from;
        if ([to hasSuffix:@"@chatroom"]) return to;
        return from;
    }
    return [w isOutgoing:wrap] ? to : from;
}

@implementation JGPTEngine

+ (instancetype)shared {
    static JGPTEngine *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[JGPTEngine alloc] init]; });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _cache = [NSMutableDictionary dictionary];
        _messageCache = [NSMutableDictionary dictionary];
        _lastIncoming = [NSMutableDictionary dictionary];
        _seen = [NSMutableSet set];
        _manualKeys = [NSMutableSet set];
        _publishTimes = [NSMutableDictionary dictionary];
        _lock = [[NSRecursiveLock alloc] init];
    }
    return self;
}

#pragma mark - 过滤

- (BOOL)shouldHandle:(id)msgWrap chatName:(NSString *)chatName {
    JGPTConfig *c = [JGPTConfig shared];
    if (!c.enabled) return NO;
    if (![[JGPTWeChat shared] msgMgr]) return NO;
    if ([[JGPTWeChat shared] typeOf:msgWrap] != 1) return NO;          // 仅文本
    if ([[JGPTWeChat shared] isOutgoing:msgWrap]) return NO;

    NSString *from = [[JGPTWeChat shared] fromOf:msgWrap];
    if (!from.length) return NO;

    NSString *content = [[JGPTWeChat shared] contentOf:msgWrap] ?: @"";
    BOOL group = [[JGPTWeChat shared] isGroupMessage:msgWrap];
    // 群聊的会话 ID 是群号，不是发言人
    NSString *chat = group ? (chatName.length ? chatName : from) : from;

    // 只有开了这个会话的开关才跑（私聊可额外用「对所有好友生效」放行）。
    // 群聊会话号偶尔被解析成发言人，两个都认一下。
    // 只有当前会话的开关打开才分析；不再用「对所有好友生效」兜底，
    // 否则所有联系人都会跑，用户看不到卡片却一直在消耗额度。
    BOOL sessionOn = [c isSessionOn:chat] || [c isSessionOn:from];
    if (!sessionOn) return NO;

    // 群聊默认要 @ 才处理；但 #画图 / #视频 这类显式指令不用 @
    BOOL mediaCommand = [content containsString:@"#画图"] || [content containsString:@"#绘图"]
                     || [content containsString:@"#生图"] || [content containsString:@"#改图"]
                     || [content containsString:@"#修图"] || [content containsString:@"#视频"]
                     || [content containsString:@"#生视频"];
    if (group && !c.groupNoAt && !mediaCommand) {
        if ([content rangeOfString:@"@"].location == NSNotFound) return NO;
    }
    return YES;
}

// 分析卡片对所有消息都跑；自动回复才受会话开关 / 群免 @ / 好友范围限制
- (BOOL)autoReplyAllowedFor:(id)msgWrap chat:(NSString *)chat {
    JGPTConfig *c = [JGPTConfig shared];
    if (!c.autoReplyEnabled) return NO;
    if ([[JGPTWeChat shared] isGroupMessage:msgWrap]) {
        if (![c isSessionOn:chat]) return NO;
        NSString *content = [[JGPTWeChat shared] contentOf:msgWrap] ?: @"";
        BOOL mediaCommand = [content containsString:@"#画图"] || [content containsString:@"#视频"]
                         || [content containsString:@"#绘图"] || [content containsString:@"#生图"];
        if (!c.groupNoAt && !mediaCommand && [content rangeOfString:@"@"].location == NSNotFound) return NO;
    } else {
        if (!c.replyAllFriends && ![c isSessionOn:chat]) return NO;
    }
    return YES;
}

- (BOOL)isClosingMessage:(NSString *)text {
    if (!text.length) return NO;
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length > 12) return NO;
    for (NSString *kw in [[JGPTPrompts closingKeywords] componentsSeparatedByString:@","]) {
        if ([t containsString:kw]) return YES;
    }
    static NSSet *ackSet = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ackSet = [NSSet setWithArray:@[@"嗯", @"哦", @"哈", @"好", @"行", @"在", @"收到", @"ok", @"OK", @"1"]];
    });
    if ([ackSet containsObject:t]) return YES;
    if (t.length <= 4 && [[t stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"哈嗯哦呵"]] length] == 0) return YES;
    return NO;
}

- (JGPTJudgeResult *)localJudge:(NSString *)text chat:(NSString *)chat {
    JGPTJudgeResult *r = [[JGPTJudgeResult alloc] init];
    r.chatID = chat;
    r.sourceText = text;
    r.usedLocalJudge = YES;
    r.status = @"local";
    r.contactName = [[JGPTWeChat shared] displayNameFor:chat];
    r.intent = @"随口闲聊";
    r.intentOptions = @[@{@"label": @"随口闲聊", @"prob": @0.6},
                        @{@"label": @"求回应求陪伴", @"prob": @0.25},
                        @{@"label": @"想确认你在不在乎", @"prob": @0.15}];
    r.risk = 2;
    r.riskOptions = @[@{@"label": @"轻微", @"prob": @0.6},
                      @{@"label": @"需要留意", @"prob": @0.3},
                      @{@"label": @"偏敏感", @"prob": @0.1}];
    r.action = @"轻松带过不深聊";
    r.actionOptions = @[@{@"label": @"接住情绪回应情感", @"prob": @0.55},
                        @{@"label": @"先确认再给建议", @"prob": @0.25},
                        @{@"label": @"直接给结论", @"prob": @0.2}];
    r.strategy = @"承接";
    r.mood = @"平静";
    r.shouldReply = @"立刻回";
    r.shouldReplyOptions = @[@{@"label": @"立刻回", @"prob": @0.65},
                             @{@"label": @"先想清楚再回", @"prob": @0.35}];
    r.humanRead = @"这句更像随口一说，不用过度解读。顺着接一句就好，别追问太多。";
    r.blocks = @[@"情绪平稳", @"没有明确诉求", @"轻松接住即可"];
    return r;
}

#pragma mark - 入口

// 占位结果：只有「正在分析…」，不带任何本地默认结论。
// 之前这里直接用 localJudge，于是每条消息都先显示同一份
// 「随口闲聊 60% / 承接 / 危险 2/10」，看起来像每次都挑同一个结果。
- (JGPTJudgeResult *)placeholderJudge:(NSString *)text chat:(NSString *)chat {
    JGPTJudgeResult *r = [[JGPTJudgeResult alloc] init];
    r.chatID = chat;
    r.sourceText = text;
    r.contactName = [[JGPTWeChat shared] displayNameFor:chat];
    r.humanRead = @"";
    r.placeholder = YES;
    r.status = @"streaming";
    r.intentOptions = @[];
    r.riskOptions = @[];
    r.actionOptions = @[];
    r.shouldReplyOptions = @[];
    r.blocks = @[];
    r.replies = @[];
    return r;
}

- (void)handleIncoming:(id)msgWrap {
    [self handleIncoming:msgWrap chatName:nil];
}

- (void)handleIncoming:(id)msgWrap chatName:(NSString *)chatName {
    if (![self shouldHandle:msgWrap chatName:chatName]) return;

    NSString *key = [[JGPTWeChat shared] messageKey:msgWrap];
    if (key.length) {
        [self.lock lock];
        BOOL dup = [self.seen containsObject:key];
        if (!dup) {
            [self.seen addObject:key];
            if (self.seen.count > 800) [self.seen removeAllObjects];
        }
        [self.lock unlock];
        if (dup) return;
    }

    BOOL group = [[JGPTWeChat shared] isGroupMessage:msgWrap];
    NSString *from = [[JGPTWeChat shared] fromOf:msgWrap];
    NSString *chat = (group && chatName.length) ? chatName : from;
    NSString *text = [[JGPTWeChat shared] contentOf:msgWrap] ?: @"";
    if (group) text = [[JGPTWeChat shared] stripGroupSenderPrefix:text];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!chat.length || !text.length) return;

    // 媒体指令（同样受会话开关限制，开关没开不响应）
    if ([self handleMediaCommand:text chat:chat replyTo:chat]) return;

    // 收线消息（晚安/嗯/哈哈）仍然分析，让用户能看见判断；
    // 只是后面不会自动发出去。
    BOOL closing = [self isClosingMessage:text];

    JGPTConfig *c = [JGPTConfig shared];
    if (!c.judgeEnabled && !c.genEnabled) return;
    if (!c.apiKey.length && c.currentNeedsKey) {
        // 没 Key 时以前会退回 localJudge，于是每条消息都显示同一份
        // 「随口闲聊 60% / 承接 / 危险 2」，看起来像每次都挑同一个结果。
        // 现在直接说明原因，不再伪造分析。
        JGPTJudgeResult *notice = [self placeholderJudge:text chat:chat];
        notice.messageKey = key;
        notice.placeholder = NO;
        notice.status = @"ok";
        notice.humanRead = @"还没填 API Key，去设置 → 接口线路填上就能开始分析。";
        notice.replies = @[];
        [self lockAndStore:notice key:key];
        [[NSNotificationCenter defaultCenter] postNotificationName:JGPTResultNotification object:notice];
        [JGPTInlineCard refreshVisibleChatList];
        return;
    }

    JGPTMemoryNote *note = [[JGPTMemoryStore shared] noteFor:chat];
    if (!note.displayName.length) note.displayName = [[JGPTWeChat shared] displayNameFor:chat];
    if (!note.gender.length) note.gender = [[JGPTWeChat shared] genderFor:chat];

    JGPTJudgeResult *local = [self placeholderJudge:text chat:chat];
    local.contactName = note.displayName;
    local.messageKey = key;
    if (closing) local.detail = @"closing";
    [self cacheResult:local];
    [self.lock lock];
    self.lastIncoming[chat] = msgWrap;
    self.lastChat = chat;
    if (key.length) self.messageCache[key] = local;
    if (self.messageCache.count > 200) [self.messageCache removeAllObjects];
    [self.lock unlock];

    [[NSNotificationCenter defaultCenter] postNotificationName:JGPTResultNotification object:local];
    [JGPTInlineCard refreshVisibleChatList];
    [[JGPTMemoryStore shared] appendHistory:@[@{@"role": @"user", @"content": text}] for:chat];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self runPipelineFor:text chat:chat note:note key:key];
    });
}

- (void)runPipelineFor:(NSString *)text chat:(NSString *)chat note:(JGPTMemoryNote *)note key:(NSString *)key {
    JGPTConfig *c = [JGPTConfig shared];
    NSString *history = [[JGPTMemoryStore shared] historyTextFor:chat limit:MAX(c.contextLines, 6)];
    BOOL isGroup = [[JGPTWeChat shared] isGroup:chat];

    JGPTJudgeResult *result = [self placeholderJudge:text chat:chat];
    result.contactName = note.displayName;
    result.messageKey = key;
    if ([[self cachedResultFor:chat].detail isEqualToString:@"closing"]) result.detail = @"closing";
    [self lockAndStore:result key:key];
    NSString *publishKey = key.length ? key : [NSString stringWithFormat:@"%@|%@", chat, text];

    void (^draft)(void) = ^{
        BOOL ready = c.apiKey.length || !c.currentNeedsKey;
        if (!(c.genEnabled && ready)) {
            [self finish:result chat:chat note:note];
            return;
        }
        NSString *prompt = [JGPTPrompts draftPrompt:result note:note history:history tones:c.tones realTone:c.realTone count:c.replyCount];
        // 流式起草：边生成边把已经完整的建议回复推进卡片，看起来是逐条冒出来的。
        __block NSInteger lastCount = 0;
        __block JGPTStream *stream = nil;
        stream = [JGPTStream startWithSystem:@"你只输出纯文本，一行一条。"
                                        user:prompt
                                    laneName:@"chat"
                                     onDelta:^(NSString *delta, NSString *accumulated) {
            NSArray *partial = [self partialRepliesFrom:accumulated];
            if (partial.count > lastCount) {
                lastCount = partial.count;
                result.replies = partial;
                result.status = @"streaming";
                [self publishResult:result key:publishKey minInterval:0.2];
            }
        } onFinish:^(NSString *accumulated, NSError *error) {
            NSArray *replies = [self repliesFromFinalText:accumulated];
            if (replies.count) result.replies = replies;
            else if (!result.replies.count)
                JGPTLog(@"draft failed: %@", error.localizedDescription);
            result.status = @"ok";
            [self finish:result chat:chat note:note];
        }];
        (void)stream;
    };

    BOOL ready = c.apiKey.length || !c.currentNeedsKey;
    if (!(c.judgeEnabled && ready)) {
        draft();
        return;
    }

    NSString *sys = [JGPTPrompts judgeSystemPrompt];
    NSString *usr = [JGPTPrompts judgeUserPrompt:text history:history note:note contact:note.displayName group:isGroup];
    __block NSString *lastHumanRead = nil;

    // 判官也走流式：humanRead 排在 JSON 第一位，
    // 收到多少就先显示多少，用户看到的是文字一点点长出来，
    // 而不是先弹出本地兜底的「随口闲聊 60%」再整体替换。
    [JGPTStream startWithSystem:sys user:usr laneName:@"chat"
                    temperature:-1 maxTokens:0
                       onDelta:^(NSString *delta, NSString *accumulated) {
        NSString *partial = [JGPTClient partialJSONStringForKey:@"humanRead" inText:accumulated];
        if (!partial.length || [partial isEqualToString:lastHumanRead]) return;
        lastHumanRead = partial;
        result.humanRead = partial;
        result.placeholder = NO;
        result.status = @"streaming";
        [self publishResult:result key:publishKey minInterval:0.25];
    } onFinish:^(NSString *accumulated, NSError *error) {
        NSDictionary *parsed = [JGPTClient parseJSONLoose:accumulated];
        // 必须真的解析出分析内容，空对象也算失败 ——
        // 否则会走 finish 里的默认文案，每条消息长得一模一样。
        if (![self isValidJudgePayload:parsed]) parsed = nil;
        if (parsed) {
            [self applyJudge:parsed to:result];
            result.placeholder = NO;
            [self publishResult:result key:publishKey minInterval:0];
            draft();
            return;
        }
        JGPTLog(@"judge stream failed: %@ / %@", error.localizedDescription, accumulated);
        // 流式拿不到可用 JSON：退一次普通请求，仍然不行再用占位文案。
        [[JGPTClient shared] chatWithSystem:sys user:usr laneName:@"chat" temperature:-1 maxTokens:0
                                 completion:^(NSDictionary *json, NSString *raw, NSError *e2) {
            NSString *content = [JGPTClient extractMessageContent:json];
            NSDictionary *p = content ? [JGPTClient parseJSONLoose:content] : nil;
            if (!p && raw) p = [JGPTClient parseJSONLoose:raw];
            if (![self isValidJudgePayload:p]) p = nil;
            if (p) {
                [self applyJudge:p to:result];
            } else {
                result.humanRead = result.humanRead.length ? result.humanRead
                                                           : @"这条没能分析出来，检查一下 Key 或接口线路。";
                JGPTLog(@"judge failed: %@ / %@", e2.localizedDescription, raw);
            }
            result.placeholder = NO;
            result.status = @"judged";
            [self publishResult:result key:publishKey minInterval:0];
            draft();
        }];
    }];
}

// 流式期间每次都刷 list 会卡；这里按最小间隔合并，最后一次强制推。
- (void)publishResult:(JGPTJudgeResult *)result key:(NSString *)key minInterval:(NSTimeInterval)interval {
    if (!result) return;
    [self.lock lock];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval last = key.length ? [self.publishTimes[key] doubleValue] : 0;
    BOOL due = (interval <= 0) || (now - last >= interval);
    if (due && key.length) self.publishTimes[key] = @(now);
    if (self.publishTimes.count > 300) [self.publishTimes removeAllObjects];
    [self.lock unlock];
    if (result.messageKey.length) {
        [self.lock lock];
        self.messageCache[result.messageKey] = result;
        [self.lock unlock];
    }
    [self cacheResult:result];
    if (!due) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:JGPTResultNotification object:result];
        [JGPTInlineCard refreshVisibleChatList];
    });
}

// 流式预览：模型按「一行一条」输出，边写边把已经完整的行推进卡片。
// 兼容旧格式（有些模型仍会吐 {"replies":[...]} 的 JSON），两种都能吃。
- (NSArray<NSString *> *)partialRepliesFrom:(NSString *)text {
    if (!text.length) return @[];
    NSInteger cap = [JGPTConfig shared].replyCount;
    if (cap < 1) cap = 4;

    NSMutableArray *out = [NSMutableArray array];

    if ([text rangeOfString:@"\"replies\""].location != NSNotFound) {
        NSRange keyRange = [text rangeOfString:@"\"replies\""];
        NSString *tail = [text substringFromIndex:keyRange.location];
        BOOL inString = NO;
        BOOL escape = NO;
        NSMutableString *cur = [NSMutableString string];
        for (NSUInteger i = 0; i < tail.length; i++) {
            unichar ch = [tail characterAtIndex:i];
            if (!inString) {
                if (ch == '"') { inString = YES; escape = NO; [cur setString:@""]; }
                continue;
            }
            if (escape) { [cur appendFormat:@"%C", ch]; escape = NO; continue; }
            if (ch == '\\') { escape = YES; continue; }
            if (ch == '"') {
                inString = NO;
                NSString *s = [cur stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (s.length && ![s isEqualToString:@"replies"]) [out addObject:s];
                if ((NSInteger)out.count >= cap) break;
                continue;
            }
            [cur appendFormat:@"%C", ch];
        }
        return out;
    }

    // 纯文本逐行模式：只取已经出现换行、确认写完的行；
    // 最后一行还在流里，等 finish 再补，避免半句闪一下。
    NSArray *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSUInteger i = 0; i + 1 < lines.count; i++) {
        NSString *s = [self cleanReplyLine:lines[i]];
        if (s.length) [out addObject:s];
        if ((NSInteger)out.count >= cap) break;
    }
    return out;
}

// 去掉序号 / 引号 / Markdown 项目符号，模型偶尔不听话
- (NSString *)cleanReplyLine:(NSString *)raw {
    if (![raw isKindOfClass:[NSString class]] || !raw.length) return @"";
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return @"";
    NSArray *prefixes = @[@"- ", @"* ", @"• ", @"· ", @"1. ", @"2. ", @"3. ", @"4. ", @"5. ",
                          @"6. ", @"7. ", @"8. ", @"9. ", @"10. "];
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSString *p in prefixes) {
            if ([s hasPrefix:p]) { s = [s substringFromIndex:p.length]; changed = YES; }
        }
    }
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"“”‘’"]];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return s;
}

- (NSArray<NSString *> *)cleanReplies:(NSArray *)raw {
    NSInteger cap = [JGPTConfig shared].replyCount;
    if (cap < 1) cap = 4;
    NSMutableArray *out = [NSMutableArray array];
    for (id item in raw) {
        NSString *s = [item isKindOfClass:[NSString class]] ? item : nil;
        if (!s.length && [item isKindOfClass:[NSDictionary class]]) s = item[@"text"];
        s = [self cleanReplyLine:s];
        if (s.length) [out addObject:s];
        if ((NSInteger)out.count >= cap) break;
    }
    return out;
}

// 把整段流式文本拆成最终回复：优先 JSON，其次逐行
- (NSArray<NSString *> *)repliesFromFinalText:(NSString *)text {
    NSInteger cap = [JGPTConfig shared].replyCount;
    if (cap < 1) cap = 4;
    NSDictionary *parsed = [JGPTClient parseJSONLoose:text];
    NSArray *replies = parsed[@"replies"];
    if ([replies isKindOfClass:[NSArray class]] && replies.count)
        return [self cleanReplies:replies];

    NSMutableArray *out = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *s = [self cleanReplyLine:line];
        if (s.length) [out addObject:s];
        if ((NSInteger)out.count >= cap) break;
    }
    return out;
}

- (void)applyJudge:(NSDictionary *)d to:(JGPTJudgeResult *)r {
    id (^get)(NSString *) = ^id(NSString *k) { id v = d[k]; return v == [NSNull null] ? nil : v; };
    if (JGPTString(get(@"intent"))) r.intent = get(@"intent");
    if ([get(@"intentOptions") isKindOfClass:[NSArray class]]) r.intentOptions = get(@"intentOptions");
    if (get(@"risk")) r.risk = [get(@"risk") doubleValue];
    if ([get(@"riskOptions") isKindOfClass:[NSArray class]]) r.riskOptions = get(@"riskOptions");
    if (JGPTString(get(@"action"))) r.action = get(@"action");
    if ([get(@"actionOptions") isKindOfClass:[NSArray class]]) r.actionOptions = get(@"actionOptions");
    if (JGPTString(get(@"strategy"))) r.strategy = get(@"strategy");
    if (JGPTString(get(@"mood"))) r.mood = get(@"mood");
    if (JGPTString(get(@"shouldReply"))) r.shouldReply = get(@"shouldReply");
    if ([get(@"shouldReplyOptions") isKindOfClass:[NSArray class]]) r.shouldReplyOptions = get(@"shouldReplyOptions");
    if (JGPTString(get(@"humanRead"))) r.humanRead = get(@"humanRead");
    if ([get(@"blocks") isKindOfClass:[NSArray class]]) r.blocks = get(@"blocks");
    r.usedLocalJudge = NO;
    r.status = @"judged";
}

// JSON 里至少要有一项真正的分析内容，否则就当解析失败，
// 不能拿空对象去过 applyJudge（那会留下上一条的默认文案）。
- (BOOL)isValidJudgePayload:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]] || !d.count) return NO;
    if (JGPTString(d[@"humanRead"]).length) return YES;
    if (JGPTString(d[@"intent"]).length) return YES;
    if (JGPTString(d[@"action"]).length) return YES;
    id opts = d[@"intentOptions"];
    if ([opts isKindOfClass:[NSArray class]] && [opts count]) return YES;
    return NO;
}

- (void)finish:(JGPTJudgeResult *)result chat:(NSString *)chat note:(JGPTMemoryNote *)note {
    if (!result.humanRead.length) result.humanRead = @"这条没能分析出来，长按消息点「🤖 分析」再试一次。";
    // 建议回复没生成出来就留空，不再塞三条固定话术，
    // 那样每条消息看起来都像同一份结果。
    result.placeholder = NO;
    result.status = @"ok";
    [self cacheResult:result];
    [self.lock lock];
    // 只把「这条消息」的占位结果换成最终结果。
    // 之前按 chatID 批量替换，会把整个会话的历史消息都指向同一份分析，
    // 于是每条气泡下面都长出一模一样的卡。
    if (result.messageKey.length) {
        self.messageCache[result.messageKey] = result;
    }
    [self.lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:JGPTResultNotification object:result];
        [JGPTInlineCard refreshVisibleChatList];
        [self autoReplyIfNeeded:result chat:chat];
    });
    [self updateMemory:note chat:chat];
}

- (void)autoReplyIfNeeded:(JGPTJudgeResult *)result chat:(NSString *)chat {
    if (!result.replies.count) return;
    // 收线 / 纯应付消息只分析，不自动回
    if ([result.detail isEqualToString:@"closing"]) return;
    if ([result.shouldReply containsString:@"先想清楚"]) return;
    JGPTConfig *c = [JGPTConfig shared];
    if (!c.autoReplyEnabled) return;
    [self.lock lock];
    id wrap = self.lastIncoming[chat];
    [self.lock unlock];
    if (wrap && ![self autoReplyAllowedFor:wrap chat:chat]) return;
    if (!wrap && ![c isSessionOn:chat]) return;
    NSInteger want = [c autoReplyIndexFor:chat];
    NSInteger idx = MIN(MAX(0, want), (NSInteger)result.replies.count - 1);
    [self sendReplyAtIndex:idx of:result];
}

- (BOOL)sendReplyAtIndex:(NSInteger)index of:(JGPTJudgeResult *)result {
    if (index < 0 || index >= (NSInteger)result.replies.count) return NO;
    JGPTConfig *c = [JGPTConfig shared];
    NSString *text = [NSString stringWithFormat:@"%@%@%@", c.msgPrefix ?: @"", result.replies[index], c.msgSuffix ?: @""];
    id quoted = nil;
    if (c.quoteMode) {
        [self.lock lock];
        quoted = self.lastIncoming[result.chatID];
        [self.lock unlock];
    }
    [[JGPTWeChat shared] sendText:text to:result.chatID quote:quoted];
    [[JGPTMemoryStore shared] appendHistory:@[@{@"role": @"assistant", @"content": result.replies[index]}] for:result.chatID];
    return YES;
}

- (void)regenerate:(JGPTJudgeResult *)result completion:(void (^)(JGPTJudgeResult *))completion {
    if (!result) return;
    JGPTConfig *c = [JGPTConfig shared];
    JGPTMemoryNote *note = [[JGPTMemoryStore shared] noteFor:result.chatID];
    NSString *history = [[JGPTMemoryStore shared] historyTextFor:result.chatID limit:MAX(c.contextLines, 6)];
    NSString *prompt = [JGPTPrompts draftPrompt:result note:note history:history tones:c.tones realTone:c.realTone count:c.replyCount];
    result.replies = @[];
    result.status = @"streaming";

    __block NSInteger lastCount = 0;
    __block JGPTStream *stream = nil;
    stream = [JGPTStream startWithSystem:@"你只输出纯文本，一行一条。"
                                    user:prompt
                                laneName:@"chat"
                                 onDelta:^(NSString *delta, NSString *accumulated) {
        NSArray *partial = [self partialRepliesFrom:accumulated];
        if ((NSInteger)partial.count > lastCount) {
            lastCount = partial.count;
            result.replies = partial;
            result.status = @"streaming";
            [self cacheResult:result];
            [self.lock lock];
            if (result.messageKey.length) self.messageCache[result.messageKey] = result;
            [self.lock unlock];
            [[NSNotificationCenter defaultCenter] postNotificationName:JGPTResultNotification object:result];
            [JGPTInlineCard refreshVisibleChatList];
        }
    } onFinish:^(NSString *accumulated, NSError *error) {
        NSArray *replies = [self repliesFromFinalText:accumulated];
        if (replies.count) result.replies = replies;
        result.status = @"ok";
        [self cacheResult:result];
        [self.lock lock];
        if (result.messageKey.length) self.messageCache[result.messageKey] = result;
        [self.lock unlock];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:JGPTResultNotification object:result];
            [JGPTInlineCard refreshVisibleChatList];
            if (completion) completion(result);
        });
    }];
    (void)stream;
}

- (void)updateMemory:(JGPTMemoryNote *)note chat:(NSString *)chat {
    JGPTConfig *c = [JGPTConfig shared];
    if (!c.memoryEnabled) return;
    if (!c.apiKey.length && c.currentNeedsKey) return;
    if (![[JGPTMemoryStore shared] shouldSummarize:chat]) return;

    NSArray *recent = [[JGPTMemoryStore shared] historyFor:chat];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSDictionary *m in recent) {
        NSString *role = [m[@"role"] isEqualToString:@"assistant"] ? @"我" : @"对方";
        if (JGPTString(m[@"content"]).length)
            [lines addObject:[NSString stringWithFormat:@"%@：%@", role, m[@"content"]]];
    }
    NSString *transcript = [lines componentsJoinedByString:@"\n"];
    NSString *prompt = [JGPTPrompts memoryUpdatePrompt:note transcript:transcript];

    [[JGPTClient shared] chatWithSystem:@"你只输出 JSON。" user:prompt laneName:@"chat"
                             completion:^(NSDictionary *json, NSString *raw, NSError *error) {
        NSString *content = [JGPTClient extractMessageContent:json];
        NSDictionary *parsed = content ? [JGPTClient parseJSONLoose:content] : nil;
        if (!parsed) return;
        JGPTMemoryNote *fresh = [[JGPTMemoryStore shared] noteFor:chat];
        void (^setIf)(NSString *, NSString *) = ^(NSString *k, NSString *v) {
            if (v.length) [fresh setValue:v forKey:k];
        };
        setIf(@"relation", parsed[@"relation"]);
        setIf(@"about", parsed[@"about"]);
        setIf(@"between", parsed[@"between"]);
        setIf(@"topics", parsed[@"topics"]);
        setIf(@"recent", parsed[@"recent"]);
        setIf(@"recentSummary", parsed[@"recentSummary"]);
        setIf(@"theirState", parsed[@"theirState"]);
        setIf(@"promises", parsed[@"promises"]);
        setIf(@"portrait", parsed[@"portrait"]);
        setIf(@"myStyle", parsed[@"myStyle"]);
        if (!fresh.displayName.length) fresh.displayName = note.displayName;
        [[JGPTMemoryStore shared] saveNote:fresh];
    }];
}

#pragma mark - 单条手动分析

- (BOOL)isManualMessageKey:(NSString *)key {
    if (!key.length) return NO;
    [self.lock lock];
    BOOL v = [self.manualKeys containsObject:key];
    [self.lock unlock];
    return v;
}

// 长按消息 → 只分析这一条。不写会话历史，不自动回复，不受会话开关限制。
- (void)analyzeMessage:(id)msgWrap chat:(NSString *)chat {
    if (!msgWrap) return;
    JGPTWeChat *w = [JGPTWeChat shared];
    if ([w typeOf:msgWrap] != 1) {
        [JGPTCommon toast:@"只能分析文字消息"];
        return;
    }
    NSString *key = [w messageKey:msgWrap] ?: @"";
    NSString *text = [w contentOf:msgWrap] ?: @"";
    if ([w isGroupMessage:msgWrap]) text = [w stripGroupSenderPrefix:text];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!chat.length) chat = XMChatOfWrapLocal(msgWrap);
    if (!chat.length || !text.length) {
        [JGPTCommon toast:@"这条消息读不到内容"];
        return;
    }

    JGPTConfig *c = [JGPTConfig shared];
    if (!c.enabled) {
        [JGPTCommon toast:@"AI 会话分析未启用"];
        return;
    }
    if (!c.apiKey.length) {
        [JGPTCommon toast:@"先在设置里填 API Key"];
        return;
    }

    [self.lock lock];
    if (key.length) [self.manualKeys addObject:key];
    // messageKey 偶尔为空（本地消息 id 还没回填），用「会话 + 文本」兜底
    NSString *composite = [NSString stringWithFormat:@"%@|%@", chat, text];
    [self.manualKeys addObject:composite];
    if (self.manualKeys.count > 400) [self.manualKeys removeAllObjects];
    [self.lock unlock];

    JGPTMemoryNote *note = [[JGPTMemoryStore shared] noteFor:chat];
    if (!note.displayName.length) note.displayName = [w displayNameFor:chat];
    if (!note.gender.length) note.gender = [w genderFor:chat];

    JGPTJudgeResult *result = [self placeholderJudge:text chat:chat];
    result.contactName = note.displayName.length ? note.displayName : [w displayNameFor:chat];
    result.messageKey = key;
    result.status = @"streaming";
    result.replies = @[];
    [self lockAndStore:result key:key];
    [JGPTCommon toast:@"正在分析这一条…"];
    [[NSNotificationCenter defaultCenter] postNotificationName:JGPTResultNotification object:result];
    [JGPTInlineCard refreshVisibleChatList];

    NSString *history = [[JGPTMemoryStore shared] historyTextFor:chat limit:MAX(c.contextLines, 6)];
    BOOL isGroup = [w isGroup:chat];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *sys = [JGPTPrompts judgeSystemPrompt];
        NSString *usr = [JGPTPrompts judgeUserPrompt:text history:history note:note contact:note.displayName group:isGroup];
        NSString *publishKey = key.length ? key : [NSString stringWithFormat:@"%@|%@", chat, text];
        __block NSString *lastHumanRead = nil;

        void (^afterJudge)(void) = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *prompt = [JGPTPrompts draftPrompt:result note:note history:history
                                                     tones:c.tones realTone:c.realTone count:c.replyCount];
                __block NSInteger lastCount = 0;
                [JGPTStream startWithSystem:@"你只输出纯文本，一行一条。"
                                        user:prompt
                                    laneName:@"chat"
                                     onDelta:^(NSString *delta, NSString *accumulated) {
                    NSArray *partial = [self partialRepliesFrom:accumulated];
                    if ((NSInteger)partial.count <= lastCount) return;
                    lastCount = partial.count;
                    result.replies = partial;
                    result.status = @"streaming";
                    [self publishResult:result key:publishKey minInterval:0.2];
                } onFinish:^(NSString *accumulated, NSError *streamError) {
                    NSArray *replies = [self repliesFromFinalText:accumulated];
                    if (replies.count) result.replies = replies;
                    result.status = @"ok";
                    [self publishResult:result key:publishKey minInterval:0];
                }];
            });
        };

        [JGPTStream startWithSystem:sys user:usr laneName:@"chat"
                        temperature:-1 maxTokens:0
                           onDelta:^(NSString *delta, NSString *accumulated) {
            NSString *partial = [JGPTClient partialJSONStringForKey:@"humanRead" inText:accumulated];
            if (!partial.length || [partial isEqualToString:lastHumanRead]) return;
            lastHumanRead = partial;
            result.humanRead = partial;
            result.placeholder = NO;
            result.status = @"streaming";
            [self publishResult:result key:publishKey minInterval:0.25];
        } onFinish:^(NSString *accumulated, NSError *error) {
            NSDictionary *parsed = [JGPTClient parseJSONLoose:accumulated];
            if (parsed) {
                [self applyJudge:parsed to:result];
                result.placeholder = NO;
                [self publishResult:result key:publishKey minInterval:0];
                afterJudge();
                return;
            }
            // 流式解析不出来再退一次普通请求
            [[JGPTClient shared] chatWithSystem:sys user:usr laneName:@"chat" temperature:-1 maxTokens:0
                                     completion:^(NSDictionary *json, NSString *raw, NSError *e2) {
                NSString *content = [JGPTClient extractMessageContent:json];
                NSDictionary *p = content ? [JGPTClient parseJSONLoose:content] : nil;
                if (!p && raw) p = [JGPTClient parseJSONLoose:raw];
                result.placeholder = NO;
                if (p) {
                    [self applyJudge:p to:result];
                    [self publishResult:result key:publishKey minInterval:0];
                    afterJudge();
                } else {
                    result.humanRead = @"这一条分析失败，点长按再试一次。";
                    result.status = @"ok";
                    [self publishResult:result key:publishKey minInterval:0];
                    [JGPTCommon toast:@"分析失败，检查 Key 或线路"];
                }
            }];
        }];
    });
}

- (void)lockAndStore:(JGPTJudgeResult *)result key:(NSString *)key {
    if (!result || !result.chatID.length) return;
    [self.lock lock];
    self.cache[result.chatID] = result;
    [self.lock unlock];
    if (key.length) {
        [self.lock lock];
        self.messageCache[key] = result;
        if (self.messageCache.count > 300) [self.messageCache removeAllObjects];
        [self.lock unlock];
    }
}

#pragma mark - 媒体指令

- (BOOL)handleMediaCommand:(NSString *)text chat:(NSString *)chat replyTo:(NSString *)replyTo {
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL isEdit = [t hasPrefix:@"#改图"] || [t hasPrefix:@"#修图"];
    BOOL isImage = isEdit || [t hasPrefix:@"#画图"] || [t hasPrefix:@"#绘图"] || [t hasPrefix:@"#生图"];
    BOOL isVideo = [t hasPrefix:@"#视频"] || [t hasPrefix:@"#生视频"];
    if (!isImage && !isVideo) return NO;

    NSString *prompt = nil;
    for (NSString *p in @[@"#改图", @"#修图", @"#画图", @"#绘图", @"#生图", @"#视频", @"#生视频"]) {
        if ([t hasPrefix:p]) {
            prompt = [[t substringFromIndex:p.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            break;
        }
    }

    // 图生图：优先用会话里最近收到的一张图（先发图，再发「#改图 换成油画风」）
    UIImage *reference = isImage ? [[JGPTWeChat shared] lastImageFor:chat] : nil;
    if (!prompt.length && isEdit) prompt = @"按原图风格自然优化";
    if (!prompt.length) {
        [JGPTCommon toast:(isImage
            ? @"用法：#画图 一只橘猫在窗台晒太阳\n图生图：先发一张图，再发「#改图 换成油画风」"
            : @"用法：#视频 海边日落延时")];
        return YES;
    }

    [JGPTMediaLog beginTask:[NSString stringWithFormat:@"%@ %@",
                             isVideo ? @"视频" : (isEdit ? @"改图" : @"画图"),
                             prompt.length > 24 ? [[prompt substringToIndex:24] stringByAppendingString:@"…"] : prompt]];
    [JGPTMediaLog logStage:(isVideo ? @"视频指令" : @"画图指令") ok:YES
                      text:[NSString stringWithFormat:@"%@：%@", isVideo ? @"#视频" : (isEdit ? @"#改图" : @"#画图"),
                            prompt.length > 40 ? [[prompt substringToIndex:40] stringByAppendingString:@"…"] : prompt]
                    detail:chat ?: @""];

    NSString *notice = isVideo ? @"🎬 正在生成视频，可能要几分钟…"
                               : (reference ? @"🎨 正在按参考图改图，稍等…" : @"🎨 正在画图，稍等…");
    // 提示只用本地 toast，不往聊天里发，免得对方看到「正在画图」这种系统话
    [JGPTCommon toast:notice];

    if (isImage) {
        [[JGPTClient shared] generateImage:prompt reference:reference completion:^(NSArray<NSString *> *urls, NSString *raw, NSError *error) {
            if (!urls.count) {
                [JGPTMediaLog logStage:@"画图失败" ok:NO text:error.localizedDescription ?: @"无返回" detail:raw ? [raw substringToIndex:MIN(raw.length, 300)] : @""];
                [JGPTMediaLog endTask];
                [JGPTCommon toast:[NSString stringWithFormat:@"画图失败：%@", error.localizedDescription ?: @"无返回"]];
                return;
            }
            [[JGPTWeChat shared] sendMediaURLs:urls kind:JGPTMediaKindImage to:replyTo caption:prompt];
        }];
    } else {
        [[JGPTClient shared] generateVideo:prompt completion:^(NSArray<NSString *> *urls, NSString *raw, NSError *error) {
            if (!urls.count) {
                [JGPTMediaLog logStage:@"视频失败" ok:NO text:error.localizedDescription ?: @"无返回" detail:raw ? [raw substringToIndex:MIN(raw.length, 300)] : @""];
                [JGPTMediaLog endTask];
                [JGPTCommon toast:[NSString stringWithFormat:@"视频失败：%@", error.localizedDescription ?: @"无返回"]];
                return;
            }
            [[JGPTWeChat shared] sendMediaURLs:urls kind:JGPTMediaKindVideo to:replyTo caption:prompt];
        }];
    }
    return YES;
}

#pragma mark - cache

- (JGPTJudgeResult *)cachedResultFor:(NSString *)chat {
    if (!chat.length) return nil;
    [self.lock lock];
    JGPTJudgeResult *r = self.cache[chat];
    [self.lock unlock];
    return r;
}

- (JGPTJudgeResult *)latestResult {
    [self.lock lock];
    JGPTJudgeResult *r = self.lastChat.length ? self.cache[self.lastChat] : nil;
    [self.lock unlock];
    return r;
}

- (JGPTJudgeResult *)cachedResultForMessage:(NSString *)messageKey {
    if (!messageKey.length) return nil;
    [self.lock lock];
    JGPTJudgeResult *r = self.messageCache[messageKey];
    [self.lock unlock];
    return r;
}

- (void)cacheResult:(JGPTJudgeResult *)result {
    if (!result.chatID.length) return;
    [self.lock lock];
    self.cache[result.chatID] = result;
    [self.lock unlock];
}

- (NSString *)lastChatID {
    [self.lock lock];
    NSString *c = self.lastChat;
    [self.lock unlock];
    return c;
}

@end
