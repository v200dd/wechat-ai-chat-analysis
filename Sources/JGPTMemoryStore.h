#import <Foundation/Foundation.h>
#import "JGPTModels.h"

@interface JGPTMemoryStore : NSObject

+ (instancetype)shared;

- (JGPTMemoryNote *)noteFor:(NSString *)wxid;
- (void)saveNote:(JGPTMemoryNote *)note;
- (void)removeNoteFor:(NSString *)wxid;
- (void)removeAll;
- (NSArray<JGPTMemoryNote *> *)allNotes;

- (NSArray<NSDictionary *> *)historyFor:(NSString *)wxid;
- (void)appendHistory:(NSArray<NSDictionary *> *)messages for:(NSString *)wxid;
- (void)clearHistoryFor:(NSString *)wxid;
- (NSString *)historyTextFor:(NSString *)wxid limit:(NSInteger)limit;

// 节流：同一个会话 120 秒内只允许总结一次
- (BOOL)shouldSummarize:(NSString *)wxid;

@end
