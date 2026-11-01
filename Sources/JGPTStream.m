#import "JGPTStream.h"
#import "JGPTConfig.h"
#import "JGPTCommon.h"
#import "JGPTClient.h"

@interface JGPTStream () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, copy) JGPTStreamDelta onDelta;
@property (nonatomic, copy) JGPTStreamDone onFinish;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableString *accumulated;
// 有些网关把正文全塞在 reasoning_content 里，content 一直为空。
// 单独存着，最后发现正文是空的时候再兜底用，绝不混进流里。
@property (nonatomic, strong) NSMutableString *reasoning;
@property (nonatomic, strong) NSMutableData *rawBody;
@property (nonatomic, assign) BOOL isSSE;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, copy) NSString *system;
@property (nonatomic, copy) NSString *user;
@property (nonatomic, copy) NSString *lane;
@property (nonatomic, assign) double temperature;
@property (nonatomic, assign) NSInteger maxTokens;
@end

@implementation JGPTStream

+ (instancetype)startWithSystem:(NSString *)system
                           user:(NSString *)user
                       laneName:(NSString *)lane
                        onDelta:(JGPTStreamDelta)onDelta
                       onFinish:(JGPTStreamDone)onFinish {
    return [self startWithSystem:system user:user laneName:lane
                     temperature:0.8 maxTokens:0
                         onDelta:onDelta onFinish:onFinish];
}

+ (instancetype)startWithSystem:(NSString *)system
                           user:(NSString *)user
                       laneName:(NSString *)lane
                    temperature:(double)temperature
                      maxTokens:(NSInteger)maxTokens
                        onDelta:(JGPTStreamDelta)onDelta
                       onFinish:(JGPTStreamDone)onFinish {
    // temperature < 0 表示不带这个参数（有些推理模型会 400 拒掉 temperature）。
    JGPTStream *s = [[JGPTStream alloc] init];
    s.onDelta = onDelta;
    s.onFinish = onFinish;
    s.system = system;
    s.user = user;
    s.lane = lane;
    s.temperature = temperature;
    s.maxTokens = maxTokens;
    s.buffer = [NSMutableData data];
    s.rawBody = [NSMutableData data];
    s.accumulated = [NSMutableString string];
    s.reasoning = [NSMutableString string];

    JGPTConfig *c = [JGPTConfig shared];
    NSString *base = [c resolvedBase];
    if (!base.length) {
        if (onFinish) onFinish(@"", [NSError errorWithDomain:@"微信 AI 会话分析" code:1
                                                    userInfo:@{NSLocalizedDescriptionKey: @"接口地址为空"}]);
        return s;
    }
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSString *url = [base hasSuffix:@"/v1"] ? [base stringByAppendingString:@"/chat/completions"]
                                            : [[base stringByAppendingString:@"/v1"] stringByAppendingString:@"/chat/completions"];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 180;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    if (c.apiKey.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", c.apiKey] forHTTPHeaderField:@"Authorization"];
        [req setValue:c.apiKey forHTTPHeaderField:@"x-api-key"];
    }

    NSMutableArray *messages = [NSMutableArray array];
    if (system.length) [messages addObject:@{@"role": @"system", @"content": system}];
    [messages addObject:@{@"role": @"user", @"content": user ?: @""}];

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"model"] = c.apiModel.length ? c.apiModel : JGPTDefaultModel;
    body[@"messages"] = messages;
    body[@"stream"] = @YES;
    if (temperature >= 0) body[@"temperature"] = @(temperature);
    if (maxTokens > 0) body[@"max_tokens"] = @(maxTokens);
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 180;
    cfg.timeoutIntervalForResource = 600;
    s.session = [NSURLSession sessionWithConfiguration:cfg delegate:s delegateQueue:nil];
    s.task = [s.session dataTaskWithRequest:req];
    [s.task resume];
    return s;
}

- (void)cancel {
    [self.task cancel];
    [self.session invalidateAndCancel];
}

- (void)finishWithError:(NSError *)err {
    if (self.finished) return;
    self.finished = YES;
    [self.session finishTasksAndInvalidate];

    // 服务端不支持 stream 时会直接返回一整段 JSON（没有 data: 行）。
    // 这种情况把整包正文当成 accumulated 交回去，解析逻辑照常可用。
    // 有的网关 Content-Type 写着 event-stream 却回整包 JSON，所以不再看 isSSE。
    if (!self.accumulated.length && self.rawBody.length) {
        NSString *whole = [[NSString alloc] initWithData:self.rawBody encoding:NSUTF8StringEncoding];
        NSDictionary *json = whole.length ? [NSJSONSerialization JSONObjectWithData:self.rawBody options:0 error:nil] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) json = [JGPTClient parseJSONLoose:whole];
        // content / reasoning_content / text 都要看，不然推理模型会被当成空回复
        NSString *content = [JGPTClient extractMessageContent:json];
        // 只有确定不是 SSE 才把裸正文当内容（SSE 的原始行里混着 data: 前缀，不能直接用）
        if (!content.length && !self.isSSE) content = whole;
        if (content.length) {
            [self.accumulated appendString:content];
            if (self.onDelta) self.onDelta(content, content);
        }
    }
    // 正文一直是空、只有思考草稿：把草稿交回去，至少能解析。
    if (!self.accumulated.length && self.reasoning.length) {
        [self.accumulated appendString:self.reasoning];
        if (self.onDelta) self.onDelta([self.reasoning copy], [self.accumulated copy]);
    }
    if (self.onFinish) self.onFinish([self.accumulated copy], err);
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSInteger code = [(NSHTTPURLResponse *)response statusCode];
    NSString *ctype = [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Content-Type"];
    self.isSSE = [ctype.lowercaseString containsString:@"event-stream"];
    if (code >= 400) {
        completionHandler(NSURLSessionResponseCancel);
        NSError *e = [NSError errorWithDomain:@"微信 AI 会话分析" code:code
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)code]}];
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithError:e]; });
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    [self.rawBody appendData:data];
    [self.buffer appendData:data];

    const char *bytes = self.buffer.bytes;
    NSUInteger len = self.buffer.length;
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < len; i++) {
        if (bytes[i] != '\n') continue;
        NSUInteger lineLen = i - start;
        if (lineLen > 0) {
            NSData *slice = [NSData dataWithBytes:bytes + start length:lineLen];
            NSString *line = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
            if (!line) {
                // 半截 UTF-8（chunk 边界切开），保留到下次再解
                break;
            }
            [self handleLine:[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        }
        start = i + 1;
    }
    if (start > 0) [self.buffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
}

- (void)handleLine:(NSString *)line {
    if (!line.length) return;
    if (![line hasPrefix:@"data:"]) return;
    self.isSSE = YES;
    NSString *payload = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!payload.length || [payload isEqualToString:@"[DONE]"]) return;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding]
                                                        options:0 error:nil];
    if (!json) {
        // 有的网关每行发裸 JSON，没有 data: 前缀
        json = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding]
                                               options:NSJSONReadingAllowFragments error:nil];
    }
    id choice = [json[@"choices"] firstObject];
    id delta = choice[@"delta"][@"content"];
    if (!delta) delta = choice[@"message"][@"content"];
    if (![delta isKindOfClass:[NSString class]] || ![(NSString *)delta length]) {
        // 思考草稿只做兜底，不进正文字符流。
        id reason = choice[@"delta"][@"reasoning_content"];
        if (!reason) reason = choice[@"message"][@"reasoning_content"];
        if ([reason isKindOfClass:[NSString class]] && [(NSString *)reason length])
            [self.reasoning appendString:reason];
        return;
    }
    [self.accumulated appendString:delta];
    if (self.onDelta) {
        NSString *acc = [self.accumulated copy];
        dispatch_async(dispatch_get_main_queue(), ^{ self.onDelta(delta, acc); });
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithError:error]; });
}

@end
