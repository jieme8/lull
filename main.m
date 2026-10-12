//
//  Lull — 空闲 N 秒后自动显示桌面（隐藏所有 App 的窗口）
//
//  三个关键点：
//    1) 空闲检测：读 IORegistry 里 IOHIDSystem 的 HIDIdleTime（纳秒）。这是系统 HID 层的真实
//       "无键鼠输入"时间，不需要任何隐私授权，也不受我们自己发的事件影响。
//    2) 显示桌面：对每个 activationPolicy == .regular 的 NSRunningApplication 调 hide()。
//       实测 macOS 26：hide() 返回值是 NO（返回值不可信），但目标确实被隐藏了，
//       所以触发后用 CGWindowList 复核屏上窗口数再记日志。
//       全程不需要「辅助功能」/「自动化」授权 —— 这是它比模拟 F11 按键干净的地方。
//    3) 不保存现场：窗口只是隐藏，点 Dock 或 Command-Tab 就原位回来；Finder（桌面/壁纸）永不隐藏。
//
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <ServiceManagement/ServiceManagement.h>
#include <math.h>
#import "icons.h"
#import "hotkeys.h"
#import "showdesktop.h"
#import "probes.h"

static NSString *const KEY_ENABLED         = @"enabled";           // 默认 YES
static NSString *const KEY_THRESHOLD       = @"idleThreshold";     // 秒，默认 120
static NSString *const KEY_SKIP_LOCKED     = @"skipWhenLocked";    // 默认 YES
static NSString *const KEY_SKIP_FULLSCREEN = @"skipWhenFullscreen";// 默认 YES
static NSString *const KEY_WAS_TRUSTED     = @"wasAccessibilityTrusted"; // 上次启动时是否已授权，用来识别"重新编译导致授权失效"
static NSString *const KEY_ICON_STYLE      = @"iconStyle";         // 0 壁纸 / 1 显示器 / 2 进度环
static NSString *const KEY_DESKTOP_MODE    = @"desktopMode";       // 0 隐藏窗口 / 1 原生显示桌面
static NSString *const FINDER_BID          = @"com.apple.finder";  // 桌面本体，永不隐藏

static const NSTimeInterval POLL_INTERVAL = 3.0;   // 轮询间隔 → 触发精度 ±3s

#pragma mark - AppDelegate

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(strong) NSStatusItem *statusItem;
@property(strong) NSTimer *timerRef;
@property(assign) BOOL latched;            // 本轮空闲已经触发过，别重复触发
@property(assign) BOOL suppressionLogged;  // 本轮的跳过原因只写一次日志
@property(assign) BOOL screenLocked;
@property(strong) NSDate *lastTriggerDate;
@property(strong) NSString *lastTriggerSummary;
@property(strong) NSString *lastSkipReason;
@property(assign) double lastIdle;
@property(strong) NSDate *guidanceShownAt;   // 授权引导弹窗的节流时间
@property(strong) NSDate *startedAt;       // 体检警告的静默期基准
@property(strong) HotKeyManager *hotKeys;
@property(strong) HotKeyWindowController *hotKeyWindow;
+ (void)registerDefaults;
- (void)hideEverythingWithReason:(NSString *)reason;
- (void)revealDesktopWithReason:(NSString *)reason manual:(BOOL)manual;
- (void)showAccessibilityGuidance;
- (void)log:(NSString *)msg;
@end

@implementation AppDelegate

#pragma mark 生命周期

+ (void)registerDefaults {
    NSDictionary *defaults = @{ KEY_ENABLED: @YES,
                                KEY_THRESHOLD: @120,
                                KEY_SKIP_LOCKED: @YES,
                                KEY_SKIP_FULLSCREEN: @YES,
                                KEY_WAS_TRUSTED: @NO,
                                KEY_ICON_STYLE: @(IdleIconStyleWallpaper),
                                KEY_DESKTOP_MODE: @(DesktopRevealModeNative) };
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}

/// 注册要早于 didFinishLaunching：分布式通知不排队，App 还没就绪时投递会永久丢失
- (void)applicationWillFinishLaunching:(NSNotification *)note {
    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    [dnc addObserver:self selector:@selector(onScreenLock:)   name:@"com.apple.screenIsLocked"   object:nil];
    [dnc addObserver:self selector:@selector(onScreenUnlock:) name:@"com.apple.screenIsUnlocked" object:nil];
    [dnc addObserver:self selector:@selector(onScreensaverStart:) name:@"com.apple.screensaver.didstart" object:nil];
    [dnc addObserver:self selector:@selector(onScreensaverStop:)  name:@"com.apple.screensaver.didstop"  object:nil];
    // 外部触发入口：CLI（--hide-now / --run-hotkey / --doctor）或快捷指令靠这三条通知驱动常驻实例
    [dnc addObserver:self selector:@selector(onExternalShowDesktop:)
                name:@"com.hujie.lull.showdesktop" object:nil];
    [dnc addObserver:self selector:@selector(onExternalRunHotKey:)
                name:@"com.hujie.lull.runhotkey" object:nil];
    [dnc addObserver:self selector:@selector(onExternalDoctor:)
                name:@"com.hujie.lull.doctor" object:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.startedAt = [NSDate date];
    [[self class] registerDefaults];
    [self setupStatusItem];

    // 自定义快捷键（Carbon 全局热键，不需要辅助功能授权）
    self.hotKeys = [HotKeyManager new];
    __weak typeof(self) weakme = self;
    self.hotKeys.logger = ^(NSString *m) { [weakme log:m]; };
    [self.hotKeys loadFromDefaults];

    self.timerRef = [NSTimer scheduledTimerWithTimeInterval:POLL_INTERVAL
                                                     target:self
                                                   selector:@selector(tick)
                                                   userInfo:nil
                                                    repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.timerRef forMode:NSRunLoopCommonModes];


    double idle = ProbeIdleSeconds();
    [self log:[NSString stringWithFormat:@"启动完成 · 阈值 %.0f 秒 · enabled=%d · 当前空闲 %.1f 秒 · 轮询 %.0fs",
               [self threshold], [self enabled], idle, POLL_INTERVAL]];
    if (idle < 0) [self log:@"警告：读不到 HIDIdleTime，空闲检测不可用"];
    BOOL trusted = DesktopAccessibilityTrusted();
    BOOL wasTrusted = [[NSUserDefaults standardUserDefaults] boolForKey:KEY_WAS_TRUSTED];
    [[NSUserDefaults standardUserDefaults] setBool:trusted forKey:KEY_WAS_TRUSTED];
    [self log:[NSString stringWithFormat:@"显示桌面方式：%@ · 辅助功能：%@ · 快捷键 %lu 条",
               DesktopRevealModeName([self desktopMode]),
               trusted ? @"已授权" : @"未授权（原生模式会自动退回隐藏）",
               (unsigned long)self.hotKeys.items.count]];

    // 上次还在、这次没了 = 重新编译导致签名指纹变化，授权作废 → 主动引导重新授权
    if (!trusted && wasTrusted) {
        [self log:@"检测到辅助功能授权已失效（上次启动时还在）→ 弹出重新授权引导"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self showAccessibilityGuidance]; });
    }
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar]
                       statusItemWithLength:NSVariableStatusItemLength];
    [self updateIcon];

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Lull"];
    menu.delegate = self;
    menu.autoenablesItems = NO;
    self.statusItem.menu = menu;
    [self rebuildMenu];
}

#pragma mark 图标

/// 图标本身带状态：暂停 → 半透明；桌面已露出 → 屏幕框填实；进度环样式还会显示空闲倒计时
- (void)updateIcon {
    if (!self.statusItem) return;
    IdleIconStyle style = (IdleIconStyle)[[NSUserDefaults standardUserDefaults] integerForKey:KEY_ICON_STYLE];
    double need = [self threshold];
    CGFloat progress = need > 0 ? (CGFloat)MIN(1.0, MAX(0.0, self.lastIdle / need)) : 0;
    // NSStatusItem.image 自 10.14 起废弃，正确写法是画在按钮上
    self.statusItem.button.image = IdleIconImage(style, NSMakeSize(18, 18), progress,
                                                  ![self enabled], self.latched);
}

- (void)pickDesktopMode:(id)sender {
    DesktopRevealMode m = (DesktopRevealMode)[(NSMenuItem *)sender tag];
    [[NSUserDefaults standardUserDefaults] setInteger:m forKey:KEY_DESKTOP_MODE];
    [self log:[NSString stringWithFormat:@"显示桌面方式 → %@", DesktopRevealModeName(m)]];
    if (m == DesktopRevealModeNative && !DesktopAccessibilityTrusted()) [self handleAccessibility:nil];
}

- (void)handleAccessibility:(id)s {
    if (DesktopAccessibilityTrusted()) { [self log:@"辅助功能：已授权"]; return; }
    DesktopOpenAccessibilitySettings();
    [self log:@"已打开 系统设置→隐私与安全→辅助功能：勾选 Lull 后，再触发一次即可走原生显示桌面"];
}

- (void)pickIconStyle:(id)sender {
    [[NSUserDefaults standardUserDefaults] setInteger:[(NSMenuItem *)sender tag] forKey:KEY_ICON_STYLE];
    [self updateIcon];
    [self log:[NSString stringWithFormat:@"图标样式 → %@", IdleIconStyleName([(NSMenuItem *)sender tag])]];
}

#pragma mark 配置读写

- (BOOL)enabled          { return [[NSUserDefaults standardUserDefaults] boolForKey:KEY_ENABLED]; }
- (double)threshold      { return MAX(5.0, [[NSUserDefaults standardUserDefaults] doubleForKey:KEY_THRESHOLD]); }
/// 冷却随阈值缩放：固定 25 秒会让"5 秒阈值"形同虚设（触发一次后要等 25 秒才可能再触发）
- (NSTimeInterval)cooldown { return MIN(25.0, MAX(2.0, [self threshold] * 0.5)); }
/// 体检里的"从未收到按键"警告只在运行 10 分钟后才说 —— 重启会把计数清零，刚启动就报警是废话
- (NSTimeInterval)uptime { return -[self.startedAt timeIntervalSinceNow]; }

- (DesktopRevealMode)desktopMode {
    return (DesktopRevealMode)[[NSUserDefaults standardUserDefaults] integerForKey:KEY_DESKTOP_MODE];
}
- (BOOL)skipWhenLocked   { return [[NSUserDefaults standardUserDefaults] boolForKey:KEY_SKIP_LOCKED]; }
- (BOOL)skipWhenFullscreen { return [[NSUserDefaults standardUserDefaults] boolForKey:KEY_SKIP_FULLSCREEN]; }
- (NSString *)selfBundleID { return [[NSBundle mainBundle] bundleIdentifier] ?: @""; }

- (void)setEnabled:(BOOL)on {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:KEY_ENABLED];
    self.latched = NO;
    [self updateIcon];
    [self log:[NSString stringWithFormat:@"%@空闲自动显示桌面", on ? @"启用" : @"暂停"]];
}

- (void)setThreshold:(double)seconds {
    [[NSUserDefaults standardUserDefaults] setDouble:seconds forKey:KEY_THRESHOLD];
    self.latched = NO;
    [self log:[NSString stringWithFormat:@"阈值改为 %.0f 秒", seconds]];
}

#pragma mark 主循环

- (void)tick {
    if (![self enabled]) { self.latched = NO; return; }

    double idle = ProbeIdleSeconds();
    self.lastIdle = idle;
    [self updateIcon];
    if (idle < 0) return;

    double need = [self threshold];

    // 有输入 → idle 归零，解锁触发闸门，下一轮空闲可以再触发
    if (idle < need) { self.latched = NO; self.suppressionLogged = NO; return; }
    if (self.latched) return;

    NSString *skip = [self suppressionReason];
    if (skip) {
        self.lastSkipReason = skip;
        if (!self.suppressionLogged) {
            [self log:[NSString stringWithFormat:@"空闲 %.0fs ≥ 阈值 %.0fs，但跳过：%@", idle, need, skip]];
            self.suppressionLogged = YES;
        }
        return;
    }

    self.latched = YES;  // 无论下面是否真的隐藏到什么，本轮都不再尝试，避免刷屏

    NSTimeInterval cooldown = [self cooldown];
    if (self.lastTriggerDate && -[self.lastTriggerDate timeIntervalSinceNow] < cooldown) {
        [self log:[NSString stringWithFormat:@"空闲 %.0fs 达阈值，但在冷却期内（还差 %.0fs），本轮跳过",
                   idle, cooldown - -[self.lastTriggerDate timeIntervalSinceNow]]];
        return;
    }
    [self revealDesktopWithReason:[NSString stringWithFormat:@"空闲 %.0fs ≥ %.0fs", idle, need] manual:NO];
}

- (NSString *)suppressionReason {
    if ([self skipWhenLocked] && self.screenLocked) return @"屏幕已锁定";
    if ([self skipWhenLocked] && ProbeScreensaverActive()) return @"屏保运行中";
    if ([self skipWhenLocked] && !ProbeAnyDisplayAwake()) return @"显示器已睡眠";
    if ([self skipWhenFullscreen] && ProbeHasFullscreenRegularWindow()) return @"有全屏显示的 App";
    return nil;
}

#pragma mark 动作：显示桌面

/// 按当前模式分派。原生模式没授权时退回隐藏模式，而不是什么都不做
- (void)revealDesktopWithReason:(NSString *)reason manual:(BOOL)manual {
    BOOL needGuidance = NO;
    if ([self desktopMode] == DesktopRevealModeNative) {
        NSString *why = nil;
        if (DesktopPostShowDesktopKey(&why)) {
            self.lastTriggerDate = [NSDate date];
            [self updateIcon];
            self.lastTriggerSummary = @"原生显示桌面（窗口移开，再按一次 F11 或点任意窗口就回来）";
            [self log:[NSString stringWithFormat:@"%@ → %@", reason, self.lastTriggerSummary]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self verifyDesktopVisible]; });
            return;
        }
        [self log:[NSString stringWithFormat:@"%@ → 原生模式不可用（%@），本次退回隐藏窗口",
                   reason, why ?: @"未知原因"]];
        // 只有用户主动触发时才引导；空闲自动触发时人不在电脑前，弹了也没用
        needGuidance = manual;
    }
    [self hideEverythingWithReason:reason];
    if (needGuidance) [self showAccessibilityGuidance];   // 先把桌面显示出来，再谈授权
}

/// 授权失效/缺失时的引导。60 秒内只弹一次，避免反复打扰
- (void)showAccessibilityGuidance {
    if (DesktopAccessibilityTrusted()) return;
    if (self.guidanceShownAt && -[self.guidanceShownAt timeIntervalSinceNow] < 60) return;
    self.guidanceShownAt = [NSDate date];

    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *al = [NSAlert new];
    al.alertStyle = NSAlertStyleWarning;
    al.messageText = @"辅助功能授权失效了";
    al.informativeText =
        @"「原生显示桌面」需要发一次系统 F11 按键，这要求辅助功能权限。\n"
        @"重新编译会改变 App 的代码签名指纹，macOS 会把它当成一个新程序，旧授权自动作废。\n\n"
        @"点「去授权」会打开 系统设置 → 隐私与安全 → 辅助功能：把 Lull 勾上"
        @"（若它已在列表里但没生效，先把开关关掉再打开）。授权后不用重启，"
        @"用菜单里的「立即显示桌面」即可验证。";
    [al addButtonWithTitle:@"去授权"];
    [al addButtonWithTitle:@"改用隐藏窗口模式"];
    if ([al runModal] == NSAlertFirstButtonReturn) {
        DesktopOpenAccessibilitySettings();
        [self log:@"已打开 系统设置→隐私与安全→辅助功能，等待勾选"];
    } else {
        [[NSUserDefaults standardUserDefaults] setInteger:DesktopRevealModeHide forKey:KEY_DESKTOP_MODE];
        [self log:@"用户暂不授权 → 显示桌面方式已切换为隐藏所有窗口"];
    }
}

- (void)hideEverythingWithReason:(NSString *)reason {
    NSArray<NSRunningApplication *> *apps = [NSWorkspace sharedWorkspace].runningApplications;
    NSString *mine = [self selfBundleID];

    NSMutableArray<NSString *> *hidden = [NSMutableArray array];

    // 访达永远不藏 —— 这是实测出来的：系统必须留一个普通 App 当前台来显示桌面。
    // 让访达当这个前台，桌面就是干净的；一旦把访达也藏掉，系统只能复活某个真实 App 的窗口，
    // 而且补藏第二轮会在访达和该 App 之间来回跳（8 轮实验不收敛）。
    // 代价：访达自己的浏览窗口会留在屏幕上（要连它一起移开只能走原生"显示桌面"，需要辅助功能授权）。
    for (NSRunningApplication *a in apps) {
        if (a.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        NSString *bid = a.bundleIdentifier ?: @"";
        if ([bid isEqualToString:mine]) continue;                 // 自己是菜单栏 App
        if ([bid isEqualToString:FINDER_BID]) continue;           // 见上
        if (a.isHidden) continue;                                 // 本来就藏着
        [a hide];                                                 // 返回值不可信，忽略
        [hidden addObject:(a.localizedName.length ? a.localizedName : bid)];
    }

    self.lastTriggerDate = [NSDate date];
    [self updateIcon];   // 图标进入"已露出桌面"的实心态

    if (hidden.count == 0) {
        self.lastTriggerSummary = @"无需隐藏（桌面已经干净）";
        [self log:[NSString stringWithFormat:@"%@ → 无需隐藏", reason]];
        return;
    }

    self.lastTriggerSummary = [NSString stringWithFormat:@"隐藏 %lu 个：%@",
                               (unsigned long)hidden.count,
                               [hidden componentsJoinedByString:@"、"]];
    [self log:[NSString stringWithFormat:@"%@ → %@", reason, self.lastTriggerSummary]];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self verifyDesktopVisible]; });
}

/// 桌面到底露出来没有 —— 只认 probes 观测到的事实，不看任何 API 返回值
- (NSString *)desktopVerdict {
    ProbeSnapshot *s = ProbeWindows();
    NSArray<NSString *> *stubborn = ProbeStubbornAppNames();   // 已 hidden 但窗口赖着不走的
    if (s.regularWindows > 0) {
        NSMutableString *msg = [NSMutableString stringWithFormat:@"  ✗ 仍有 %ld 个窗口未收起（%@）",
                                (long)s.regularWindows, [s.regularAppNames componentsJoinedByString:@"、"]];
        if (stubborn.count)
            [msg appendFormat:@"\n    %@：已 hide 成功，是它自己不让窗口走（unhide 再 hide 也按不住）"
                              " —— 这类抗隐藏窗口只有原生「显示桌面」能移开",
             [stubborn componentsJoinedByString:@"、"]];
        return msg;
    }
    NSMutableString *msg = [NSMutableString stringWithString:@"  ✓ 桌面已露出"];
    if (s.finderWindows) [msg appendFormat:@"（访达剩 %ld 个窗口：系统必须留一个前台 App）", (long)s.finderWindows];
    if (!s.desktopLayerAlive) [msg appendString:@"  ✗ 桌面图标层没了！"];   // 藏过头的警报
    return msg;
}

- (void)verifyDesktopVisible {
    double idle = ProbeIdleSeconds();
    if (idle < 1.5) { [self log:@"  复核跳过：你已经开始操作了"]; return; }
    [self log:[self desktopVerdict]];
}

#pragma mark 锁屏/屏保通知

- (void)onScreenLock:(id)s    { self.screenLocked = YES; self.latched = NO; [self log:@"锁屏：暂停触发"]; }
- (void)onScreenUnlock:(id)s  { self.screenLocked = NO; self.latched = NO; self.suppressionLogged = NO; [self log:@"解锁：恢复触发"]; }
- (void)onScreensaverStart:(id)s { [self log:@"屏保开始"]; }
- (void)onScreensaverStop:(id)s  { self.latched = NO; self.suppressionLogged = NO; }

- (void)onExternalShowDesktop:(id)s {
    self.latched = YES;
    [self revealDesktopWithReason:@"外部通知" manual:YES];
}

- (void)onExternalRunHotKey:(NSNotification *)n {
    NSInteger idx = [n.object integerValue] - 1;
    HotKeyItem *it = (idx >= 0) ? [self.hotKeys itemAtIndex:(NSUInteger)idx] : nil;
    if (!it) { [self log:[NSString stringWithFormat:@"外部请求打开第 %@ 条：不存在", n.object]]; return; }
    [self log:[NSString stringWithFormat:@"外部请求打开第 %@ 条 → %@（%@）", n.object, it.name, it.comboString]];
    [self.hotKeys launchItem:it];
}

#pragma mark 体检报告

/// 常驻实例把体检结果写到这里，CLI --doctor 轮询读取（这样能拿到只有进程内才知道的状态）
static NSString *DoctorReportPath(void) {
    NSString *lib = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    return [[lib stringByAppendingPathComponent:@"Logs"] stringByAppendingPathComponent:@"Lull-doctor.txt"];
}

- (void)onExternalDoctor:(NSNotification *)n {
    NSString *report = [self doctorReport];
    // CLI 用 nonce 确认这份报告是为它这次请求写的 —— 文件 mtime 只有秒级精度，不能用来判新旧
    NSString *nonce = [n.object isKindOfClass:NSString.class] ? n.object : nil;
    if (nonce.length) report = [report stringByAppendingFormat:@"nonce=%@\n", nonce];
    NSString *path = DoctorReportPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                               withIntermediateDirectories:YES attributes:nil error:nil];
    [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self log:@"体检报告已生成"];
}

- (NSString *)doctorReport {
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm:ss";
    BOOL trusted = DesktopAccessibilityTrusted();
    double idle = ProbeIdleSeconds();
    ProbeSnapshot *snap = ProbeWindows();
    NSMutableString *r = [NSMutableString string];

    [r appendFormat:@"Lull 体检 · %@ · pid %d\n", [df stringFromDate:[NSDate date]], getpid()];
    [r appendFormat:@"显示桌面方式：%@ · 辅助功能：%@\n",
       DesktopRevealModeName([self desktopMode]), trusted ? @"已授权" : @"未授权"];
    [r appendFormat:@"空闲检测：%@ · 当前 %.1fs · 阈值 %.0fs · 总开关 %@\n",
       idle >= 0 ? @"可读" : @"✗ 读不到 HIDIdleTime", idle, [self threshold], [self enabled] ? @"开" : @"关"];
    [r appendFormat:@"保护：锁屏/屏保/息屏=%@ · 全屏 App=%@\n",
       [self skipWhenLocked] ? @"开" : @"关", [self skipWhenFullscreen] ? @"开" : @"关"];
    [r appendFormat:@"闸门：latched=%d · 上次触发 %@ · %@\n", self.latched,
       self.lastTriggerDate ? [df stringFromDate:self.lastTriggerDate] : @"从未",
       self.lastTriggerSummary ?: @"（无记录）"];
    [r appendFormat:@"快捷键：%@ · 共 %lu 条\n", self.hotKeys.isSuspended ? @"挂起中（设置窗口开着）" : @"在册",
       (unsigned long)self.hotKeys.items.count];

    for (NSUInteger i = 0; i < self.hotKeys.items.count; i++) {
        HotKeyItem *it = self.hotKeys.items[i];
        BOOL pathOK = it.appPath.length && [[NSFileManager defaultManager] fileExistsAtPath:it.appPath];
        BOOL bidOK  = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:it.bundleID] != nil;
        [r appendFormat:@"  #%lu %@ %@｜触发 %lu 次｜路径 %@｜bundleID %@\n", (unsigned long)(i + 1),
         it.comboString, it.name, (unsigned long)it.fireCount,
         pathOK ? @"OK" : (bidOK ? @"已失效(可自愈)" : @"✗ 找不到"), bidOK ? @"OK" : @"✗"];
    }
    [r appendFormat:@"窗口快照：%@\n", ProbeSnapshotDescription(snap)];
    NSArray<NSString *> *stubborn = ProbeStubbornAppNames();
    if (stubborn.count) [r appendFormat:@"抗隐藏残留：%@\n", [stubborn componentsJoinedByString:@"、"]];

    NSMutableArray<NSString *> *warn = [NSMutableArray array];
    if ([self desktopMode] == DesktopRevealModeNative && !trusted)
        [warn addObject:@"原生模式未授权 → 触发时会自动退回隐藏窗口"];
    for (HotKeyItem *it in self.hotKeys.items) {
        if (![it isConfigured]) { [warn addObject:[NSString stringWithFormat:@"%@ 还没设组合键", it.name]]; continue; }
        if (it.registerFailed) [warn addObject:[NSString stringWithFormat:@"%@ 的 %@ 注册失败", it.name, it.comboString]];
        else if (!it.fireCount && !self.hotKeys.isSuspended && [self uptime] > 600)
            [warn addObject:[NSString stringWithFormat:@"%@ 的 %@ 本次启动后还没收到过按键（重启会清零；"
                                                       @"若你确实按过，就是组合键被别的程序占了 —— Carbon 不报冲突）",
                                                    it.name, it.comboString]];
    }
    if (snap.regularWindows == 0 && !snap.desktopLayerAlive) [warn addObject:@"桌面图标层消失 = 藏过头了"];
    if (stubborn.count)
        [warn addObject:[NSString stringWithFormat:@"%@ 抗隐藏（hide 成功但窗口不走）→ 用原生显示桌面才能移开",
                                          [stubborn componentsJoinedByString:@"、"]]];

    [r appendString:warn.count
        ? [NSString stringWithFormat:@"自检结论：\n  ⚠ %@\n", [warn componentsJoinedByString:@"\n  ⚠ "]]
        : @"自检结论：一切正常\n"];
    return r;
}

#pragma mark 菜单

- (NSString *)statusLine {
    NSString *idleStr = self.lastIdle >= 0 ? [NSString stringWithFormat:@"%.0fs", self.lastIdle] : @"?";
    NSString *head = [NSString stringWithFormat:@"%@ · 阈值 %.0fs · 当前空闲 %@",
                      [self enabled] ? @"● 运行中" : @"○ 已暂停", [self threshold], idleStr];
    NSMutableArray *parts = [NSMutableArray arrayWithObject:head];
    if (self.lastTriggerSummary) {
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm";
        [parts addObject:[NSString stringWithFormat:@"上次 %@ %@",
                          [df stringFromDate:self.lastTriggerDate], self.lastTriggerSummary]];
    }
    return [parts componentsJoinedByString:@"\n"];
}

- (void)menuNeedsUpdate:(NSMenu *)menu { [self rebuildMenu]; }

- (void)rebuildMenu {
    NSMenu *menu = self.statusItem.menu;
    [menu removeAllItems];

    NSMenuItem *info = [self itemWith:self.statusLine action:NULL];
    info.enabled = NO;
    [menu addItem:info];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *enable = [self itemWith:@"空闲自动显示桌面" action:@selector(toggleEnabled:)];
    enable.state = [self enabled] ? NSControlStateValueOn : NSControlStateValueOff;
    enable.keyEquivalent = @"e";
    enable.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [menu addItem:enable];

    NSMenuItem *now = [self itemWith:@"立即显示桌面" action:@selector(showNow:)];
    now.keyEquivalent = @"d";
    now.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [menu addItem:now];

    [menu addItem:NSMenuItem.separatorItem];

    // 阈值
    NSMenuItem *thItem = [self itemWith:[NSString stringWithFormat:@"触发阈值：%.0f 秒", [self threshold]] action:NULL];
    NSMenu *thMenu = [[NSMenu alloc] init];
    thMenu.autoenablesItems = NO;
    NSArray *presets = @[@5, @30, @60, @120, @180, @300, @600];
    NSArray *labels = @[@"5 秒（测试用）", @"30 秒", @"1 分钟", @"2 分钟", @"3 分钟", @"5 分钟", @"10 分钟"];
    for (NSUInteger i = 0; i < presets.count; i++) {
        double v = [presets[i] doubleValue];
        NSMenuItem *mi = [self itemWith:labels[i] action:@selector(pickThreshold:)];
        mi.tag = (NSInteger)v;
        mi.state = (fabs([self threshold] - v) < 0.5) ? NSControlStateValueOn : NSControlStateValueOff;
        [thMenu addItem:mi];
    }
    thItem.submenu = thMenu;
    [menu addItem:thItem];

    // 保护开关
    NSMenuItem *sk1 = [self itemWith:@"锁屏 / 屏保 / 息屏时不触发" action:@selector(toggleSkipLocked:)];
    sk1.state = [self skipWhenLocked] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:sk1];

    NSMenuItem *sk2 = [self itemWith:@"有全屏 App 时不触发" action:@selector(toggleSkipFullscreen:)];
    sk2.state = [self skipWhenFullscreen] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:sk2];

    // 图标样式（每个选项左侧直接放预览图，菜单里就能看到效果）
    IdleIconStyle cur = (IdleIconStyle)[[NSUserDefaults standardUserDefaults] integerForKey:KEY_ICON_STYLE];
    NSMenuItem *iconItem = [self itemWith:[NSString stringWithFormat:@"图标样式：%@", IdleIconStyleName(cur)] action:NULL];
    NSMenu *iconMenu = [[NSMenu alloc] init];
    iconMenu.autoenablesItems = NO;
    NSArray *styles = @[@(IdleIconStyleWallpaper), @(IdleIconStyleMonitor), @(IdleIconStyleRing)];
    NSArray *iconLabels = @[@"壁纸（屏幕+地平线+太阳）", @"显示器（屏幕+支架）", @"进度环（含空闲倒计时）"];
    for (NSUInteger i = 0; i < styles.count; i++) {
        NSInteger v = [styles[i] integerValue];
        NSMenuItem *mi = [self itemWith:iconLabels[i] action:@selector(pickIconStyle:)];
        mi.tag = v;
        mi.state = (cur == v) ? NSControlStateValueOn : NSControlStateValueOff;
        mi.image = IdleIconImage((IdleIconStyle)v, NSMakeSize(18, 18), v == IdleIconStyleRing ? 0.55 : 0, NO, NO);
        [iconMenu addItem:mi];
    }
    iconItem.submenu = iconMenu;
    [menu addItem:iconItem];

    // 显示桌面方式
    DesktopRevealMode mode = [self desktopMode];
    NSMenuItem *modeItem = [self itemWith:[NSString stringWithFormat:@"显示桌面方式：%@",
                                           DesktopRevealModeName(mode)] action:NULL];
    NSMenu *modeMenu = [[NSMenu alloc] init];
    modeMenu.autoenablesItems = NO;
    NSArray *modeDefs = @[ @((NSInteger)DesktopRevealModeNative), @((NSInteger)DesktopRevealModeHide) ];
    NSArray *modeLabels = @[ @"原生显示桌面（等同按 F11，需辅助功能）",
                             @"隐藏所有窗口（零权限，访达窗口会留下）" ];
    for (NSUInteger i = 0; i < modeDefs.count; i++) {
        NSInteger v = [modeDefs[i] integerValue];
        NSMenuItem *mi = [self itemWith:modeLabels[i] action:@selector(pickDesktopMode:)];
        mi.tag = v;
        mi.state = (mode == (DesktopRevealMode)v) ? NSControlStateValueOn : NSControlStateValueOff;
        [modeMenu addItem:mi];
    }
    [modeMenu addItem:NSMenuItem.separatorItem];
    BOOL trusted = DesktopAccessibilityTrusted();
    BOOL hadTrust = [[NSUserDefaults standardUserDefaults] boolForKey:KEY_WAS_TRUSTED];
    NSString *permTitle = trusted ? @"辅助功能：已授权 ✓"
                          : (hadTrust ? @"辅助功能：上次授权已失效 — 点此重新授权"
                                      : @"辅助功能：未授权 — 点此去勾选");
    NSMenuItem *perm = [self itemWith:permTitle action:@selector(handleAccessibility:)];
    [modeMenu addItem:perm];
    modeItem.submenu = modeMenu;
    [menu addItem:modeItem];

    // 快捷键
    NSUInteger hkCount = self.hotKeys.items.count;
    NSMenuItem *hkItem = [self itemWith:[NSString stringWithFormat:@"自定义快捷键…（已配 %lu 条）",
                                         (unsigned long)hkCount] action:@selector(openHotKeys:)];
    hkItem.keyEquivalent = @",";
    hkItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [menu addItem:hkItem];

    if (hkCount) {
        NSMenuItem *hkRun = [self itemWith:@"打开已绑定的 App" action:NULL];
        NSMenu *sub = [[NSMenu alloc] init];
        sub.autoenablesItems = NO;
        for (HotKeyItem *it in self.hotKeys.items) {
            NSString *title = [NSString stringWithFormat:@"%@    %@", it.comboString, it.name];
            if (it.registerFailed) title = [title stringByAppendingString:@"    ⚠ 被占用"];
            NSMenuItem *mi = [self itemWith:title action:@selector(runHotKeyItem:)];
            mi.representedObject = it;
            [sub addItem:mi];
        }
        hkRun.submenu = sub;
        [menu addItem:hkRun];
    }

    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *boot = [self itemWith:@"开机自启" action:@selector(toggleAutostart:)];
    boot.state = [self autostartEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    boot.toolTip = @"通过 macOS SMAppService 注册登录项";
    [menu addItem:boot];

    [menu addItem:[self itemWith:@"打开日志（~/Library/Logs/Lull.log）" action:@selector(openLog:)]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self itemWith:@"退出" action:@selector(quit:)]];
}

- (NSMenuItem *)itemWith:(NSString *)title action:(SEL)action {
    NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:title
                                                action:action
                                         keyEquivalent:@""];
    mi.target = self;
    return mi;
}

#pragma mark 菜单动作

- (void)toggleEnabled:(id)s      { [self setEnabled:![self enabled]]; }
- (void)pickThreshold:(id)s      { [self setThreshold:[(NSMenuItem *)s tag]]; }
- (void)showNow:(id)s            { [self revealDesktopWithReason:@"手动触发" manual:YES]; self.latched = YES; }

- (void)openHotKeys:(id)s {
    if (!self.hotKeyWindow)
        self.hotKeyWindow = [[HotKeyWindowController alloc] initWithManager:self.hotKeys];
    [self.hotKeyWindow showAndActivate];
}

- (void)runHotKeyItem:(id)s      { [self.hotKeys launchItem:[(NSMenuItem *)s representedObject]]; }
- (void)toggleSkipLocked:(id)s   { [[NSUserDefaults standardUserDefaults] setBool:![self skipWhenLocked] forKey:KEY_SKIP_LOCKED]; }
- (void)toggleSkipFullscreen:(id)s { [[NSUserDefaults standardUserDefaults] setBool:![self skipWhenFullscreen] forKey:KEY_SKIP_FULLSCREEN]; }

#pragma mark 开机自启

- (BOOL)autostartEnabled {
    if (@available(macOS 13.0, *)) { return [SMAppService mainAppService].status == SMAppServiceStatusEnabled; }
    return NO;
}

- (void)toggleAutostart:(id)s {
    NSAlert *alert = [NSAlert new];
    if (@available(macOS 13.0, *)) {
        NSError *err = nil;
        BOOL on = [self autostartEnabled];
        BOOL ok = on ? [[SMAppService mainAppService] unregisterAndReturnError:&err]
                     : [[SMAppService mainAppService] registerAndReturnError:&err];
        [self log:[NSString stringWithFormat:@"开机自启 %@ → %@", on ? @"关闭" : @"开启",
                   ok ? @"成功" : [NSString stringWithFormat:@"失败：%@ (code %ld)",
                                   err.localizedDescription ?: @"?", (long)err.code]]];
        if (ok) return;
        alert.messageText = @"开机自启设置失败";
        alert.informativeText = [NSString stringWithFormat:@"%@\n\n可以手动在 系统设置 → 通用 → 登录项 里添加 Lull。",
                                 err.localizedDescription ?: @"未知错误"];
    } else {
        alert.messageText = @"需要 macOS 13 或更高";
        alert.informativeText = @"当前系统不支持 SMAppService 登录项。";
    }
    [alert runModal];
}

- (void)openLog:(id)s {
    NSString *p = [self logPath];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:p]];
}

- (void)quit:(id)s { [NSApp terminate:nil]; }

#pragma mark 日志

- (NSString *)logPath {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    dir = [dir stringByAppendingPathComponent:@"Logs"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"Lull.log"];
}

- (void)log:(NSString *)msg {
    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss"; }
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
    NSLog(@"%@", [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);

    NSString *path = [self logPath];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { [[line dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:NO]; return; }
    @try {
        unsigned long long sizeBefore = [fh seekToEndOfFile];   // 追到末尾，返回值就是原长度
        if (sizeBefore > 256 * 1024) {  // 超过 256KB 就重开，避免无限增长
            [fh closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            [[line dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:NO];
            return;
        }
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *e) {
    } @finally {
        [fh closeFile];
    }
}
@end

static BOOL ResidentInstanceExists(void) {
    for (NSRunningApplication *a in [NSWorkspace sharedWorkspace].runningApplications)
        if ([a.bundleIdentifier isEqualToString:@"com.hujie.lull"]
            && a.processIdentifier != getpid()) return YES;
    return NO;
}

static void PostResidentCommand(NSString *name, NSString *object) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(),
            (__bridge CFStringRef)name, (__bridge CFStringRef)object, NULL, true);
}

/// 从 bundle 内的二进制直接调用，方便无 UI 场景（快捷指令 / 键盘快捷键 / 脚本）验证与使用：
///   Lull --autostart on|off     注册或取消登录项（SMAppService）
///   Lull --hide-now             立即显示桌面（按当前模式）
static NSString *ValueAfterFlag(int argc, const char *argv[], const char *flag, BOOL needsValue) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], flag) == 0) {
            if (!needsValue) return @"1";
            if (i + 1 < argc) return [NSString stringWithUTF8String:argv[i + 1]];
            return @"";
        }
    }
    return nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *delegate = [AppDelegate new];
        NSApp.delegate = delegate;
        [AppDelegate registerDefaults];   // CLI 分支不经过 applicationDidFinishLaunching，阈值/模式等默认值必须先加载

        // —— 登录项 ——
        NSString *autostart = ValueAfterFlag(argc, argv, "--autostart", YES);
        if (autostart) {
            if (@available(macOS 13.0, *)) {
                NSError *err = nil;
                BOOL turnOn = [autostart isEqualToString:@"on"] || [autostart isEqualToString:@"1"];
                BOOL ok = turnOn ? [[SMAppService mainAppService] registerAndReturnError:&err]
                                 : [[SMAppService mainAppService] unregisterAndReturnError:&err];
                SMAppServiceStatus st = [SMAppService mainAppService].status;
                printf("autostart=%s ok=%d status=%ld (%s)\n",
                       turnOn ? "on" : "off", ok, (long)st,
                       (err.localizedDescription ?: (st == SMAppServiceStatusEnabled ? @"已注册" : @"未注册")).UTF8String);
                if (!ok && err) printf("error: %s\n", err.localizedDescription.UTF8String);
                return ok ? 0 : 1;
            }
            printf("需要 macOS 13+\n");
            return 1;
        }

        // —— 立即显示桌面 ——
        if (ValueAfterFlag(argc, argv, "--hide-now", NO)) {
            // 有常驻实例就交给它执行：CLI 自己藏的话，进程退出时系统会把父 App 重新前置，
            // 复核结果会被这个假象污染。
            if (ResidentInstanceExists()) {
                PostResidentCommand(@"com.hujie.lull.showdesktop", nil);
                printf("已向常驻实例发出「显示桌面」请求（结果见日志）\n");
            } else {
                [delegate revealDesktopWithReason:@"命令行 --hide-now" manual:YES];
            }
            for (int i = 0; i < 30; i++) {   // 等复核块跑完
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
            return 0;
        }

        // —— 体检：让常驻实例写报告，CLI 用 nonce 确认是为本次请求写的 ——
        if (ValueAfterFlag(argc, argv, "--doctor", NO)) {
            NSString *path = DoctorReportPath();
            NSString *nonce = [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970 * 1000];
            NSString *marker = [@"nonce=" stringByAppendingString:nonce];
            if (!ResidentInstanceExists()) {
                printf("常驻实例没在运行 —— 先打开 Lull 再体检\n");
                return 1;
            }
            PostResidentCommand(@"com.hujie.lull.doctor", nonce);
            for (int i = 0; i < 50; i++) {   // 最多等 5 秒
                NSString *rep = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
                if ([rep containsString:marker]) {
                    NSRange at = [rep rangeOfString:@"nonce="];   // nonce 是内部握手用的小尾巴，不给人看
                    if (at.location != NSNotFound) rep = [rep substringToIndex:at.location];
                    printf("%s", rep.UTF8String);
                    return 0;
                }
                // 分布式通知不排队：App 刚启动、观察者还没注册上时那次投递就永久丢了，所以要重发
                if (i && i % 15 == 0) PostResidentCommand(@"com.hujie.lull.doctor", nonce);
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
            printf("常驻实例 5 秒内没响应体检 —— 拒绝打印可能过期的旧报告\n");
            return 1;
        }


        // —— 快捷键：列出 / 按序号打开（不注册热键，避免和 GUI 实例抢）——
        HotKeyManager *hk = [HotKeyManager new];
        hk.logger = ^(NSString *m) { printf("  · %s\n", m.UTF8String); };
        [hk reloadItemsWithoutRegistering];

        if (ValueAfterFlag(argc, argv, "--list-hotkeys", NO)) {
            NSArray<HotKeyItem *> *items = hk.items;
            if (!items.count) printf("（还没有配置。启动 App 后在菜单栏选「自定义快捷键…」）\n");
            [items enumerateObjectsUsingBlock:^(HotKeyItem *it, NSUInteger i, BOOL *stop) {
                printf("%-3lu %-10s %-16s %s\n", (unsigned long)(i + 1), it.comboString.UTF8String,
                       it.name.UTF8String, it.appPath.UTF8String);
            }];
            return 0;
        }

        NSString *which = ValueAfterFlag(argc, argv, "--run-hotkey", YES);
        if (which) {
            NSInteger idx = which.integerValue - 1;
            HotKeyItem *it = (idx >= 0 && idx < (NSInteger)hk.items.count) ? hk.items[idx] : nil;
            if (!it) { printf("没有第 %s 条快捷键\n", which.UTF8String); return 1; }
            if (ResidentInstanceExists()) {   // 交给常驻实例，测的就是按快捷键时走的同一段代码
                PostResidentCommand(@"com.hujie.lull.runhotkey", which);
                printf("已通知常驻实例打开 #%s %s（%s）\n", which.UTF8String,
                       it.name.UTF8String, it.comboString.UTF8String);
            } else {
                printf("执行 #%s → %s（%s）\n", which.UTF8String, it.name.UTF8String, it.comboString.UTF8String);
                [hk launchItem:it];
            }
            for (int i = 0; i < 40; i++) {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
            return 0;
        }

        [NSApp run];
    }
    return 0;
}
