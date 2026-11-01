#import "JGPTCommon.h"

NSString * const JGPTResultNotification = @"com.wechatai.result.ready";
NSString * const JGPTConfigChangedNotification = @"com.wechatai.config.changed";

// 线程局部深度：同一个线程里我们自己的 hook 最多嵌套 8 层，
// 超过就认为是对端插件把 IMP 链成了环，直接退化成调用原实现。
static __thread NSInteger gXMHookDepth = 0;

BOOL XMHookGuardEnter(void) {
    if (gXMHookDepth >= 8) return NO;
    gXMHookDepth++;
    return YES;
}

void XMHookGuardLeave(void) {
    if (gXMHookDepth > 0) gXMHookDepth--;
}

NSInteger XMHookGuardDepth(void) { return gXMHookDepth; }

static BOOL gXMMenuOpenFlag = NO;
static CFTimeInterval gXMMenuCheckAt = 0;

BOOL JGPTMenuIsOpen(void) {
    // rowHeight 可能被后台线程调用，那里绝不能碰 UIKit；只信最近一次主线程结果。
    if (![NSThread isMainThread]) return gXMMenuOpenFlag;

    CFTimeInterval now = CACurrentMediaTime();
    if (now - gXMMenuCheckAt < 0.1) return gXMMenuOpenFlag;
    gXMMenuCheckAt = now;

    BOOL open = NO;
    @try {
        NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w && ![wins containsObject:w]) [wins addObject:w];
        }
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w && ![wins containsObject:w]) [wins addObject:w];
                }
            }
        }
        for (UIWindow *w in wins) {
            if (!w || w.hidden) continue;
            NSString *cls = NSStringFromClass([w class]);
            if ([cls containsString:@"MenuWindow"] || [cls containsString:@"MMMenu"]) { open = YES; break; }

            NSMutableArray *queue = [NSMutableArray arrayWithObject:w];
            NSInteger guard = 0;
            while (queue.count && guard++ < 400) {
                UIView *v = queue.firstObject;
                [queue removeObjectAtIndex:0];
                if (!v) continue;
                NSString *vc = NSStringFromClass([v class]);
                if ([vc containsString:@"MenuContentView"] || ([vc containsString:@"MMMenu"] && [vc containsString:@"View"])) {
                    if (!v.hidden && v.alpha > 0.01 && v.window) { open = YES; break; }
                }
                for (UIView *sub in v.subviews) [queue addObject:sub];
            }
            if (open) break;
        }
    } @catch (__unused NSException *e) {}
    gXMMenuOpenFlag = open;
    return open;
}

@implementation JGPTCommon

+ (UIViewController *)topViewController {
    // 微信里装了多个插件时，keyWindow 常常是别的插件自建的浮窗。
    // 这里按「层级低 + 有导航控制器 + 是 keyWindow」打分，挑真正的主窗口。
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w && ![wins containsObject:w]) [wins addObject:w];
            }
        }
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w && ![wins containsObject:w]) [wins addObject:w];
    }

    UIWindow *best = nil;
    NSInteger bestScore = NSIntegerMin;
    for (UIWindow *w in wins) {
        if (!w.rootViewController) continue;
        if (w.hidden) continue;
        NSInteger score = 0;
        if (w.windowLevel <= UIWindowLevelNormal + 1) score += 100;
        if ([w.rootViewController isKindOfClass:[UINavigationController class]]) score += 50;
        if (w.isKeyWindow) score += 20;
        if (w.rootViewController.presentedViewController) score += 15;
        if (score > bestScore) { bestScore = score; best = w; }
    }
    if (!best) best = [UIApplication sharedApplication].keyWindow;
    if (!best) best = wins.firstObject;

    UIViewController *vc = best.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]])
        vc = ((UINavigationController *)vc).visibleViewController;
    if ([vc isKindOfClass:[UITabBarController class]])
        vc = ((UITabBarController *)vc).selectedViewController;
    return vc;
}

+ (void)alert:(NSString *)title message:(NSString *)message {
    [self alert:title message:message in:[self topViewController]];
}

+ (void)alert:(NSString *)title message:(NSString *)message in:(UIViewController *)vc {
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

+ (void)input:(NSString *)title value:(NSString *)value in:(UIViewController *)vc done:(void (^)(NSString *))done {
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = value ?: @""; }];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            if (done) done(a.textFields.firstObject.text ?: @"");
        }]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

+ (void)toast:(NSString *)text { [self toast:text in:nil]; }

+ (void)toast:(NSString *)text in:(UIView *)view {
    if (!text.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *host = view ?: [self topViewController].view;
        if (!host) return;
        UILabel *l = [[UILabel alloc] init];
        l.text = text;
        l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        l.textColor = [UIColor whiteColor];
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 0;
        l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
        l.layer.cornerRadius = 10;
        l.layer.masksToBounds = YES;
        CGSize max = CGSizeMake(host.bounds.size.width - 64, 200);
        CGSize sz = [l sizeThatFits:max];
        l.frame = CGRectMake((host.bounds.size.width - (sz.width + 28)) / 2.0,
                             host.bounds.size.height - sz.height - 120,
                             sz.width + 28, sz.height + 18);
        l.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
        [host addSubview:l];
        l.alpha = 0;
        [UIView animateWithDuration:0.18 animations:^{ l.alpha = 1; } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.25 delay:1.4 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL finished2) { [l removeFromSuperview]; }];
        }];
    });
}

+ (UIColor *)accentColor {
    return [UIColor colorWithRed:0.15 green:0.68 blue:0.48 alpha:1.0];
}

+ (UIColor *)cardColor {
    if (@available(iOS 13.0, *)) return [UIColor secondarySystemGroupedBackgroundColor];
    return [UIColor whiteColor];
}

+ (BOOL)isDark {
    if (@available(iOS 13.0, *)) {
        return [UITraitCollection currentTraitCollection].userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

@end
