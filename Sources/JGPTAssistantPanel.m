#import "JGPTAssistantPanel.h"
#import "JGPTConfig.h"
#import "JGPTEngine.h"
#import "JGPTCommon.h"
#import "JGPTWeChat.h"
#import "JGPTMemoryStore.h"
#import "JGPTSettingsVC.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const void *kJGPTPanelKey = &kJGPTPanelKey;

@interface JGPTAssistantPanel (Internal)
- (void)presentAsSheetFrom:(UIViewController *)vc;
@end

@interface JGPTSheetVC : UIViewController
@property (nonatomic, strong) JGPTJudgeResult *result;
@property (nonatomic, strong) UILabel *readLabel;
@property (nonatomic, strong) UIStackView *replyStack;
@property (nonatomic, strong) UILabel *headLabel;
@property (nonatomic, strong) UISwitch *sessionSwitch;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIControl *dim;
@property (nonatomic, strong) UIScrollView *scroll;
@end

@implementation JGPTSheetVC

- (instancetype)init {
    if (self = [super init]) {
        self.title = @"微信 AI 会话分析";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(close)];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"换一批"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(regen)],
        [[UIBarButtonItem alloc] initWithTitle:@"设置"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(openSettings)],
    ];

    _scroll = [[UIScrollView alloc] init];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _headLabel = [[UILabel alloc] init];
    _headLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _headLabel.textColor = [UIColor secondaryLabelColor];
    _headLabel.numberOfLines = 0;

    _readLabel = [[UILabel alloc] init];
    _readLabel.font = [UIFont systemFontOfSize:13];
    _readLabel.numberOfLines = 0;
    _readLabel.textColor = [UIColor labelColor];

    UILabel *sessionTitle = [[UILabel alloc] init];
    sessionTitle.text = @"本会话启用";
    sessionTitle.font = [UIFont systemFontOfSize:13];
    _sessionSwitch = [[UISwitch alloc] init];
    [_sessionSwitch addTarget:self action:@selector(sessionToggled:) forControlEvents:UIControlEventValueChanged];
    UIStackView *sessionRow = [[UIStackView alloc] initWithArrangedSubviews:@[sessionTitle, _sessionSwitch]];
    sessionRow.axis = UILayoutConstraintAxisHorizontal;
    sessionRow.alignment = UIStackViewAlignmentCenter;
    sessionRow.distribution = UIStackViewDistributionEqualSpacing;

    _replyStack = [[UIStackView alloc] init];
    _replyStack.axis = UILayoutConstraintAxisVertical;
    _replyStack.spacing = 8;

    UIStackView *root = [[UIStackView alloc] initWithArrangedSubviews:@[_headLabel, sessionRow, _readLabel, _replyStack]];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 14;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:root];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:g.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [root.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor constant:16],
        [root.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor constant:-16],
        [root.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:14],
        [root.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:-16],
        [root.widthAnchor constraintEqualToAnchor:_scroll.widthAnchor constant:-32],
    ]];
}

- (void)setResult:(JGPTJudgeResult *)result {
    _result = result;
    if (!self.isViewLoaded) [self loadViewIfNeeded];
    self.headLabel.text = [NSString stringWithFormat:@"%@ · 危险等级 %.0f/10（%@）",
                           result.contactName.length ? result.contactName : @"对话",
                           result.risk, result.riskLabel];
    self.readLabel.text = [self analysisTextFor:result];
    self.sessionSwitch.on = [[JGPTConfig shared] isSessionOn:result.chatID];
    for (UIView *v in [self.replyStack.arrangedSubviews copy]) {
        [self.replyStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSArray *replies = result.replies.count ? result.replies : @[@"（还没生成，点右上角换一批）"];
    for (NSInteger i = 0; i < (NSInteger)replies.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:[NSString stringWithFormat:@"%ld. %@", (long)(i + 1), replies[i]] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14];
        b.titleLabel.numberOfLines = 0;
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
        b.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        b.layer.cornerRadius = 10;
        b.tag = i;
        [b addTarget:self action:@selector(send:) forControlEvents:UIControlEventTouchUpInside];
        [self.replyStack addArrangedSubview:b];
    }
}

- (NSString *)percentText:(NSArray *)options fallback:(NSString *)fallback {
    NSMutableArray *lines = [NSMutableArray array];
    for (id item in options) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *label = item[@"label"] ?: item[@"text"];
        if (![label isKindOfClass:[NSString class]] || !label.length) continue;
        double prob = [item[@"prob"] doubleValue];
        if (prob > 0 && prob <= 1) prob *= 100;
        [lines addObject:prob > 0 ? [NSString stringWithFormat:@"· %@：%.0f%%", label, prob]
                                  : [NSString stringWithFormat:@"· %@", label]];
    }
    if (!lines.count && fallback.length) [lines addObject:[NSString stringWithFormat:@"· %@", fallback]];
    return [lines componentsJoinedByString:@"\n"];
}

- (NSString *)analysisTextFor:(JGPTJudgeResult *)r {
    NSMutableArray *parts = [NSMutableArray array];
    if (r.humanRead.length) [parts addObject:r.humanRead];
    if (r.strategy.length) [parts addObject:[NSString stringWithFormat:@"本轮策略：%@", r.strategy]];
    NSString *intents = [self percentText:r.intentOptions fallback:r.intent];
    if (intents.length) [parts addObject:[@"当前真实意图\n" stringByAppendingString:intents]];
    NSString *should = [self percentText:r.shouldReplyOptions fallback:r.shouldReply];
    if (should.length) [parts addObject:[@"是否应该立刻回复\n" stringByAppendingString:should]];
    NSString *actions = [self percentText:r.actionOptions fallback:r.action];
    if (actions.length) [parts addObject:[@"最佳动作\n" stringByAppendingString:actions]];
    return [parts componentsJoinedByString:@"\n\n"];
}

- (void)send:(UIButton *)sender {
    if ([[JGPTEngine shared] sendReplyAtIndex:sender.tag of:self.result]) {
        [JGPTCommon toast:@"已发送" in:nil];
        [self close];
    }
}

- (void)regen {
    [JGPTCommon toast:@"正在换一批…" in:self.view];
    __weak typeof(self) weakSelf = self;
    [[JGPTEngine shared] regenerate:self.result completion:^(JGPTJudgeResult *r) {
        dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.result = r; });
    }];
}

- (void)sessionToggled:(UISwitch *)sw {
    if (!self.result.chatID.length) return;
    [[JGPTConfig shared] setSession:self.result.chatID on:sw.isOn];
    [JGPTCommon toast:sw.isOn ? @"本会话已开启" : @"本会话已关闭" in:self.view];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)openSettings {
    JGPTMainVC *vc = [[JGPTMainVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

@end

@interface JGPTAssistantPanel ()
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *riskLabel;
@property (nonatomic, strong) UILabel *readLabel;
@property (nonatomic, strong) UIStackView *replyStack;
@property (nonatomic, strong) UIButton *regenButton;
@property (nonatomic, strong) JGPTJudgeResult *result;
@end

@implementation JGPTAssistantPanel (Internal)

- (void)presentAsSheetFrom:(UIViewController *)vc {
    if (!vc) return;
    JGPTSheetVC *sheet = [[JGPTSheetVC alloc] init];
    sheet.result = self.result;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:sheet];
    if (@available(iOS 15.0, *)) {
        // SDK 14.5 头文件没有 UISheetPresentationController，运行时按需配置
        id sheetPC = [nav valueForKey:@"sheetPresentationController"];
        if (sheetPC) {
            Class detentClass = NSClassFromString(@"UISheetPresentationControllerDetent");
            if (detentClass) {
                id medium = ((id (*)(id, SEL))objc_msgSend)(detentClass, NSSelectorFromString(@"mediumDetent"));
                id large = ((id (*)(id, SEL))objc_msgSend)(detentClass, NSSelectorFromString(@"largeDetent"));
                if (medium && large) [sheetPC setValue:@[medium, large] forKey:@"detents"];
            }
            [sheetPC setValue:@YES forKey:@"prefersGrabberVisible"];
        }
    }
    [vc presentViewController:nav animated:YES completion:nil];
}

@end

@implementation JGPTAssistantPanel

+ (instancetype)sharedPanel {
    static JGPTAssistantPanel *panel = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        panel = [[JGPTAssistantPanel alloc] initWithFrame:CGRectZero];
    });
    return panel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.hidden = YES;
        [self buildUI];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onResult:)
                                                     name:JGPTResultNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)buildUI {
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.backgroundColor = [JGPTCommon cardColor];
    _card.layer.cornerRadius = 16;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.shadowColor = [UIColor blackColor].CGColor;
    _card.layer.shadowOpacity = 0.16;
    _card.layer.shadowRadius = 16;
    _card.layer.shadowOffset = CGSizeMake(0, 6);
    [self addSubview:_card];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor secondaryLabelColor];
    [_card addSubview:_titleLabel];

    _riskLabel = [[UILabel alloc] init];
    _riskLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    _riskLabel.textAlignment = NSTextAlignmentCenter;
    _riskLabel.layer.cornerRadius = 8;
    _riskLabel.layer.masksToBounds = YES;
    [_card addSubview:_riskLabel];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"收起" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:12];
    [close addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:close];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [close.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-14],
        [close.topAnchor constraintEqualToAnchor:_card.topAnchor constant:10],
    ]];

    _readLabel = [[UILabel alloc] init];
    _readLabel.font = [UIFont systemFontOfSize:14];
    _readLabel.numberOfLines = 0;
    _readLabel.textColor = [UIColor labelColor];
    [_card addSubview:_readLabel];

    _replyStack = [[UIStackView alloc] init];
    _replyStack.axis = UILayoutConstraintAxisVertical;
    _replyStack.spacing = 6;
    [_card addSubview:_replyStack];

    _regenButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_regenButton setTitle:@"🔄 换一批" forState:UIControlStateNormal];
    _regenButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [_regenButton addTarget:self action:@selector(regenerate) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_regenButton];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [_card addGestureRecognizer:pan];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = MIN(self.bounds.size.width - 24, 560);
    CGFloat x = (self.bounds.size.width - width) / 2.0;
    CGFloat bottomInset = 0;
    if (@available(iOS 11.0, *)) bottomInset = self.safeAreaInsets.bottom;
    CGFloat h = MIN(self.bounds.size.height * 0.62, 460);
    _card.frame = CGRectMake(x, self.bounds.size.height - h - bottomInset - 10, width, h);

    CGFloat pad = 14;
    _titleLabel.frame = CGRectMake(pad, 12, width - 120, 18);
    _riskLabel.frame = CGRectMake(width - 116, 12, 56, 18);
    CGFloat y = 40;
    CGFloat readH = [_readLabel sizeThatFits:CGSizeMake(width - pad * 2, 120)].height;
    _readLabel.frame = CGRectMake(pad, y, width - pad * 2, readH);
    y += readH + 8;

    CGFloat footer = 30;
    CGFloat replyH = MAX(0, h - y - footer - 8);
    _replyStack.frame = CGRectMake(pad, y, width - pad * 2, replyH);
    _regenButton.frame = CGRectMake(width - 100, h - footer, 90, footer);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit) return nil;
    // 只有卡片区域接收触摸，避免挡住聊天页
    CGPoint p = [self convertPoint:point toView:self.card];
    if ([self.card pointInside:p withEvent:event]) return hit;
    return nil;
}

- (void)showResult:(JGPTJudgeResult *)result inView:(UIView *)view {
    if (!result) return;
    self.result = result;
    self.currentChat = result.chatID;
    dispatch_async(dispatch_get_main_queue(), ^{
        // 从 ActionSheet 的回调里立刻 present 会失败，等它收完再弹
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *top = [JGPTCommon topViewController];
            if (!top) return;
            if (top.presentedViewController) top = top.presentedViewController;
            if ([top isKindOfClass:[UIAlertController class]]) return;
            [self presentAsSheetFrom:top];
        });
    });
}

- (void)render {
    JGPTJudgeResult *r = self.result;
    if (!r) return;
    NSString *name = r.contactName.length ? r.contactName : @"对话";
    _titleLabel.text = [NSString stringWithFormat:@"%@ · %@", name, r.mood.length ? r.mood : @"分析"];
    _riskLabel.text = [NSString stringWithFormat:@"风险 %.0f", r.risk];
    _riskLabel.backgroundColor = r.risk >= 6 ? [UIColor colorWithRed:0.95 green:0.4 blue:0.35 alpha:0.18]
                                             : [[JGPTCommon accentColor] colorWithAlphaComponent:0.16];
    _riskLabel.textColor = r.risk >= 6 ? [UIColor systemRedColor] : [JGPTCommon accentColor];

    NSMutableString *read = [NSMutableString string];
    if (r.humanRead.length) [read appendString:r.humanRead];
    if (r.action.length) [read appendFormat:@"\n建议：%@", r.action];
    _readLabel.text = read;

    for (UIView *v in [_replyStack.arrangedSubviews copy]) {
        [_replyStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSArray *replies = r.replies.count ? r.replies : @[@"（还没生成，点换一批）"];
    for (NSInteger i = 0; i < (NSInteger)replies.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:replies[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14];
        b.titleLabel.numberOfLines = 2;
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
        b.backgroundColor = [UIColor tertiarySystemFillColor];
        b.layer.cornerRadius = 9;
        b.tag = i;
        [b addTarget:self action:@selector(replyTapped:) forControlEvents:UIControlEventTouchUpInside];
        [b.heightAnchor constraintGreaterThanOrEqualToConstant:34].active = YES;
        [_replyStack addArrangedSubview:b];
    }
    [self setNeedsLayout];
}

- (void)replyTapped:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if ([[JGPTEngine shared] sendReplyAtIndex:idx of:self.result]) {
        [JGPTCommon toast:@"已发送" in:self.superview];
        [self hide];
    }
}

- (void)regenerate {
    if (!self.result) return;
    [JGPTCommon toast:@"正在换一批…" in:self.superview];
    [[JGPTEngine shared] regenerate:self.result completion:^(JGPTJudgeResult *r) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self render]; });
    }];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    if (g.state == UIGestureRecognizerStateChanged) {
        self.card.transform = CGAffineTransformMakeTranslation(0, MAX(0, t.y));
    } else if (g.state == UIGestureRecognizerStateEnded) {
        if (t.y > 80) [self hide];
        else [UIView animateWithDuration:0.2 animations:^{ self.card.transform = CGAffineTransformIdentity; }];
    }
}

- (void)hide {
    [UIView animateWithDuration:0.18 animations:^{ self.alpha = 0; } completion:^(BOOL finished) {
        self.hidden = YES;
        self.card.transform = CGAffineTransformIdentity;
        [self removeFromSuperview];
    }];
}

- (void)onResult:(NSNotification *)note {
    JGPTJudgeResult *r = note.object;
    if (![r isKindOfClass:[JGPTJudgeResult class]]) return;
    // 结果只进缓存；卡片 / 入口条由 JGPTChatCard 的定时器刷新，不主动弹窗
}

#pragma mark - 清理旧版右上角按钮

// 2.6.5 起不再挂右上角 🤖。这个方法只用于把老版本留下的按钮摘掉。
- (void)detachNavBarButton {
    NSMutableSet<UINavigationItem *> *items = [NSMutableSet set];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w && ![windows containsObject:w]) [windows addObject:w];
            }
        }
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w && ![windows containsObject:w]) [windows addObject:w];
    }
    for (UIWindow *w in windows) {
        [self collectNavItemsFromController:w.rootViewController into:items depth:0];
    }
    for (UINavigationItem *item in items) {
        NSMutableArray *arr = [item.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
        for (UIBarButtonItem *b in [arr copy]) {
            if ([b.accessibilityLabel isEqualToString:@"微信 AI 会话分析"]) [arr removeObject:b];
        }
        item.rightBarButtonItems = arr.count ? arr : nil;
        if ([item.rightBarButtonItem.accessibilityLabel isEqualToString:@"微信 AI 会话分析"]) {
            item.rightBarButtonItem = nil;
        }
    }
}

- (void)collectNavItemsFromController:(UIViewController *)vc into:(NSMutableSet *)set depth:(NSInteger)depth {
    if (!vc || depth > 6) return;
    if (vc.navigationItem) [set addObject:vc.navigationItem];
    if (vc.navigationController.navigationItem) [set addObject:vc.navigationController.navigationItem];
    if (vc.presentedViewController) [self collectNavItemsFromController:vc.presentedViewController into:set depth:depth + 1];
    for (UIViewController *c in vc.childViewControllers) [self collectNavItemsFromController:c into:set depth:depth + 1];
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *c in ((UINavigationController *)vc).viewControllers)
            [self collectNavItemsFromController:c into:set depth:depth + 1];
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *c in ((UITabBarController *)vc).viewControllers)
            [self collectNavItemsFromController:c into:set depth:depth + 1];
    }
}

@end
