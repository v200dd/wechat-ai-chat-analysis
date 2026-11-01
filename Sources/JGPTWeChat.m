#import "JGPTWeChat.h"
#import "JGPTCommon.h"
#import "JGPTMediaLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>

static id JGPTValue(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static NSString *JGPTStr(id obj, NSString *key) {
    id v = JGPTValue(obj, key);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

@implementation JGPTWeChat

+ (instancetype)shared {
    static JGPTWeChat *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[JGPTWeChat alloc] init]; });
    return shared;
}

- (id)service:(NSString *)className {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    Class centerClass = NSClassFromString(@"MMServiceCenter");
    if (centerClass) {
        id center = ((id (*)(id, SEL))objc_msgSend)(centerClass, NSSelectorFromString(@"defaultCenter"));
        if (center) {
            id svc = ((id (*)(id, SEL, Class))objc_msgSend)(center, NSSelectorFromString(@"getService:"), cls);
            if (svc) return svc;
        }
    }
    // 兜底：MMContext
    Class ctxClass = NSClassFromString(@"MMContext");
    if (ctxClass) {
        id ctx = nil;
        if ([ctxClass respondsToSelector:NSSelectorFromString(@"activeUserContext")])
            ctx = ((id (*)(id, SEL))objc_msgSend)(ctxClass, NSSelectorFromString(@"activeUserContext"));
        if (ctx && [ctx respondsToSelector:NSSelectorFromString(@"getService:")])
            return ((id (*)(id, SEL, Class))objc_msgSend)(ctx, NSSelectorFromString(@"getService:"), cls);
    }
    if ([cls respondsToSelector:NSSelectorFromString(@"sharedInstance")])
        return ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"sharedInstance"));
    return nil;
}

- (id)msgMgr { return [self service:@"CMessageMgr"]; }
- (id)contactMgr { return [self service:@"CContactMgr"]; }

- (NSString *)selfWxid {
    static NSString *cached = nil;
    if (cached.length) return cached;
    @try {
        id mgr = [self contactMgr];
        id selfContact = nil;
        if (mgr && [mgr respondsToSelector:NSSelectorFromString(@"getSelfContact")])
            selfContact = ((id (*)(id, SEL))objc_msgSend)(mgr, NSSelectorFromString(@"getSelfContact"));
        NSString *wxid = JGPTStr(selfContact, @"m_nsUsrName");
        if (!wxid.length) wxid = [[NSUserDefaults standardUserDefaults] stringForKey:@"mm_username"];
        cached = wxid;
    } @catch (__unused NSException *e) {}
    return cached ?: @"";
}

- (id)contactFor:(NSString *)wxid {
    if (!wxid.length) return nil;
    @try {
        id mgr = [self contactMgr];
        SEL sel = NSSelectorFromString(@"getContactByName:");
        if (mgr && [mgr respondsToSelector:sel])
            return ((id (*)(id, SEL, id))objc_msgSend)(mgr, sel, wxid);
    } @catch (__unused NSException *e) {}
    return nil;
}

- (NSString *)displayNameFor:(NSString *)wxid {
    id c = [self contactFor:wxid];
    NSString *remark = JGPTStr(c, @"m_nsRemark");
    NSString *nick = JGPTStr(c, @"m_nsNickName");
    if (remark.length) return remark;
    if (nick.length) return nick;
    if (wxid.length) return wxid;
    return @"";
}

- (NSString *)genderFor:(NSString *)wxid {
    id c = [self contactFor:wxid];
    id sex = JGPTValue(c, @"m_uiSex");
    if ([sex respondsToSelector:@selector(integerValue)]) {
        NSInteger v = [sex integerValue];
        if (v == 1) return @"男";
        if (v == 2) return @"女";
    }
    return nil;
}

- (BOOL)isGroup:(NSString *)wxid {
    return [wxid hasSuffix:@"@chatroom"];
}

- (id)messageFrom:(NSString *)from to:(NSString *)to text:(NSString *)text isSender:(BOOL)isSender {
    Class wrapClass = NSClassFromString(@"CMessageWrap");
    if (!wrapClass) return nil;
    id wrap = nil;
    SEL init1 = NSSelectorFromString(@"initWithMsgType:");
    SEL init2 = NSSelectorFromString(@"initWithMsgType:nsFromUsr:");
    if ([wrapClass instancesRespondToSelector:init2])
        wrap = ((id (*)(id, SEL, int, id))objc_msgSend)([wrapClass alloc], init2, 1, from);
    else if ([wrapClass instancesRespondToSelector:init1])
        wrap = ((id (*)(id, SEL, int))objc_msgSend)([wrapClass alloc], init1, 1);
    if (!wrap) return nil;
    @try {
        [wrap setValue:text ?: @"" forKey:@"m_nsContent"];
        [wrap setValue:from ?: @"" forKey:@"m_nsFromUsr"];
        [wrap setValue:to ?: @"" forKey:@"m_nsToUsr"];
        [wrap setValue:@1 forKey:@"m_uiMessageType"];
        [wrap setValue:@(isSender ? 1 : 0) forKey:@"m_uiIsSenderStatus"];
        [wrap setValue:@((unsigned int)[[NSDate date] timeIntervalSince1970]) forKey:@"m_uiCreateTime"];
        [wrap setValue:@((unsigned int)(arc4random() % 90000 + 10000)) forKey:@"m_n64MesSvrID"];
    } @catch (__unused NSException *e) {}
    return wrap;
}

- (void)sendText:(NSString *)text to:(NSString *)wxid {
    [self sendText:text to:wxid quote:nil];
}

- (void)sendText:(NSString *)text to:(NSString *)wxid quote:(id)quotedWrap {
    if (!text.length || !wxid.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            id mgr = [self msgMgr];
            if (!mgr) return;
            NSString *me = [self selfWxid];
            id wrap = [self messageFrom:me to:wxid text:text isSender:YES];
            if (!wrap) return;
            if (quotedWrap) {
                @try { [wrap setValue:quotedWrap forKey:@"m_msgQuote"]; } @catch (__unused NSException *e) {}
            }
            SEL add = NSSelectorFromString(@"AddMsg:MsgWrap:");
            SEL addLocal = NSSelectorFromString(@"AddLocalMsg:MsgWrap:");
            SEL addLocal2 = NSSelectorFromString(@"AddLocalMsg:MsgWrap:fixTime:NewMsgArriveNotify:");
            if ([mgr respondsToSelector:add])
                ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, add, wxid, wrap);
            else if ([mgr respondsToSelector:addLocal2])
                ((void (*)(id, SEL, id, id, BOOL, BOOL))objc_msgSend)(mgr, addLocal2, wxid, wrap, NO, YES);
            else if ([mgr respondsToSelector:addLocal])
                ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, addLocal, wxid, wrap);
            else {
                SEL send = NSSelectorFromString(@"sendMsg:toContactUsrName:");
                if ([mgr respondsToSelector:send])
                    ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, send, text, wxid);
            }
        } @catch (NSException *e) {
            JGPTLog(@"sendText exception %@", e);
        }
    });
}

- (NSString *)contentOf:(id)msgWrap { return JGPTStr(msgWrap, @"m_nsContent"); }
- (NSString *)fromOf:(id)msgWrap { return JGPTStr(msgWrap, @"m_nsFromUsr"); }
- (NSString *)toOf:(id)msgWrap { return JGPTStr(msgWrap, @"m_nsToUsr"); }
- (unsigned int)typeOf:(id)msgWrap {
    id v = JGPTValue(msgWrap, @"m_uiMessageType");
    return [v respondsToSelector:@selector(unsignedIntValue)] ? [v unsignedIntValue] : 0;
}

- (BOOL)isGroupMessage:(id)msgWrap {
    if (!msgWrap) return NO;
    if ([msgWrap respondsToSelector:NSSelectorFromString(@"IsChatRoomMessage")])
        return ((BOOL (*)(id, SEL))objc_msgSend)(msgWrap, NSSelectorFromString(@"IsChatRoomMessage"));
    return [[self fromOf:msgWrap] hasSuffix:@"@chatroom"];
}

- (BOOL)isOutgoing:(id)msgWrap {
    if (!msgWrap) return NO;
    for (NSString *key in @[@"m_uiIsSenderStatus", @"m_bIsSender", @"m_isSender"]) {
        id v = JGPTValue(msgWrap, key);
        if ([v respondsToSelector:@selector(boolValue)] && [v boolValue]) return YES;
    }
    for (NSString *selName in @[@"IsSender", @"isSender", @"IsSendByMe", @"isSendByMe"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([msgWrap respondsToSelector:sel]) {
            @try {
                if (((BOOL (*)(id, SEL))objc_msgSend)(msgWrap, sel)) return YES;
            } @catch (__unused NSException *e) {}
        }
    }
    NSString *from = [self fromOf:msgWrap];
    NSString *me = [self selfWxid];
    if (me.length && [from isEqualToString:me]) return YES;
    // 群消息里 from 是群号 → 一定是别人发的
    if ([from hasSuffix:@"@chatroom"]) return NO;
    return NO;
}

- (NSString *)messageKey:(id)msgWrap {
    if (!msgWrap) return nil;
    id svr = JGPTValue(msgWrap, @"m_n64MesSvrID");
    if ([svr respondsToSelector:@selector(unsignedLongLongValue)] && [svr unsignedLongLongValue] > 0)
        return [NSString stringWithFormat:@"svr-%llu", [svr unsignedLongLongValue]];
    id local = JGPTValue(msgWrap, @"m_uiMesLocalID");
    if ([local respondsToSelector:@selector(unsignedIntValue)] && [local unsignedIntValue] > 0)
        return [NSString stringWithFormat:@"loc-%u", [local unsignedIntValue]];
    NSString *from = [self fromOf:msgWrap];
    NSString *content = [self contentOf:msgWrap];
    if (from.length && content.length) {
        // 退回内容哈希时把创建时间一起算进去：
        // 只按 from+content 会让「同一句重复发送」共用一条分析。
        id ts = JGPTValue(msgWrap, @"m_uiCreateTime");
        unsigned int t = [ts respondsToSelector:@selector(unsignedIntValue)] ? [ts unsignedIntValue] : 0;
        return [NSString stringWithFormat:@"%@-%lu-%u", from, (unsigned long)content.hash, t];
    }
    return nil;
}

#pragma mark - 最近一张图（图生图参考）

- (void)rememberImageFrom:(id)msgWrap chat:(NSString *)chat {
    if (!msgWrap || !chat.length) return;
    UIImage *img = nil;
    id data = JGPTValue(msgWrap, @"m_dtImg");
    if ([data isKindOfClass:[NSData class]] && [data length]) img = [UIImage imageWithData:data];
    if (!img) {
        NSString *path = JGPTStr(msgWrap, @"m_nsImgPath") ?: JGPTStr(msgWrap, @"m_nsFilePath");
        if (path.length && [[NSFileManager defaultManager] fileExistsAtPath:path])
            img = [UIImage imageWithContentsOfFile:path];
    }
    if (!img) return;
    static NSMutableDictionary<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        if (cache.count > 60) [cache removeAllObjects];
        cache[chat] = img;
    }
}

- (UIImage *)lastImageFor:(NSString *)chat {
    if (!chat.length) return nil;
    static NSMutableDictionary<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) { return cache[chat]; }
}

- (NSString *)chatIDFromController:(UIViewController *)vc {
    if (!vc) return nil;
    NSArray *keys = @[@"m_chatRoomContact", @"m_contact", @"m_contactWrap", @"m_chatContact",
                      @"m_oContact", @"m_contactInfo", @"m_chatContactInfo", @"m_userContact",
                      @"m_oContactInfo", @"m_contactData"];
    for (NSString *k in keys) {
        id contact = JGPTValue(vc, k);
        NSString *wxid = JGPTStr(contact, @"m_nsUsrName");
        if (wxid.length) return wxid;
        wxid = JGPTStr(contact, @"m_nsUserName");
        if (wxid.length) return wxid;
        wxid = JGPTStr(contact, @"m_nsChatName");
        if (wxid.length) return wxid;
        id wrap = JGPTValue(contact, @"m_contact");
        wxid = JGPTStr(wrap, @"m_nsUsrName");
        if (wxid.length) return wxid;
    }
    for (NSString *k in @[@"m_nsUsrName", @"m_nsUserName", @"m_chatName", @"chatName",
                          @"m_nsChatName", @"m_chatUserName", @"m_sessionId", @"m_nsSessionId"]) {
        NSString *s = JGPTStr(vc, k);
        if (s.length) return s;
    }
    // 部分版本把会话名放在无参方法里
    for (NSString *selName in @[@"getChatName", @"chatName", @"getCurrentChatName", @"currentChatName"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            @try {
                id v = ((id (*)(id, SEL))objc_msgSend)(vc, sel);
                if ([v isKindOfClass:[NSString class]] && [v length]) return v;
            } @catch (__unused NSException *e) {}
        }
    }
    // 兜底：从 viewModel / tableViewModel 里找
    for (NSString *k in @[@"m_viewModel", @"m_tableViewModel", @"m_chatViewModel"]) {
        id vm = JGPTValue(vc, k);
        if (!vm) continue;
        for (NSString *kk in @[@"m_chatName", @"chatName", @"m_nsUsrName", @"m_chatUserName"]) {
            NSString *s = JGPTStr(vm, kk);
            if (s.length) return s;
        }
    }
    return nil;
}

// 从屏幕上的消息气泡反推当前会话 ID：群聊取群号，私聊取对方 wxid。
// 微信聊天页的 VC 有时拿不到会话 ivar，这个方法比猜 ivar 稳。
- (NSString *)chatIDFromWindow:(UIWindow *)win {
    if (!win) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:win];
    NSInteger guard = 0;
    while (queue.count && guard++ < 4000) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([NSStringFromClass([v class]) containsString:@"TextMessageCellView"]) {
            id wrap = nil;
            for (NSString *selName in @[@"getCurrentMessageWrap", @"getMessageWrap", @"messageWrap"]) {
                SEL sel = NSSelectorFromString(selName);
                if ([v respondsToSelector:sel]) {
                    @try { wrap = ((id (*)(id, SEL))objc_msgSend)(v, sel); } @catch (__unused NSException *e) {}
                    if (wrap) break;
                }
            }
            if (!wrap) {
                id vm = JGPTValue(v, @"m_viewModel") ?: JGPTValue(v, @"viewModel");
                wrap = JGPTValue(vm, @"messageWrap") ?: JGPTValue(vm, @"m_messageWrap");
            }
            if (wrap) {
                NSString *from = JGPTStr(wrap, @"m_nsFromUsr");
                NSString *to = JGPTStr(wrap, @"m_nsToUsr");
                BOOL outgoing = JGPTBool(JGPTValue(wrap, @"m_uiIsSenderStatus"));
                BOOL group = [wrap respondsToSelector:NSSelectorFromString(@"IsChatRoomMessage")]
                           ? ((BOOL (*)(id, SEL))objc_msgSend)(wrap, NSSelectorFromString(@"IsChatRoomMessage"))
                           : ([from hasSuffix:@"@chatroom"] || [to hasSuffix:@"@chatroom"]);
                if (group) {
                    if ([from hasSuffix:@"@chatroom"]) return from;
                    if ([to hasSuffix:@"@chatroom"]) return to;
                }
                NSString *cand = outgoing ? to : from;
                if (cand.length) return cand;
            }
        }
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }
    return nil;
}

- (NSString *)stripGroupSenderPrefix:(NSString *)content {
    if (!content.length) return content;
    // 群消息形如 "wxid_xxx:\n真实内容"
    NSRange r = [content rangeOfString:@":\n"];
    if (r.location != NSNotFound && r.location < 60) {
        NSString *head = [content substringToIndex:r.location];
        if ([head rangeOfString:@" "].location == NSNotFound)
            return [[content substringFromIndex:r.location + r.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return content;
}

- (void)registerPluginEntry {
    static BOOL registered = NO;
    if (registered) return;
    @try {
        Class mgrClass = NSClassFromString(@"WCPluginsMgr");
        if (!mgrClass) return;
        id mgr = nil;
        if ([mgrClass respondsToSelector:NSSelectorFromString(@"sharedInstance")])
            mgr = ((id (*)(id, SEL))objc_msgSend)(mgrClass, NSSelectorFromString(@"sharedInstance"));
        if (!mgr) mgr = [self service:@"WCPluginsMgr"];
        SEL sel = NSSelectorFromString(@"registerControllerWithTitle:version:controller:");
        if (!mgr || ![mgr respondsToSelector:sel]) return;
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(mgr, sel, @"微信 AI 会话分析", @"2.7.6", @"JGPTMainVC");
        registered = YES;
        JGPTLog(@"plugin entry registered");
    } @catch (NSException *e) {
        JGPTLog(@"register exception %@", e);
    }
}

- (void)renameLegacyPluginEntries {
    // 旧版可能用 "Jev Chat" / "JevGPT" 注册过插件入口，注册表里会残留旧标题。
    // 这里把同 controller 的旧条目改名成「微信 AI 会话分析」，避免插件管理页还显示旧名。
    @try {
        Class mgrClass = NSClassFromString(@"WCPluginsMgr");
        if (!mgrClass) return;
        id mgr = nil;
        if ([mgrClass respondsToSelector:NSSelectorFromString(@"sharedInstance")])
            mgr = ((id (*)(id, SEL))objc_msgSend)(mgrClass, NSSelectorFromString(@"sharedInstance"));
        if (!mgr) mgr = [self service:@"WCPluginsMgr"];
        if (!mgr) return;

        NSArray *selectors = @[@"plugins", @"pluginList", @"allPlugins", @"m_plugins", @"m_pluginList",
                               @"pluginInfos", @"m_pluginInfos", @"registeredPlugins", @"m_registeredPlugins",
                               @"pluginItems", @"m_pluginItems", @"items", @"m_items"];
        NSArray *legacyNames = @[@"Jev Chat", @"JevChat", @"JevGPT", @"Jev-Chat", @"JecGPT", @"Jec Chat", @"JecChat", @"微信AI助手"];
        for (NSString *selName in selectors) {
            SEL sel = NSSelectorFromString(selName);
            if (![mgr respondsToSelector:sel]) continue;
            id list = ((id (*)(id, SEL))objc_msgSend)(mgr, sel);
            if (![list isKindOfClass:[NSArray class]] && ![list isKindOfClass:[NSSet class]]) continue;
            for (id item in list) {
                NSString *title = JGPTStr(item, @"title") ?: JGPTStr(item, @"name") ?: JGPTStr(item, @"pluginName");
                if (!title.length) continue;
                BOOL legacy = NO;
                for (NSString *old in legacyNames) {
                    if ([title isEqualToString:old] || [title containsString:@"Jev"] || [title containsString:@"JecGPT"]) {
                        legacy = YES;
                        break;
                    }
                }
                if (!legacy) continue;
                for (NSString *key in @[@"title", @"name", @"pluginName", @"m_nsTitle", @"m_nsName"]) {
                    @try {
                        if ([item valueForKey:key]) [item setValue:@"微信 AI 会话分析" forKey:key];
                    } @catch (__unused NSException *e) {}
                }
                JGPTLog(@"renamed legacy plugin entry: %@", title);
            }
            if ([list respondsToSelector:NSSelectorFromString(@"reloadData")])
                ((void (*)(id, SEL))objc_msgSend)(list, NSSelectorFromString(@"reloadData"));
        }

        // 兜底：遍历 WCPluginsMgr 所有无参对象返回方法，清理未知命名的集合
        unsigned int count = 0;
        Method *methods = class_copyMethodList(mgrClass, &count);
        for (unsigned int i = 0; i < count; i++) {
            Method m = methods[i];
            if (method_getNumberOfArguments(m) != 2) continue;
            const char *ret = method_copyReturnType(m);
            BOOL isObject = ret && ret[0] == '@';
            free((void *)ret);
            if (!isObject) continue;
            NSString *name = NSStringFromSelector(method_getName(m));
            if ([name hasPrefix:@"_"] || [name hasPrefix:@"set"] || [name hasPrefix:@"init"]) continue;
            @try {
                id list = ((id (*)(id, SEL))objc_msgSend)(mgr, method_getName(m));
                if (![list isKindOfClass:[NSArray class]] && ![list isKindOfClass:[NSSet class]]) continue;
                BOOL changed = NO;
                for (id item in list) {
                    NSString *title = JGPTStr(item, @"title") ?: JGPTStr(item, @"name")
                                    ?: JGPTStr(item, @"pluginName") ?: JGPTStr(item, @"m_nsTitle");
                    if (!title.length) continue;
                    NSString *lower = [title lowercaseString];
                    if (!([lower containsString:@"jec"] || [lower containsString:@"jev"]
                          || [title containsString:@"微信AI助手"])) continue;
                    for (NSString *key in @[@"title", @"name", @"pluginName", @"m_nsTitle", @"m_nsName"]) {
                        @try {
                            if ([item valueForKey:key]) [item setValue:@"微信 AI 会话分析" forKey:key];
                        } @catch (__unused NSException *e) {}
                    }
                    changed = YES;
                    JGPTLog(@"renamed plugin entry via %@: %@", name, title);
                }
                if (changed) JGPTLog(@"plugin collection %@ sanitized", name);
            } @catch (__unused NSException *e) {}
        }
        if (methods) free(methods);
    } @catch (NSException *e) {
        JGPTLog(@"rename legacy exception %@", e);
    }
}

#pragma mark - 媒体发送

- (NSString *)mediaDirectory {
    NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/WeChatAIAnalysis/media"];
    [[NSFileManager defaultManager] createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
    return base;
}

// 下载完成后直接走微信自己的「发图 / 发视频」通道（参考 PKCWeChatTools 的做法）：
//   图片：WeixinContentLogicController FormImageMsg:withImage:withData: → AddMsg:MsgWrap:
//   视频：CaptureVideoInfo genVideoInfoWithVideoUrl:thumb: → AddVideoMsg:ToUsr:VideoInfo:
// 不写相册，也不自己拼 CMessageWrap（那样对方只会收到空图）。
- (void)sendMediaURLs:(NSArray<NSString *> *)urls kind:(JGPTMediaKind)kind to:(NSString *)wxid caption:(NSString *)caption {
    if (!urls.count || !wxid.length) return;
    NSString *first = urls.firstObject;
    BOOL isVideo = (kind == JGPTMediaKindVideo);

    void (^deliver)(NSData *) = ^(NSData *data) {
        if (!data.length) {
            [JGPTMediaLog logStage:@"下载失败" ok:NO text:isVideo ? @"视频没拿到" : @"图片没拿到" detail:first];
            [JGPTMediaLog endTask];
            [JGPTCommon toast:@"下载失败，图片没拿到"];
            return;
        }
        [JGPTMediaLog logStage:@"下载完成" ok:YES
                          text:[NSString stringWithFormat:@"%.0f KB", data.length / 1024.0]
                        detail:first];
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = isVideo ? [self jgpt_sendVideoData:data to:wxid]
                              : [self jgpt_sendImageData:data to:wxid];
            [JGPTMediaLog logStage:(ok ? @"发送成功" : @"发送失败") ok:ok
                              text:(isVideo ? @"视频 → 会话" : @"图片 → 会话")
                            detail:wxid ?: @""];
            [JGPTMediaLog endTask];
            if (!ok) {
                [JGPTCommon toast:(isVideo ? @"视频发送失败" : @"图片发送失败")];
            }
        });
    };

    if ([first hasPrefix:@"data:"]) {
        NSRange comma = [first rangeOfString:@","];
        NSString *b64 = comma.location == NSNotFound ? nil : [first substringFromIndex:comma.location + 1];
        NSData *data = b64 ? [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
        deliver(data);
        return;
    }

    NSURL *url = [NSURL URLWithString:first];
    if (!url) {
        [JGPTCommon toast:@"返回的媒体地址无效"];
        return;
    }
    static NSURLSession *dlSession = nil;
    static dispatch_once_t dlOnce;
    dispatch_once(&dlOnce, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 300;
        cfg.timeoutIntervalForResource = 1800;
        dlSession = [NSURLSession sessionWithConfiguration:cfg];
    });
    [JGPTMediaLog logStage:@"开始下载" ok:YES text:isVideo ? @"视频" : @"图片" detail:first];
    [[dlSession downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
        NSData *data = location ? [NSData dataWithContentsOfURL:location] : nil;
        if (err && !data.length) {
            [JGPTMediaLog logStage:@"下载失败" ok:NO text:err.localizedDescription detail:first];
        [JGPTMediaLog endTask];
        }
        deliver(data);
    }] resume];
}

// 图片：走 WeixinContentLogicController 表单 + AddMsg
- (BOOL)jgpt_sendImageData:(NSData *)data to:(NSString *)wxid {
    UIImage *img = [UIImage imageWithData:data];
    if (!img) {
        [JGPTMediaLog logStage:@"发图失败" ok:NO text:@"数据不是有效图片" detail:@""];
        return NO;
    }
    Class logicClass = NSClassFromString(@"WeixinContentLogicController");
    id mgr = [self msgMgr];
    if (!logicClass || !mgr) {
        [JGPTMediaLog logStage:@"发图失败" ok:NO text:@"微信类不可用" detail:logicClass ? @"CMessageMgr 缺失" : @"WeixinContentLogicController 缺失"];
        return NO;
    }
    @try {
        id logic = ((id (*)(id, SEL))objc_msgSend)([logicClass alloc], NSSelectorFromString(@"init"));
        SEL formSel = NSSelectorFromString(@"FormImageMsg:withImage:withData:");
        if (![logic respondsToSelector:formSel]) {
            [JGPTMediaLog logStage:@"发图失败" ok:NO text:@"FormImageMsg 不存在" detail:@""];
            return NO;
        }
        id wrap = ((id (*)(id, SEL, id, id, id))objc_msgSend)(logic, formSel, wxid, img, data);
        if (!wrap) {
            [JGPTMediaLog logStage:@"发图失败" ok:NO text:@"FormImageMsg 返回空" detail:@""];
            return NO;
        }
        // 原图标记，否则微信按缩略图发，对方看到糊图
        id ext = ((id (*)(id, SEL))objc_msgSend)(wrap, NSSelectorFromString(@"m_extendInfoWithMsgType"));
        SEL setImg = NSSelectorFromString(@"setImage:withData:isOriginImage:");
        if (ext && [ext respondsToSelector:setImg])
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(ext, setImg, img, data, YES);
        ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, NSSelectorFromString(@"AddMsg:MsgWrap:"), wxid, wrap);
        return YES;
    } @catch (NSException *e) {
        JGPTLog(@"send image exception %@", e);
        [JGPTMediaLog logStage:@"发图失败" ok:NO text:@"异常" detail:e.reason ?: @""];
    }
    return NO;
}

// 视频：写到临时目录 → 生成 VideoInfo → AddVideoMsg:ToUsr:VideoInfo:
- (BOOL)jgpt_sendVideoData:(NSData *)data to:(NSString *)wxid {
    if (!data.length) return NO;
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"xb_%@.mp4", [[NSUUID UUID] UUIDString]]];
    if (![data writeToFile:tmp atomically:YES]) return NO;

    id mgr = [self msgMgr];
    Class capture = NSClassFromString(@"CaptureVideoInfo");
    if (!mgr || !capture) {
        [JGPTMediaLog logStage:@"发视频失败" ok:NO text:@"微信类不可用" detail:capture ? @"CMessageMgr 缺失" : @"CaptureVideoInfo 缺失"];
        return NO;
    }

    // 缩略图
    NSString *thumbPath = nil;
    @try {
        AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:tmp]];
        AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        gen.appliesPreferredTrackTransform = YES;
        CGImageRef cg = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(1, 600) actualTime:NULL error:nil];
        if (cg) {
            UIImage *thumb = [UIImage imageWithCGImage:cg];
            CGImageRelease(cg);
            NSData *thumbData = UIImageJPEGRepresentation(thumb, 0.7);
            thumbPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"xb_%@.jpg", [[NSUUID UUID] UUIDString]]];
            [thumbData writeToFile:thumbPath atomically:YES];
        }
    } @catch (__unused NSException *e) {}

    @try {
        UIImage *thumb = thumbPath ? [UIImage imageWithContentsOfFile:thumbPath] : nil;
        SEL genSel = NSSelectorFromString(@"genVideoInfoWithVideoUrl:thumb:");
        if (![capture respondsToSelector:genSel]) {
            [JGPTMediaLog logStage:@"发视频失败" ok:NO text:@"genVideoInfo 不存在" detail:@""];
            return NO;
        }
        id info = ((id (*)(id, SEL, id, id))objc_msgSend)(capture, genSel,
                                                          [NSURL fileURLWithPath:tmp], thumb);
        if (!info) {
            [JGPTMediaLog logStage:@"发视频失败" ok:NO text:@"genVideoInfo 返回空" detail:@""];
            return NO;
        }
        if (thumbPath && [info respondsToSelector:NSSelectorFromString(@"setThumb_path:")])
            ((void (*)(id, SEL, id))objc_msgSend)(info, NSSelectorFromString(@"setThumb_path:"), thumbPath);

        NSString *me = [self selfWxid];
        SEL addVideo = NSSelectorFromString(@"AddVideoMsg:ToUsr:VideoInfo:");
        if (![mgr respondsToSelector:addVideo]) {
            [JGPTMediaLog logStage:@"发视频失败" ok:NO text:@"AddVideoMsg 不存在" detail:@""];
            return NO;
        }
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(mgr, addVideo, me, wxid, info);
        return YES;
    } @catch (NSException *e) {
        JGPTLog(@"send video exception %@", e);
        [JGPTMediaLog logStage:@"发视频失败" ok:NO text:@"异常" detail:e.reason ?: @""];
    }
    return NO;
}

+ (void)jgpt_sendText:(NSString *)text to:(NSString *)wxid {
    [[JGPTWeChat shared] sendText:text to:wxid];
}


@end
