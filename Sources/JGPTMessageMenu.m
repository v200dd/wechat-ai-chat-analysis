#import "JGPTMessageMenu.h"
#import "JGPTCommon.h"
#import "JGPTEngine.h"
#import "JGPTWeChat.h"
#import "JGPTConfig.h"
#import <objc/runtime.h>
#import <objc/message.h>

// 微信长按菜单结构：
//   cell.operationMenuItems → NSArray（可能是 [[item,item],[item]] 的分行数组）
//   MMMenuContentView updateWithData:animated: → 真正渲染
// 只在渲染阶段往最后一行追加，和 wxtts 完全一致。
// 改 operationMenuItems 的返回值会与 menu 内部缓存的行列数量不一致，
// 表现就是「菜单闪一下又消失」。

static id gXMMenuWrap = nil;           // 当前长按的那条消息
static NSString *gXMMenuChat = nil;    // 当前会话
static NSString *gXMMenuText = nil;

static id XMSafeObject(id v) {
    uintptr_t a = (uintptr_t)v;
    if (!v || a < 0x1000) return nil;
    return object_getClass(v) ? v : nil;
}

static id XMWrapFromCell(id obj) {
    if (!obj) return nil;
    Class wrapClass = NSClassFromString(@"CMessageWrap");
    if (!wrapClass) return nil;

    NSMutableArray *queue = [NSMutableArray arrayWithObject:obj];
    NSInteger guard = 0;
    while (queue.count && guard++ < 200) {
        id cur = XMSafeObject(queue.firstObject);
        [queue removeObjectAtIndex:0];
        if (!cur) continue;
        if ([cur isKindOfClass:wrapClass]) return cur;

        // viewModel / cell 上常常只有 ivar，没有 getter
        for (Class c = [cur class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
            unsigned int ic = 0;
            Ivar *ivars = class_copyIvarList(c, &ic);
            for (unsigned int i = 0; i < ic; i++) {
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (!type || type[0] != '@') continue;
                id v = nil;
                @try { v = object_getIvar(cur, ivars[i]); } @catch (__unused NSException *e) {}
                v = XMSafeObject(v);
                if (v && [v isKindOfClass:wrapClass]) {
                    if (ivars) free(ivars);
                    return v;
                }
            }
            if (ivars) free(ivars);
        }

        for (NSString *selName in @[@"getCurrentMessageWrap", @"messageWrap", @"m_messageWrap",
                                    @"msgWrap", @"viewModel", @"m_viewModel", @"message"]) {
            SEL sel = NSSelectorFromString(selName);
            if (![cur respondsToSelector:sel]) continue;
            id v = nil;
            @try { v = ((id (*)(id, SEL))objc_msgSend)(cur, sel); } @catch (__unused NSException *e) {}
            v = XMSafeObject(v);
            if (!v || v == cur) continue;
            if ([v isKindOfClass:wrapClass]) return v;
            if (![queue containsObject:v]) [queue addObject:v];
        }
    }
    return nil;
}

static NSString *XMChatIDForWrap(id wrap) {
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

static NSString *XMWrapText(id wrap) {
    if (!wrap) return @"";
    JGPTWeChat *w = [JGPTWeChat shared];
    NSString *text = [w contentOf:wrap] ?: @"";
    if ([w isGroupMessage:wrap]) text = [w stripGroupSenderPrefix:text];
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// 记住当前长按的是哪一条（只在 cell 自己实现的方法上挂，不改返回值）
static void XMCaptureLongPressCell(id cell) {
    if (!cell) return;
    id wrap = XMWrapFromCell(cell);
    if (!wrap) return;
    JGPTWeChat *w = [JGPTWeChat shared];
    if ([w typeOf:wrap] != 1) return;
    // 自己发的消息也允许单独分析（截图里大多是本机发出的红包/链接）；
    // 只是不会触发自动回复（analyzeMessage 内部不涉及自动回复）。

    NSString *text = XMWrapText(wrap);
    if (!text.length) return;
    gXMMenuWrap = wrap;
    gXMMenuText = text;
    gXMMenuChat = XMChatIDForWrap(wrap);
}

@interface XMAnalyzeMenuTarget : NSObject
- (void)wechatAIAnalyzeMessage:(id)sender;
@end

@implementation XMAnalyzeMenuTarget
- (void)wechatAIAnalyzeMessage:(id)sender {
    id wrap = gXMMenuWrap;
    NSString *chat = gXMMenuChat;
    if (!wrap) {
        [JGPTCommon toast:@"没拿到这条消息"];
        return;
    }
    [[JGPTEngine shared] analyzeMessage:wrap chat:chat];
}
@end

static id gXMMenuTarget = nil;

static id XMMakeAnalyzeMenuItem(void) {
    Class cls = NSClassFromString(@"MMMenuItem");
    if (!cls) return nil;
    if (!gXMMenuTarget) gXMMenuTarget = [[XMAnalyzeMenuTarget alloc] init];
    SEL action = NSSelectorFromString(@"wechatAIAnalyzeMessage:");

    // 与 wxtts 一致：优先 svgName。
    // 这个版本的 initWithTitle:icon: 期望的是图标名字符串，
    // 传 UIImage 会让菜单量不出宽高，表现就是「按一下菜单就不见了」。
    if ([cls instancesRespondToSelector:NSSelectorFromString(@"initWithTitle:svgName:target:action:")]) {
        return ((id (*)(id, SEL, id, id, id, SEL))objc_msgSend)(
            [cls alloc], NSSelectorFromString(@"initWithTitle:svgName:target:action:"),
            @"🤖 分析", @"icons_filled_radar", gXMMenuTarget, action);
    }
    if ([cls instancesRespondToSelector:NSSelectorFromString(@"initWithTitle:icon:target:action:")]) {
        return ((id (*)(id, SEL, id, id, id, SEL))objc_msgSend)(
            [cls alloc], NSSelectorFromString(@"initWithTitle:icon:target:action:"),
            @"🤖 分析", @"icons_filled_radar", gXMMenuTarget, action);
    }
    if ([cls instancesRespondToSelector:NSSelectorFromString(@"initWithTitle:")]) {
        id item = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithTitle:"), @"🤖 分析");
        @try {
            [item setValue:gXMMenuTarget forKey:@"_target"];
            [item setValue:@1004 forKey:@"_menuType"];
        } @catch (__unused NSException *e) {}
        Ivar iv = class_getInstanceVariable(cls, "_action");
        if (iv) @try {
            memcpy((char *)(__bridge void *)item + ivar_getOffset(iv), &action, sizeof(SEL));
        } @catch (__unused NSException *e) {}
        return item;
    }
    return nil;
}

static BOOL XMRowHasAnalyze(NSArray *row) {
    for (id item in row) {
        NSString *t = nil;
        @try { t = [item valueForKey:@"title"]; } @catch (__unused NSException *e) {}
        if (![t isKindOfClass:[NSString class]]) {
            @try { t = [item valueForKey:@"_title"]; } @catch (__unused NSException *e) {}
        }
        if ([t isKindOfClass:[NSString class]] && [t containsString:@"🤖"]) return YES;
    }
    return NO;
}

// 菜单数据对象：NMMenuData / MMMenuData，有 itemRows 和 calculateMenuLayout
static void XMInjectAnalyzeIntoMenuData(id data) {
    if (!data || ![JGPTConfig shared].enabled) return;
    if (!gXMMenuWrap || !gXMMenuText.length) {
        // 有的版本 operationMenuItems 不走 cell 类，退化为按当前窗口里的
        // 长按高亮 cell 找一次。
        UIWindow *win = [UIApplication sharedApplication].keyWindow;
        UIView *found = nil;
        NSMutableArray *queue = [NSMutableArray arrayWithObject:win];
        NSInteger guard = 0;
        while (queue.count && guard++ < 3000) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if (!v) continue;
            NSString *cls = NSStringFromClass([v class]);
            if ([cls containsString:@"MessageCellView"]) {
                id w = XMWrapFromCell(v);
                if (w) { found = v; break; }
            }
            for (UIView *sub in v.subviews) [queue addObject:sub];
        }
        if (found) XMCaptureLongPressCell(found);
    }
    if (!gXMMenuWrap || !gXMMenuText.length) return;

    id rowsObj = nil;
    for (NSString *selName in @[@"itemRows", @"menuItemRows", @"rows", @"items", @"menuItems"]) {
        SEL rowsSel = NSSelectorFromString(selName);
        if (![data respondsToSelector:rowsSel]) continue;
        @try { rowsObj = ((id (*)(id, SEL))objc_msgSend)(data, rowsSel); } @catch (__unused NSException *e) {}
        if ([rowsObj isKindOfClass:[NSArray class]] && [rowsObj count]) break;
        rowsObj = nil;
    }
    if (!rowsObj) return;

    NSArray *rows = rowsObj;
    for (id row in rows) {
        if ([row isKindOfClass:[NSArray class]] && XMRowHasAnalyze(row)) return;
    }

    // 关键：只往「已经存在的可变行」里追加。
    // itemRows 的外层数组有时是 NSArray 副本，往外层新增一行不会进入真实数据，
    // 表现就是菜单里完全看不到这一项（2.7.3 的问题）。
    // 这里挑当前项数最少的一行（一般是最后一行），加上短标题「🤖 分析」，
    // 不会像「单独分析」那样把整排撑出屏幕；另外还有屏幕夹取兜底。
    NSMutableArray *targetRow = nil;
    NSUInteger fewest = NSUIntegerMax;
    for (id row in rows) {
        if (![row isKindOfClass:[NSMutableArray class]]) continue;
        NSUInteger n = [(NSArray *)row count];
        if (n < fewest) { fewest = n; targetRow = row; }
    }
    id item = XMMakeAnalyzeMenuItem();
    if (!item) return;

    if (!targetRow) {
        // 兜底：所有行都是不可变数组时，复制最后一行再替换回去
        id last = [rows lastObject];
        if (![last isKindOfClass:[NSArray class]]) return;
        NSMutableArray *copy = [last mutableCopy];
        [copy addObject:item];
        if ([rows isKindOfClass:[NSMutableArray class]]) {
            [(NSMutableArray *)rows removeLastObject];
            [(NSMutableArray *)rows addObject:copy];
        } else {
            @try { [data setValue:rows forKey:@"itemRows"]; } @catch (__unused NSException *e) { return; }
        }
    } else {
        [targetRow addObject:item];
    }

    SEL calc = NSSelectorFromString(@"calculateMenuLayout");
    if ([data respondsToSelector:calc]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(data, calc); } @catch (__unused NSException *e) {}
    }
}

// 自己发的消息靠右，菜单以气泡为锚点展开，加一项后整块会往左/右溢出屏幕。
// 布局算完后把菜单容器夹回屏幕内。
static void XMClampMenuInsideScreen(id contentView) {
    if (![contentView isKindOfClass:[UIView class]]) return;
    UIView *v = (UIView *)contentView;
    UIWindow *win = v.window;
    if (!win) return;
    CGFloat screenW = win.bounds.size.width;
    UIView *card = v;
    for (NSInteger i = 0; i < 4; i++) {
        if (card.superview == win || !card.superview) break;
        card = card.superview;
    }
    for (NSInteger i = 0; i < 4 && card; i++) {
        CGRect r = [card convertRect:card.bounds toView:win];
        if (r.size.width <= 0 || r.size.width > screenW) { card = card.superview; continue; }
        CGFloat dx = 0;
        if (CGRectGetMinX(r) < 4) dx = 4 - CGRectGetMinX(r);
        else if (CGRectGetMaxX(r) > screenW - 4) dx = (screenW - 4) - CGRectGetMaxX(r);
        if (dx == 0) return;
        CGPoint c = card.center;
        c.x += dx;
        card.center = c;
        return;
    }
}

static NSMutableDictionary<NSString *, NSArray<NSValue *> *> *XMMenuUpdateOrigins(void) {
    static NSMutableDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

// 每个类单独一个 trampoline：直接共用一个函数会把父类实现一起改掉。
static void XMInstallMenuUpdateHook(Class cls, SEL sel) {
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
    NSString *key = [NSString stringWithFormat:@"%@-%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
    NSArray *old = XMMenuUpdateOrigins()[key];
    if (old.count && [(NSValue *)old.firstObject pointerValue] == cur && old.count > 1) return;

    XMMenuUpdateOrigins()[key] = @[[NSValue valueWithPointer:cur]];
    IMP tramp = imp_implementationWithBlock(^(id obj, id data, BOOL animated) {
        if (XMHookGuardEnter()) {
            @try { XMInjectAnalyzeIntoMenuData(data); } @catch (__unused NSException *e) {}
            XMHookGuardLeave();
        }
        ((void (*)(id, SEL, id, BOOL))cur)(obj, sel, data, animated);
        // 微信某些版本会在这之后重建行的 frame，补一次布局计算
        if (XMHookGuardEnter()) {
            SEL calc = NSSelectorFromString(@"calculateMenuLayout");
            if (data && [data respondsToSelector:calc]) {
                @try { ((void (*)(id, SEL))objc_msgSend)(data, calc); } @catch (__unused NSException *e) {}
            }
            XMHookGuardLeave();
        }
        // 等这一轮布局落定后把菜单夹回屏幕（自己发的消息最容易被撑出去）
        __weak id weakObj = obj;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { XMClampMenuInsideScreen(weakObj); } @catch (__unused NSException *e) {}
        });
    });
    method_setImplementation(own, tramp);
}

static void XMInstallMenuHook(void) {
    static Class *classes = NULL;
    static unsigned int count = 0;
    if (!classes) classes = objc_copyClassList(&count);
    NSArray *sels = @[@"updateWithData:animated:", @"updateWithDate:animated:"];
    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        const char *n = class_getName(c);
        if (!n) continue;
        NSString *name = @(n);
        if (![name containsString:@"MenuContentView"]) continue;
        for (NSString *sn in sels) {
            XMInstallMenuUpdateHook(c, NSSelectorFromString(sn));
        }
    }
}

#pragma mark - 记录长按的是哪条消息

// 只在自己的实现上挂，返回原值，绝不改动菜单数据。
static void XMInstallCellCapture(Class cls, SEL sel, NSMutableArray *store) {
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
    for (NSValue *v in store) if (v.pointerValue == cur) return;

    [store addObject:[NSValue valueWithPointer:cur]];
    IMP tramp = imp_implementationWithBlock(^id(id obj) {
        if (!XMHookGuardEnter()) return ((id (*)(id, SEL))cur)(obj, sel);
        @try { XMCaptureLongPressCell(obj); } @catch (__unused NSException *e) {}
        XMHookGuardLeave();
        return ((id (*)(id, SEL))cur)(obj, sel);
    });
    method_setImplementation(own, tramp);
}

@implementation JGPTMessageMenu

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        XMInstallMenuHook();

        static NSMutableArray *captured = nil;
        captured = [NSMutableArray array];

        static Class *classes = NULL;
        static unsigned int count = 0;
        if (!classes) classes = objc_copyClassList(&count);
        for (unsigned int i = 0; i < count; i++) {
            Class c = classes[i];
            const char *n = class_getName(c);
            if (!n) continue;
            NSString *name = @(n);
            if (![name containsString:@"MessageCellView"]) continue;
            // 只挂 operationMenuItems：generateOperationMenu 也会被菜单复用，
            // 两边都挂会让同一个 cell 被记录两次，增加和其他插件互相回环的风险。
            XMInstallCellCapture(c, NSSelectorFromString(@"operationMenuItems"), captured);
        }
    });
}

@end
