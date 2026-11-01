#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "JGPTCommon.h"
#import "JGPTConfig.h"
#import "JGPTEngine.h"
#import "JGPTWeChat.h"
#import "JGPTMemoryStore.h"
#import "JGPTChatCard.h"
#import "JGPTInlineCard.h"
#import "JGPTAssistantPanel.h"
#import "JGPTMessageMenu.h"

// 只保留三条消息级 hook + 一条入口挂载定时器。
// 不再 hook 任何 UIViewController 生命周期：与 WCFloatSplit 这类插件
// 同时 swizzle viewDidAppear 会互相把对方的 IMP 当成"原实现"，
// 形成 A→B→A 无限递归（2.1.0 的 SIGSEGV 就是这么来的）。

#pragma mark - 消息入口

static void (*orig_AsyncOnAddMsg)(id, SEL, id, id);
static void hook_AsyncOnAddMsg(id self, SEL _cmd, id chatName, id msgWrap) {
    if (!XMHookGuardEnter()) {
        if (orig_AsyncOnAddMsg) orig_AsyncOnAddMsg(self, _cmd, chatName, msgWrap);
        return;
    }
    if (orig_AsyncOnAddMsg) orig_AsyncOnAddMsg(self, _cmd, chatName, msgWrap);
    // 只给「我们自己的处理」加重入锁，原实现永远照常调用
    static BOOL inHandle = NO;
    if (inHandle) { XMHookGuardLeave(); return; }
    inHandle = YES;
    @try {
        NSString *session = [chatName isKindOfClass:[NSString class]] ? (NSString *)chatName : nil;
        if ([[JGPTWeChat shared] typeOf:msgWrap] == 3 && ![[JGPTWeChat shared] isOutgoing:msgWrap]) {
            NSString *chat = [[JGPTWeChat shared] isGroupMessage:msgWrap] && session.length
                           ? session : [[JGPTWeChat shared] fromOf:msgWrap];
            [[JGPTWeChat shared] rememberImageFrom:msgWrap chat:chat];
        }
        [[JGPTEngine shared] handleIncoming:msgWrap chatName:session];
    } @catch (NSException *e) {
        JGPTLog(@"AsyncOnAddMsg exception %@", e);
    }
    inHandle = NO;
    XMHookGuardLeave();
}

// 自己发的 #画图 / #视频 指令：只在本机触发，不进入微信发送流程。
// 微信发送走的路由有好几条（sendMsg:toContactUsrName: / AddMsg:MsgWrap: /
// AddLocalMsg:...），每条都要在「调用原实现之前」拦，否则指令已经发出去了。
// 指令被拦截后清空输入框（只清内容和这条指令一致的那个）
static void XMClearChatInput(NSString *command) {
    if (!command.length) return;
    NSString *target = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:win];
    NSInteger guard = 0;
    while (queue.count && guard++ < 3000) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)v;
            NSString *cur = [tv.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (cur.length && [cur isEqualToString:target]) {
                tv.text = @"";
                if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)])
                    [tv.delegate textViewDidChange:tv];
            }
        } else if ([v isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)v;
            NSString *cur = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (cur.length && [cur isEqualToString:target]) {
                tf.text = @"";
                [tf sendActionsForControlEvents:UIControlEventEditingChanged];
            }
        }
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }
}

static NSString *XMMediaPrefixIn(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || !text.length) return nil;
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *p in @[@"#画图", @"#绘图", @"#生图", @"#改图", @"#修图", @"#视频", @"#生视频"]) {
        if ([t hasPrefix:p]) return p;
    }
    return nil;
}

// 返回 YES 表示已拦下，调用方必须直接 return，不要调原实现
static BOOL XMInterceptMediaCommand(NSString *text, NSString *chat) {
    if (!XMMediaPrefixIn(text) || !chat.length) return NO;
    static BOOL inMedia = NO;
    if (inMedia) return NO;
    inMedia = YES;
    [[JGPTEngine shared] handleMediaCommand:text chat:chat replyTo:chat];
    XMClearChatInput(text);
    inMedia = NO;
    return YES;
}

static void (*orig_AddMsg)(id, SEL, id, id);
static void hook_AddMsg(id self, SEL _cmd, id chatName, id msgWrap) {
    if (!XMHookGuardEnter()) {
        if (orig_AddMsg) orig_AddMsg(self, _cmd, chatName, msgWrap);
        return;
    }
    if ([[JGPTWeChat shared] isOutgoing:msgWrap] && [[JGPTWeChat shared] typeOf:msgWrap] == 1) {
        NSString *text = [[JGPTWeChat shared] contentOf:msgWrap];
        BOOL group = [[JGPTWeChat shared] isGroupMessage:msgWrap];
        NSString *session = [chatName isKindOfClass:[NSString class]] ? (NSString *)chatName : nil;
        NSString *chat = group && session.length ? session : [[JGPTWeChat shared] toOf:msgWrap];
        if (XMInterceptMediaCommand(text, chat)) { XMHookGuardLeave(); return; }
    }

    if (orig_AddMsg) orig_AddMsg(self, _cmd, chatName, msgWrap);

    // 有的微信版本只走 AddMsg 不走 AsyncOnAddMsg：这里补一条入口。
    // 引擎内部按 messageKey 去重，重复投递不会跑两遍。
    static BOOL inIncoming = NO;
    if (!inIncoming && ![[JGPTWeChat shared] isOutgoing:msgWrap]) {
        inIncoming = YES;
        @try {
            NSString *session = [chatName isKindOfClass:[NSString class]] ? (NSString *)chatName : nil;
            [[JGPTEngine shared] handleIncoming:msgWrap chatName:session];
        } @catch (__unused NSException *e) {}
        inIncoming = NO;
    }

    static BOOL inHandle = NO;
    if (inHandle) { XMHookGuardLeave(); return; }
    inHandle = YES;
    @try {
        if ([[JGPTWeChat shared] isOutgoing:msgWrap]) {
            NSString *chat = [[JGPTWeChat shared] isGroupMessage:msgWrap] ? chatName : [[JGPTWeChat shared] toOf:msgWrap];
            NSString *text = [[JGPTWeChat shared] contentOf:msgWrap];
            if (chat.length && text.length)
                [[JGPTMemoryStore shared] appendHistory:@[@{@"role": @"assistant", @"content": text}] for:chat];
        }
    } @catch (__unused NSException *e) {}
    inHandle = NO;
    XMHookGuardLeave();
}

// 文本直发通道
static void (*orig_sendMsgTo)(id, SEL, id, id);
static void hook_sendMsgTo(id self, SEL _cmd, id text, id usrName) {
    if (!XMHookGuardEnter()) {
        if (orig_sendMsgTo) orig_sendMsgTo(self, _cmd, text, usrName);
        return;
    }
    NSString *chat = [usrName isKindOfClass:[NSString class]] ? (NSString *)usrName : nil;
    if (XMInterceptMediaCommand([text isKindOfClass:[NSString class]] ? (NSString *)text : nil, chat)) {
        XMHookGuardLeave();
        return;
    }
    if (orig_sendMsgTo) orig_sendMsgTo(self, _cmd, text, usrName);
    XMHookGuardLeave();
}

// 本地上屏通道（发图 / 发视频 / 部分版本的文字也走这里）
static void (*orig_AddLocalMsg2)(id, SEL, id, id);
static void hook_AddLocalMsg2(id self, SEL _cmd, id chatName, id msgWrap) {
    if (!XMHookGuardEnter()) {
        if (orig_AddLocalMsg2) orig_AddLocalMsg2(self, _cmd, chatName, msgWrap);
        return;
    }
    if ([[JGPTWeChat shared] isOutgoing:msgWrap] && [[JGPTWeChat shared] typeOf:msgWrap] == 1) {
        NSString *text = [[JGPTWeChat shared] contentOf:msgWrap];
        BOOL group = [[JGPTWeChat shared] isGroupMessage:msgWrap];
        NSString *session = [chatName isKindOfClass:[NSString class]] ? (NSString *)chatName : nil;
        NSString *chat = group && session.length ? session : [[JGPTWeChat shared] toOf:msgWrap];
        if (XMInterceptMediaCommand(text, chat)) { XMHookGuardLeave(); return; }
    }
    if (orig_AddLocalMsg2) orig_AddLocalMsg2(self, _cmd, chatName, msgWrap);
    XMHookGuardLeave();
}

static void (*orig_AddLocalMsg4)(id, SEL, id, id, BOOL, BOOL);
static void hook_AddLocalMsg4(id self, SEL _cmd, id chatName, id msgWrap, BOOL fixTime, BOOL notify) {
    if (!XMHookGuardEnter()) {
        if (orig_AddLocalMsg4) orig_AddLocalMsg4(self, _cmd, chatName, msgWrap, fixTime, notify);
        return;
    }
    if ([[JGPTWeChat shared] isOutgoing:msgWrap] && [[JGPTWeChat shared] typeOf:msgWrap] == 1) {
        NSString *text = [[JGPTWeChat shared] contentOf:msgWrap];
        BOOL group = [[JGPTWeChat shared] isGroupMessage:msgWrap];
        NSString *session = [chatName isKindOfClass:[NSString class]] ? (NSString *)chatName : nil;
        NSString *chat = group && session.length ? session : [[JGPTWeChat shared] toOf:msgWrap];
        if (XMInterceptMediaCommand(text, chat)) { XMHookGuardLeave(); return; }
    }
    if (orig_AddLocalMsg4) orig_AddLocalMsg4(self, _cmd, chatName, msgWrap, fixTime, notify);
    XMHookGuardLeave();
}

static void (*orig_AddLocalMsg5)(id, SEL, id, id, BOOL, BOOL, BOOL);
static void hook_AddLocalMsg5(id self, SEL _cmd, id chatName, id msgWrap, BOOL fixTime, BOOL notify, BOOL unique) {
    if (!XMHookGuardEnter()) {
        if (orig_AddLocalMsg5) orig_AddLocalMsg5(self, _cmd, chatName, msgWrap, fixTime, notify, unique);
        return;
    }
    if ([[JGPTWeChat shared] isOutgoing:msgWrap] && [[JGPTWeChat shared] typeOf:msgWrap] == 1) {
        NSString *text = [[JGPTWeChat shared] contentOf:msgWrap];
        BOOL group = [[JGPTWeChat shared] isGroupMessage:msgWrap];
        NSString *session = [chatName isKindOfClass:[NSString class]] ? (NSString *)chatName : nil;
        NSString *chat = group && session.length ? session : [[JGPTWeChat shared] toOf:msgWrap];
        if (XMInterceptMediaCommand(text, chat)) { XMHookGuardLeave(); return; }
    }
    if (orig_AddLocalMsg5) orig_AddLocalMsg5(self, _cmd, chatName, msgWrap, fixTime, notify, unique);
    XMHookGuardLeave();
}

#pragma mark - 聊天页

// 只 hook 聊天页自己的 viewDidLoad，用来把标题行挂上去、并给 VC 打标记。
// 只认「自己实现 viewDidLoad」的类，父子类都 hook 会 A→B→A 递归爆栈。
static NSMutableDictionary<NSString *, NSValue *> *XMOrigChatDidLoad(void) {
    static NSMutableDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

static IMP XMOrigChatDidLoadFor(id obj) {
    NSMutableDictionary *d = XMOrigChatDidLoad();
    for (Class c = [obj class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        NSValue *v = d[NSStringFromClass(c)];
        if (v) return v.pointerValue;
    }
    return NULL;
}

static void hook_chatPageDidLoad(id self, SEL _cmd) {
    // 栈深度保护：别的插件若把 viewDidLoad 的 IMP 又指回我们，
    // 这里直接判定成环，不再往下调（2.6.2 的 SIGSEGV 是栈溢出）。
    if (!XMHookGuardEnter()) return;
    IMP orig = XMOrigChatDidLoadFor(self);
    if (orig && orig != (IMP)hook_chatPageDidLoad) ((void (*)(id, SEL))orig)(self, _cmd);
    else if (orig == (IMP)hook_chatPageDidLoad) { XMHookGuardLeave(); return; }

    UIViewController *vc = (UIViewController *)self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [JGPTChatCard mountOnChatController:vc];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [JGPTChatCard mountOnChatController:vc];
    });
    XMHookGuardLeave();
}

static void XMInstallChatPageHooks(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObjects:
        @"BaseMsgContentViewController", @"NewChatViewController", @"ChatRoomViewController",
        @"SingleChatViewController", @"MsgContentViewController", nil];

    static Class *classes = NULL;
    static unsigned int count = 0;
    if (!classes) classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        const char *n = class_getName(c);
        if (!n) continue;
        NSString *name = @(n);
        if (![name containsString:@"MsgContent"]) continue;
        if (!class_getSuperclass(c)) continue;
        if (![name hasSuffix:@"ViewController"]) continue;
        if (![names containsObject:name]) [names addObject:name];
    }

    SEL sel = NSSelectorFromString(@"viewDidLoad");
    NSMutableSet<Class> *implementers = [NSMutableSet set];
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        unsigned int mc = 0;
        Method *ml = class_copyMethodList(cls, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            if (method_getName(ml[j]) == sel) { [implementers addObject:cls]; break; }
        }
        if (ml) free(ml);
    }

    for (Class cls in implementers) {
        BOOL ancestorHooked = NO;
        for (Class c = class_getSuperclass(cls); c && c != [NSObject class]; c = class_getSuperclass(c)) {
            if ([implementers containsObject:c]) { ancestorHooked = YES; break; }
        }
        if (ancestorHooked) continue;

        unsigned int mc = 0;
        Method *ml = class_copyMethodList(cls, &mc);
        Method own = NULL;
        for (unsigned int j = 0; j < mc; j++) {
            if (method_getName(ml[j]) == sel) { own = ml[j]; break; }
        }
        if (ml) free(ml);
        if (!own) continue;

        IMP cur = method_getImplementation(own);
        if (cur == (IMP)hook_chatPageDidLoad) continue;
        XMOrigChatDidLoad()[NSStringFromClass(cls)] = [NSValue valueWithPointer:cur];
        method_setImplementation(own, (IMP)hook_chatPageDidLoad);
    }
}

#pragma mark - 插件名替换

static void (*orig_registerPlugin)(id, SEL, id, id, id);
static void hook_registerPlugin(id self, SEL _cmd, id title, id version, id controller) {
    NSString *t = [title isKindOfClass:[NSString class]] ? title : @"";
    NSString *lower = [t lowercaseString];
    if ([lower containsString:@"jec"] || [lower containsString:@"jev"] ||
        [t containsString:@"微信AI助手"]) {
        t = @"微信 AI 会话分析";
    }
    if (orig_registerPlugin) orig_registerPlugin(self, _cmd, t, version, controller);
}

static void XMInstallPluginRenameHook(void) {
    Class mgr = NSClassFromString(@"WCPluginsMgr");
    if (!mgr) return;
    SEL sel = NSSelectorFromString(@"registerControllerWithTitle:version:controller:");
    Method m = class_getInstanceMethod(mgr, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == (IMP)hook_registerPlugin) return;
    orig_registerPlugin = (void (*)(id, SEL, id, id, id))cur;
    method_setImplementation(m, (IMP)hook_registerPlugin);
}

#pragma mark - 安装

static void XMSwizzle(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;
    if (outOrig) *outOrig = cur;
    method_setImplementation(m, newImp);
}

static void XMInstallHooks(void) {
    XMInstallPluginRenameHook();
    XMInstallChatPageHooks();

    Class msgMgr = NSClassFromString(@"CMessageMgr");
    if (msgMgr) {
        XMSwizzle(msgMgr, NSSelectorFromString(@"AsyncOnAddMsg:MsgWrap:"), (IMP)hook_AsyncOnAddMsg, (IMP *)&orig_AsyncOnAddMsg);
        XMSwizzle(msgMgr, NSSelectorFromString(@"AddMsg:MsgWrap:"), (IMP)hook_AddMsg, (IMP *)&orig_AddMsg);
        XMSwizzle(msgMgr, NSSelectorFromString(@"sendMsg:toContactUsrName:"), (IMP)hook_sendMsgTo, (IMP *)&orig_sendMsgTo);
        XMSwizzle(msgMgr, NSSelectorFromString(@"AddLocalMsg:MsgWrap:"), (IMP)hook_AddLocalMsg2, (IMP *)&orig_AddLocalMsg2);
        XMSwizzle(msgMgr, NSSelectorFromString(@"AddLocalMsg:MsgWrap:fixTime:NewMsgArriveNotify:"),
                  (IMP)hook_AddLocalMsg4, (IMP *)&orig_AddLocalMsg4);
        XMSwizzle(msgMgr, NSSelectorFromString(@"AddLocalMsg:MsgWrap:fixTime:NewMsgArriveNotify:Unique:"),
                  (IMP)hook_AddLocalMsg5, (IMP *)&orig_AddLocalMsg5);
    }
}

__attribute__((constructor)) static void XMInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            XMInstallHooks();
            [JGPTChatCard install];
            [JGPTInlineCard install];
            [JGPTMessageMenu install];
            [[JGPTWeChat shared] registerPluginEntry];
            [[JGPTWeChat shared] renameLegacyPluginEntries];
            JGPTLog(@"微信 AI 会话分析 loaded");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[JGPTWeChat shared] registerPluginEntry];
            [[JGPTWeChat shared] renameLegacyPluginEntries];
        });
    }
}
