//
//  probes.h —— 唯一的事实来源（single source of truth）
//
//  为什么单独一层：这次反复踩坑的根源是"信了 API 的自我评价"。实测教训：
//    · -[NSRunningApplication hide] 返回 NO，但目标确实被藏了
//    · -[NSRunningApplication activateWithOptions:] 返回 YES，但 App 并没到前台
//    · RegisterEventHotKey 返回 noErr，但组合键已被别的程序占用，事件永远收不到
//      （而且 Carbon 不报跨进程冲突 —— 连"探针"都测不出来，别再拿它下结论）
//  所以：判断成败只能看系统外部可观测状态 —— 窗口列表、前台 App、进程、崩溃报告。
//  本文件就是这些观测的唯一出口；App 的日志、自检、回归测试全部从这里取数。
//
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 一次窗口快照。只统计"与任一活动屏幕有交集"的窗口 —— 这样原生"显示桌面"
/// 把窗口移到屏幕外时也算已收起，两种模式共用同一套判据。
@interface ProbeSnapshot : NSObject
@property(assign) NSInteger regularWindows;      // 普通 App（不含访达）的窗口数
@property(assign) NSInteger finderWindows;       // 访达浏览窗口数（layer 0）
@property(assign) BOOL desktopLayerAlive;        // 桌面图标层是否还在（证明壁纸/图标没被弄没）
@property(strong) NSArray<NSString *> *regularAppNames;  // 还有哪些普通 App 有窗口
@end

double ProbeIdleSeconds(void);                   // HID 真实无输入秒数；<0 = 读不到
BOOL ProbeAnyDisplayAwake(void);                 // 只要有一块屏亮着就算 YES
BOOL ProbeScreensaverActive(void);

ProbeSnapshot *ProbeWindows(void);

NSString *ProbeFrontmostBundleID(void);          // 读不到时返回 @""
NSString *ProbeFrontmostName(void);

/// 是否有普通 App 的窗口正好铺满整块屏（Keynote 演讲、视频全屏等）
BOOL ProbeHasFullscreenRegularWindow(void);

/// 某个 App（按 bundle id）当前在屏上、且与屏幕有交集的普通层窗口数。
/// 用来验证"hide/activate 到底生效没有"—— 只看事实，不信返回值。
NSInteger ProbeWindowsOwnedBy(NSString *bundleID);

/// 供 --doctor / 回归测试使用：把快照渲染成一行人读文本
NSString *ProbeSnapshotDescription(ProbeSnapshot *snap);

NS_ASSUME_NONNULL_END
