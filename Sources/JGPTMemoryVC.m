#import "JGPTMemoryVC.h"
#import "JGPTMemoryStore.h"
#import "JGPTConfig.h"
#import "JGPTCommon.h"
#import "JGPTWeChat.h"

@interface JGPTMemoryVC ()
@property (nonatomic, strong) NSArray<JGPTMemoryNote *> *notes;
@end

@implementation JGPTMemoryVC

+ (JGPTMemoryStore *)store { return [JGPTMemoryStore shared]; }
+ (NSNumber *)allCount { return @([[JGPTMemoryStore shared] allNotes].count); }

- (instancetype)init {
    if (@available(iOS 13.0, *)) return [super initWithStyle:UITableViewStyleInsetGrouped];
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"记忆档案";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(reloadNotes)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadNotes];
}

- (void)reloadNotes {
    self.notes = [[JGPTMemoryStore shared] allNotes];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.notes.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.notes.count) return @"还没有档案。收到消息并完成分析后会自动建档。";
    return [NSString stringWithFormat:@"共 %lu 位联系人 · 每轮对话后节流更新（约 2 分钟）", (unsigned long)self.notes.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    JGPTMemoryNote *n = self.notes[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = n.displayName.length ? n.displayName : n.wxid;
    NSMutableArray *sub = [NSMutableArray array];
    if (n.relation.length) [sub addObject:n.relation];
    if (n.theirState.length) [sub addObject:n.theirState];
    if (n.recentSummary.length) [sub addObject:n.recentSummary];
    cell.detailTextLabel.text = [sub componentsJoinedByString:@" · "];
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryNone;

    // 右侧：自动回复开关 + 「第N条 ▸」，和原版一致
    JGPTConfig *c = [JGPTConfig shared];
    BOOL on = [c isSessionOn:n.wxid];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.tag = indexPath.row;
    [sw addTarget:self action:@selector(toggleAutoReply:) forControlEvents:UIControlEventValueChanged];

    UIButton *pick = [UIButton buttonWithType:UIButtonTypeSystem];
    NSInteger idx = [c autoReplyIndexFor:n.wxid];
    [pick setTitle:[NSString stringWithFormat:@"第%ld条 ▸", (long)(idx + 1)] forState:UIControlStateNormal];
    pick.titleLabel.font = [UIFont systemFontOfSize:12];
    pick.tag = indexPath.row;
    pick.hidden = !on;
    [pick addTarget:self action:@selector(pickReplyIndex:) forControlEvents:UIControlEventTouchUpInside];
    [pick sizeToFit];
    pick.frame = CGRectMake(0, 0, MAX(64, pick.bounds.size.width + 8), 30);

    CGFloat swW = 51;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, swW + pick.frame.size.width + 6, 32)];
    sw.frame = CGRectMake(0, 1, swW, 30);
    pick.frame = CGRectMake(swW + 6, 1, pick.frame.size.width, 30);
    [box addSubview:sw];
    [box addSubview:pick];
    cell.accessoryView = box;
    return cell;
}

- (void)pickReplyIndex:(UIButton *)sender {
    if (sender.tag >= (NSInteger)self.notes.count) return;
    JGPTMemoryNote *n = self.notes[sender.tag];
    JGPTConfig *c = [JGPTConfig shared];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"自动发第几条"
                                                              message:n.displayName.length ? n.displayName : n.wxid
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < 4; i++) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"第 %ld 条", (long)(i + 1)]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
            [c setAutoReplyIndex:i for:n.wxid];
            [self.tableView reloadData];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = sender;
    a.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)toggleAutoReply:(UISwitch *)sw {
    if (sw.tag >= (NSInteger)self.notes.count) return;
    JGPTMemoryNote *n = self.notes[sw.tag];
    JGPTConfig *c = [JGPTConfig shared];
    [c setSession:n.wxid on:sw.isOn];
    // 打开某个联系人＝允许它自动回复；总开关只是兜底
    if (sw.isOn && !c.autoReplyEnabled) {
        c.autoReplyEnabled = YES;
        [c synchronize];
    }
    [JGPTCommon toast:sw.isOn ? @"已开启本会话" : @"已关闭本会话" in:self.view];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    JGPTMemoryNote *n = self.notes[indexPath.row];
    [self.navigationController pushViewController:[[JGPTMemoryDetailVC alloc] initWithWxid:n.wxid] animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    JGPTMemoryNote *n = self.notes[indexPath.row];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除档案"
                                                              message:[NSString stringWithFormat:@"确定删除「%@」的相处笔记？", n.displayName ?: n.wxid]
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
        [[JGPTMemoryStore shared] removeNoteFor:n.wxid];
        [[JGPTConfig shared] clearSession:n.wxid];
        [self reloadNotes];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

@implementation JGPTMemoryListVC
@end

@interface JGPTMemoryDetailVC ()
@property (nonatomic, strong) JGPTMemoryNote *note;
@property (nonatomic, strong) NSArray<NSString *> *keys;
@property (nonatomic, strong) NSArray<NSString *> *titles;
@end

@implementation JGPTMemoryDetailVC

- (instancetype)initWithWxid:(NSString *)wxid {
    if (@available(iOS 13.0, *)) self = [super initWithStyle:UITableViewStyleInsetGrouped];
    else self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) _wxid = [wxid copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.note = [[JGPTMemoryStore shared] noteFor:self.wxid];
    self.title = self.note.displayName.length ? self.note.displayName : @"相处笔记";
    self.keys = @[@"relation", @"about", @"between", @"topics", @"recent",
                  @"recentSummary", @"theirState", @"promises", @"portrait", @"myStyle"];
    self.titles = @[@"我们之间", @"这是 TA", @"关系定位", @"长期话题", @"近期动态",
                    @"动态小结", @"TA 最近", @"待办承诺", @"画像小结", @"我的习惯"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"编辑"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(editCurrent)];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : self.keys.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"联系人" : @"相处笔记";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"称呼";
            cell.detailTextLabel.text = self.note.displayName ?: self.wxid;
        } else {
            cell.textLabel.text = @"性别";
            cell.detailTextLabel.text = self.note.gender.length ? self.note.gender : @"未知";
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSString *value = [self.note valueForKey:self.keys[indexPath.row]];
    cell.textLabel.text = self.titles[indexPath.row];
    cell.detailTextLabel.text = value.length ? value : @"—";
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) return;
    NSString *key = self.keys[indexPath.row];
    NSString *value = [self.note valueForKey:key];
    [JGPTCommon input:self.titles[indexPath.row] value:value in:self done:^(NSString *text) {
        [self.note setValue:text forKey:key];
        [[JGPTMemoryStore shared] saveNote:self.note];
        [self.tableView reloadData];
    }];
}

- (void)editCurrent {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"编辑档案" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < (NSInteger)self.keys.count; i++) {
        NSString *key = self.keys[i];
        [a addAction:[UIAlertAction actionWithTitle:self.titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [JGPTCommon input:self.titles[i] value:[self.note valueForKey:key] in:self done:^(NSString *text) {
                [self.note setValue:text forKey:key];
                [[JGPTMemoryStore shared] saveNote:self.note];
                [self.tableView reloadData];
            }];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:a animated:YES completion:nil];
}

@end
