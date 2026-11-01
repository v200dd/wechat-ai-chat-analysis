#import "JGPTSettingsVC.h"
#import "JGPTConfig.h"
#import "JGPTCommon.h"
#import "JGPTClient.h"
#import "JGPTPrompts.h"
#import "JGPTMemoryVC.h"
#import "JGPTMemoryStore.h"
#import "JGPTWeChat.h"
#import "JGPTAboutVC.h"
#import "JGPTMediaLog.h"
#import "JGPTMediaLogVC.h"

typedef NS_ENUM(NSInteger, XMSection) {
    XMSectionBasic = 0,
    XMSectionApi,
    XMSectionMedia,
    XMSectionBehavior,
    XMSectionMemory,
    XMSectionUsage,
    XMSectionAbout,
    XMSectionCount,
};

@interface JGPTMainVC ()
@property (nonatomic, strong) NSArray<NSString *> *fetchedModels;
@end

@implementation JGPTMainVC

- (instancetype)init {
    if (@available(iOS 13.0, *)) return [super initWithStyle:UITableViewStyleInsetGrouped];
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"微信 AI 会话分析";
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:JGPTConfigChangedNotification object:nil];
}

- (void)closeSettings {
    // 从聊天页的分析面板点「设置」进来时，上面叠了两层模态：
    // 设置页 → 分析面板 → 聊天页。关掉设置后再把分析面板一起收掉，
    // 直接回到聊天页，不用再点一次「关闭」。
    UIViewController *presenter = self.navigationController.presentingViewController ?: self.presentingViewController;
    __weak UIViewController *weakPresenter = presenter;
    [self dismissViewControllerAnimated:YES completion:^{
        UIViewController *p = weakPresenter;
        if (!p) return;
        NSString *cls = NSStringFromClass([p class]);
        if ([cls containsString:@"JGPTSheet"] || [cls containsString:@"JGPTAssistant"]) {
            [p dismissViewControllerAnimated:YES completion:nil];
        }
    }];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)reload { [self.tableView reloadData]; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    // 从聊天页面板以全屏方式打开时（root 是被 present 的 nav），
    // 必须给一个能直接回到聊天页的关闭按钮；作为插件页 push 进来时不显示。
    BOOL presented = (self.navigationController.presentingViewController != nil)
                  || (self.presentingViewController != nil);
    UIBarButtonItem *left = self.navigationItem.leftBarButtonItem;
    BOOL ours = (left.tag == 96601);
    if (presented && !left) {
        UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(closeSettings)];
        close.tag = 96601;
        self.navigationItem.leftBarButtonItem = close;
    } else if (!presented && ours) {
        self.navigationItem.leftBarButtonItem = nil;
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return XMSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case XMSectionBasic: return 1;
        case XMSectionApi: return 6;
        case XMSectionMedia: return 8;
        case XMSectionBehavior: return 9;
        case XMSectionMemory: return 2;
        case XMSectionUsage: return 3;
        default: return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case XMSectionBasic: return @"基础功能";
        case XMSectionApi: return @"接口设置";
        case XMSectionMedia: return @"画图 / 视频";
        case XMSectionBehavior: return @"回复行为";
        case XMSectionMemory: return @"记忆档案";
        case XMSectionUsage: return @"用量统计";
        default: return @"关于";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    JGPTConfig *c = [JGPTConfig shared];
    switch (section) {
        case XMSectionBasic:
            return @"聊天页点顶部备注名字三下开启。\n长按任意消息点「🤖 分析」即可。";
        case XMSectionApi:
            return [NSString stringWithFormat:@"当前端点：%@\n填入端点与 API Key 后即可使用，支持任意 OpenAI 兼容接口。", [c resolvedBase]];
        case XMSectionMedia:
            return @"画图与视频各自独立分组：画图 Key、视频 Key 可分别填写。\n"
                    "模型名称按所使用服务商的文档填写。\n"
                    "聊天里发 #画图 描述 或 #视频 描述，生成后直接发到当前会话。\n"
                    "出问题看「画图 / 视频调用日记」：一次调用一行，点开看每一步。";
        case XMSectionBehavior:
            return @"自动回复按会话生效：在记忆档案列表里给某个联系人打开开关并选第几条。\n"
                    "收尾消息（晚安/睡了）不会自动回。真实口吻打开后，话术只定方向，落笔仍像你自己。\n"
                    "建议回复条数 1~10 条，默认 4 条；聊天页内嵌卡里可以直接点「换一批」。";
        default:
            return nil;
    }
}

- (UITableViewCell *)cellWithTitle:(NSString *)title detail:(NSString *)detail accessory:(UITableViewCellAccessoryType)acc {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail ?: @"";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = acc;
    return cell;
}

- (UITableViewCell *)switchCell:(NSString *)title on:(BOOL)on tag:(NSInteger)tag {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.tag = tag;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    JGPTConfig *c = [JGPTConfig shared];
    NSInteger s = indexPath.section, r = indexPath.row;

    if (s == XMSectionBasic) {
        return [self switchCell:@"启用微信 AI 会话分析" on:c.enabled tag:100];
    }
    if (s == XMSectionApi) {
        if (r == 0) {
            NSString *preset = c.apiPreset == JGPTApiPresetCustom ? @"自定义" : @"默认";
            return [self cellWithTitle:@"接口线路" detail:preset accessory:UITableViewCellAccessoryDisclosureIndicator];
        }
        if (r == 1) return [self cellWithTitle:@"端点" detail:[c resolvedBase] accessory:UITableViewCellAccessoryDisclosureIndicator];
        if (r == 2) {
            return [self cellWithTitle:@"API Key"
                                detail:c.apiKey.length ? @"已设置" : @"未设置"
                             accessory:UITableViewCellAccessoryDisclosureIndicator];
        }
        if (r == 3) return [self cellWithTitle:@"对话模型" detail:c.apiModel.length ? c.apiModel : @"未设置" accessory:UITableViewCellAccessoryDisclosureIndicator];
        if (r == 4) return [self cellWithTitle:@"获取模型" detail:@"" accessory:UITableViewCellAccessoryDisclosureIndicator];
        return [self cellWithTitle:@"关联上下文" detail:[NSString stringWithFormat:@"%ld 条", (long)c.contextLines] accessory:UITableViewCellAccessoryDisclosureIndicator];
    }
    if (s == XMSectionMedia) {
        if (r == 0) return [self cellWithTitle:@"画图 / 视频接口" detail:c.mediaBase.length ? c.mediaBase : @"主接口" accessory:UITableViewCellAccessoryDisclosureIndicator];
        if (r == 1) return [self cellWithTitle:@"画图 Key" detail:c.mediaKey.length ? @"已设置（独立）" : @"复用主 Key" accessory:UITableViewCellAccessoryDisclosureIndicator];
        if (r == 2) return [self cellWithTitle:@"画图模型" detail:c.imageModel.length ? c.imageModel : JGPTDefaultImageModel accessory:UITableViewCellAccessoryDisclosureIndicator];
        if (r == 3) return [self cellWithTitle:@"视频 Key" detail:c.videoKey.length ? @"已设置（独立）" : @"未设置" accessory:UITableViewCellAccessoryDisclosureIndicator];
        if (r == 4) return [self cellWithTitle:@"视频模型" detail:c.videoModel.length ? c.videoModel : JGPTDefaultVideoModel accessory:UITableViewCellAccessoryDisclosureIndicator];
        if (r == 5) return [self cellWithTitle:@"获取画图模型" detail:@"" accessory:UITableViewCellAccessoryDisclosureIndicator];
        if (r == 6) return [self cellWithTitle:@"获取视频模型" detail:@"" accessory:UITableViewCellAccessoryDisclosureIndicator];
        NSArray *tasks = [JGPTMediaLog tasks];
        NSUInteger total = [JGPTMediaLog entries].count;
        NSString *detail = tasks.count
            ? [NSString stringWithFormat:@"%lu 次 / %lu 步", (unsigned long)tasks.count, (unsigned long)total]
            : @"空";
        return [self cellWithTitle:@"画图 / 视频调用日记" detail:detail
                         accessory:UITableViewCellAccessoryDisclosureIndicator];
    }
    if (s == XMSectionBehavior) {
        if (r == 0) return [self switchCell:@"意图判断" on:c.judgeEnabled tag:200];
        if (r == 1) return [self switchCell:@"建议回复" on:c.genEnabled tag:201];
        if (r == 2) return [self switchCell:@"真实口吻" on:c.realTone tag:202];
        if (r == 3) return [self switchCell:@"自动回复" on:c.autoReplyEnabled tag:206];
        if (r == 4) {
            NSString *tones = c.tones.count ? [c.tones componentsJoinedByString:@"、"] : @"未选择";
            return [self cellWithTitle:@"话术人设"
                                detail:(c.tones.count > 1 ? [NSString stringWithFormat:@"%lu 种", (unsigned long)c.tones.count] : tones)
                             accessory:UITableViewCellAccessoryDisclosureIndicator];
        }
        if (r == 5) return [self cellWithTitle:@"自动回复第几条"
                                        detail:[NSString stringWithFormat:@"第 %ld 条", (long)(c.autoReplyIndex + 1)]
                                     accessory:UITableViewCellAccessoryDisclosureIndicator];
        if (r == 6) return [self cellWithTitle:@"建议回复条数"
                                        detail:[NSString stringWithFormat:@"%ld 条", (long)c.replyCount]
                                     accessory:UITableViewCellAccessoryDisclosureIndicator];
        if (r == 7) return [self switchCell:@"群聊免 @" on:c.groupNoAt tag:203];
        return [self switchCell:@"群聊引用回复" on:c.quoteMode tag:204];
    }
    if (s == XMSectionMemory) {
        if (r == 0) return [self cellWithTitle:@"查看记忆档案" detail:[NSString stringWithFormat:@"%lu 位", (unsigned long)[[JGPTMemoryVC allCount] unsignedIntegerValue]] accessory:UITableViewCellAccessoryDisclosureIndicator];
        return [self cellWithTitle:@"清除全部记忆" detail:@"" accessory:UITableViewCellAccessoryNone];
    }
    if (s == XMSectionUsage) {
        NSArray *lanes = @[@"chat", @"image", @"video"];
        NSArray *titles = @[@"对话", @"画图", @"视频"];
        NSDictionary *u = [c usageForLane:lanes[r]];
        return [self cellWithTitle:titles[r]
                            detail:[NSString stringWithFormat:@"今日 %@ / 累计 %@", u[@"today"], u[@"total"]]
                         accessory:UITableViewCellAccessoryNone];
    }
    return [self cellWithTitle:@"关于" detail:@"版本 2.7.6" accessory:UITableViewCellAccessoryDisclosureIndicator];
}

- (void)switchChanged:(UISwitch *)sw {
    JGPTConfig *c = [JGPTConfig shared];
    switch (sw.tag) {
        case 100: c.enabled = sw.isOn; break;
        case 103: c.showCard = sw.isOn; break;
        case 200: c.judgeEnabled = sw.isOn; break;
        case 201: c.genEnabled = sw.isOn; break;
        case 202: c.realTone = sw.isOn; break;
        case 203: c.groupNoAt = sw.isOn; break;
        case 204: c.quoteMode = sw.isOn; break;
        case 206: c.autoReplyEnabled = sw.isOn; break;
        default: break;
    }
    [c synchronize];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    JGPTConfig *c = [JGPTConfig shared];
    NSInteger s = indexPath.section, r = indexPath.row;

    if (s == XMSectionApi) {
        if (r == 0) [self choosePreset];
        else if (r == 1) [self showEndpointActions];
        else if (r == 2) {
            [JGPTCommon input:@"API Key" value:c.apiKey in:self done:^(NSString *t) { c.apiKey = t; [c synchronize]; }];
        } else if (r == 3) {
            [JGPTCommon input:@"对话模型" value:c.apiModel in:self done:^(NSString *t) { c.apiModel = t; [c synchronize]; }];
        } else if (r == 4) {
            [self fetchModels];
        } else if (r == 5) {
            [self chooseContext];
        }
    } else if (s == XMSectionMedia) {
        if (r == 0) {
            [JGPTCommon input:@"画图 / 视频接口（留空复用主接口）" value:c.mediaBase in:self done:^(NSString *t) {
                c.mediaBase = t;
                [c synchronize];
            }];
        } else if (r == 1) {
            [JGPTCommon input:@"画图 Key（留空复用主 Key）" value:c.mediaKey in:self done:^(NSString *t) {
                c.mediaKey = t;
                [c synchronize];
            }];
        } else if (r == 2) {
            [JGPTCommon input:@"画图模型" value:c.imageModel in:self done:^(NSString *t) { c.imageModel = t; [c synchronize]; }];
        } else if (r == 3) {
            [JGPTCommon input:@"视频 Key（必填，单独分组）" value:c.videoKey in:self done:^(NSString *t) {
                c.videoKey = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                [c synchronize];
            }];
        } else if (r == 4) {
            [JGPTCommon input:@"视频模型" value:c.videoModel in:self done:^(NSString *t) { c.videoModel = t; [c synchronize]; }];
        } else if (r == 5) {
            [self fetchMediaModels];
        } else if (r == 6) {
            [self fetchVideoModels];
        } else {
            [self.navigationController pushViewController:[[JGPTMediaLogVC alloc] init] animated:YES];
        }
    } else if (s == XMSectionMemory) {
        if (r == 0) [self.navigationController pushViewController:[[JGPTMemoryListVC alloc] init] animated:YES];
        else [self confirmClearMemory];
    } else if (s == XMSectionBehavior) {
        if (r == 4) {
            [self.navigationController pushViewController:[[JGPTToneVC alloc] init] animated:YES];
        } else if (r == 5) {
            [self chooseAutoReplyIndex];
        } else if (r == 6) {
            [self chooseReplyCount];
        }
    } else if (s == XMSectionUsage) {
        [c clearUsage];
        [self.tableView reloadData];
        [JGPTCommon toast:@"已清零" in:self.view];
    } else if (s == XMSectionAbout) {
        [self.navigationController pushViewController:[[JGPTAboutVC alloc] init] animated:YES];
    }
}

- (void)chooseReplyCount {
    JGPTConfig *c = [JGPTConfig shared];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"建议回复条数"
                                                              message:@"每条消息下面显示几条建议"
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 1; i <= 10; i++) {
        NSString *title = [NSString stringWithFormat:@"%ld 条%@", (long)i, (i == 4 ? @"（默认）" : @"")];
        [a addAction:[UIAlertAction actionWithTitle:title
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
            c.replyCount = i;
            [c synchronize];
            [self.tableView reloadData];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 120, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)chooseAutoReplyIndex {
    JGPTConfig *c = [JGPTConfig shared];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"自动回复第几条"
                                                              message:@"自动发出建议回复里的第几条"
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < 4; i++) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"第 %ld 条", (long)(i + 1)]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
            c.autoReplyIndex = i;
            [c synchronize];
            [self.tableView reloadData];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 120, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 线路

- (void)choosePreset {
    JGPTConfig *c = [JGPTConfig shared];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"接口线路" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"默认 · %@", JGPTDefaultBase]
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *_) {
        c.apiPreset = JGPTApiPresetDefault;
        [c synchronize];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"自定义"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *_) {
        c.apiPreset = JGPTApiPresetCustom;
        [c synchronize];
        [JGPTCommon input:@"自定义端点" value:c.customBase in:self done:^(NSString *t) {
            c.customBase = t;
            [c synchronize];
        }];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 120, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showEndpointActions {
    JGPTConfig *c = [JGPTConfig shared];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"端点" message:[c resolvedBase] preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [UIPasteboard generalPasteboard].string = [c resolvedBase];
        [JGPTCommon toast:@"已复制" in:self.view];
    }]];
    if (c.apiPreset == JGPTApiPresetCustom) {
        [a addAction:[UIAlertAction actionWithTitle:@"修改自定义地址" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [JGPTCommon input:@"自定义端点" value:c.customBase in:self done:^(NSString *t) {
                c.customBase = t;
                [c synchronize];
            }];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 120, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 获取模型

- (void)fetchModels {
    [JGPTCommon toast:@"正在获取模型…" in:self.view];
    __weak typeof(self) weakSelf = self;
    [[JGPTClient shared] fetchModelsWithCompletion:^(NSArray<NSString *> *ids, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ids.count) {
                [JGPTCommon alert:@"获取失败" message:error.localizedDescription ?: @"未返回模型" in:weakSelf];
                return;
            }
            weakSelf.fetchedModels = ids;
            [weakSelf showModelPicker:ids];
        });
    }];
}

- (void)showModelPicker:(NSArray<NSString *> *)ids {
    JGPTConfig *c = [JGPTConfig shared];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"模型（%lu）", (unsigned long)ids.count]
                                                              message:@"选择后写入对话模型"
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    NSInteger limit = MIN((NSInteger)ids.count, 40);
    for (NSInteger i = 0; i < limit; i++) {
        NSString *mid = ids[i];
        [a addAction:[UIAlertAction actionWithTitle:mid style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            c.apiModel = mid;
            [c synchronize];
            [JGPTCommon toast:[NSString stringWithFormat:@"已选 %@", mid] in:self.view];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 120, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)fetchMediaModels {
    [JGPTCommon toast:@"正在获取画图模型…" in:self.view];
    __weak typeof(self) weakSelf = self;
    [[JGPTClient shared] fetchMediaModelsWithCompletion:^(NSArray<NSString *> *ids, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ids.count) {
                [JGPTCommon alert:@"获取失败" message:error.localizedDescription ?: @"未返回模型" in:weakSelf];
                return;
            }
            [weakSelf showMediaModelPicker:ids];
        });
    }];
}

- (void)showMediaModelPicker:(NSArray<NSString *> *)ids {
    JGPTConfig *c = [JGPTConfig shared];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"画图模型（%lu）", (unsigned long)ids.count]
                                                              message:@"写入画图模型"
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    NSInteger limit = MIN((NSInteger)ids.count, 40);
    for (NSInteger i = 0; i < limit; i++) {
        NSString *mid = ids[i];
        [a addAction:[UIAlertAction actionWithTitle:mid style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            c.imageModel = mid;
            [c synchronize];
            [JGPTCommon toast:[NSString stringWithFormat:@"已选 %@", mid] in:self.view];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 120, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)fetchVideoModels {
    [JGPTCommon toast:@"正在获取视频模型…" in:self.view];
    __weak typeof(self) weakSelf = self;
    [[JGPTClient shared] fetchVideoModelsWithCompletion:^(NSArray<NSString *> *ids, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *videoOnly = ids;
            NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSString *mid, NSDictionary *bindings) {
                NSString *l = mid.lowercaseString;
                return [l containsString:@"video"] || [l containsString:@"grok"] || [l containsString:@"seedance"] || [l containsString:@"sora"] || [l containsString:@"veo"];
            }];
            NSArray *filtered = [ids filteredArrayUsingPredicate:p];
            if (filtered.count) videoOnly = filtered;
            if (!videoOnly.count) {
                [JGPTCommon alert:@"获取失败" message:error.localizedDescription ?: @"未返回模型" in:weakSelf];
                return;
            }
            [weakSelf showVideoModelPicker:videoOnly];
        });
    }];
}

- (void)showVideoModelPicker:(NSArray<NSString *> *)ids {
    JGPTConfig *c = [JGPTConfig shared];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"视频模型（%lu）", (unsigned long)ids.count]
                                                              message:@"选择后写入视频模型"
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    NSInteger limit = MIN((NSInteger)ids.count, 40);
    for (NSInteger i = 0; i < limit; i++) {
        NSString *mid = ids[i];
        [a addAction:[UIAlertAction actionWithTitle:mid style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            c.videoModel = mid;
            [c synchronize];
            [JGPTCommon toast:[NSString stringWithFormat:@"已选 %@", mid] in:self.view];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 120, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 其他

- (void)chooseContext {
    JGPTConfig *c = [JGPTConfig shared];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"关联上下文" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *n in @[@0, @3, @5, @8, @10, @15]) {
        [a addAction:[UIAlertAction actionWithTitle:[n integerValue] == 0 ? @"不关联" : [NSString stringWithFormat:@"%@ 条", n]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
            c.contextLines = [n integerValue];
            [c synchronize];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 120, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)confirmClearMemory {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"清除全部记忆" message:@"所有联系人的档案都会删除，不可恢复。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
        [[JGPTMemoryVC store] removeAll];
        [JGPTCommon toast:@"已清除" in:self.view];
        [self.tableView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

@implementation JGPTToneVC

- (instancetype)init {
    if (@available(iOS 13.0, *)) return [super initWithStyle:UITableViewStyleInsetGrouped];
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"话术人设";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [JGPTPrompts toneNames].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSString *name = [JGPTPrompts toneNames][indexPath.row];
    cell.textLabel.text = name;
    cell.accessoryType = [[JGPTConfig shared].tones containsObject:name] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    JGPTConfig *c = [JGPTConfig shared];
    NSString *name = [JGPTPrompts toneNames][indexPath.row];
    NSMutableArray *tones = [c.tones mutableCopy] ?: [NSMutableArray array];
    if ([tones containsObject:name]) [tones removeObject:name];
    else [tones addObject:name];
    c.tones = tones;
    [c synchronize];
    [tableView reloadData];
}

@end
