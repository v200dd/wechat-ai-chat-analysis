#import "JGPTInlineCard.h"
#import "JGPTConfig.h"
#import "JGPTCommon.h"
#import "JGPTEngine.h"
#import "JGPTModels.h"
#import "JGPTWeChat.h"
#import "JGPTMemoryStore.h"
#import <objc/runtime.h>
#import <objc/message.h>

// 聊天页内嵌分析卡（对齐参考项目的做法）：
//   BaseChatViewModel.rowHeight  → 该消息有分析结果时，把卡片高度加进行高
//   TextMessageCellView.layoutSubviews → 把卡片贴在气泡正下方
// 只 hook 这两个具体方法，且原实现永远先调用；带重入保护，
// 不会和 WCFloatSplit 那类插件形成 A→B→A 递归。

static const CGFloat kCardPadX = 10;
static const CGFloat kCardPadY = 8;
static const CGFloat kReplyRowH = 28;
static const CGFloat kReplyGap = 6;
static const CGFloat kRegenRowH = 30;
static const CGFloat kRegenGap = 8;

static NSMutableDictionary<NSString *, NSNumber *> *XMHeightCache(void) {
    static NSMutableDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

#pragma mark - 卡片视图

@interface XMInlineCardView : UIView
@property (nonatomic, copy) NSString *chat;
@property (nonatomic, copy) NSString *messageKey;
@property (nonatomic, strong) UILabel *textLabel;
@property (nonatomic, strong) UIStackView *replyStack;
@property (nonatomic, strong) UIButton *regenButton;
@property (nonatomic, copy) NSString *msgKey;
@property (nonatomic, assign) CGFloat measuredHeight;
- (void)render:(JGPTJudgeResult *)r width:(CGFloat)width messageKey:(NSString *)msgKey;
@end

@implementation XMInlineCardView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [JGPTCommon cardColor];
        self.layer.cornerRadius = 12;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
        self.layer.borderColor = [[JGPTCommon accentColor] colorWithAlphaComponent:0.25].CGColor;

        _textLabel = [[UILabel alloc] init];
        _textLabel.numberOfLines = 0;
        [self addSubview:_textLabel];

        _replyStack = [[UIStackView alloc] init];
        _replyStack.axis = UILayoutConstraintAxisVertical;
        _replyStack.spacing = kReplyGap;
        [self addSubview:_replyStack];

        // 内嵌卡里直接换一批，不用再点顶部那行进设置/面板
        _regenButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_regenButton setTitle:@"🔄 换一批" forState:UIControlStateNormal];
        _regenButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _regenButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        [_regenButton addTarget:self action:@selector(regenTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_regenButton];
    }
    return self;
}

static UIFont *XMHeadingFont(void) { return [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold]; }
static UIFont *XMBodyFont(void) { return [UIFont systemFontOfSize:12]; }
static UIFont *XMReplyFont(void) { return [UIFont systemFontOfSize:12.5]; }

+ (NSAttributedString *)analysisTextFor:(JGPTJudgeResult *)r {
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
    UIColor *label = [UIColor labelColor];
    UIColor *secondary = [UIColor secondaryLabelColor];
    UIColor *accent = [JGPTCommon accentColor];

    void (^append)(NSString *, UIFont *, UIColor *) = ^(NSString *t, UIFont *f, UIColor *c) {
        if (!t.length) return;
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:t
                                                                 attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: c}]];
    };

    if (r.placeholder && !r.humanRead.length) {
        append(@"正在分析这条消息…", XMBodyFont(), secondary);
        return s;
    }
    // 读心还在流式写：先只长这一段文字，等判断字段到了再展开成完整卡片。
    if ([r.status isEqualToString:@"streaming"] && !r.intent.length && !r.action.length) {
        append(r.humanRead, XMBodyFont(), label);
        return s;
    }
    append(@"- 意图 -\n", [UIFont systemFontOfSize:12 weight:UIFontWeightBold], label);
    append((r.humanRead.length ? r.humanRead : @"分析中…"), XMBodyFont(), label);

    if (r.strategy.length) {
        append(@"\n\n", XMBodyFont(), label);
        append([NSString stringWithFormat:@"本轮策略：%@", r.strategy], XMHeadingFont(), accent);
    }

    NSMutableArray *intents = [NSMutableArray array];
    for (id item in r.intentOptions) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *l = item[@"label"];
        if (![l isKindOfClass:[NSString class]] || !l.length) continue;
        double p = [item[@"prob"] doubleValue];
        if (p > 0 && p <= 1) p *= 100;
        [intents addObject:p > 0 ? [NSString stringWithFormat:@"· %@：%.0f%%", l, p] : [NSString stringWithFormat:@"· %@", l]];
    }
    if (!intents.count && r.intent.length) [intents addObject:[NSString stringWithFormat:@"· %@", r.intent]];
    if (intents.count) {
        append(@"\n\n", XMBodyFont(), label);
        append(@"当前真实意图\n", XMHeadingFont(), secondary);
        append([intents componentsJoinedByString:@"\n"], XMBodyFont(), label);
    }

    JGPTMemoryNote *note = r.chatID.length ? [[JGPTMemoryStore shared] noteFor:r.chatID] : nil;
    NSMutableArray *meta = [NSMutableArray array];
    if (note.relation.length) [meta addObject:[NSString stringWithFormat:@"关系：%@", note.relation]];
    if (r.risk > 0) [meta addObject:[NSString stringWithFormat:@"危险等级：%.0f/10（%@）", r.risk, r.riskLabel]];
    if (r.shouldReply.length) [meta addObject:[NSString stringWithFormat:@"是否立刻回复：%@", r.shouldReply]];
    if (meta.count) {
        append(@"\n\n", XMBodyFont(), label);
        append([meta componentsJoinedByString:@"\n"], XMBodyFont(), secondary);
    }

    if (r.action.length) {
        append(@"\n\n", XMBodyFont(), label);
        append(@"最佳动作\n", XMHeadingFont(), secondary);
        append([NSString stringWithFormat:@"· %@", r.action], XMBodyFont(), label);
    }
    if (r.replies.count) {
        append(@"\n\n", XMBodyFont(), label);
        BOOL streaming = [r.status isEqualToString:@"streaming"];
        append(streaming ? @"建议回复 · 生成中…" : @"建议回复", XMHeadingFont(), secondary);
    }
    return s;
}

+ (CGFloat)heightForResult:(JGPTJudgeResult *)r width:(CGFloat)width {
    if (!r) return 0;
    // 注意：rowHeight 会被微信在后台线程调用（列表预计算行高）。
    // 这里绝对不能用 UILabel 量高 —— UIKit 控件在非主线程创建/布局会直接
    // 在 CoreFoundation / CoreText 里 SIGSEGV（2.6.2 的闪退就是这个）。
    // boundingRectWithSize 是纯文本测量，任意线程都安全。
    CGFloat textW = width - kCardPadX * 2;
    NSAttributedString *text = [self analysisTextFor:r];
    CGRect box = [text boundingRectWithSize:CGSizeMake(textW, CGFLOAT_MAX)
                                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                    context:nil];
    CGFloat textH = ceil(box.size.height);
    CGFloat replies = r.replies.count ? (r.replies.count * kReplyRowH + (r.replies.count - 1) * kReplyGap) : 0;
    CGFloat regen = replies > 0 ? (kRegenGap + kRegenRowH) : 0;
    return kCardPadY * 2 + ceil(textH) + (replies > 0 ? 10 + replies : 0) + regen;
}

- (void)render:(JGPTJudgeResult *)r width:(CGFloat)width messageKey:(NSString *)msgKey {
    self.chat = r.chatID;
    self.msgKey = msgKey;
    self.messageKey = nil;
    self.textLabel.attributedText = [[self class] analysisTextFor:r];
    CGFloat textW = width - kCardPadX * 2;
    CGFloat textH = [self.textLabel sizeThatFits:CGSizeMake(textW, CGFLOAT_MAX)].height;
    self.textLabel.frame = CGRectMake(kCardPadX, kCardPadY, textW, ceil(textH));

    for (UIView *v in [self.replyStack.arrangedSubviews copy]) {
        [self.replyStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSInteger idx = 0;
    for (NSString *text in r.replies) {
        if (![text isKindOfClass:[NSString class]] || !text.length) continue;
        idx++;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:[NSString stringWithFormat:@"%ld. %@", (long)idx, text] forState:UIControlStateNormal];
        b.titleLabel.font = XMReplyFont();
        b.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
        b.backgroundColor = [UIColor tertiarySystemFillColor];
        b.layer.cornerRadius = 8;
        b.tag = idx - 1;
        [b addTarget:self action:@selector(replyTapped:) forControlEvents:UIControlEventTouchUpInside];
        [b.heightAnchor constraintEqualToConstant:kReplyRowH].active = YES;
        [self.replyStack addArrangedSubview:b];
    }
    CGFloat replies = self.replyStack.arrangedSubviews.count
        ? (self.replyStack.arrangedSubviews.count * kReplyRowH + (self.replyStack.arrangedSubviews.count - 1) * kReplyGap)
        : 0;
    CGFloat replyY = kCardPadY + ceil(textH) + 10;
    self.replyStack.frame = CGRectMake(kCardPadX, replyY, textW, replies);
    self.regenButton.hidden = (replies <= 0);
    self.regenButton.frame = CGRectMake(kCardPadX, replyY + replies + kRegenGap, textW, kRegenRowH);
    CGFloat regen = replies > 0 ? (kRegenGap + kRegenRowH) : 0;
    self.measuredHeight = kCardPadY * 2 + ceil(textH) + (replies > 0 ? 10 + replies : 0) + regen;
}

- (void)regenTapped:(UIButton *)sender {
    JGPTJudgeResult *r = nil;
    if (self.msgKey.length) r = [[JGPTEngine shared] cachedResultForMessage:self.msgKey];
    if (!r && self.chat.length) r = [[JGPTEngine shared] cachedResultFor:self.chat];
    if (!r) {
        [JGPTCommon toast:@"还没有可换的分析" in:nil];
        return;
    }
    [JGPTCommon toast:@"正在换一批…" in:nil];
    [[JGPTEngine shared] regenerate:r completion:^(JGPTJudgeResult *fresh) {
        [JGPTInlineCard refreshVisibleChatList];
    }];
}

- (void)replyTapped:(UIButton *)sender {
    JGPTJudgeResult *r = [[JGPTEngine shared] cachedResultFor:self.chat];
    if (!r) return;
    if ([[JGPTEngine shared] sendReplyAtIndex:sender.tag of:r]) {
        [JGPTCommon toast:@"已发送" in:nil];
    }
}

@end

#pragma mark - 取值

static id XMValue(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static id XMWrapOf(id viewModel) {
    id wrap = XMValue(viewModel, @"messageWrap") ?: XMValue(viewModel, @"m_messageWrap");
    if (wrap) return wrap;
    id inner = XMValue(viewModel, @"viewModel");
    wrap = XMValue(inner, @"messageWrap") ?: XMValue(inner, @"m_messageWrap");
    if (wrap) return wrap;
    // 子 view model → 顺着 parentModel 往上找
    for (id p = XMValue(viewModel, @"parentModel"); p; p = XMValue(p, @"parentModel")) {
        wrap = XMValue(p, @"messageWrap") ?: XMValue(p, @"m_messageWrap");
        if (wrap) return wrap;
        id vm = XMValue(p, @"viewModel");
        wrap = XMValue(vm, @"messageWrap") ?: XMValue(vm, @"m_messageWrap");
        if (wrap) return wrap;
    }
    if ([viewModel respondsToSelector:NSSelectorFromString(@"getCurrentMessageWrap")])
        return ((id (*)(id, SEL))objc_msgSend)(viewModel, NSSelectorFromString(@"getCurrentMessageWrap"));
    if ([viewModel respondsToSelector:NSSelectorFromString(@"getMessageWrap")])
        return ((id (*)(id, SEL))objc_msgSend)(viewModel, NSSelectorFromString(@"getMessageWrap"));

    // 最后兜底：扫一遍 ivar，找类型是 CMessageWrap 的那个。
    // rowHeight 阶段拿到的 ViewModel 往往既没有 messageWrap 也没有 getMessageWrap，
    // 这一步能保证「加高度」和「画卡片」用的是同一份数据。
    Class wrapClass = NSClassFromString(@"CMessageWrap");
    if (wrapClass) {
        for (Class c = [viewModel class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(c, &count);
            for (unsigned int i = 0; i < count; i++) {
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (!type || type[0] != '@') continue;
                @try {
                    id v = object_getIvar(viewModel, ivars[i]);
                    if (v && [v isKindOfClass:wrapClass]) {
                        if (ivars) free(ivars);
                        return v;
                    }
                } @catch (__unused NSException *e) {}
            }
            if (ivars) free(ivars);
        }
    }
    return nil;
}

static NSString *XMChatOfWrap(id wrap) {
    if (!wrap) return nil;
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

// 该消息要不要显示卡片；返回 nil 表示不显示
static JGPTJudgeResult *XMResultForWrap(id wrap) {
    if (!wrap) return nil;
    JGPTWeChat *w = [JGPTWeChat shared];
    if ([w typeOf:wrap] != 1) return nil;
    NSString *chat = XMChatOfWrap(wrap);
    if (!chat.length) return nil;
    JGPTConfig *c = [JGPTConfig shared];
    if (!c.enabled) return nil;

    NSString *text = [[w contentOf:wrap] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([w isGroupMessage:wrap])
        text = [[w stripGroupSenderPrefix:text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSString *key = [w messageKey:wrap];
    // 长按手动分析过的这一条：即使会话开关没开也要显示
    NSString *composite = [NSString stringWithFormat:@"%@|%@", chat, text ?: @""];
    BOOL manual = [[JGPTEngine shared] isManualMessageKey:key]
               || [[JGPTEngine shared] isManualMessageKey:composite];
    // 自动分析只处理别人发来的；长按手动分析的自己发的消息也要出卡片
    if (!manual && [w isOutgoing:wrap]) return nil;
    if (!manual && ![c isSessionOn:chat] && ![c isSessionOn:[w fromOf:wrap]]) return nil;

    JGPTJudgeResult *r = nil;
    if (key.length) r = [[JGPTEngine shared] cachedResultForMessage:key];
    // 同一条 key 偶尔会命中上一条消息的分析（svrId 缺失 / 复用时）。
    // 内容对不上就当作没有，绝不把旧分析贴到新消息下面。
    if (r && r.sourceText.length && text.length
        && ![r.sourceText isEqualToString:text] && !manual) r = nil;
    // 结果已经绑定了别的消息 key → 不是这一条，直接不显示。
    if (r && !manual && r.messageKey.length && key.length
        && ![r.messageKey isEqualToString:key]) r = nil;
    // 缓存 key 由 svrId / localId 拼成，偶尔和引擎记的对不上；
    // 再按「同一会话 + 同一条文本」匹配一次。
    if (!r) {
        // 只在「这条结果本身没有绑定消息 key」时才按文本兜底，
        // 避免另一条同文消息的分析被贴到这条旧气泡下面。
        JGPTJudgeResult *chatResult = [[JGPTEngine shared] cachedResultFor:chat];
        if (chatResult && !chatResult.messageKey.length
            && text.length && chatResult.sourceText.length
            && [chatResult.sourceText isEqualToString:text]) r = chatResult;
    }
    if (!r || ![r isReady]) {
        // 消息 ID 对不上时，只有「内容完全一致」才退回会话级结果，
        // 避免同一会话的每条消息都挂上同一张卡。
        JGPTJudgeResult *chatResult = [[JGPTEngine shared] cachedResultFor:chat];
        if (chatResult && !chatResult.messageKey.length
            && [chatResult.chatID isEqualToString:chat]
            && chatResult.sourceText.length
            && [chatResult.sourceText isEqualToString:text]) {
            r = chatResult;
        } else {
            r = nil;
        }
    }
    return r;
}

#pragma mark - 行高

// 每个类各自记一份原实现：不同 ViewModel 的 rowHeight 实现并不一样
static NSMutableDictionary<NSString *, NSValue *> *XMOrigRowHeightMap(void) {
    static NSMutableDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

static NSMutableDictionary<NSString *, NSValue *> *XMOrigCellLayoutMap(void) {
    static NSMutableDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

// 2.6.3 关键修复：原来的写法是「所有类共用一个 hook 函数 + 按 [self class] 找原实现」。
// 子类 rowHeight 里一旦写 [super rowHeight]，父类的 Method 也被我们改过，
// 于是又回到同一个 hook，而 [self class] 仍是子类 → 永远拿到子类的原实现
// → 无限递归 → 栈溢出 SIGSEGV（崩溃日志里 fault address ≈ SP）。
// 现在每个类一个独立 trampoline（捕获自己的 Class），[super ...] 会走到父类
// 自己的 trampoline，链条自然终止；加高度只在最外层做一次。
static __thread NSInteger gXMInlineDepth = 0;

static double XMRowHeightOriginal(id obj, Class cls) {
    NSValue *v = XMOrigRowHeightMap()[NSStringFromClass(cls)];
    if (!v) return 0;
    IMP imp = v.pointerValue;
    SEL sel = NSSelectorFromString(@"rowHeight");
    return ((double (*)(id, SEL))imp)(obj, sel);
}

static double XMRowHeightTrampoline(id obj, Class cls) {
    // 先加深度再调原实现：子类 rowHeight 里的 [super rowHeight] 会进父类
    // trampoline，此时 depth>0，只返回父类原始行高，不再重复加卡片高度。
    // 菜单打开期间不要改行高，否则 cell 会重排、菜单跟着消失
    if (JGPTMenuIsOpen()) return XMRowHeightOriginal(obj, cls);

    BOOL outermost = (gXMInlineDepth == 0);
    gXMInlineDepth++;
    double base = XMRowHeightOriginal(obj, cls);
    if (!outermost) {
        gXMInlineDepth--;
        return base;
    }
    @try {
        id wrap = XMWrapOf(obj);
        JGPTJudgeResult *r = XMResultForWrap(wrap);
        if (r) {
            NSString *key = [[JGPTWeChat shared] messageKey:wrap] ?: @"";
            NSString *clsName = NSStringFromClass([obj class]);
            BOOL ok = YES;
            if ([clsName containsString:@"SubViewModel"]) {
                id parent = XMValue(obj, @"parentModel");
                NSArray *subs = parent ? XMValue(parent, @"subViewModels") : nil;
                ok = ![subs isKindOfClass:[NSArray class]] || !subs.count || (subs.lastObject == obj);
            }
            if (ok) {
                CGFloat width = [UIScreen mainScreen].bounds.size.width - 24;
                // 读心是流式长出来的，行高必须跟着文本长度变，
                // 否则卡片下半截会被裁掉（只按 replies 做 key 就会这样）。
                NSString *cacheKey = [NSString stringWithFormat:@"%@|%.0f|%lu|%lu|%lu", key, width,
                                      (unsigned long)[[r.replies componentsJoinedByString:@"|"] hash],
                                      (unsigned long)r.humanRead.length,
                                      (unsigned long)(r.strategy.length + r.action.length + r.intent.length)];
                CGFloat cardH = 0;
                @synchronized (XMHeightCache()) {
                    NSNumber *h = XMHeightCache()[cacheKey];
                    if (h) cardH = h.doubleValue;
                    else {
                        cardH = [XMInlineCardView heightForResult:r width:width];
                        XMHeightCache()[cacheKey] = @(cardH);
                        if (XMHeightCache().count > 400) [XMHeightCache() removeAllObjects];
                    }
                }
                base += cardH + 6;
            }
        }
    } @catch (__unused NSException *e) {}
    gXMInlineDepth--;
    return base;
}

#pragma mark - cell 布局

static void XMCellLayoutOriginal(id obj, Class cls, SEL _cmd) {
    NSValue *v = XMOrigCellLayoutMap()[NSStringFromClass(cls)];
    if (!v) return;
    IMP imp = v.pointerValue;
    ((void (*)(id, SEL))imp)(obj, _cmd);
}

static void XMCellLayoutTrampoline(id obj, Class cls, SEL _cmd) {
    if (JGPTMenuIsOpen()) {
        XMCellLayoutOriginal(obj, cls, _cmd);
        return;
    }
    BOOL outermost = (gXMInlineDepth == 0);
    gXMInlineDepth++;
    XMCellLayoutOriginal(obj, cls, _cmd);
    if (!outermost) {
        gXMInlineDepth--;
        return;
    }
    @try {
        UIView *cell = (UIView *)obj;
        id wrap = XMWrapOf(obj);
        JGPTJudgeResult *r = XMResultForWrap(wrap);
        XMInlineCardView *card = objc_getAssociatedObject(obj, @"xb.inline.card");

        if (!r) {
            if (card) card.hidden = YES;
        } else {
            CGFloat width = cell.bounds.size.width - 24;
            if (width >= 100) {
                if (!card) {
                    card = [[XMInlineCardView alloc] initWithFrame:CGRectZero];
                    card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
                    objc_setAssociatedObject(obj, @"xb.inline.card", card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                NSString *key = [NSString stringWithFormat:@"%@|%lu|%lu",
                                 r.chatID, (unsigned long)[[r.replies componentsJoinedByString:@"|"] hash],
                                 (unsigned long)r.humanRead.length];
                if (![card.messageKey isEqualToString:key]) {
                    NSString *mk = [[JGPTWeChat shared] messageKey:wrap];
                    if (!mk.length) mk = [NSString stringWithFormat:@"%@|%@", r.chatID ?: @"", r.sourceText ?: @""];
                    [card render:r width:width messageKey:mk];
                    card.messageKey = key;
                }
                if (card.superview != cell) [cell addSubview:card];
                card.hidden = NO;

                CGFloat h = card.measuredHeight > 0 ? card.measuredHeight : [XMInlineCardView heightForResult:r width:width];
                CGFloat avail = cell.bounds.size.height - 4;
                if (avail < 40) {
                    card.hidden = YES;
                } else {
                    if (h > avail) h = avail;
                    CGFloat y = cell.bounds.size.height - h - 4;
                    if (y < 0) y = 0;
                    card.frame = CGRectMake(12, y, width, h);
                    [cell bringSubviewToFront:card];
                }
            }
        }
    } @catch (__unused NSException *e) {}
    gXMInlineDepth--;
}

#pragma mark - 安装

@implementation JGPTInlineCard

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static Class *classes = NULL;
        static unsigned int count = 0;
        if (!classes) classes = objc_copyClassList(&count);

        SEL rowSel = NSSelectorFromString(@"rowHeight");
        SEL layoutSel = NSSelectorFromString(@"layoutSubviews");

        for (unsigned int i = 0; i < count; i++) {
            Class c = classes[i];
            const char *n = class_getName(c);
            if (!n) continue;
            NSString *name = @(n);
            if (![name containsString:@"ViewModel"]) continue;

            unsigned int mc = 0;
            Method *ml = class_copyMethodList(c, &mc);
            Method own = NULL;
            for (unsigned int j = 0; j < mc; j++) {
                if (method_getName(ml[j]) == rowSel) { own = ml[j]; break; }
            }
            if (ml) free(ml);
            if (!own) continue;

            IMP cur = method_getImplementation(own);
            XMOrigRowHeightMap()[name] = [NSValue valueWithPointer:cur];
            IMP tramp = imp_implementationWithBlock(^double(id obj) {
                return XMRowHeightTrampoline(obj, c);
            });
            method_setImplementation(own, tramp);
        }

        for (unsigned int i = 0; i < count; i++) {
            Class c = classes[i];
            const char *n = class_getName(c);
            if (!n) continue;
            NSString *name = @(n);
            if (![name containsString:@"MessageCellView"]) continue;

            unsigned int mc = 0;
            Method *ml = class_copyMethodList(c, &mc);
            Method own = NULL;
            for (unsigned int j = 0; j < mc; j++) {
                if (method_getName(ml[j]) == layoutSel) { own = ml[j]; break; }
            }
            if (ml) free(ml);
            if (!own) continue;

            IMP cur = method_getImplementation(own);
            XMOrigCellLayoutMap()[name] = [NSValue valueWithPointer:cur];
            IMP tramp = imp_implementationWithBlock(^(id obj) {
                XMCellLayoutTrampoline(obj, c, layoutSel);
            });
            method_setImplementation(own, tramp);
        }
    });
}

+ (void)refreshVisibleChatList {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 长按菜单正在显示时绝不动列表：
        // beginUpdates/endUpdates 换行高、setContentOffset 都会让微信
        // 把菜单收掉（用户看到的就是「按住一会儿菜单不见了」）。
        if (JGPTMenuIsOpen()) return;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.rootViewController) continue;
            NSMutableArray *queue = [NSMutableArray arrayWithObject:w];
            NSInteger guard = 0;
            while (queue.count && guard++ < 3000) {
                UIView *v = queue.firstObject;
                [queue removeObjectAtIndex:0];
                if ([v isKindOfClass:[UITableView class]]) {
                    UITableView *tv = (UITableView *)v;
                    // beginUpdates/endUpdates 只重新问一遍行高，不会把列表滚回顶部
                    [tv beginUpdates];
                    [tv endUpdates];
                    for (UITableViewCell *c in tv.visibleCells) [c setNeedsLayout];
                    // 本来就在底部附近的话，自动滚到底，让整张卡露出来
                    CGFloat maxY = MAX(0, tv.contentSize.height - tv.bounds.size.height + tv.adjustedContentInset.bottom);
                    if (maxY > 0 && tv.contentOffset.y > maxY - 220) {
                        // 流式时每秒会刷好几次，已经贴底就别再反复做动画，不然会抖。
                        CGFloat gap = maxY - tv.contentOffset.y;
                        if (gap > 8) [tv setContentOffset:CGPointMake(0, maxY) animated:(gap > 60)];
                    }
                    return;
                }
                if ([v isKindOfClass:[UICollectionView class]]) {
                    UICollectionView *cv = (UICollectionView *)v;
                    [cv.collectionViewLayout invalidateLayout];
                    return;
                }
                for (UIView *sub in v.subviews) [queue addObject:sub];
            }
        }
    });
}

+ (BOOL)hasCardForMessageKey:(NSString *)key {
    if (!key.length) return NO;
    return [[JGPTEngine shared] cachedResultForMessage:key] != nil;
}

@end
