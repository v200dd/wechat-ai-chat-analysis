#import "JGPTPrompts.h"
#import "JGPTModels.h"

@implementation JGPTPrompts

+ (NSArray<NSString *> *)toneNames {
    return @[@"高情商话术", @"贴吧老哥", @"拒绝加班", @"卑微乙方", @"稳如老狗",
             @"已读乱回", @"鱼塘主", @"职场黑话", @"阴阳怪气", @"情绪价值",
             @"夸夸", @"讨好型人格", @"狗头军师", @"嘴硬心软", @"惜字如金"];
}

+ (NSArray<NSString *> *)riskLevels {
    return @[@"几乎无风险", @"轻微", @"需要留意", @"偏敏感", @"高风险", @"极易踩雷"];
}

+ (NSArray<NSString *> *)strategies {
    return @[@"承接", @"推进", @"降温", @"试探", @"共情", @"给台阶", @"转移话题"];
}

+ (NSArray<NSString *> *)actionCandidates {
    return @[@"接住情绪回应情感", @"先确认再给建议", @"轻松带过不深聊",
             @"直接给结论", @"约下一次见面", @"先不回，稍后再接", @"道歉并给补救方案"];
}

+ (NSArray<NSString *> *)humanIntents {
    return @[@"求回应求陪伴", @"想确认你在不在乎", @"随口闲聊", @"在试探边界",
             @"表达不满", @"有事相求", @"分享喜悦", @"单纯通知"];
}

+ (NSString *)judgeSystemPrompt {
    return @"你是一个只输出 JSON 的对话分析师。"
           @"分析微信里对方刚发来的一条消息：真实意图、情绪、风险、这一轮该怎么接。"
           @"只基于用户给出的对话与记忆，不编造未出现的事实。"
           @"输出严格为 JSON 对象，不要 Markdown、不要解释。";
}

+ (NSString *)judgeUserPrompt:(NSString *)text
                     history:(NSString *)history
                        note:(JGPTMemoryNote *)note
                     contact:(NSString *)contact
                       group:(BOOL)isGroup {
    NSMutableString *p = [NSMutableString string];
    [p appendString:@"【场景】微信 "];
    [p appendString:isGroup ? @"群聊" : @"私聊"];
    if (contact.length) [p appendFormat:@"，对方：%@", contact];
    [p appendString:@"\n"];

    NSString *brief = [note brief];
    if (brief.length) [p appendFormat:@"【相处笔记】\n%@\n", brief];
    if (history.length) [p appendFormat:@"【最近对话】\n%@\n", history];
    [p appendFormat:@"【对方刚发来】%@\n", text];

    // humanRead 第一个写：插件是流式解析，用户能看着这几句一点点长出来。
    [p appendString:@"\n【输出 JSON 字段】（严格按下面顺序输出）\n"
                    @"humanRead: 先写这一项。3~5 句读心，像朋友私下分析，直接说对方的状态和潜台词、该怎么拿捏分寸，不评价用户\n"
                    @"intent: 从这些里选一个最贴近的："];
    [p appendString:[[self humanIntents] componentsJoinedByString:@" / "]];
    [p appendString:@"\nintentOptions: [{\"label\":意图,\"prob\":0~1}]，2~4 项，prob 之和约等于 1\n"
                    @"mood: 对方此刻情绪，4~8 字\n"
                    @"risk: 0~10 的数字，回错话的代价（危险等级）\n"
                    @"riskOptions: [{\"label\":风险描述,\"prob\":0~1}]，2~3 项\n"
                    @"action: 这一轮最佳动作，短句\n"
                    @"actionOptions: [{\"label\":动作,\"prob\":0~1}]，2~4 项\n"
                    @"strategy: 从这些里选："];
    [p appendString:[[self strategies] componentsJoinedByString:@" / "]];
    [p appendString:@"\nshouldReply: \"立刻回\" 或 \"先想清楚再回\"\n"
                    @"shouldReplyOptions: [{\"label\":\"立刻回\",\"prob\":0~1},{\"label\":\"先想清楚再回\",\"prob\":0~1}]，两项之和约等于 1\n"
                    @"blocks: 3~5 条要点短句数组\n"];
    return p;
}

+ (NSString *)humanReadPrompt:(NSString *)text
                      history:(NSString *)history
                         note:(JGPTMemoryNote *)note
                      contact:(NSString *)contact {
    NSMutableString *p = [NSMutableString stringWithString:@"你是很懂人心的真人，正在微信里看一段对话。\n"];
    if (note.relation.length) [p appendFormat:@"和对方的关系：%@。读懂对方时一定带上这层关系（亲人/伴侣/领导/陌生人，分寸完全不同）。\n", note.relation];
    NSString *brief = [note brief];
    if (brief.length) [p appendFormat:@"【相处笔记】\n%@\n", brief];
    if (history.length) [p appendFormat:@"最近对话：\n%@\n", history];
    if (contact.length) [p appendFormat:@"对方称呼：%@\n", contact];
    [p appendFormat:@"现在对方发来：「%@」\n", text];
    [p appendString:@"请像真人一样、从多个方面判断后，给我几句「读心」，不要说教、不要客套、不要评价我。\n"
                    @"硬性要求：只基于上面最近对话和相处笔记里【确有的信息】分析；对方没提到的具体细节一律不许脑补或假设，宁可写\"感觉是…\"也不能编造情节。\n"
                    @"起笔直接进入对方此刻的状态或这句话的分量，讲清：ta 此刻的状态和语气、这句话的潜台词、我们之间该拿捏的分寸、最适合怎么回、最不该踩的雷。两三个短句，像朋友私下分析。\n"];
    return p;
}

+ (NSString *)draftPrompt:(JGPTJudgeResult *)result
                    note:(JGPTMemoryNote *)note
                 history:(NSString *)history
                    tones:(NSArray<NSString *> *)tones
                  realTone:(BOOL)realTone
                    count:(NSInteger)count {
    if (count < 1) count = 4;
    if (count > 10) count = 10;
    NSMutableString *p = [NSMutableString string];
    [p appendFormat:@"你在替用户在微信里回消息。写 %ld 条可以直接发送的回复。\n", (long)count];
    if (tones.count) [p appendFormat:@"人设/话术方向：%@\n", [tones componentsJoinedByString:@"、"]];
    if (realTone) [p appendString:@"话术只定方向，落笔要像用户自己说话：短句、口语、少标点堆叠、不用书面语，不要每条都带表情。\n"];
    if (result.intent.length) [p appendFormat:@"对方意图：%@；情绪：%@；风险：%.0f/10\n", result.intent, result.mood ?: @"", result.risk];
    if (result.action.length) [p appendFormat:@"这一轮最佳动作：%@\n", result.action];
    if (result.humanRead.length) [p appendFormat:@"读心结论：%@\n", result.humanRead];
    if (note.brief.length) [p appendFormat:@"相处笔记：\n%@\n", note.brief];
    if (history.length) [p appendFormat:@"最近对话：\n%@\n", history];
    if (result.sourceText.length) [p appendFormat:@"要回的消息：「%@」\n", result.sourceText];
    if ([result.shouldReply containsString:@"先想清楚"])
        [p appendFormat:@"判断层认为这条可以先想清楚再回：%ld 条都要给，但不要急着推进关系。\n", (long)count];
    // 流式输出：一行一条，模型边写边出，界面就能逐条冒出来。
    [p appendFormat:@"要求：\n"
                    @"1. 正好 %ld 行，每行一条，风格互不相同（承接/推进/降温/玩笑/认真 轮换），每条 5~30 字；\n"
                    @"2. 不要序号、不要引号、不要解释、不要空行、不要 Markdown、不要 JSON；\n"
                    @"3. 第一行直接就是可以发出去的话。\n", (long)count];
    return p;
}

+ (NSString *)memoryUpdatePrompt:(JGPTMemoryNote *)note transcript:(NSString *)transcript {
    NSMutableString *p = [NSMutableString string];
    [p appendString:@"你在维护一份微信联系人的相处笔记。根据新增对话，增量更新笔记。\n"];
    [p appendString:@"只改有依据的部分；没有新信息的字段保持原样；不要清空已有内容；不要编造。\n"];
    NSString *brief = [note brief];
    if (brief.length) [p appendFormat:@"【现有笔记】\n%@\n", brief];
    [p appendFormat:@"【新增对话】\n%@\n", transcript];
    [p appendString:@"输出严格 JSON，字段：relation, about, between, topics, recent, recentSummary, theirState, promises, portrait, myStyle。"
                    @"每个字段都是一段简短中文，没有就留空字符串。\n"];
    return p;
}

+ (NSString *)closingKeywords {
    return @"晚安,睡了,去忙,先这样,回头聊,拜拜,再见,不聊了,下线,洗澡,吃饭去";
}

@end
