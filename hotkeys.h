// 自定义快捷键 → 一键打开指定 App
// 用 Carbon RegisterEventHotKey（系统热键分发），实测 macOS 26 可用且不需要「辅助功能」授权
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const HotKeyDefaultsKey;   // UserDefaults 里存条目数组的 key

@interface HotKeyItem : NSObject <NSCopying>
@property(copy)   NSString *identifier;   // UUID，稳定标识
@property(copy)   NSString *name;         // 显示名
@property(copy)   NSString *bundleID;
@property(copy)   NSString *appPath;      // .app 绝对路径
@property(assign) uint32_t  keyCode;      // 0 = 尚未设置
@property(assign) uint32_t  carbonMods;   // cmdKey|optionKey|controlKey|shiftKey
@property(assign) BOOL      registerFailed;
@property(assign) NSUInteger fireCount;      // 运行时统计：收到过多少次按键（用来区分"没送到"和"送到了但失败"）
@property(strong, nullable) NSDate *lastFired;   // 注册失败（多半是被占用）
@property(readonly) NSString *comboString;    // "⌃⌥⌘9"；未设置时是 "未设置"
@property(readonly) BOOL       isConfigured;
+ (nullable instancetype)itemWithDictionary:(NSDictionary *)dict;
- (NSDictionary *)dictionaryValue;
@end

@interface HotKeyManager : NSObject
@property(strong, readonly) NSArray<HotKeyItem *> *items;
@property(readonly, getter=isSuspended) BOOL suspended;   // 设置窗口打开中 → 热键全部挂起
@property(copy, nullable) void (^logger)(NSString *message);

- (void)suspendForSettings;      // 打开设置窗口：全部反注册，避免按键被热键吃掉
- (void)resumeAfterSettings;     // 关闭窗口：重新注册并报告冲突

- (void)reloadItemsWithoutRegistering;   // 只从 UserDefaults 读条目（CLI 用，不抢热键）
- (void)loadFromDefaults;              // 读 UserDefaults 并注册全部
- (void)registerAll;                   // 全部重注册，更新各条目的 registerFailed
- (BOOL)addItemForAppAtURL:(NSURL *)url error:(NSString * _Nullable __autoreleasing * _Nullable)err;
- (BOOL)updateItem:(HotKeyItem *)item withKeyCode:(uint32_t)keyCode mods:(uint32_t)mods
             error:(NSString * _Nullable __autoreleasing * _Nullable)err;
- (void)removeItem:(HotKeyItem *)item;
- (void)launchItem:(HotKeyItem *)item;  // 已运行则激活（顺带取消隐藏），否则启动
- (nullable HotKeyItem *)itemAtIndex:(NSUInteger)index;
@end

@interface HotKeyWindowController : NSWindowController
- (instancetype)initWithManager:(HotKeyManager *)manager;
- (void)showAndActivate;
@end

NS_ASSUME_NONNULL_END
