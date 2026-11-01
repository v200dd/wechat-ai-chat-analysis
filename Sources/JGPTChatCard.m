#import "JGPTChatCard.h"
#import "JGPTConfig.h"
#import "JGPTCommon.h"
#import "JGPTWeChat.h"
#import "JGPTAssistantPanel.h"
#import "JGPTEngine.h"
#import "JGPTModels.h"
#import "JGPTMemoryStore.h"
#import <objc/runtime.h>
#import <objc/message.h>

// 2.6.9 起不再接管 navigationItem.titleView。
// 之前把入口塞进 titleView，微信朋友圈 / 视频号会复用同一份导航栏，
// 入口就被带到别的页面；而且 titleView 变宽会把备注名整体挤歪。
//
// 现在的做法：
//   入口条是聊天页自己 view 的子视图，只可能出现在聊天页；
//   位置在导航栏下沿，显示「AI 会话分析（开启）/（关闭）」；
//   单点切换本会话开关，长按打开会话面板。
// 朋友圈 / 视频号 / 详情页天然看不到它，因为那些页面不持有这个 view。

static const void *kXMChatPageKey = &kXMChatPageKey;
static const void *kXMTripleTapKey = &kXMTripleTapKey;
static const void *kXMEntryBarKey = &kXMEntryBarKey;

static NSHashTable *XMEntryBars(void) {
    static NSHashTable *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
    return t;
}

static BOOL XMIsAncestor(UIViewController *a, UIViewController *b);
static BOOL XMChatIsFront(UIViewController *vc);
static BOOL XMForeignClass(NSString *cls);
static BOOL XMIsChatClass(NSString *cls);

#pragma mark - 入口条

@interface XMTripleTapCatcher : NSObject <UIGestureRecognizerDelegate>
@end

@implementation XMTripleTapCatcher
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    UIView *v = g.view;
    if (!v) return NO;
    CGPoint p = [g locationInView:v];
    CGFloat top = 20;
    if (@available(iOS 11.0, *)) top = v.safeAreaInsets.top;
    if (top < 20) top = 44;
    // 只认导航栏那一条（标题 / 备注名区域）
    return p.y <= top + 44;
}
@end

@interface XMChatEntryBar : UIView
@property (nonatomic, weak) UIViewController *ownerVC;
@property (nonatomic, weak) UINavigationBar *hostBar;
@property (nonatomic, copy) NSString *chat;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, assign) BOOL on;
@property (nonatomic, assign) CFTimeInterval lastValidate;
- (void)refresh;
- (void)layoutInHost;
- (void)validateHost;
@end

@implementation XMChatEntryBar

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        _label = [[UILabel alloc] init];
        _label.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightSemibold];
        _label.textAlignment = NSTextAlignmentLeft;
        _label.numberOfLines = 1;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_label];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)];
        tap.cancelsTouchesInView = NO;
        [self addGestureRecognizer:tap];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
        lp.minimumPressDuration = 0.45;
        lp.cancelsTouchesInView = NO;
        [self addGestureRecognizer:lp];
    }
    return self;
}

- (void)refresh {
    JGPTConfig *c = [JGPTConfig shared];
    self.on = self.chat.length ? [c isSessionOn:self.chat] : NO;
    self.label.text = self.on ? @"AI 会话分析（开启）" : @"AI 会话分析（关闭）";
    // 统一绿色，开启时实色、关闭时浅一点，确保在浅色/深色导航栏上都看得清
    UIColor *green = [JGPTCommon accentColor];
    self.label.textColor = self.on ? green : [green colorWithAlphaComponent:0.65];
    self.hidden = !c.uiVisible;
    [self setNeedsLayout];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self validateHost];
}

// 微信朋友圈 / 视频号会复用同一个 UINavigationBar。
// 只要宿主不再是这个聊天页，立刻把自己从导航栏上摘掉，
// 不能靠 0.5s 的 tick 兜底（那一眼就能看到）。
- (void)detachSoon {
    self.hidden = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf removeFromSuperview];
    });
}

- (void)validateHost {
    UIViewController *vc = self.ownerVC;
    if (!vc || !vc.isViewLoaded || !self.window) {
        [self detachSoon];
        return;
    }
    UINavigationController *nav = vc.navigationController;
    if (!nav) {
        [self detachSoon];
        return;
    }
    // push 进朋友圈 / 视频号时，栈顶立刻不再是聊天页，这一下就把入口摘掉。
    // 不校验 navigationBar.topItem：微信部分页面是自绘导航栏，那个 item 对不上，
    // 会把聊天页自己的入口误藏掉（2.6.8 之前踩过）。
    if (nav.topViewController != vc) {
        [self detachSoon];
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastValidate < 0.25) return;
    self.lastValidate = now;
    if (!XMChatIsFront(vc)) {
        [self detachSoon];
        return;
    }
    // 最后一关：按真实层级做一次命中测试。
    // 微信有些页面（朋友圈「个人相册」、视频号某些子页）不是新的
    // ViewController，而是把内容盖在同一个导航栈 / 同一个父容器上；
    // 这时控制器树看起来还是聊天页，但入口实际被别的视图挡住了。
    // 命中点不是我们 → 说明不在聊天页，隐藏。
    if (self.window) {
        CGPoint center = [self.superview convertPoint:self.center toView:nil];
        UIView *hit = [self.window hitTest:center withEvent:nil];
        // 命中点落在朋友圈 / 视频号这类视图上才算「被顶掉」；
        // 命中导航栏内部的其它子视图属于正常情况，不能误藏。
        for (UIResponder *r = hit; r; r = r.nextResponder) {
            if ([r isKindOfClass:[UIViewController class]]) {
                if (XMForeignClass(NSStringFromClass([(UIViewController *)r class]))) {
                    [self detachSoon];
                    return;
                }
                break;
            }
            if ([r isKindOfClass:[UIWindow class]]) break;
        }
        if (hit) {
            NSString *hc = NSStringFromClass([hit class]);
            if (XMForeignClass(hc)) {
                [self detachSoon];
                return;
            }
        }
    }
    self.hidden = NO;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.label.frame = self.bounds;
}

// 直接挂在导航栏最底部那一行：不改 titleView、不改返回键，
// 备注名和其他插件的标题都不会被挤动；也不占聊天内容高度。
// 导航栈顶一旦不是这个聊天页（朋友圈 / 视频号 / 详情页），
// validateHost 立刻把它摘掉。
- (void)layoutInHost {
    UIViewController *vc = self.ownerVC;
    UINavigationBar *bar = vc.navigationController.navigationBar;
    if (!bar || !bar.window) return;

    // 挂在导航栏内部的底部空白带：视觉上就在顶部，不接管 titleView，
    // 所以备注名 / 返回键 / 中间其他插件的标题一个像素都不动；
    // 也不会覆盖聊天内容（导航栏外面一概不碰）。
    if (self.superview != bar) {
        [bar addSubview:self];
        self.hostBar = bar;
    }
    CGFloat h = 11;
    CGFloat maxW = MIN(210, bar.bounds.size.width - 24);
    CGSize fit = [self.label sizeThatFits:CGSizeMake(maxW, h)];
    CGFloat w = MIN(maxW, ceil(fit.width) + 8);
    // 放在导航栏底部空白带最左侧（返回键下方那一条），中间完整留给群名
    CGRect target = CGRectMake(8, MAX(0, bar.bounds.size.height - h), w, h);
    if (!CGRectEqualToRect(self.frame, target)) self.frame = target;
    if (bar.subviews.lastObject != self) [bar bringSubviewToFront:self];
}

- (void)toggleSession {
    if (!self.chat.length) return;
    JGPTConfig *c = [JGPTConfig shared];
    BOOL now = [c isSessionOn:self.chat];
    [c setSession:self.chat on:!now];
    [JGPTCommon toast:(!now ? @"AI 会话分析已开启" : @"AI 会话分析已关闭")];
    [self refresh];
    [JGPTChatCard tick];
}

- (void)onTap {
    dispatch_async(dispatch_get_main_queue(), ^{ [self toggleSession]; });
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (JGPTMenuIsOpen()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [JGPTChatCard showSessionSheetForChat:self.chat hostVC:nil];
    });
}

@end

#pragma mark - 页面识别

static NSArray<UIWindow *> *XMAllWindows(void) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w && ![out containsObject:w]) [out addObject:w];
            }
        }
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w && ![out containsObject:w]) [out addObject:w];
    }
    return out;
}

static void XMCollectControllers(UIViewController *vc, NSMutableArray *out, NSInteger depth) {
    if (!vc || depth > 8) return;
    if (![out containsObject:vc]) [out addObject:vc];
    if (vc.presentedViewController) XMCollectControllers(vc.presentedViewController, out, depth + 1);
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *c in ((UINavigationController *)vc).viewControllers)
            XMCollectControllers(c, out, depth + 1);
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *c in ((UITabBarController *)vc).viewControllers)
            XMCollectControllers(c, out, depth + 1);
    }
    for (UIViewController *c in vc.childViewControllers) XMCollectControllers(c, out, depth + 1);
}

static NSArray<UIViewController *> *XMAllControllers(void) {
    NSMutableArray *all = [NSMutableArray array];
    for (UIWindow *w in XMAllWindows()) {
        if (!w.rootViewController) continue;
        XMCollectControllers(w.rootViewController, all, 0);
    }
    return all;
}

static UIViewController *XMFrontControllerForWindow(UIWindow *w) {
    if (!w || w.hidden) return nil;
    UIViewController *vc = w.rootViewController;
    for (NSInteger i = 0; i < 8 && vc; i++) {
        if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
            vc = vc.presentedViewController;
            continue;
        }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *top = ((UINavigationController *)vc).visibleViewController;
            if (top && top != vc) { vc = top; continue; }
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *sel = ((UITabBarController *)vc).selectedViewController;
            if (sel && sel != vc) { vc = sel; continue; }
        }
        break;
    }
    return vc;
}

static BOOL XMIsAncestor(UIViewController *a, UIViewController *b) {
    for (UIViewController *p = b.parentViewController; p; p = p.parentViewController) {
        if (p == a) return YES;
    }
    return NO;
}

static BOOL XMClassMatches(UIViewController *vc, NSArray<NSString *> *keys) {
    NSString *cls = NSStringFromClass([vc class]);
    for (NSString *k in keys) if ([cls containsString:k]) return YES;
    return NO;
}

static UIViewController *XMControllerAtPoint(CGPoint p) {
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    for (UIWindow *w in XMAllWindows()) {
        if (!w || w.hidden || w.alpha < 0.01 || !w.rootViewController) continue;
        if (!CGRectContainsPoint(w.frame, p)) continue;
        [wins addObject:w];
    }
    [wins sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel == b.windowLevel) return NSOrderedSame;
        return a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
    }];

    for (UIWindow *w in wins) {
        CGPoint local = [w convertPoint:p fromWindow:nil];
        UIView *hit = [w hitTest:local withEvent:nil];
        if (!hit) continue;
        if (hit == w && w.windowLevel > UIWindowLevelNormal + 10) continue;
        for (UIResponder *r = hit; r; r = r.nextResponder) {
            if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
            if ([r isKindOfClass:[UIWindow class]]) break;
        }
        return (UIViewController *)w.rootViewController;
    }
    return nil;
}

static BOOL XMForeignClass(NSString *cls) {
    if (!cls.length) return NO;
    for (NSString *bad in @[@"Moment", @"Sns", @"Timeline", @"FriendCircle", @"Finder",
                            @"Channel", @"VideoChannel", @"Favorite", @"Wallet", @"Pay",
                            @"Reader", @"WebView", @"Game", @"Emoticon", @"Sticker",
                            @"Search", @"ContactList", @"SessionList", @"AddressBook",
                            @"Setting", @"Login", @"Profile", @"ContactInfo", @"ChatInfo",
                            @"ChatDetail", @"MemberInfo", @"GroupInfo"]) {
        if ([cls containsString:bad]) return YES;
    }
    return NO;
}

static BOOL XMChainHasForeignPage(UIViewController *vc) {
    NSInteger guard = 0;
    for (UIViewController *r = vc; r && guard++ < 12; r = r.parentViewController) {
        if (XMForeignClass(NSStringFromClass([r class]))) return YES;
    }
    return NO;
}

static UIViewController *XMFrontLeafForWindow(UIWindow *w) {
    if (!w || w.hidden || !w.rootViewController) return nil;
    UIViewController *vc = w.rootViewController;
    for (NSInteger i = 0; i < 12 && vc; i++) {
        if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
            vc = vc.presentedViewController;
            continue;
        }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *top = ((UINavigationController *)vc).topViewController;
            if (top && top != vc) { vc = top; continue; }
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *sel = ((UITabBarController *)vc).selectedViewController;
            if (sel && sel != vc) { vc = sel; continue; }
        }
        UIViewController *candidate = nil;
        for (UIViewController *child in vc.childViewControllers) {
            if (!child.isViewLoaded || child.view.window != w || child.view.hidden || child.view.alpha < 0.05) continue;
            if (child.view.bounds.size.width < 100 || child.view.bounds.size.height < 100) continue;
            candidate = child;
        }
        if (candidate) { vc = candidate; continue; }
        break;
    }
    return vc;
}

static BOOL XMHasForeignFrontPage(void) {
    for (UIWindow *w in XMAllWindows()) {
        if (!w.isKeyWindow && w.windowLevel > UIWindowLevelNormal + 1) continue;
        UIViewController *front = XMFrontLeafForWindow(w);
        for (UIViewController *r = front; r; r = r.parentViewController) {
            if (XMForeignClass(NSStringFromClass([r class]))) return YES;
        }
    }
    return NO;
}

static BOOL XMHasPresentedAbove(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded) return NO;
    UIWindow *win = vc.view.window;
    if (!win) return NO;
    UIViewController *cur = win.rootViewController;
    NSInteger guard = 0;
    while (cur && cur.presentedViewController && !cur.presentedViewController.isBeingDismissed && guard++ < 8) {
        UIViewController *next = cur.presentedViewController;
        // vc 本身就在这个模态里面（例如聊天页被包在 present 的 nav 里）时，
        // 不算「被盖住」，继续往下走。
        if (next == vc || XMIsAncestor(vc, next) || XMIsAncestor(next, vc)) { cur = next; continue; }
        UIModalPresentationStyle st = next.modalPresentationStyle;
        BOOL transparent = (st == UIModalPresentationOverFullScreen
                            || st == UIModalPresentationOverCurrentContext);
        if (!transparent) return YES;
        cur = next;
    }
    return NO;
}

// 正向识别聊天页：类名必须像聊天页，且整条父链上不能有朋友圈/视频号。
// 之前用「黑名单 + 打分」，某些朋友圈子页（个人相册 SnsUserPage 等）
// 既不在黑名单里、又挂着输入框，于是被误判成聊天页。
static BOOL XMIsChatClass(NSString *cls) {
    if (!cls.length) return NO;
    if (XMForeignClass(cls)) return NO;
    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"MsgContent", @"ChatView", @"ChatRoomViewController", @"NewChatViewController",
                 @"BaseChatViewController", @"SingleChatViewController"];
    });
    for (NSString *k in keys) if ([cls containsString:k]) return YES;
    return NO;
}

static BOOL XMChatIsFront(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded) return NO;
    UIWindow *win = vc.view.window;
    if (!win || win.hidden) return NO;
    if (XMHasPresentedAbove(vc)) return NO;

    // 正向校验：最前面的叶子页必须真的像聊天页。
    UIViewController *leaf0 = XMFrontLeafForWindow(win);
    if (!leaf0) return NO;
    if (!XMIsChatClass(NSStringFromClass([leaf0 class]))
        && !XMIsChatClass(NSStringFromClass([vc class]))) return NO;

    // 最前面的「叶子页面」必须还是这个聊天页（或它自己内部的聊天子控制器）。
    // 朋友圈 / 视频号 / 详情页无论用 push、present，还是塞成聊天页的 child
    // 覆盖在上面，这里都会返回别的控制器 → 入口立刻隐藏。
    // 这一条不依赖类名，比黑名单稳。
    UIViewController *leaf = XMFrontLeafForWindow(win);
    if (leaf && leaf != vc) {
        NSString *lc = NSStringFromClass([leaf class]);
        BOOL innerChat = XMIsAncestor(vc, leaf)
                      && ([lc containsString:@"Chat"] || [lc containsString:@"Msg"]
                          || [lc containsString:@"Input"] || [lc containsString:@"Keyboard"]);
        if (!innerChat) return NO;
    }

    UINavigationController *nav = vc.navigationController;
    if (nav) {
        UIViewController *top = nav.topViewController;
        if (top && top != vc && !XMIsAncestor(vc, top)) return NO;
    }

    CGRect b = win.bounds;
    CGPoint mid = [win convertPoint:CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b) + 60) toWindow:nil];
    CGPoint top = [win convertPoint:CGPointMake(CGRectGetMidX(b), CGRectGetMinY(b) + 56) toWindow:nil];

    UIViewController *cMid = XMControllerAtPoint(mid);
    if (cMid && XMChainHasForeignPage(cMid)) return NO;

    UIViewController *cTop = XMControllerAtPoint(top);
    if (cTop && XMChainHasForeignPage(cTop)) return NO;

    return YES;
}

static BOOL XMIsInfoPage(UIViewController *vc) {
    return XMClassMatches(vc, @[@"ChatRoomInfo", @"AddContactToChatRoom", @"ChatInfo",
                                @"ChatDetail", @"ContactInfo", @"ContactProfile",
                                @"SessionInfo", @"SingleChatInfo", @"GroupInfo",
                                @"ContactDetail", @"UserInfo", @"MemberInfo",
                                @"ChatRoomMember", @"Profile"]);
}

static BOOL XMInfoPageUsable(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded) return NO;
    UIView *v = vc.view;
    if (!v.window || v.hidden || v.alpha < 0.05) return NO;
    if (v.bounds.size.width < 200 || v.bounds.size.height < 200) return NO;
    if (vc.presentedViewController) return NO;
    return YES;
}

static BOOL XMHasBottomInput(UIView *root, NSInteger depth) {
    if (!root || depth > 10) return NO;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:[UITextView class]] || [sub isKindOfClass:[UITextField class]]) {
            CGRect r = [sub convertRect:sub.bounds toView:nil];
            if (r.size.height > 0 && r.origin.y > screenH * 0.5) return YES;
        }
        NSString *cls = NSStringFromClass([sub class]);
        if (([cls containsString:@"Input"] || [cls containsString:@"ToolView"])
            && sub.bounds.size.height > 20) {
            CGRect r = [sub convertRect:sub.bounds toView:nil];
            if (r.size.height > 20 && r.origin.y > screenH * 0.6) return YES;
        }
        if (XMHasBottomInput(sub, depth + 1)) return YES;
    }
    return NO;
}

static BOOL XMHasScrollList(UIView *root, NSInteger depth) {
    if (!root || depth > 8) return NO;
    if ([root isKindOfClass:[UITableView class]] || [root isKindOfClass:[UICollectionView class]]) return YES;
    for (UIView *sub in root.subviews) if (XMHasScrollList(sub, depth + 1)) return YES;
    return NO;
}

static BOOL XMUsable(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded) return NO;
    UIView *v = vc.view;
    if (!v.window || v.hidden || v.alpha < 0.05) return NO;
    if (v.bounds.size.width < 200 || v.bounds.size.height < 200) return NO;
    return YES;
}

static BOOL XMOnScreen(UIViewController *vc) {
    if (!XMUsable(vc)) return NO;
    if (XMHasPresentedAbove(vc)) return NO;
    UIViewController *front = XMFrontControllerForWindow(vc.view.window);
    if (!front) return NO;
    if (front == vc) return YES;
    if (XMIsAncestor(vc, front)) {
        UINavigationController *nav = vc.navigationController;
        if (!nav || nav.topViewController == vc) return YES;
    }
    return NO;
}

static NSInteger XMScoreController(UIViewController *vc) {
    if (!XMUsable(vc)) return -1;
    NSString *cls = NSStringFromClass([vc class]);
    // 只认真正的聊天页。之前朋友圈的「个人相册」页也带联系人对象，
    // chatIDFromController 能取到 wxid，于是被打分选成了聊天页 ——
    // 这就是入口出现在朋友圈顶部的根因。
    if (!XMIsChatClass(cls)) return -1;
    if ([cls containsString:@"JGPT"] || [cls containsString:@"XMChat"]) return -1;
    if ([cls containsString:@"Alert"] || [cls containsString:@"ActionSheet"]) return -1;
    if (XMIsInfoPage(vc)) return -1;
    for (NSString *bad in @[@"Setting", @"Login", @"WebView", @"Wallet", @"Moment",
                            @"Favorite", @"Emoticon", @"Picker", @"Camera", @"Scan",
                            @"Reader", @"Pay", @"Game", @"TabBar", @"SessionList",
                            @"NewSession", @"Label", @"Editor", @"ContactList",
                            @"Navigation", @"TabBarController"]) {
        if ([cls containsString:bad]) return -1;
    }

    NSInteger score = 0;
    if ([cls containsString:@"MsgContent"]) score += 100;
    if ([cls containsString:@"ChatView"]) score += 70;
    if ([cls containsString:@"ChatRoom"]) score += 40;
    if ([[JGPTWeChat shared] chatIDFromController:vc].length) score += 50;
    if (XMHasBottomInput(vc.view, 0)) score += 40;
    if (vc.navigationController.viewControllers.count >= 2) {
        score += 10;
        if (XMHasBottomInput(vc.view, 0) || XMHasScrollList(vc.view, 0)) score += 35;
    }
    return score;
}

static UIViewController *XMFindChatController(NSString **outChat) {
    UIViewController *best = nil;
    NSInteger bestScore = 39;
    for (UIViewController *vc in XMAllControllers()) {
        if (objc_getAssociatedObject(vc, kXMChatPageKey) && XMOnScreen(vc)) {
            if (outChat) {
                NSString *c = [[JGPTWeChat shared] chatIDFromController:vc];
                if (!c.length) c = [[JGPTWeChat shared] chatIDFromWindow:vc.view.window];
                *outChat = c;
            }
            return vc;
        }
        NSInteger s = XMScoreController(vc);
        if (s > bestScore && XMOnScreen(vc)) {
            bestScore = s;
            best = vc;
        }
    }
    if (best && outChat) {
        NSString *c = [[JGPTWeChat shared] chatIDFromController:best];
        if (!c.length) c = [[JGPTWeChat shared] chatIDFromWindow:best.view.window];
        *outChat = c;
    }
    return best;
}

static BOOL XMHasBlockingModal(void) {
    for (UIWindow *w in XMAllWindows()) {
        UIViewController *vc = w.rootViewController;
        if (!vc) continue;
        UIViewController *p = vc.presentedViewController;
        if (!p || p.isBeingDismissed) continue;
        if ([p isKindOfClass:[UIAlertController class]]) return YES;
        NSString *cls = NSStringFromClass([p class]);
        if ([cls containsString:@"JGPT"] || [cls containsString:@"XiongMao"]) return YES;
        UIModalPresentationStyle style = p.modalPresentationStyle;
        if (style == UIModalPresentationFullScreen
            || style == UIModalPresentationPageSheet
            || style == UIModalPresentationFormSheet) return YES;
    }
    return NO;
}

#pragma mark - 旧版 titleView 清理

// 老版本把 XMTitleLine 挂到 navigationItem.titleView 上，微信复用导航栏时会带到
// 朋友圈。新版本不再创建它，这里只负责把残留实例摘掉。
static void XMStripLegacyTitleViews(void) {
    // 只清前 40 次（约半分钟）：旧版残留摘干净就停，
    // 不再每秒遍历整棵视图树，省电。
    static NSInteger runs = 0;
    if (runs >= 40) return;
    runs++;
    static CFTimeInterval last = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - last < 1.0) return;
    last = now;

    NSMutableArray<UIView *> *queue = [NSMutableArray array];
    for (UIWindow *w in XMAllWindows()) if (w) [queue addObject:w];
    NSInteger guard = 0;
    while (queue.count && guard++ < 20000) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UINavigationBar class]]) {
            UINavigationBar *bar = (UINavigationBar *)v;
            NSMutableArray *items = [NSMutableArray array];
            if (bar.topItem) [items addObject:bar.topItem];
            if (bar.items) [items addObjectsFromArray:bar.items];
            for (UINavigationItem *item in items) {
                UIView *tv = item.titleView;
                if (!tv) continue;
                NSString *cls = NSStringFromClass([tv class]);
                if (![cls containsString:@"XMTitleLine"]) continue;
                item.titleView = nil;
            }
        }
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }
}

#pragma mark - 实现

// push 任何页面时先把入口摘掉：朋友圈 / 视频号 / 聊天详情一秒都不会带过去。
// 如果 push 的还是聊天页，0.7s 后的 tick 会重新挂上。
static void (*gXMOrigPush)(id, SEL, id, BOOL);

static void XMHookPush(id self, SEL _cmd, id vc, BOOL animated) {
    // 目标不是聊天页（朋友圈 / 视频号 / 详情 / 设置…）→ 先把入口摘掉，
    // 保证切换过程中一帧都不会残留。
    NSString *cls = vc ? NSStringFromClass([(NSObject *)vc class]) : @"";
    BOOL toChat = [cls containsString:@"MsgContent"] || [cls containsString:@"ChatView"];
    // 任何 push 都先摘：旧会话的状态条不会在新页面 / 新会话上闪一下。
    [JGPTChatCard hideAllBars];
    if (gXMOrigPush) gXMOrigPush(self, _cmd, vc, animated);
    if (toChat) {
        dispatch_async(dispatch_get_main_queue(), ^{ [JGPTChatCard tick]; });
    }
}

static void XMSwizzleOwn(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    if (!cls) return;
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    Method own = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) == sel) { own = list[i]; break; }
    }
    if (list) free(list);
    if (!own) return;
    IMP cur = method_getImplementation(own);
    if (cur == newImp) return;
    if (outOrig) *outOrig = cur;
    method_setImplementation(own, newImp);
}

static void XMInstallEntryHooks(void) {
    XMSwizzleOwn(NSClassFromString(@"UINavigationController"),
                 NSSelectorFromString(@"pushViewController:animated:"),
                 (IMP)XMHookPush, (IMP *)&gXMOrigPush);
}

static NSMutableDictionary<NSString *, NSValue *> *XMChatLifeOrigins(void) {
    static NSMutableDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

// 每个类 / 每个选择器独立 trampoline。
// 聊天页一旦开始切走（朋友圈 / 视频号 / 详情），viewWillDisappear 立刻触发，
// 这一刻就把入口摘掉，不依赖定时器，也不依赖页面类名。
static void XMInstallChatLifecycle(Class cls, SEL sel, void (^body)(id)) {
    if (!cls || !sel) return;
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    Method own = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) == sel) { own = list[i]; break; }
    }
    if (list) free(list);
    if (!own) return;

    IMP cur = method_getImplementation(own);
    NSString *key = [NSString stringWithFormat:@"%@-%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
    NSValue *old = XMChatLifeOrigins()[key];
    if (old && old.pointerValue == cur) return;
    XMChatLifeOrigins()[key] = [NSValue valueWithPointer:cur];

    IMP tramp = imp_implementationWithBlock(^(id obj) {
        if (XMHookGuardEnter()) {
            @try { body(obj); } @catch (__unused NSException *e) {}
            XMHookGuardLeave();
        }
        ((void (*)(id, SEL))cur)(obj, sel);
    });
    method_setImplementation(own, tramp);
}

static void XMInstallChatLifecycleHooks(void) {
    static Class *classes = NULL;
    static unsigned int count = 0;
    if (!classes) classes = objc_copyClassList(&count);

    SEL willDisappear = NSSelectorFromString(@"viewWillDisappear:");
    SEL didAppear = NSSelectorFromString(@"viewDidAppear:");

    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        const char *n = class_getName(c);
        if (!n) continue;
        NSString *name = @(n);
        if (![name containsString:@"MsgContent"]) continue;
        if (![name hasSuffix:@"ViewController"]) continue;

        XMInstallChatLifecycle(c, willDisappear, ^(id obj) {
            [JGPTChatCard hideAllBars];
        });
        XMInstallChatLifecycle(c, didAppear, ^(id obj) {
            dispatch_async(dispatch_get_main_queue(), ^{ [JGPTChatCard tick]; });
        });
    }
}

@implementation JGPTChatCard

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        XMInstallChatLifecycleHooks();
        XMInstallEntryHooks();
        // 改为事件驱动为主：push/pop、导航栏重排、view 出现时都能立刻校正，
        // 定时器只做低频兜底（1.2s），在不影响反应速度的前提下省电。
        NSTimer *t = [NSTimer timerWithTimeInterval:1.2 repeats:YES block:^(NSTimer *timer) {
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
            @autoreleasepool { [self tick]; }
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        [self tick];
    });
}

+ (void)hideAllBars {
    @synchronized (XMEntryBars()) {
        for (XMChatEntryBar *bar in [XMEntryBars() allObjects]) {
            bar.hidden = YES;
            [bar removeFromSuperview];
        }
    }
}

+ (XMChatEntryBar *)ensureBarOn:(UIViewController *)vc chat:(NSString *)chat {
    XMChatEntryBar *bar = objc_getAssociatedObject(vc, kXMEntryBarKey);
    if (!bar) {
        bar = [[XMChatEntryBar alloc] initWithFrame:CGRectMake(16, 46, 160, 18)];
        bar.ownerVC = vc;
        objc_setAssociatedObject(vc, kXMEntryBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @synchronized (XMEntryBars()) { [XMEntryBars() addObject:bar]; }
        [vc.view addSubview:bar];
    }
    if (chat.length && ![bar.chat isEqualToString:chat]) bar.chat = chat;
    [bar refresh];
    [bar layoutInHost];
    return bar;
}

+ (void)tick {
    @try {
        // 长按菜单显示期间不改导航栏、不摘视图：
        // 微信的菜单和导航栏共用一个 window，动子视图会让菜单提前收起。
        if (JGPTMenuIsOpen()) return;
        XMStripLegacyTitleViews();

        if (XMHasBlockingModal()) {
            [self hideAllBars];
            [[JGPTAssistantPanel sharedPanel] detachNavBarButton];
            return;
        }
        if (XMHasForeignFrontPage()) {
            [self hideAllBars];
            [[JGPTAssistantPanel sharedPanel] detachNavBarButton];
            return;
        }

        BOOL onInfoPage = NO;
        for (UIViewController *vc in XMAllControllers()) {
            if (!XMInfoPageUsable(vc) || !XMIsInfoPage(vc)) continue;
            if (!XMOnScreen(vc)) continue;
            onInfoPage = YES;
            break;
        }
        if (onInfoPage) {
            [self hideAllBars];
            [[JGPTAssistantPanel sharedPanel] detachNavBarButton];
            return;
        }

        NSString *chat = nil;
        UIViewController *chatVC = XMFindChatController(&chat);
        if (!chatVC) {
            [self hideAllBars];
            [[JGPTAssistantPanel sharedPanel] detachNavBarButton];
            return;
        }

        [self installTripleTapOn:chatVC];

        JGPTConfig *c = [JGPTConfig shared];
        if (!XMIsChatClass(NSStringFromClass([chatVC class])) || !c.uiVisible || !XMChatIsFront(chatVC)) {
            [self hideAllBars];
            [[JGPTAssistantPanel sharedPanel] detachNavBarButton];
            return;
        }

        if (!chat.length) chat = [[JGPTWeChat shared] chatIDFromController:chatVC];
        if (!chat.length) chat = [[JGPTWeChat shared] chatIDFromWindow:chatVC.view.window];
        if (!chat.length) chat = [[JGPTEngine shared] lastChatID];

        XMChatEntryBar *bar = [self ensureBarOn:chatVC chat:chat ?: @""];
        bar.hidden = NO;
        [bar refresh];
        [bar layoutInHost];

        // 只把非当前聊天页的入口隐藏掉；不碰任何 navigationItem。
        @synchronized (XMEntryBars()) {
            for (XMChatEntryBar *other in [XMEntryBars() allObjects]) {
                if (other.ownerVC != chatVC) {
                    other.hidden = YES;
                    [other removeFromSuperview];
                }
            }
        }
        [[JGPTAssistantPanel sharedPanel] detachNavBarButton];
    } @catch (NSException *e) {
        JGPTLog(@"tick exception %@", e);
    }
}

+ (void)detachAllTitleLines {
    [self hideAllBars];
    XMStripLegacyTitleViews();
}

// 兼容旧调用：只摘除入口，不删除聊天页视图
+ (void)detach {
    [self hideAllBars];
}

+ (void)attachTo:(UIViewController *)vc chat:(NSString *)chat {
    if (!vc || !vc.isViewLoaded) return;
    if (!XMIsChatClass(NSStringFromClass([vc class]))) return;
    if (![JGPTConfig shared].uiVisible) return;
    if (!XMChatIsFront(vc)) return;
    XMChatEntryBar *bar = [self ensureBarOn:vc chat:chat ?: @""];
    bar.hidden = NO;
    [bar layoutInHost];
}

+ (void)hideBar { [self hideAllBars]; }

#pragma mark - 连点三下标题

+ (void)installTripleTapOn:(UIViewController *)vc {
    static XMTripleTapCatcher *catcher = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        catcher = [[XMTripleTapCatcher alloc] init];
        UIWindow *win = [UIApplication sharedApplication].keyWindow;
        if (!win) win = [UIApplication sharedApplication].windows.firstObject;
        if (win) {
            UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(handleTripleTap:)];
            g.numberOfTapsRequired = 3;
            g.cancelsTouchesInView = NO;
            g.delaysTouchesEnded = NO;
            g.delegate = catcher;
            [win addGestureRecognizer:g];
        }
    });
    UINavigationBar *bar = vc.navigationController.navigationBar;
    if (bar && !objc_getAssociatedObject(bar, kXMTripleTapKey)) {
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(handleTripleTap:)];
        tap.numberOfTapsRequired = 3;
        tap.cancelsTouchesInView = NO;
        tap.delaysTouchesEnded = NO;
        [bar addGestureRecognizer:tap];
        objc_setAssociatedObject(bar, kXMTripleTapKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (vc.isViewLoaded && !objc_getAssociatedObject(vc, kXMTripleTapKey)) {
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(handleTripleTap:)];
        tap.numberOfTapsRequired = 3;
        tap.cancelsTouchesInView = NO;
        tap.delaysTouchesEnded = NO;
        [vc.view addGestureRecognizer:tap];
        objc_setAssociatedObject(vc, kXMTripleTapKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

+ (void)handleTripleTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    UIView *host = g.view;
    if (!host) return;
    CGPoint p = [g locationInView:host];
    CGFloat w = host.bounds.size.width;
    if (p.x < w * 0.18 || p.x > w * 0.82) return;
    if (![host isKindOfClass:[UINavigationBar class]] && p.y > 140) return;
    // 只在聊天页生效，朋友圈 / 视频号三连点什么也不做
    NSString *chat = nil;
    UIViewController *vc = XMFindChatController(&chat);
    if (!vc || !XMChatIsFront(vc)) return;
    [self toggleUI];
}

+ (void)toggleUI {
    JGPTConfig *c = [JGPTConfig shared];
    c.uiVisible = !c.uiVisible;
    [c synchronize];
    dispatch_async(dispatch_get_main_queue(), ^{
        [JGPTCommon toast:(c.uiVisible ? @"AI 入口已显示" : @"AI 入口已隐藏")];
        [self tick];
    });
}

+ (void)mountOnChatController:(UIViewController *)vc {
    if (!vc || !vc.isViewLoaded) return;
    objc_setAssociatedObject(vc, kXMChatPageKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self installTripleTapOn:vc];
    JGPTConfig *c = [JGPTConfig shared];
    if (!c.uiVisible || !XMChatIsFront(vc)) {
        XMChatEntryBar *old = objc_getAssociatedObject(vc, kXMEntryBarKey);
        old.hidden = YES;
        return;
    }
    NSString *chat = [[JGPTWeChat shared] chatIDFromController:vc];
    if (!chat.length) chat = [[JGPTWeChat shared] chatIDFromWindow:vc.view.window];
    if (!chat.length) chat = [[JGPTEngine shared] lastChatID];
    [self attachTo:vc chat:chat ?: @""];
}

+ (void)showResultCardForChat:(NSString *)chat {
    if (!chat.length) return;
    JGPTJudgeResult *r = [[JGPTEngine shared] cachedResultFor:chat];
    if (r && ![r.chatID isEqualToString:chat]) r = nil;
    if (!r || !r.isReady) {
        [JGPTCommon toast:@"这个会话还没有分析结果，等对方发一条消息"];
        return;
    }
    [[JGPTAssistantPanel sharedPanel] showResult:r inView:nil];
}

#pragma mark - 会话开关

+ (void)showSessionSheetForChat:(NSString *)chat hostVC:(UIViewController *)hostVC {
    if (!chat.length) chat = [[JGPTEngine shared] lastChatID];
    if (!chat.length) {
        [JGPTCommon alert:@"微信 AI 会话分析"
                  message:@"还没识别到当前会话，先在聊天页里点开任意对话。"
                       in:(hostVC ?: [JGPTCommon topViewController])];
        return;
    }

    JGPTConfig *c = [JGPTConfig shared];
    BOOL on = [c isSessionOn:chat];
    BOOL isGroup = [[JGPTWeChat shared] isGroup:chat];
    NSString *name = [[JGPTWeChat shared] displayNameFor:chat];
    if (!name.length) name = chat;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"微信 AI 会话分析 · %@", name]
                                                                  message:on ? @"本会话已开启" : @"本会话未开启"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:(on ? @"关闭本会话" : @"开启本会话")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
        [c setSession:chat on:!on];
        [JGPTCommon toast:(!on ? @"已开启" : @"已关闭")];
        [self tick];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"查看分析与建议"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showResultCardForChat:chat];
        });
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"清除上下文"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
        [[JGPTMemoryStore shared] clearHistoryFor:chat];
        [JGPTCommon toast:@"已清除上下文"];
    }]];

    if (isGroup) {
        BOOL noAt = c.groupNoAt;
        [sheet addAction:[UIAlertAction actionWithTitle:(noAt ? @"关闭群聊免 @" : @"开启群聊免 @")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
            c.groupNoAt = !noAt;
            [c synchronize];
            [JGPTCommon toast:(!noAt ? @"群聊免 @ 已开启" : @"群聊免 @ 已关闭")];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIViewController *presenter = hostVC ?: [JGPTCommon topViewController];
    if (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) return;
    sheet.popoverPresentationController.sourceView = presenter.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(presenter.view.bounds.size.width / 2,
                                                                 presenter.view.bounds.size.height - 80, 1, 1);
    [presenter presentViewController:sheet animated:YES completion:nil];
}

@end
