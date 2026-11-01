#import "JGPTMemoryStore.h"
#import "JGPTCommon.h"

static NSString * const kMemoryFile = @"memory.json";
static NSString * const kHistoryFile = @"history.json";

@interface JGPTMemoryStore ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *memory;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray *> *history;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastSummary;
@property (nonatomic, strong) NSRecursiveLock *lock;
@end

@implementation JGPTMemoryStore

+ (instancetype)shared {
    static JGPTMemoryStore *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[JGPTMemoryStore alloc] init]; });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _lock = [[NSRecursiveLock alloc] init];
        _lastSummary = [NSMutableDictionary dictionary];
        [self load];
    }
    return self;
}

- (NSString *)directory {
    NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/WeChatAIAnalysis"];
    [[NSFileManager defaultManager] createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
    return base;
}

- (NSString *)pathFor:(NSString *)file {
    return [[self directory] stringByAppendingPathComponent:file];
}

- (void)load {
    NSData *mData = [NSData dataWithContentsOfFile:[self pathFor:kMemoryFile]];
    NSDictionary *m = mData ? [NSJSONSerialization JSONObjectWithData:mData options:0 error:nil] : nil;
    self.memory = [m isKindOfClass:[NSDictionary class]] ? [m mutableCopy] : [NSMutableDictionary dictionary];

    NSData *hData = [NSData dataWithContentsOfFile:[self pathFor:kHistoryFile]];
    NSDictionary *h = hData ? [NSJSONSerialization JSONObjectWithData:hData options:0 error:nil] : nil;
    self.history = [h isKindOfClass:[NSDictionary class]] ? [h mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)persistMemory {
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.memory options:0 error:nil];
    [d writeToFile:[self pathFor:kMemoryFile] atomically:YES];
}

- (void)persistHistory {
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.history options:0 error:nil];
    [d writeToFile:[self pathFor:kHistoryFile] atomically:YES];
}

#pragma mark - notes

- (JGPTMemoryNote *)noteFor:(NSString *)wxid {
    if (!wxid.length) return nil;
    [self.lock lock];
    NSDictionary *d = self.memory[wxid];
    JGPTMemoryNote *note = d ? [JGPTMemoryNote noteWithDictionary:d] : [[JGPTMemoryNote alloc] init];
    note.wxid = wxid;
    [self.lock unlock];
    return note;
}

- (void)saveNote:(JGPTMemoryNote *)note {
    if (!note.wxid.length) return;
    [self.lock lock];
    note.updatedAt = [[NSDate date] timeIntervalSince1970];
    self.memory[note.wxid] = [note dictionaryRepresentation];
    [self persistMemory];
    [self.lock unlock];
}

- (void)removeNoteFor:(NSString *)wxid {
    if (!wxid.length) return;
    [self.lock lock];
    [self.memory removeObjectForKey:wxid];
    [self.history removeObjectForKey:wxid];
    [self persistMemory];
    [self persistHistory];
    [self.lock unlock];
}

- (void)removeAll {
    [self.lock lock];
    [self.memory removeAllObjects];
    [self.history removeAllObjects];
    [self persistMemory];
    [self persistHistory];
    [self.lock unlock];
}

- (NSArray<JGPTMemoryNote *> *)allNotes {
    [self.lock lock];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in self.memory) {
        JGPTMemoryNote *n = [JGPTMemoryNote noteWithDictionary:self.memory[key]];
        if (!n.wxid.length) n.wxid = key;
        [out addObject:n];
    }
    [self.lock unlock];
    return [out sortedArrayUsingComparator:^NSComparisonResult(JGPTMemoryNote *a, JGPTMemoryNote *b) {
        return [@(b.updatedAt) compare:@(a.updatedAt)];
    }];
}

#pragma mark - history

- (NSArray<NSDictionary *> *)historyFor:(NSString *)wxid {
    if (!wxid.length) return @[];
    [self.lock lock];
    NSArray *a = self.history[wxid] ?: @[];
    [self.lock unlock];
    return a;
}

- (void)appendHistory:(NSArray<NSDictionary *> *)messages for:(NSString *)wxid {
    if (!wxid.length || !messages.count) return;
    [self.lock lock];
    NSMutableArray *cur = [self.history[wxid] mutableCopy] ?: [NSMutableArray array];
    for (NSDictionary *m in messages) {
        NSDictionary *last = cur.lastObject;
        if (last && [last[@"role"] isEqual:m[@"role"]] && [last[@"content"] isEqual:m[@"content"]]) continue;
        [cur addObject:m];
    }
    while (cur.count > 40) [cur removeObjectAtIndex:0];
    self.history[wxid] = cur;
    [self persistHistory];
    [self.lock unlock];
}

- (void)clearHistoryFor:(NSString *)wxid {
    if (!wxid.length) return;
    [self.lock lock];
    [self.history removeObjectForKey:wxid];
    [self.lastSummary removeObjectForKey:wxid];
    [self persistHistory];
    [self.lock unlock];
}

- (NSString *)historyTextFor:(NSString *)wxid limit:(NSInteger)limit {
    NSArray<NSDictionary *> *h = [self historyFor:wxid];
    if (!h.count) return @"";
    NSInteger start = MAX(0, (NSInteger)h.count - MAX(0, limit));
    NSMutableArray *lines = [NSMutableArray array];
    for (NSInteger i = start; i < (NSInteger)h.count; i++) {
        NSDictionary *m = h[i];
        NSString *role = [m[@"role"] isEqualToString:@"assistant"] ? @"我" : @"对方";
        NSString *text = JGPTString(m[@"content"]);
        if (text.length) [lines addObject:[NSString stringWithFormat:@"%@：%@", role, text]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (BOOL)shouldSummarize:(NSString *)wxid {
    if (!wxid.length) return NO;
    [self.lock lock];
    NSTimeInterval last = [self.lastSummary[wxid] doubleValue];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    BOOL ok = (now - last) > 120;
    if (ok) self.lastSummary[wxid] = @(now);
    [self.lock unlock];
    return ok;
}

@end
