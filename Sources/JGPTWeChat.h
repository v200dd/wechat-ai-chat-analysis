#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, JGPTMediaKind) {
    JGPTMediaKindImage = 0,
    JGPTMediaKindVideo = 1,
};

@interface JGPTWeChat : NSObject

+ (instancetype)shared;

- (NSString *)selfWxid;
- (id)service:(NSString *)className;
- (id)msgMgr;
- (id)contactMgr;
- (id)contactFor:(NSString *)wxid;

- (NSString *)displayNameFor:(NSString *)wxid;
- (NSString *)genderFor:(NSString *)wxid;
- (BOOL)isGroup:(NSString *)wxid;

- (id)messageFrom:(NSString *)from
                to:(NSString *)to
             text:(NSString *)text
        isSender:(BOOL)isSender;
- (void)sendText:(NSString *)text to:(NSString *)wxid;
- (void)sendText:(NSString *)text to:(NSString *)wxid quote:(id)quotedWrap;
- (void)sendMediaURLs:(NSArray<NSString *> *)urls kind:(JGPTMediaKind)kind to:(NSString *)wxid caption:(NSString *)caption;

- (NSString *)contentOf:(id)msgWrap;
- (NSString *)fromOf:(id)msgWrap;
- (NSString *)toOf:(id)msgWrap;
- (unsigned int)typeOf:(id)msgWrap;
- (BOOL)isGroupMessage:(id)msgWrap;
- (BOOL)isOutgoing:(id)msgWrap;
- (NSString *)messageKey:(id)msgWrap;

// 记住会话里最近一张图，供「#改图」做图生图参考
- (void)rememberImageFrom:(id)msgWrap chat:(NSString *)chat;
- (UIImage *)lastImageFor:(NSString *)chat;

- (NSString *)chatIDFromController:(UIViewController *)vc;
- (NSString *)chatIDFromWindow:(UIWindow *)win;
- (NSString *)stripGroupSenderPrefix:(NSString *)content;

- (void)registerPluginEntry;
- (void)renameLegacyPluginEntries;

@end
