#import <UIKit/UIKit.h>
#import "JGPTModels.h"

@class JGPTMemoryStore;

@interface JGPTMemoryVC : UITableViewController
+ (JGPTMemoryStore *)store;
+ (NSNumber *)allCount;
@end

@interface JGPTMemoryListVC : JGPTMemoryVC
@end

@interface JGPTMemoryDetailVC : UITableViewController
@property (nonatomic, copy) NSString *wxid;
- (instancetype)initWithWxid:(NSString *)wxid;
@end
