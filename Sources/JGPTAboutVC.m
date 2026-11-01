#import "JGPTAboutVC.h"
#import <UIKit/UIKit.h>

// 关于页：版本 / 开源地址 / 说明
// 不包含任何联系方式和收款入口。

static NSString * const kAboutRepoURL = @"https://github.com/v200dd/wechat-ai-chat-analysis";
static NSString * const kAboutVersion = @"2.7.6";
static NSString * const kAboutFooter = @"微信 AI 会话分析\n"
                                        @"意图分析 / 建议回复 / 记忆档案 / 画图 / 视频\n"
                                        @"仅供学习与个人研究使用，请遵守微信服务条款。";

@implementation JGPTAboutVC

- (instancetype)init {
    if (@available(iOS 13.0, *)) return [super initWithStyle:UITableViewStyleInsetGrouped];
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"关于";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 3; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"微信 AI 会话分析";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return kAboutFooter;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    switch (indexPath.row) {
        case 0:
            cell.textLabel.text = @"版本";
            cell.detailTextLabel.text = kAboutVersion;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        case 1:
            cell.textLabel.text = @"项目主页";
            cell.detailTextLabel.text = @"GitHub";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        default:
            cell.textLabel.text = @"开源协议";
            cell.detailTextLabel.text = @"MIT";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row != 1) return;
    NSURL *url = [NSURL URLWithString:kAboutRepoURL];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end
