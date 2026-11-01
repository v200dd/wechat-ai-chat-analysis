#import <Foundation/Foundation.h>

@class JGPTJudgeResult;
@class JGPTMemoryNote;

@interface JGPTPrompts : NSObject

+ (NSArray<NSString *> *)toneNames;
+ (NSArray<NSString *> *)riskLevels;
+ (NSArray<NSString *> *)strategies;
+ (NSArray<NSString *> *)actionCandidates;
+ (NSArray<NSString *> *)humanIntents;

+ (NSString *)judgeSystemPrompt;
+ (NSString *)judgeUserPrompt:(NSString *)text
                     history:(NSString *)history
                        note:(JGPTMemoryNote *)note
                     contact:(NSString *)contact
                       group:(BOOL)isGroup;

+ (NSString *)humanReadPrompt:(NSString *)text
                      history:(NSString *)history
                         note:(JGPTMemoryNote *)note
                      contact:(NSString *)contact;

+ (NSString *)draftPrompt:(JGPTJudgeResult *)result
                    note:(JGPTMemoryNote *)note
                 history:(NSString *)history
                    tones:(NSArray<NSString *> *)tones
                  realTone:(BOOL)realTone
                    count:(NSInteger)count;

+ (NSString *)memoryUpdatePrompt:(JGPTMemoryNote *)note
                       transcript:(NSString *)transcript;

+ (NSString *)closingKeywords;

@end
