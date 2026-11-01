#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#ifdef DEBUG
#define JGPTLog(fmt, ...) NSLog((@"[微信 AI 会话分析] " fmt), ##__VA_ARGS__)
#else
#define JGPTLog(fmt, ...) do {} while (0)
#endif

static inline NSString *JGPTString(id v) {
    return [v isKindOfClass:[NSString class]] ? v : nil;
}
static inline NSNumber *JGPTNumber(id v) {
    return [v isKindOfClass:[NSNumber class]] ? v : nil;
}
static inline BOOL JGPTBool(id v) {
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
}
static inline double JGPTDouble(id v) {
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0;
}

// 全局 hook 重入深度保护：多个插件同时 swizzle 同一个方法时，
// A→B→A 会把栈打穿（2.6.2 的 SIGSEGV 就是栈溢出）。
// 每个 hook 进来先 XMHookGuardEnter()，深度超限就直接走原实现并返回。
BOOL XMHookGuardEnter(void);
void XMHookGuardLeave(void);
NSInteger XMHookGuardDepth(void);

// 微信长按菜单是否正在显示（MMMenuWindow / MMMenuContentView 等）。
// 菜单显示期间我们的 hook 一律退化成「什么都不做」，
// 避免改行高 / 动子视图把菜单顶掉（表现就是按住一会儿菜单消失）。
BOOL JGPTMenuIsOpen(void);

FOUNDATION_EXPORT NSString * const JGPTResultNotification;
FOUNDATION_EXPORT NSString * const JGPTConfigChangedNotification;

@interface JGPTCommon : NSObject
+ (UIViewController *)topViewController;
+ (void)alert:(NSString *)title message:(NSString *)message;
+ (void)alert:(NSString *)title message:(NSString *)message in:(UIViewController *)vc;
+ (void)input:(NSString *)title value:(NSString *)value in:(UIViewController *)vc done:(void (^)(NSString *text))done;
+ (void)toast:(NSString *)text;
+ (void)toast:(NSString *)text in:(UIView *)view;
+ (UIColor *)accentColor;
+ (UIColor *)cardColor;
+ (BOOL)isDark;
@end
