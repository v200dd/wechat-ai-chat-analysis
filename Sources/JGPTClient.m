#import "JGPTClient.h"
#import "JGPTConfig.h"
#import "JGPTCommon.h"
#import "JGPTMediaLog.h"

@implementation JGPTClient

+ (instancetype)shared {
    static JGPTClient *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[JGPTClient alloc] init]; });
    return shared;
}

#pragma mark - URL

- (NSString *)base {
    return [[JGPTConfig shared] resolvedBase];
}

- (NSString *)mediaBase {
    NSString *b = [[JGPTConfig shared] mediaBase];
    b = [b stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return b.length ? b : [self base];
}

- (NSString *)trimmed:(NSString *)b {
    b = [b stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([b hasSuffix:@"/"]) b = [b substringToIndex:b.length - 1];
    return b ?: @"";
}

- (NSString *)endpoint:(NSString *)path {
    return [self endpoint:path base:[self base]];
}

- (NSString *)mediaEndpoint:(NSString *)path {
    return [self endpoint:path base:[self mediaBase]];
}

- (NSString *)endpoint:(NSString *)path base:(NSString *)raw {
    NSString *b = [self trimmed:raw];
    if (!b.length) return nil;
    if ([b hasSuffix:path]) return b;
    // 用户可能已经填到 /v1
    if ([b hasSuffix:@"/v1"] || [b hasSuffix:@"/api/v1"]) return [b stringByAppendingString:path];
    return [[b stringByAppendingString:@"/v1"] stringByAppendingString:path];
}

- (NSMutableURLRequest *)requestFor:(NSString *)url {
    return [self requestFor:url key:[JGPTConfig shared].apiKey];
}

- (NSMutableURLRequest *)mediaRequestFor:(NSString *)url {
    JGPTConfig *c = [JGPTConfig shared];
    // 画图分组：画图 Key → 主 Key
    NSString *key = c.mediaKey.length ? c.mediaKey : c.apiKey;
    return [self requestFor:url key:key];
}

- (NSMutableURLRequest *)videoRequestFor:(NSString *)url {
    // 视频是单独分组：只认视频 Key，不再回落到画图 Key / 主 Key
    NSString *key = [JGPTConfig shared].videoKey;
    return [self requestFor:url key:key];
}

- (NSMutableURLRequest *)requestFor:(NSString *)url key:(NSString *)key {
    if (!url.length) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 120;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (key.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
        [req setValue:key forHTTPHeaderField:@"x-api-key"];
    }
    // 备用站/默认站都是标准 OpenAI 兼容协议，不带 wxid 头
    return req;
}

- (NSURLSession *)session {
    static NSURLSession *session = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 120;
        cfg.timeoutIntervalForResource = 600;
        session = [NSURLSession sessionWithConfiguration:cfg];
    });
    return session;
}

// 画图 / 视频用独立 session：出图经常 2~5 分钟，视频更久，
// 沿用 120s 的对话超时必然报超时。
- (NSURLSession *)mediaSession {
    static NSURLSession *session = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 600;
        cfg.timeoutIntervalForResource = 1800;
        cfg.waitsForConnectivity = NO;
        session = [NSURLSession sessionWithConfiguration:cfg];
    });
    return session;
}

#pragma mark - 思考模式参数

- (NSDictionary *)thinkingPayload {
    JGPTConfig *c = [JGPTConfig shared];
    JGPTThinkingMode m = c.thinkingMode;
    NSString *base = [[self base] lowercaseString];
    NSString *model = [c.apiModel lowercaseString];

    if (m == JGPTThinkingAuto) {
        BOOL reasoning = [model containsString:@"gpt-5"] || [model hasPrefix:@"o1"] || [model hasPrefix:@"o3"]
                      || [model hasPrefix:@"o4"] || [model containsString:@"qwen3"] || [model containsString:@"glm-4.5"]
                      || [model containsString:@"glm-4.6"] || [model containsString:@"gemini-2.5"]
                      || [model containsString:@"thinking"];
        if (!reasoning) return @{};
        if ([base containsString:@"dashscope"] || [base containsString:@"aliyuncs"] || [base containsString:@"siliconflow"])
            m = JGPTThinkingBailian;
        else if ([base containsString:@"bigmodel"] || [base containsString:@"volces"] || [base containsString:@"doubao"])
            m = JGPTThinkingGLM;
        else if ([base containsString:@"openrouter"]) m = JGPTThinkingOpenRouter;
        else if ([base containsString:@"generativelanguage"] || [base containsString:@"gemini"]) m = JGPTThinkingGemini;
        else if ([base containsString:@"openai"]) m = JGPTThinkingOpenAI;
        else m = JGPTThinkingNone;
    }

    switch (m) {
        case JGPTThinkingBailian: return @{@"enable_thinking": @NO};
        case JGPTThinkingGLM: return @{@"thinking": @{@"type": @"disabled"}};
        case JGPTThinkingOpenAI: return @{@"reasoning_effort": @"minimal"};
        case JGPTThinkingOpenRouter: return @{@"reasoning": @{@"enabled": @NO}};
        case JGPTThinkingGemini: return @{@"thinking_budget": @0};
        case JGPTThinkingVLLM: return @{@"chat_template_kwargs": @{@"enable_thinking": @NO}};
        default: return @{};
    }
}

#pragma mark - 对话

- (void)chatWithSystem:(NSString *)system
                  user:(NSString *)user
              laneName:(NSString *)lane
            completion:(JGPTCompletion)completion {
    [self chatWithSystem:system user:user laneName:lane temperature:0.8 maxTokens:0 completion:completion];
}

- (void)chatWithSystem:(NSString *)system
                  user:(NSString *)user
              laneName:(NSString *)lane
           temperature:(double)temperature
             maxTokens:(NSInteger)maxTokens
            completion:(JGPTCompletion)completion {
    NSString *url = [self endpoint:@"/chat/completions"];
    NSMutableURLRequest *req = [self requestFor:url];
    if (!req) {
        if (completion) completion(nil, nil, [NSError errorWithDomain:@"微信 AI 会话分析" code:1
                                                              userInfo:@{NSLocalizedDescriptionKey: @"接口地址为空"}]);
        return;
    }

    NSMutableArray *messages = [NSMutableArray array];
    if (system.length) [messages addObject:@{@"role": @"system", @"content": system}];
    [messages addObject:@{@"role": @"user", @"content": user ?: @""}];

    JGPTConfig *c = [JGPTConfig shared];
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"model"] = c.apiModel.length ? c.apiModel : JGPTDefaultModel;
    body[@"messages"] = messages;
    if (temperature >= 0) body[@"temperature"] = @(temperature);
    if (maxTokens > 0) body[@"max_tokens"] = @(maxTokens);
    [body addEntriesFromDictionary:[self thinkingPayload]];

    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[[self session] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *raw = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (!json && raw.length) json = [JGPTClient parseJSONLoose:raw];
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (!err && code >= 400) {
            NSString *msg = json[@"error"][@"message"] ?: [NSString stringWithFormat:@"HTTP %ld", (long)code];
            if (code == 404 || [msg.lowercaseString containsString:@"model"]) {
                msg = [NSString stringWithFormat:@"%@\n（模型不可用：设置 → 接口线路 → 获取模型，换一个再试）", msg];
            } else if (code == 401 || code == 403) {
                msg = [NSString stringWithFormat:@"%@\n（Key 无效或没权限：设置 → 接口线路 → API Key）", msg];
            }
            err = [NSError errorWithDomain:@"微信 AI 会话分析" code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        if (json[@"usage"][@"total_tokens"])
            [c addUsage:[json[@"usage"][@"total_tokens"] integerValue] lane:lane ?: @"chat"];
        if (completion) completion(json, raw, err);
    }] resume];
}

#pragma mark - 画图

- (void)generateImage:(NSString *)prompt
            reference:(UIImage *)reference
           completion:(JGPTMediaCompletion)completion {
    NSString *path = reference ? @"/images/edits" : @"/images/generations";
    // 有的站点是 https://host/v1/images/generations，有的是 https://host/images/generations。
    // 两个都试，404 就换下一个。
    NSMutableArray<NSString *> *urlsToTry = [NSMutableArray array];
    NSString *primary = [self mediaEndpoint:path];
    if (primary.length) [urlsToTry addObject:primary];
    NSString *bareBase = [self trimmed:[self mediaBase]];
    if ([bareBase hasSuffix:@"/v1"]) bareBase = [bareBase substringToIndex:bareBase.length - 3];
    NSString *bare = [bareBase stringByAppendingString:path];
    if (bare.length && ![urlsToTry containsObject:bare]) [urlsToTry addObject:bare];
    if (!urlsToTry.count) {
        if (completion) completion(nil, nil, [NSError errorWithDomain:@"微信 AI 会话分析" code:1
                                                              userInfo:@{NSLocalizedDescriptionKey: @"接口地址为空"}]);
        return;
    }
    [self postImageTo:urlsToTry index:0 prompt:prompt reference:reference completion:completion];
}

- (void)postImageTo:(NSArray<NSString *> *)urls
               index:(NSInteger)index
              prompt:(NSString *)prompt
           reference:(UIImage *)reference
          completion:(JGPTMediaCompletion)completion {
    if (index >= (NSInteger)urls.count) {
        if (completion) completion(nil, nil, [NSError errorWithDomain:@"微信 AI 会话分析" code:-2
                                                              userInfo:@{NSLocalizedDescriptionKey: @"画图接口不可用（/v1 与不带 /v1 都试过了）"}]);
        return;
    }
    NSString *url = urls[index];
    JGPTConfig *c = [JGPTConfig shared];
    NSMutableURLRequest *req = [self mediaRequestFor:url];
    NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];
    [JGPTMediaLog logStage:@"画图请求" ok:YES
                      text:[NSString stringWithFormat:@"%@ · %@", c.imageModel.length ? c.imageModel : @"默认模型", reference ? @"图生图" : @"文生图"]
                    detail:url];
    if (!req) {
        if (completion) completion(nil, nil, [NSError errorWithDomain:@"微信 AI 会话分析" code:1
                                                              userInfo:@{NSLocalizedDescriptionKey: @"接口地址为空"}]);
        return;
    }

    if (reference) {
        // multipart/form-data
        NSString *boundary = @"----WeChatAIBoundary7d91";
        [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
    forHTTPHeaderField:@"Content-Type"];
        NSMutableData *body = [NSMutableData data];
        void (^field)(NSString *, NSString *) = ^(NSString *name, NSString *value) {
            [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", boundary, name, value] dataUsingEncoding:NSUTF8StringEncoding]];
        };
        if (c.imageModel.length) field(@"model", c.imageModel);
        field(@"prompt", prompt ?: @"");
        field(@"n", @"1");
        [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"image\"; filename=\"ref.png\"\r\nContent-Type: image/png\r\n\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:UIImagePNGRepresentation(reference) ?: [NSData data]];
        [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        req.HTTPBody = body;
    } else {
        NSMutableDictionary *body = [NSMutableDictionary dictionary];
        body[@"prompt"] = prompt ?: @"";
        body[@"n"] = @1;
        body[@"size"] = @"1024x1024";
        body[@"image_size"] = @"1024x1024";
        body[@"batch_size"] = @1;
        if (c.imageModel.length) body[@"model"] = c.imageModel;
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }

    req.timeoutInterval = 600;
    [[[self mediaSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *raw = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (!json && raw.length) json = [JGPTClient parseJSONLoose:raw];
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        NSTimeInterval cost = [NSDate timeIntervalSinceReferenceDate] - started;
        if (!err && code >= 400) {
            NSString *msg = json[@"error"][@"message"] ?: [NSString stringWithFormat:@"HTTP %ld", (long)code];
            if (code == 404) {
                [JGPTMediaLog logStage:@"画图端点" ok:NO text:[NSString stringWithFormat:@"HTTP 404，换另一种拼法"] detail:url];
                // 端点不对，换另一个拼法
                [self postImageTo:urls index:index + 1 prompt:prompt reference:reference completion:completion];
                return;
            }
            [JGPTMediaLog logStage:@"画图失败" ok:NO text:[NSString stringWithFormat:@"HTTP %ld", (long)code]
                            detail:msg.length ? msg : (raw.length ? [raw substringToIndex:MIN(raw.length, 300)] : @"")];
            err = [NSError errorWithDomain:@"微信 AI 会话分析" code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        NSMutableArray *urls = [NSMutableArray array];
        id list = json[@"data"];
        if ([list isKindOfClass:[NSArray class]]) {
            for (NSDictionary *item in list) {
                NSString *u = item[@"url"];
                NSString *b64 = item[@"b64_json"];
                if (u.length) [urls addObject:u];
                else if (b64.length) [urls addObject:[@"data:image/png;base64," stringByAppendingString:b64]];
            }
        }
        if (!urls.count && json[@"url"]) [urls addObject:json[@"url"]];
        if (!urls.count && json[@"images"]) {
            for (id item in json[@"images"]) {
                if ([item isKindOfClass:[NSString class]]) [urls addObject:item];
                else if ([item isKindOfClass:[NSDictionary class]] && item[@"url"]) [urls addObject:item[@"url"]];
            }
        }
        if (!err && !urls.count) {
            err = [NSError errorWithDomain:@"微信 AI 会话分析" code:-2
                                  userInfo:@{NSLocalizedDescriptionKey: raw.length ? [raw substringToIndex:MIN(raw.length, 200)] : @"未返回图片"}];
        }
        if (err) {
            if (code < 400 && err.code != -2)
                [JGPTMediaLog logStage:@"画图失败" ok:NO text:err.localizedDescription
                                detail:[NSString stringWithFormat:@"耗时 %.1fs", cost]];
        } else {
            [JGPTMediaLog logStage:@"画图返回" ok:YES
                              text:[NSString stringWithFormat:@"%lu 张 · 耗时 %.1fs", (unsigned long)urls.count, cost]
                            detail:urls.firstObject ?: @""];
        }
        if (completion) completion(urls, raw, err);
    }] resume];
}

#pragma mark - 视频

- (void)generateVideo:(NSString *)prompt completion:(JGPTMediaCompletion)completion {
    JGPTConfig *c = [JGPTConfig shared];
    NSString *url = [self mediaEndpoint:@"/videos/generations"];
    if (!c.videoKey.length) {
        if (completion) completion(nil, nil, [NSError errorWithDomain:@"微信 AI 会话分析" code:1
                                                              userInfo:@{NSLocalizedDescriptionKey: @"未设置视频 Key（设置 → 画图 / 视频 → 视频 Key）"}]);
        return;
    }
    NSMutableURLRequest *req = [self videoRequestFor:url];
    if (!req) {
        if (completion) completion(nil, nil, [NSError errorWithDomain:@"微信 AI 会话分析" code:1
                                                              userInfo:@{NSLocalizedDescriptionKey: @"接口地址为空"}]);
        return;
    }
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"prompt"] = prompt ?: @"";
    // 视频模型固定 grok-imagine-video-1.5，不跟随画图模型
    body[@"model"] = c.videoModel.length ? c.videoModel : JGPTDefaultVideoModel;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    req.timeoutInterval = 600;
    [JGPTMediaLog logStage:@"视频请求" ok:YES
                      text:[NSString stringWithFormat:@"%@", c.videoModel.length ? c.videoModel : @"默认模型"]
                    detail:url ?: @""];

    [[[self mediaSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *raw = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (!json && raw.length) json = [JGPTClient parseJSONLoose:raw];
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (!err && code >= 400) {
            NSString *msg = json[@"error"][@"message"] ?: [NSString stringWithFormat:@"HTTP %ld", (long)code];
            if (completion) completion(nil, nil, [NSError errorWithDomain:@"微信 AI 会话分析" code:code
                                                                 userInfo:@{NSLocalizedDescriptionKey: msg}]);
            return;
        }
        NSString *direct = json[@"url"] ?: json[@"video_url"];
        if (direct.length) {
            [JGPTMediaLog logStage:@"视频返回" ok:YES text:@"直出地址" detail:direct];
            if (completion) completion(@[direct], raw, nil);
            return;
        }
        NSString *rid = json[@"id"] ?: json[@"request_id"] ?: json[@"task_id"];
        if (!rid.length) {
            [JGPTMediaLog logStage:@"视频失败" ok:NO text:@"未返回任务 ID" detail:raw ? [raw substringToIndex:MIN(raw.length, 300)] : @""];
            if (completion) completion(nil, raw, [NSError errorWithDomain:@"微信 AI 会话分析" code:-2
                                                                userInfo:@{NSLocalizedDescriptionKey: @"未返回任务 ID"}]);
            return;
        }
        [JGPTMediaLog logStage:@"视频排队" ok:YES text:[NSString stringWithFormat:@"任务 %@", rid] detail:url ?: @""];
        [self pollVideo:rid attempt:0 completion:completion];
    }] resume];
}

- (void)pollVideo:(NSString *)requestID attempt:(NSInteger)attempt completion:(JGPTMediaCompletion)completion {
    if (attempt > 180) {
        if (completion) completion(nil, nil, [NSError errorWithDomain:@"微信 AI 会话分析" code:-3
                                                             userInfo:@{NSLocalizedDescriptionKey: @"视频生成超时"}]);
        return;
    }
    NSString *url = [self mediaEndpoint:[NSString stringWithFormat:@"/videos/%@", requestID]];
    NSMutableURLRequest *req = [self videoRequestFor:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 60;
    [[[self mediaSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *status = [json[@"status"] lowercaseString] ?: @"";
        NSString *videoURL = json[@"url"] ?: json[@"video_url"] ?: json[@"output"];
        if ([videoURL isKindOfClass:[NSDictionary class]]) videoURL = ((NSDictionary *)videoURL)[@"url"];
        if (videoURL.length && ![status isEqualToString:@"failed"]) {
            [JGPTMediaLog logStage:@"视频返回" ok:YES text:[NSString stringWithFormat:@"轮询第 %ld 次", (long)attempt]
                            detail:videoURL];
            if (completion) completion(@[videoURL], nil, nil);
            return;
        }
        if ([status isEqualToString:@"failed"] || [status isEqualToString:@"error"]) {
            NSString *msg = json[@"error"][@"message"] ?: @"视频生成失败";
            [JGPTMediaLog logStage:@"视频失败" ok:NO text:msg detail:requestID];
            if (completion) completion(nil, nil, [NSError errorWithDomain:@"微信 AI 会话分析" code:-4
                                                                 userInfo:@{NSLocalizedDescriptionKey: msg}]);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self pollVideo:requestID attempt:attempt + 1 completion:completion];
        });
    }] resume];
}

#pragma mark - 解析

- (void)fetchModelsWithCompletion:(void (^)(NSArray<NSString *> *, NSError *))completion {
    NSString *url = [self endpoint:@"/models"];
    NSMutableURLRequest *req = [self requestFor:url];
    [self runModelFetch:req completion:completion];
}

- (void)fetchMediaModelsWithCompletion:(void (^)(NSArray<NSString *> *, NSError *))completion {
    NSString *url = [self mediaEndpoint:@"/models"];
    NSMutableURLRequest *req = [self mediaRequestFor:url];
    [self runModelFetch:req completion:completion];
}

- (void)fetchVideoModelsWithCompletion:(void (^)(NSArray<NSString *> *, NSError *))completion {
    NSString *url = [self mediaEndpoint:@"/models"];
    NSMutableURLRequest *req = [self videoRequestFor:url];
    if (![JGPTConfig shared].videoKey.length) {
        if (completion) completion(nil, [NSError errorWithDomain:@"微信 AI 会话分析" code:1
                                                        userInfo:@{NSLocalizedDescriptionKey: @"先填视频 Key"}]);
        return;
    }
    [self runModelFetch:req completion:completion];
}

- (void)runModelFetch:(NSMutableURLRequest *)req completion:(void (^)(NSArray<NSString *> *, NSError *))completion {
    if (!req) {
        if (completion) completion(nil, [NSError errorWithDomain:@"微信 AI 会话分析" code:1
                                                        userInfo:@{NSLocalizedDescriptionKey: @"接口地址为空"}]);
        return;
    }
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 25;
    [[[self session] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (!err && code >= 400) {
            NSString *msg = json[@"error"][@"message"] ?: [NSString stringWithFormat:@"HTTP %ld", (long)code];
            err = [NSError errorWithDomain:@"微信 AI 会话分析" code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        id list = json[@"data"];
        if ([list isKindOfClass:[NSArray class]]) {
            for (id item in list) {
                NSString *mid = nil;
                if ([item isKindOfClass:[NSDictionary class]]) mid = item[@"id"];
                else if ([item isKindOfClass:[NSString class]]) mid = item;
                if (mid.length) [ids addObject:mid];
            }
        }
        if (!ids.count && [json[@"models"] isKindOfClass:[NSArray class]]) {
            for (id item in json[@"models"]) {
                NSString *mid = [item isKindOfClass:[NSDictionary class]] ? item[@"id"] : ([item isKindOfClass:[NSString class]] ? item : nil);
                if (mid.length) [ids addObject:mid];
            }
        }
        if (!err && !ids.count)
            err = [NSError errorWithDomain:@"微信 AI 会话分析" code:-2
                                  userInfo:@{NSLocalizedDescriptionKey: @"未返回模型列表"}];
        NSArray *sorted = [ids sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        if (completion) completion(sorted, err);
    }] resume];
}

+ (NSString *)extractMessageContent:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    id choices = json[@"choices"];
    if ([choices isKindOfClass:[NSArray class]] && [choices count]) {
        id first = [choices firstObject];
        id content = first[@"message"][@"content"];
        if ([content isKindOfClass:[NSString class]]) return content;
        if ([content isKindOfClass:[NSArray class]]) {
            NSMutableString *s = [NSMutableString string];
            for (id part in content) {
                if ([part isKindOfClass:[NSDictionary class]] && [part[@"text"] isKindOfClass:[NSString class]])
                    [s appendString:part[@"text"]];
            }
            return s;
        }
        id text = first[@"text"];
        if ([text isKindOfClass:[NSString class]]) return text;
        // 有些推理模型把正文全放在 reasoning_content，content 是空的。
        id reasoning = first[@"message"][@"reasoning_content"];
        if (![reasoning isKindOfClass:[NSString class]])
            reasoning = first[@"delta"][@"reasoning_content"];
        if ([reasoning isKindOfClass:[NSString class]] && [reasoning length]) return reasoning;
    }
    id output = json[@"output"];
    if ([output isKindOfClass:[NSString class]]) return output;
    if ([output isKindOfClass:[NSDictionary class]] && [output[@"text"] isKindOfClass:[NSString class]]) return output[@"text"];
    id content = json[@"content"];
    if ([content isKindOfClass:[NSString class]]) return content;
    return nil;
}

+ (NSDictionary *)parseJSONLoose:(NSString *)text {
    if (!text.length) return nil;
    NSString *s = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"```"]) {
        NSRange firstNL = [s rangeOfString:@"\n"];
        if (firstNL.location != NSNotFound) s = [s substringFromIndex:firstNL.location + 1];
        if ([s hasSuffix:@"```"]) s = [s substringToIndex:s.length - 3];
    }
    id obj = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    NSRange l = [s rangeOfString:@"{"];
    NSRange r = [s rangeOfString:@"}" options:NSBackwardsSearch];
    if (l.location != NSNotFound && r.location != NSNotFound && r.location > l.location) {
        NSString *sub = [s substringWithRange:NSMakeRange(l.location, r.location - l.location + 1)];
        obj = [NSJSONSerialization JSONObjectWithData:[sub dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    }
    return nil;
}

// 从「写到一半」的 JSON 里取出某个字符串字段的当前值。
// 只要引号还没闭合，就返回已经收到的部分（末尾的半句也算），
// 这样读心能随着流一个字一个字长出来。
+ (NSString *)partialJSONStringForKey:(NSString *)key inText:(NSString *)text {
    if (!key.length || !text.length) return nil;
    NSString *needle = [NSString stringWithFormat:@"\"%@\"", key];
    NSRange kr = [text rangeOfString:needle];
    if (kr.location == NSNotFound) return nil;
    NSUInteger i = NSMaxRange(kr);
    // 跳过冒号和空白，等第一个引号
    while (i < text.length && [text characterAtIndex:i] != '"') {
        unichar ch = [text characterAtIndex:i];
        if (ch != ':' && ch != ' ' && ch != '\n' && ch != '\r' && ch != '\t') return nil;
        i++;
    }
    if (i >= text.length) return nil;
    i++; // 跳过开头引号

    NSMutableString *out = [NSMutableString string];
    BOOL escape = NO;
    for (; i < text.length; i++) {
        unichar ch = [text characterAtIndex:i];
        if (escape) {
            switch (ch) {
                case 'n': [out appendString:@"\n"]; break;
                case 't': [out appendString:@"\t"]; break;
                case 'r': break;
                case '"': [out appendString:@"\""]; break;
                case '\\': [out appendString:@"\\"]; break;
                case '/': [out appendString:@"/"]; break;
                default: [out appendFormat:@"%C", ch]; break;
            }
            escape = NO;
            continue;
        }
        if (ch == '\\') { escape = YES; continue; }
        if (ch == '"') break;   // 字段已闭合
        [out appendFormat:@"%C", ch];
    }
    return out;
}

@end
