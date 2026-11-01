#import "JGPTMediaLog.h"

NSString * const JGPTMediaLogChangedNotification = @"com.wechatai.medialog.changed";

static NSString * const kXMStoreKey = @"xb.media.log";
static const NSInteger kXMMaxEntries = 300;

static NSString *gXMTaskID = nil;
static NSString *gXMTaskTitle = nil;

static NSMutableArray<NSDictionary *> *XMBuffer(void) {
    static NSMutableArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = [NSMutableArray array];
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kXMStoreKey];
        if ([saved isKindOfClass:[NSArray class]]) [a addObjectsFromArray:saved];
    });
    return a;
}

static NSDateFormatter *XMFormatter(void) {
    static NSDateFormatter *f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"MM-dd HH:mm:ss";
    });
    return f;
}

static void XMSave(void) {
    [[NSUserDefaults standardUserDefaults] setObject:[XMBuffer() copy] forKey:kXMStoreKey];
}

@implementation JGPTMediaLog

+ (void)beginTask:(NSString *)title {
    @synchronized (XMBuffer()) {
        gXMTaskTitle = [title copy] ?: @"画图 / 视频";
        gXMTaskID = [NSString stringWithFormat:@"%.0f-%u", [[NSDate date] timeIntervalSince1970] * 1000,
                     arc4random() % 100000];
    }
}

+ (void)endTask {
    @synchronized (XMBuffer()) {
        gXMTaskID = nil;
        gXMTaskTitle = nil;
    }
}

+ (void)logStage:(NSString *)stage ok:(BOOL)ok text:(NSString *)text detail:(NSString *)detail {
    if (!stage.length && !text.length) return;
    NSMutableDictionary *e = [@{
        @"t": [XMFormatter() stringFromDate:[NSDate date]],
        @"stage": stage ?: @"",
        @"ok": @(ok),
        @"text": text ?: @"",
        @"detail": detail ?: @"",
    } mutableCopy];
    @synchronized (XMBuffer()) {
        if (gXMTaskID.length) {
            e[@"gid"] = gXMTaskID;
            e[@"gtitle"] = gXMTaskTitle ?: @"画图 / 视频";
        }
        [XMBuffer() insertObject:e atIndex:0];
        while ((NSInteger)XMBuffer().count > kXMMaxEntries) [XMBuffer() removeLastObject];
        XMSave();
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:JGPTMediaLogChangedNotification object:nil];
    });
}

+ (NSArray<NSDictionary *> *)entries {
    @synchronized (XMBuffer()) { return [XMBuffer() copy]; }
}

+ (NSArray<NSDictionary *> *)tasks {
    NSArray<NSDictionary *> *all = [self entries];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray *> *buckets = [NSMutableDictionary dictionary];

    for (NSDictionary *e in all) {
        NSString *gid = e[@"gid"];
        if (!gid.length) {
            // 没有归组的（例如启动时的零散记录）各自单独一条
            gid = [NSString stringWithFormat:@"solo-%@-%lu", e[@"t"] ?: @"",
                   (unsigned long)[all indexOfObject:e]];
        }
        NSMutableArray *arr = buckets[gid];
        if (!arr) { arr = [NSMutableArray array]; buckets[gid] = arr; }
        [arr addObject:e];
    }

    // 保持「最新任务在前」：按每组第一条出现顺序
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSDictionary *e in all) {
        NSString *gid = e[@"gid"];
        if (!gid.length) gid = [NSString stringWithFormat:@"solo-%@-%lu", e[@"t"] ?: @"",
                                (unsigned long)[all indexOfObject:e]];
        if (![order containsObject:gid]) [order addObject:gid];
    }

    for (NSString *gid in order) {
        NSMutableArray *arr = buckets[gid];
        if (!arr.count) continue;
        BOOL ok = YES;
        NSString *title = nil;
        NSMutableArray *stages = [NSMutableArray array];
        for (NSDictionary *e in arr) {
            if (![e[@"ok"] boolValue]) ok = NO;
            if (!title.length && [e[@"gtitle"] length]) title = e[@"gtitle"];
            if ([e[@"stage"] length]) [stages addObject:e[@"stage"]];
        }
        if (!title.length) title = arr.firstObject[@"stage"] ?: @"调用";
        NSDictionary *first = arr.firstObject;
        [out addObject:@{
            @"title": title,
            @"t": first[@"t"] ?: @"",
            @"ok": @(ok),
            @"count": @(arr.count),
            @"summary": [stages componentsJoinedByString:@" → "],
            @"entries": arr,
        }];
    }
    return out;
}

+ (void)clear {
    @synchronized (XMBuffer()) {
        [XMBuffer() removeAllObjects];
        gXMTaskID = nil;
        gXMTaskTitle = nil;
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kXMStoreKey];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:JGPTMediaLogChangedNotification object:nil];
    });
}

@end
