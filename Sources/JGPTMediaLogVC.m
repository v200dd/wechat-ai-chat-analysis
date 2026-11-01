#import "JGPTMediaLogVC.h"
#import "JGPTMediaLog.h"
#import "JGPTCommon.h"

#pragma mark - 单次任务详情

@interface JGPTMediaLogDetailVC ()
@property (nonatomic, strong) NSArray<NSDictionary *> *entries;
@property (nonatomic, copy) NSString *titleText;
@end

@implementation JGPTMediaLogDetailVC

- (instancetype)initWithTask:(NSDictionary *)task {
    if (self = [super initWithStyle:UITableViewStyleInsetGrouped]) {
        _entries = task[@"entries"] ?: @[];
        _titleText = task[@"title"] ?: @"调用";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.titleText;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX((NSInteger)self.entries.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"点一行可复制这一行的详情。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (!self.entries.count) {
        cell.textLabel.text = @"没有记录";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        return cell;
    }
    NSDictionary *e = self.entries[indexPath.row];
    BOOL ok = [e[@"ok"] boolValue];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", ok ? @"✅" : @"❌", e[@"stage"] ?: @""];
    cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    cell.textLabel.textColor = ok ? [UIColor labelColor] : [UIColor systemRedColor];
    NSMutableArray *parts = [NSMutableArray array];
    if ([e[@"t"] length]) [parts addObject:e[@"t"]];
    if ([e[@"text"] length]) [parts addObject:e[@"text"]];
    cell.detailTextLabel.text = [parts componentsJoinedByString:@" · "];
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.entries.count) return;
    NSDictionary *e = self.entries[indexPath.row];
    NSString *detail = e[@"detail"];
    if (!detail.length) return;
    UIPasteboard.generalPasteboard.string = detail;
    [JGPTCommon toast:@"详情已复制" in:self.view];
}

@end

#pragma mark - 任务列表

@implementation JGPTMediaLogVC

- (instancetype)init {
    if (@available(iOS 13.0, *)) return [super initWithStyle:UITableViewStyleInsetGrouped];
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"画图 / 视频调用日记";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(clearAll)];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reload)
                                                 name:JGPTMediaLogChangedNotification
                                               object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)reload { [self.tableView reloadData]; }

- (void)clearAll {
    [JGPTMediaLog clear];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX((NSInteger)[JGPTMediaLog tasks].count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"每次 #画图 / #视频 只显示一行，点开看请求 → 返回 → 下载 → 发送的完整过程。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSDictionary *> *list = [JGPTMediaLog tasks];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (!list.count) {
        cell.textLabel.text = @"还没有记录";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *task = list[indexPath.row];
    BOOL ok = [task[@"ok"] boolValue];
    NSString *title = task[@"title"] ?: @"调用";
    NSInteger count = [task[@"count"] integerValue];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@ · %ld 步", ok ? @"✅" : @"❌", title, (long)count];
    cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    cell.textLabel.textColor = ok ? [UIColor labelColor] : [UIColor systemRedColor];
    NSString *t = task[@"t"] ?: @"";
    NSString *summary = task[@"summary"] ?: @"";
    if (summary.length > 60) summary = [[summary substringToIndex:60] stringByAppendingString:@"…"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@", t, summary];
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<NSDictionary *> *list = [JGPTMediaLog tasks];
    if (indexPath.row >= (NSInteger)list.count) return;
    JGPTMediaLogDetailVC *vc = [[JGPTMediaLogDetailVC alloc] initWithTask:list[indexPath.row]];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
