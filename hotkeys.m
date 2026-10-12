#import "hotkeys.h"
#import <Carbon/Carbon.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdlib.h>

#pragma mark - 键码显示名

static NSDictionary<NSNumber *, NSString *> *KeyCodeNames(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @(0):@"A", @(1):@"S", @(2):@"D", @(3):@"F", @(4):@"H", @(5):@"G", @(6):@"Z", @(7):@"X",
            @(8):@"C", @(9):@"V", @(11):@"B", @(12):@"Q", @(13):@"W", @(14):@"E", @(15):@"R", @(16):@"Y",
            @(17):@"T", @(18):@"1", @(19):@"2", @(20):@"3", @(21):@"4", @(22):@"6", @(23):@"5", @(24):@"=",
            @(25):@"9", @(26):@"7", @(27):@"-", @(28):@"8", @(29):@"0", @(30):@"]", @(31):@"O", @(32):@"U",
            @(33):@"[", @(34):@"I", @(35):@"P", @(36):@"↩", @(37):@"L", @(38):@"J", @(39):@"'", @(40):@"K",
            @(41):@";", @(42):@"\\", @(43):@",", @(44):@"/", @(45):@"N", @(46):@"M", @(47):@".", @(48):@"⇥",
            @(49):@"空格", @(50):@"`", @(51):@"⌫", @(52):@"⎋", @(53):@"⌘", @(54):@"⇧", @(55):@"⌥", @(56):@"⌃",
            @(65):@".", @(66):@"*", @(67):@"+", @(68):@"⌦", @(69):@"@", @(71):@"↩", @(75):@"/", @(76):@"↩",
            @(78):@"-", @(81):@"=", @(82):@"0", @(83):@"1", @(84):@"2", @(85):@"3", @(86):@"4", @(87):@"5",
            @(88):@"6", @(89):@"7", @(91):@"8", @(92):@"9", @(96):@"F5", @(97):@"F6", @(98):@"F7", @(99):@"F3",
            @(100):@"F8", @(101):@"F9", @(103):@"F11", @(105):@"F13", @(106):@"F16", @(107):@"F14", @(109):@"F10",
            @(111):@"F12", @(113):@"F15", @(114):@"Help", @(115):@"↖", @(116):@"⇞", @(117):@"⌦", @(118):@"F4",
            @(119):@"↘", @(120):@"F2", @(121):@"⇟", @(122):@"F1", @(123):@"←", @(124):@"→", @(125):@"↓", @(126):@"↑",
        };
    });
    return table;
}

static uint32_t CarbonModsFromCocoa(NSEventModifierFlags f) {
    uint32_t m = 0;
    if (f & NSEventModifierFlagCommand) m |= cmdKey;
    if (f & NSEventModifierFlagOption)  m |= optionKey;
    if (f & NSEventModifierFlagControl) m |= controlKey;
    if (f & NSEventModifierFlagShift)   m |= shiftKey;
    return m;
}

static NSString *ModifierGlyphs(uint32_t carbonMods) {   // Apple 的固定顺序 ⌃⇧⌘
    NSMutableString *s = [NSMutableString string];
    if (carbonMods & controlKey) [s appendString:@"⌃"];
    if (carbonMods & optionKey)  [s appendString:@"⌥"];
    if (carbonMods & shiftKey)   [s appendString:@"⇧"];
    if (carbonMods & cmdKey)     [s appendString:@"⌘"];
    return s;
}

static NSString *KeyNameForCode(uint32_t code) {
    NSString *n = KeyCodeNames()[@(code)];
    return n ?: [NSString stringWithFormat:@"键%u", code];
}

#pragma mark - HotKeyItem

@implementation HotKeyItem

+ (instancetype)itemWithDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    HotKeyItem *it = [HotKeyItem new];
    it.identifier = dict[@"id"] ?: [[NSUUID UUID] UUIDString];
    it.name        = dict[@"name"] ?: @"未命名";
    it.bundleID    = dict[@"bundleID"] ?: @"";
    it.appPath     = dict[@"appPath"] ?: @"";
    it.keyCode     = (uint32_t)[dict[@"keyCode"] unsignedIntValue];
    it.carbonMods  = (uint32_t)[dict[@"mods"] unsignedIntValue];
    return it;
}

- (NSDictionary *)dictionaryValue {
    return @{ @"id": self.identifier ?: @"", @"name": self.name ?: @"",
              @"bundleID": self.bundleID ?: @"", @"appPath": self.appPath ?: @"",
              @"keyCode": @(self.keyCode), @"mods": @(self.carbonMods) };
}

- (BOOL)isConfigured { return self.keyCode != 0 && self.carbonMods != 0; }

- (NSString *)comboString {
    if (![self isConfigured]) return @"未设置";
    return [NSString stringWithFormat:@"%@%@", ModifierGlyphs(self.carbonMods), KeyNameForCode(self.keyCode)];
}

- (id)copyWithZone:(NSZone *)zone {
    HotKeyItem *c = [HotKeyItem new];
    c.identifier = self.identifier; c.name = self.name; c.bundleID = self.bundleID;
    c.appPath = self.appPath; c.keyCode = self.keyCode; c.carbonMods = self.carbonMods;
    return c;
}
@end

#pragma mark - HotKeyManager

NSString *const HotKeyDefaultsKey = @"hotkeys";

@interface HotKeyManager () {
    NSMutableArray<HotKeyItem *> *_items;
    NSMutableData *_refData;                               // 裸 EventHotKeyRef 指针序列。不能放进 NSArray：
                                                           // 它既不是 objc 对象也不可 __bridge，ARC 会 objc_retain 它 → 崩溃
    NSMutableDictionary<NSNumber *, HotKeyItem *> *_byCarbonID;
}
@property(assign, readwrite, getter=isSuspended) BOOL suspended;
@property(copy) NSString *lastRequestedID;   // 最近一次请求打开的条目，用于丢弃过期的前台检查
- (void)handleCarbonID:(uint32_t)cID;
@end

static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef event, void *refcon) {
    HotKeyManager *m = (__bridge HotKeyManager *)refcon;
    EventHotKeyID hid;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof(hid), NULL, &hid) == noErr) {
        [m handleCarbonID:hid.id];
    }
    return noErr;
}

@implementation HotKeyManager

- (instancetype)init {
    if ((self = [super init])) {
        _items = [NSMutableArray array];
        _refData = [NSMutableData data];
        _byCarbonID = [NSMutableDictionary dictionary];
        EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
        OSStatus s = InstallApplicationEventHandler(NewEventHandlerUPP(HotKeyHandler), 1, &spec,
                                                     (__bridge void *)self, NULL);
        if (s != noErr && self.logger) self.logger([NSString stringWithFormat:@"Carbon 事件处理器安装失败 %d", (int)s]);
    }
    return self;
}

- (NSArray<HotKeyItem *> *)items { return [_items copy]; }

- (HotKeyItem *)itemAtIndex:(NSUInteger)i { return i < _items.count ? _items[i] : nil; }

- (void)log:(NSString *)m { if (self.logger) self.logger(m); }

#pragma mark 持久化

- (void)reloadItemsWithoutRegistering {
    NSArray *raw = [[NSUserDefaults standardUserDefaults] arrayForKey:HotKeyDefaultsKey];
    [_items removeAllObjects];
    for (NSDictionary *d in raw) {
        HotKeyItem *it = [HotKeyItem itemWithDictionary:d];
        if (it) [_items addObject:it];
    }
}

- (void)loadFromDefaults {
    [self reloadItemsWithoutRegistering];
    [self registerAll];
}

- (void)persist {
    NSMutableArray *arr = [NSMutableArray array];
    for (HotKeyItem *it in _items) [arr addObject:it.dictionaryValue];
    [[NSUserDefaults standardUserDefaults] setObject:arr forKey:HotKeyDefaultsKey];
}

#pragma mark 注册

- (void)unregisterAll {
    const EventHotKeyRef *refs = (const EventHotKeyRef *)_refData.bytes;
    NSUInteger count = _refData.length / sizeof(EventHotKeyRef);
    for (NSUInteger i = 0; i < count; i++) UnregisterEventHotKey(refs[i]);
    [_refData setLength:0];
    [_byCarbonID removeAllObjects];
}

- (void)registerAll {
    [self unregisterAll];
    if (self.suspended) return;      // 设置窗口开着：等它关闭时再注册
    NSUInteger okCount = 0, configured = 0;
    for (NSUInteger i = 0; i < _items.count; i++) {
        HotKeyItem *it = _items[i];
        it.registerFailed = NO;
        if (![it isConfigured]) continue;
        configured++;

        uint32_t cID = (uint32_t)(i + 1);
        EventHotKeyID hid = { .signature = 'idlH', .id = cID };
        EventHotKeyRef ref = NULL;
        OSStatus s = RegisterEventHotKey(it.keyCode, it.carbonMods, hid,
                                         GetApplicationEventTarget(), 0, &ref);
        if (s == noErr && ref) {
            [_refData appendBytes:&ref length:sizeof(ref)];   // 只存指针，不交给 ARC/CF 管理
            _byCarbonID[@(cID)] = it;
            okCount++;
        } else {
            it.registerFailed = YES;
            [self log:[NSString stringWithFormat:@"快捷键 %@ → %@ 注册失败（code %d，可能已被其他 App 占用）",
                       it.comboString, it.name, (int)s]];
        }
    }
    if (configured == 0) return;     // 一条都没设键，别在日志里刷存在感
    [self log:[NSString stringWithFormat:@"快捷键注册完成：%lu/%lu 条已设键的注册成功",
               (unsigned long)okCount, (unsigned long)configured]];
}

- (void)suspendForSettings {
    if (self.suspended) return;
    self.suspended = YES;
    [self unregisterAll];
    [self log:@"设置窗口打开 → 全部快捷键已挂起（否则录制时按下的键会被已有热键吃掉）"];
}

- (void)resumeAfterSettings {
    if (!self.suspended) return;
    self.suspended = NO;
    [self registerAll];
}

- (void)handleCarbonID:(uint32_t)cID {
    HotKeyItem *it = _byCarbonID[@(cID)];
    if (!it) return;

    NSTimeInterval since = it.lastFired ? -[it.lastFired timeIntervalSinceNow] : 999;
    it.lastFired = [NSDate date];
    it.fireCount++;
    if (since < 0.5) return;   // 按住不放开键重复会以 ~0.3s 间隔连续回调，只认第一次

    [self log:[NSString stringWithFormat:@"快捷键 %@ 触发 → 打开 %@", it.comboString, it.name]];
    [self launchItem:it];
}

#pragma mark 增删改

- (BOOL)addItemForAppAtURL:(NSURL *)url error:(NSString * __autoreleasing *)err {
    NSBundle *b = [NSBundle bundleWithURL:url];
    NSString *bid = b.bundleIdentifier;
    if (!bid.length) {
        if (err) *err = [NSString stringWithFormat:@"%@ 不是有效的 App（读不到 bundle id）", url.lastPathComponent];
        return NO;
    }
    for (HotKeyItem *it in _items) {
        if ([it.bundleID isEqualToString:bid]) {
            if (err) *err = [NSString stringWithFormat:@"%@ 已经在列表里了", it.name];
            return NO;
        }
    }
    HotKeyItem *it = [HotKeyItem new];
    it.identifier = [[NSUUID UUID] UUIDString];
    it.name = url.URLByDeletingPathExtension.lastPathComponent;
    it.bundleID = bid;
    it.appPath = url.path;
    [_items addObject:it];
    [self persist];
    [self log:[NSString stringWithFormat:@"新增快捷键条目：%@（%@），接下来给它设一个组合键", it.name, bid]];
    [self registerAll];
    return YES;
}

- (BOOL)updateItem:(HotKeyItem *)item withKeyCode:(uint32_t)keyCode mods:(uint32_t)mods
             error:(NSString * __autoreleasing *)err {
    for (HotKeyItem *other in _items) {
        if (other != item && other.keyCode == keyCode && other.carbonMods == mods) {
            if (err) *err = [NSString stringWithFormat:@"和「%@」的 %@ 撞了", other.name, other.comboString];
            return NO;
        }
    }
    item.keyCode = keyCode;
    item.carbonMods = mods;
    [self persist];
    [self registerAll];
    if (self.suspended) {   // 挂起中注册不了，冲突只能等关窗时检出
        [self log:[NSString stringWithFormat:@"%@ 的快捷键设为 %@（关闭设置窗口后正式注册并检测冲突）",
                   item.name, item.comboString]];
        return YES;
    }
    if (item.registerFailed) {
        if (err) *err = [NSString stringWithFormat:@"%@ 被其他程序占用", item.comboString];
        return NO;
    }
    [self log:[NSString stringWithFormat:@"%@ 的快捷键设为 %@", item.name, item.comboString]];
    return YES;
}

- (void)removeItem:(HotKeyItem *)item {
    [_items removeObjectIdenticalTo:item];
    [self persist];
    [self registerAll];
    [self log:[NSString stringWithFormat:@"删除快捷键条目：%@", item.name]];
}

#pragma mark 打开 App

- (void)launchItem:(HotKeyItem *)item {
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    BOOL wasRunning = NO;
    for (NSRunningApplication *a in ws.runningApplications)
        if ([a.bundleIdentifier isEqualToString:item.bundleID]) { wasRunning = YES; break; }
    self.lastRequestedID = item.identifier;

    NSURL *url = item.appPath.length ? [NSURL fileURLWithPath:item.appPath] : nil;
    if (url && ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        [self log:[NSString stringWithFormat:@"%@ 的记录路径已失效：%@", item.name, item.appPath]];
        url = nil;
    }
    if (!url) url = [ws URLForApplicationWithBundleIdentifier:item.bundleID];
    if (url && ![url.path isEqualToString:item.appPath]) {
        // 自愈：App 被移动/重命名但 bundle id 还能解析 → 更新记录，下次不用再找
        [self log:[NSString stringWithFormat:@"%@ 的路径已自动更新 → %@", item.name, url.path]];
        item.appPath = url.path;
        [self persist];
    }
    if (!url) {
        [self log:[NSString stringWithFormat:@"打不开 %@：路径和 bundle id（%@）都解析不到，"
                                             @"App 可能已卸载或改名，请在设置里删掉这条重新添加",
                   item.name, item.bundleID]];
        return;
    }

    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    // 关键：已运行的 App 光调 activateWithOptions: 只是"置前"，如果它此刻一个窗口都没有
    // （聊天/Electron 类 App 关掉窗口后很常见），看上去就是按了没反应。
    // 走 LaunchServices 的 open 会额外发一个 reopen 事件，App 通常会新建或恢复窗口；
    // activates=YES 保证置前，同时 open 会取消隐藏（正好接上「空闲隐藏窗口」）。
    cfg.activates = YES;

    __weak typeof(self) me = self;
    [ws openApplicationAtURL:url configuration:cfg completionHandler:^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!app) {
                if (me.logger) me.logger([NSString stringWithFormat:@"%@ %@ 失败：%@",
                    wasRunning ? @"激活" : @"启动", item.name,
                    error.localizedDescription ?: @"未知错误"]);
                return;
            }
            if (me.logger) me.logger([NSString stringWithFormat:@"%@ %@（pid %d）→ 已请求前置",
                wasRunning ? @"激活" : @"启动", item.name, app.processIdentifier]);

            // 不信返回值：0.6 秒后实测前台到底是不是它
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                // 连续触发时，上一条的延迟检查会赶上新的请求，比对错了对象就会报假 ✗
                if (![item.identifier isEqualToString:me.lastRequestedID]) return;
                NSRunningApplication *front = [NSWorkspace sharedWorkspace].frontmostApplication;
                BOOL got = [front.bundleIdentifier isEqualToString:item.bundleID];
                NSString *line = [NSString stringWithFormat:@"  %@ 当前前台=%@（期望 %@）",
                                  got ? @"✓ 已置前" : @"✗ 没到前台",
                                  front.localizedName ?: (front.bundleIdentifier ?: @"?"), item.name];
                if (me.logger) me.logger(line);
            });
        });
    }];
}
@end

#pragma mark - 快捷键录制控件

@interface HotKeyRecorderButton : NSButton
@property(assign) uint32_t keyCode;
@property(assign) uint32_t carbonMods;
@property(assign) BOOL recording;
@property(copy, nullable) void (^onCaptured)(uint32_t keyCode, uint32_t mods);
@property(copy, nullable) void (^onHint)(NSString *hint);
- (void)setComboKey:(uint32_t)k mods:(uint32_t)m;
@end

@implementation HotKeyRecorderButton

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        self.bezelStyle = NSBezelStyleRounded;
        [self setButtonType:NSButtonTypePushOnPushOff];   // 录制中保持按下态
        [self refreshTitle];
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)setComboKey:(uint32_t)k mods:(uint32_t)m {
    self.keyCode = k; self.carbonMods = m;
    [self refreshTitle];
}

- (NSString *)comboText {
    if (!self.keyCode || !self.carbonMods) return @"点击设置";
    NSMutableString *s = [NSMutableString string];
    if (self.carbonMods & controlKey) [s appendString:@"⌃"];
    if (self.carbonMods & optionKey)  [s appendString:@"⌥"];
    if (self.carbonMods & shiftKey)   [s appendString:@"⇧"];
    if (self.carbonMods & cmdKey)     [s appendString:@"⌘"];
    [s appendString:KeyNameForCode(self.keyCode)];
    return s;
}

- (void)refreshTitle {
    self.title = self.recording ? @"按下快捷键…" : [self comboText];
    self.state = self.recording ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)mouseDown:(NSEvent *)e {
    [self beginRecording];
    [super mouseDown:e];
}

- (void)beginRecording {
    self.recording = YES;
    [self refreshTitle];
    [[self window] makeFirstResponder:self];
}

- (void)endRecording {
    if (!self.recording) return;
    self.recording = NO;
    [self refreshTitle];
}

- (BOOL)resignFirstResponder {
    [self endRecording];
    return [super resignFirstResponder];
}

- (void)keyDown:(NSEvent *)e {
    if (!self.recording) { [super keyDown:e]; return; }
    if (e.keyCode == 53) {                       // ⎋ 取消
        [self endRecording];
        if (self.onHint) self.onHint(@"已取消录制");
        return;
    }
    NSEventModifierFlags f = e.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagOption |
         NSEventModifierFlagControl | NSEventModifierFlagShift);
    if (!f) {                                    // 拒绝裸键，否则会吞掉正常打字
        if (self.onHint) self.onHint(@"快捷键必须至少带一个修饰键（⌘ / ⌥ / ⌃ / ⇧）");
        return;
    }
    // 纯 ⌃ 组合实测是能触发的（⌃2/⌃Q/⌃W/⌃3 都有成功记录），所以不拦截。
    // Carbon 注册不报跨进程冲突，真撞车时不会报错 —— 但状态列的「已注册·未收到按键」会暴露它，
    // 提醒文案放在录制成功的那条提示里（见 onCaptured 分支）。
    uint32_t key = e.keyCode, mods = CarbonModsFromCocoa(f);
    [self endRecording];
    if (self.onCaptured) self.onCaptured(key, mods);
}

// 录制期间按住修饰键会持续触发 flagsChanged，别让它打断录制
- (void)flagsChanged:(NSEvent *)e { if (!self.recording) [super flagsChanged:e]; }
@end

#pragma mark - 设置窗口

static const CGFloat ROW_W = 660;

@interface HotKeyWindowController () <NSWindowDelegate>
@property(strong) HotKeyManager *manager;
@property(strong) NSWindow *win;
@property(strong) NSStackView *root;
@property(strong) NSStackView *listStack;
@property(strong) NSTextField *hintLabel;
@end

@implementation HotKeyWindowController

- (instancetype)initWithManager:(HotKeyManager *)manager {
    if ((self = [super init])) {
        _manager = manager;
        [self buildWindow];
    }
    return self;
}

- (void)buildWindow {
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, ROW_W + 32, 320)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                    backing:NSBackingStoreBuffered defer:NO];
    w.title = @"自定义快捷键";
    w.releasedWhenClosed = NO;
    w.delegate = self;
    [w center];
    self.win = w;

    NSView *container = [NSView new];
    w.contentView = container;

    self.root = [NSStackView stackViewWithViews:@[]];
    self.root.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.root.alignment = NSLayoutAttributeLeading;
    self.root.distribution = NSStackViewDistributionFill;
    self.root.spacing = 8;
    self.root.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.root];
    [NSLayoutConstraint activateConstraints:@[
        [self.root.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [self.root.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [self.root.topAnchor constraintEqualToAnchor:container.topAnchor constant:16],
        [self.root.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16],
    ]];

    NSTextField *explain = [self labelWith:@"给常用 App 设一个全局快捷键，按下即打开（已运行则切到前台并取消隐藏）。打开本窗口期间所有快捷键暂时停用，关闭后自动恢复。"
                                      bold:NO size:11 color:[NSColor secondaryLabelColor]];
    [self.root addArrangedSubview:explain];

    self.listStack = [NSStackView stackViewWithViews:@[]];
    self.listStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.listStack.alignment = NSLayoutAttributeLeading;
    self.listStack.spacing = 6;
    [self.root addArrangedSubview:self.listStack];

    self.hintLabel = [self labelWith:@"提示：录制时按 ⎋ 取消；快捷键必须包含 ⌘/⌥/⌃ 之一。"
                                bold:NO size:11 color:[NSColor secondaryLabelColor]];
    [self.root addArrangedSubview:self.hintLabel];

    NSButton *add = [NSButton buttonWithTitle:@"添加 App…" target:self action:@selector(addApp:)];
    NSButton *done = [NSButton buttonWithTitle:@"完成" target:self action:@selector(closeWindow:)];
    done.keyEquivalent = @"\r";
    NSStackView *footer = [NSStackView stackViewWithViews:@[add, [NSView new], done]];
    footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footer.distribution = NSStackViewDistributionFill;
    [footer.widthAnchor constraintEqualToConstant:ROW_W].active = YES;
    [self.root addArrangedSubview:footer];
}

- (NSTextField *)labelWith:(NSString *)s bold:(BOOL)bold size:(CGFloat)size color:(NSColor *)color {
    NSTextField *tf = [NSTextField labelWithString:s];
    tf.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    tf.textColor = color;
    tf.lineBreakMode = NSLineBreakByTruncatingTail;
    return tf;
}

- (void)showAndActivate {
    [self.manager suspendForSettings];   // 先挂起，否则录制时按的键会被已有热键抢走
    [self rebuildRows];
    [self.win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)relayout {
    [self.root layoutSubtreeIfNeeded];
    NSSize sz = self.root.fittingSize;
    [self.win setContentSize:NSMakeSize(ROW_W + 32, sz.height + 32)];
    [self.win center];
}

- (void)rebuildRows {
    for (NSView *v in self.listStack.arrangedSubviews) [v removeFromSuperview];

    if (self.manager.items.count == 0) {
        NSTextField *empty = [self labelWith:@"（还没有条目，点下面的「添加 App…」）"
                                        bold:NO size:12 color:[NSColor tertiaryLabelColor]];
        [self.listStack addArrangedSubview:empty];
        [self relayout];
        return;
    }

    NSArray<HotKeyItem *> *items = self.manager.items;
    for (NSUInteger i = 0; i < items.count; i++) [self.listStack addArrangedSubview:[self rowForItem:items[i] index:i]];
    [self relayout];
}

- (NSView *)rowForItem:(HotKeyItem *)it index:(NSUInteger)index {
    NSTextField *name = [self labelWith:it.name bold:YES size:12 color:[NSColor labelColor]];
    [name.widthAnchor constraintEqualToConstant:110].active = YES;

    HotKeyRecorderButton *rec = [[HotKeyRecorderButton alloc] initWithFrame:NSMakeRect(0, 0, 120, 24)];
    [rec setComboKey:it.keyCode mods:it.carbonMods];
    [rec.widthAnchor constraintEqualToConstant:120].active = YES;
    __weak typeof(self) me = self;
    rec.onCaptured = ^(uint32_t key, uint32_t mods) {
        NSString *err = nil;
        if (![me.manager updateItem:it withKeyCode:key mods:mods error:&err]) {
            [me setHint:[NSString stringWithFormat:@"❌ %@", err]];
        } else {
            NSString *tip = [NSString stringWithFormat:@"✓ %@ → %@", it.name, it.comboString];
            if (!(mods & (cmdKey | optionKey))) {
                tip = [tip stringByAppendingString:@"；不带 ⌘/⌥ 偶尔会和其他程序撞车，"
                          @"若状态一直是「未收到按键」就换个组合"];
            }
            [me setHint:tip];
        }
        [me rebuildRows];
    };
    rec.onHint = ^(NSString *h) { [me setHint:h]; };

    NSTextField *path = [self labelWith:it.appPath.lastPathComponent bold:NO size:11 color:[NSColor tertiaryLabelColor]];
    [path.widthAnchor constraintEqualToConstant:150].active = YES;

    // 状态列：区分"注册失败" / "收到过按键" / "从未收到按键"（后者说明按键被系统或别的程序吃了）
    NSString *statText; NSColor *statColor;
    if (it.registerFailed)        { statText = @"⚠ 注册失败";  statColor = [NSColor systemRedColor]; }
    else if (it.fireCount)        { statText = [NSString stringWithFormat:@"✓ 已触发 %lu 次", (unsigned long)it.fireCount];
                                    statColor = [NSColor systemGreenColor]; }
    else                          { statText = @"已注册·未收到按键"; statColor = [NSColor secondaryLabelColor]; }
    NSTextField *status = [self labelWith:statText bold:NO size:11 color:statColor];
    [status.widthAnchor constraintEqualToConstant:112].active = YES;

    NSButton *run = [NSButton buttonWithTitle:@"打开" target:self action:@selector(runItem:)];
    run.tag = (NSInteger)index;                       // NSButton 没有 representedObject，用下标索引
    NSButton *del = [NSButton buttonWithTitle:@"删除" target:self action:@selector(removeItem:)];
    del.tag = (NSInteger)index;

    NSStackView *row = [NSStackView stackViewWithViews:@[name, rec, path, status, run, del]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8;
    [row.widthAnchor constraintEqualToConstant:ROW_W].active = YES;
    return row;
}

- (void)setHint:(NSString *)h {
    self.hintLabel.stringValue = h ?: @"";
    self.hintLabel.textColor = [h hasPrefix:@"❌"] ? [NSColor systemRedColor] : [NSColor secondaryLabelColor];
}

- (void)addApp:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.title = @"选择要绑定快捷键的 App";
    p.canChooseFiles = YES;
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = NO;
    p.allowedContentTypes = @[[UTType typeWithIdentifier:@"com.apple.application-bundle"]];
    p.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
    __weak typeof(self) me = self;
    [p beginSheetModalForWindow:self.win completionHandler:^(NSModalResponse resp) {
        if (resp != NSModalResponseOK) return;
        NSString *err = nil;
        if (![me.manager addItemForAppAtURL:p.URL error:&err]) [me setHint:[NSString stringWithFormat:@"❌ %@", err]];
        else [me setHint:@"已添加，点「点击设置」按下你的快捷键"];
        [me rebuildRows];
    }];
}

- (void)runItem:(NSButton *)sender {
    HotKeyItem *it = [self.manager itemAtIndex:(NSUInteger)MAX(sender.tag, 0)];
    if (!it) return;
    [self.manager launchItem:it];
    [self setHint:[NSString stringWithFormat:@"已请求打开 %@", it.name]];
}

- (void)removeItem:(NSButton *)sender {
    HotKeyItem *it = [self.manager itemAtIndex:(NSUInteger)MAX(sender.tag, 0)];
    if (!it) return;
    [self.manager removeItem:it];
    [self setHint:@"已删除"];
    [self rebuildRows];
}

- (void)closeWindow:(id)sender { [self.win performClose:sender]; }   // 必须走 close，才触发 windowWillClose

- (BOOL)windowShouldClose:(NSWindow *)sender { return YES; }

- (void)windowWillClose:(NSNotification *)note {
    [self.manager resumeAfterSettings];   // 关窗即恢复注册，并报告被占用的条目
}
@end
