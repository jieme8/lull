//
//  verify.m —— 回归网。每条断言都对应这次真实踩过的一个坑，改完代码必须全绿。
//  用法：./build.sh --verify        （由 build.sh 传入源码目录）
//
//  原则：断言只看"外部可观测事实"（窗口列表、前台 App、进程），绝不拿 API 返回值当证据 ——
//  hide() 返回 NO 却生效、activate 返回 YES 却没到前台、热键注册 noErr 却收不到按键，
//  这三种"说谎的返回值"都曾经让我误判过。
//
#import "probes.h"
#import "hotkeys.h"
#import <Carbon/Carbon.h>
#include <unistd.h>

static int gPass = 0, gFail = 0, gSkip = 0;
static NSString *gDir;

static void check(NSString *name, BOOL ok, NSString *detail) {
    if (ok) { gPass++; printf("  ✓ %s\n", name.UTF8String); }
    else    { gFail++; printf("  ✗ %s\n      原因：%s\n", name.UTF8String, (detail ? detail.UTF8String : "(无)")); }
}
static void skip(NSString *name, NSString *why) {
    gSkip++; printf("  · %s —— 跳过：%s\n", name.UTF8String, why.UTF8String);
}

static NSString *readSrc(NSString *file) {
    NSString *path = [gDir stringByAppendingPathComponent:file];
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return s ?: @"";
}

static void spin(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

/// 轮询等条件成立。固定 sleep 会让断言跟着系统快慢抖，这里等到成立或超时
static BOOL waitUntil(BOOL (^cond)(void), NSTimeInterval timeout) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([until timeIntervalSinceNow] > 0) {
        if (cond()) return YES;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return cond();
}

static NSRunningApplication *appWithBundle(NSString *bid) {
    for (NSRunningApplication *a in [NSWorkspace sharedWorkspace].runningApplications)
        if ([a.bundleIdentifier isEqualToString:bid]) return a;
    return nil;
}

static BOOL openAppAtURL(NSURL *url) {
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.activates = YES;
    __block BOOL done = NO, ok = NO;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:url configuration:cfg
                                      completionHandler:^(NSRunningApplication *app, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{ done = YES; ok = (app != nil); });
    }];
    for (int i = 0; i < 100 && !done; i++) spin(0.1);
    return ok;
}

#pragma mark 1. 静态检查：把三条教训钉死在源码里

/// 静态检查只看代码，不看注释 —— 否则"解释为什么不用某 API"的注释自己会触发禁令
static NSString *stripComments(NSString *src) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"//[^\\n]*|/\\*.*?\\*/"
                                                      options:NSRegularExpressionDotMatchesLineSeparators error:nil];
    });
    return [re stringByReplacingMatchesInString:src options:0
                                          range:NSMakeRange(0, src.length) withTemplate:@""];
}

static void staticChecks(void) {
    printf("\n[1] 静态检查（防止重犯）\n");

    NSString *hk = stripComments(readSrc(@"hotkeys.m"));
    NSString *mn = stripComments(readSrc(@"main.m"));
    check(@"hotkeys.m 不再用会撒谎的 activateWithOptions: 做激活",
          ![hk containsString:@"activateWithOptions:"], @"出现了 activateWithOptions: —— 它返回 YES 不代表真到了前台");
    check(@"hotkeys.m 走 open + activates（能对已运行 App 发 reopen）",
          [hk containsString:@"cfg.activates = YES"], @"没找到 cfg.activates = YES");

    check(@"main.m 不把 hide 的返回值当判据",
          ![mn containsString:@"= [a hide]"] && ![mn containsString:@"if ([a hide]"],
          @"出现了把 hide 返回值拿来判断的写法");
    check(@"main.m 保留「访达不隐藏」这条不变量",
          [mn containsString:@"isEqualToString:FINDER_BID]) continue;"],
          @"访达豁免代码不见了 —— 系统必须留一个前台 App，藏访达会让别的 App 被复活");
    check(@"main.m 复核只看窗口事实",
          [mn containsString:@"ProbeWindows()"], @"复核逻辑没有走 probes");
}

#pragma mark 2. 事实层可用

static void probeChecks(void) {
    printf("\n[2] 事实层（probes）\n");

    double idle = ProbeIdleSeconds();
    check(@"空闲时间可读", idle >= 0, @"读不到 HIDIdleTime，空闲检测整条链路都是瞎的");
    printf("      当前无输入 %.1f 秒\n", idle);

    ProbeSnapshot *s = ProbeWindows();
    check(@"窗口快照可读，且桌面图标层在", s.desktopLayerAlive,
          @"没看到桌面图标层 —— 可能访达被藏了，或探针对层的判断需要更新");
    printf("      %s\n", ProbeSnapshotDescription(s).UTF8String);
}

#pragma mark 3. 挂起/恢复状态机

static void suspendChecks(void) {
    printf("\n[3] 快捷键挂起/恢复（设置窗口开着时必须挂起，关窗必须恢复）\n");

    if ([NSBundle mainBundle].bundleIdentifier) {
        skip(@"隔离域检查", @"本二进制的 defaults 域不为空，会污染真实配置");
        return;
    }
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:@[@{ @"id": @"v1", @"name": @"靶子", @"bundleID": @"com.apple.TextEdit",
                      @"appPath": @"", @"keyCode": @105, @"mods": @(controlKey | cmdKey) }]
          forKey:HotKeyDefaultsKey];

    HotKeyManager *m = [HotKeyManager new];
    m.logger = ^(NSString *s) { };
    [m loadFromDefaults];
    check(@"载入后不处于挂起", !m.isSuspended, @"载入就被挂起，热键永远不会生效");

    [m suspendForSettings];
    check(@"开窗后进入挂起", m.isSuspended, @"设置窗口开着时热键没挂起，会吃掉录制按键");
    [m suspendForSettings];
    check(@"重复挂起不报错", m.isSuspended, @"幂等性被破坏");

    [m resumeAfterSettings];
    check(@"关窗后解除挂起", !m.isSuspended, @"关窗没恢复 —— 热键会永久失效");
    check(@"关窗后条目未标记注册失败", !m.items.firstObject.registerFailed,
          m.items.firstObject.registerFailed ? @"registerFailed 仍为真" : @"");
    [d removeObjectForKey:HotKeyDefaultsKey];
}

#pragma mark 4. 隐藏与恢复：只用窗口数作证

static void hideRestoreChecks(void) {
    printf("\n[4] 靶子 App：隐藏是否真生效、快捷键能否带回已运行的 App\n");

    NSString *bid = @"com.apple.TextEdit";
    NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bid];
    if (!url) { skip(@"靶子测试", @"找不到 TextEdit"); return; }

    BOOL wasRunning = appWithBundle(bid) != nil;
    NSInteger before = ProbeWindowsOwnedBy(bid);
    if (!wasRunning) {
        if (!openAppAtURL(url)) { skip(@"靶子测试", @"启动 TextEdit 失败"); return; }
        waitUntil(^BOOL(void){ return ProbeWindowsOwnedBy(bid) > 0; }, 4.0);
        before = ProbeWindowsOwnedBy(bid);
    }
    if (before == 0) { skip(@"靶子测试", @"TextEdit 没有可观测窗口（可能停在打开面板）"); return; }

    // 隐藏：不看返回值，只看窗口数
    [appWithBundle(bid) hide];
    BOOL gone = waitUntil(^BOOL(void){ return ProbeWindowsOwnedBy(bid) == 0; }, 3.0);
    check(@"hide 之后窗口真的从屏上消失（忽略返回值）", gone,
          [NSString stringWithFormat:@"3 秒后仍有 %ld 个窗口", (long)ProbeWindowsOwnedBy(bid)]);

    // 已运行 + 处于隐藏态 → 走 open 必须把窗口带回来并置前（这就是"按了没反应"那个 bug）
    check(@"open 能打开已运行的 App", openAppAtURL(url), @"openApplicationAtURL 没完成");
    BOOL back = waitUntil(^BOOL(void){ return ProbeWindowsOwnedBy(bid) > 0; }, 3.0);
    check(@"已运行的 App 经 open 后窗口回来了（reopen 生效）", back,
          [NSString stringWithFormat:@"窗口数=%ld，说明只是置前、没恢复窗口", (long)ProbeWindowsOwnedBy(bid)]);

    // 前台归属可以轮询；但如果测试期间你真的动了键鼠，焦点判定就不可信 —— 宁可跳过也别报假红
    BOOL front = waitUntil(^BOOL(void){ return [ProbeFrontmostBundleID() isEqualToString:bid]; }, 3.0);
    if (!front && ProbeIdleSeconds() < 1.5) skip(@"实测前台归属", @"测试期间有真实输入，焦点判定不可信");
    else check(@"实测前台确实是它（不信 activate 的返回值）", front,
               [NSString stringWithFormat:@"当前前台=%@", ProbeFrontmostName()]);

    if (!wasRunning) { [appWithBundle(bid) terminate]; printf("      （已退出测试启动的 TextEdit）\n"); }
}

#pragma mark 5. 配置过期自愈

static void stalePathChecks(void) {
    printf("\n[5] App 改名/移动后的路径自愈\n");

    if ([NSBundle mainBundle].bundleIdentifier) { skip(@"路径自愈", @"defaults 域不隔离"); return; }
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:@[] forKey:HotKeyDefaultsKey];

    HotKeyManager *m = [HotKeyManager new];
    m.logger = ^(NSString *s) { };
    NSString *err = nil;
    NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.TextEdit"];
    if (!url || ![m addItemForAppAtURL:url error:&err]) { skip(@"路径自愈", @"无法添加靶子条目"); return; }

    HotKeyItem *it = m.items.lastObject;
    it.appPath = @"/Applications/这个App根本不存在.app";
    [m launchItem:it];
    BOOL healed = waitUntil(^BOOL(void){ return [it.appPath isEqualToString:url.path]; }, 3.0);
    check(@"路径失效后能按 bundle id 自愈", healed, [NSString stringWithFormat:@"当前记录=%@", it.appPath]);

    [appWithBundle(@"com.apple.TextEdit") terminate];
    [d removeObjectForKey:HotKeyDefaultsKey];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { printf("用法：verify <源码目录>\n"); return 2; }
        gDir = [NSString stringWithUTF8String:argv[1]];

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        printf("Lull 回归验证\n源码目录：%s\n", gDir.UTF8String);
        staticChecks();
        probeChecks();
        suspendChecks();
        hideRestoreChecks();
        stalePathChecks();

        printf("\n结果：✓%d ✗%d ·跳过%d\n", gPass, gFail, gSkip);
        if (gFail) printf("有断言失败：先修好再提交。\n");
        return gFail ? 1 : 0;
    }
}
