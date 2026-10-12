// 挂起/恢复生命周期测试（不碰真实配置：裸二进制的 NSUserDefaults 域和 App 不同）
// 重点回归风险：设置窗口关闭后必须重新注册，否则热键会悄悄失效
#import "../hotkeys.h"
#import <Carbon/Carbon.h>

static void *g;   // 只为让 printf 里的指针可读

int main(void) {
    @autoreleasepool {
        NSBundle *mb = [NSBundle mainBundle];
        printf("本进程的 defaults 域 = %s（必须是 nil，否则会污染真实配置）\n",
               mb.bundleIdentifier.UTF8String ?: "(nil)");
        if (mb.bundleIdentifier) { printf("域不为空，中止\n"); return 2; }
        (void)g;

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:@[@{ @"id": @"probe-1", @"name": @"探针App", @"bundleID": @"com.example.probe",
                          @"appPath": @"", @"keyCode": @105, @"mods": @(controlKey | cmdKey) }]
              forKey:HotKeyDefaultsKey];

        HotKeyManager *m = [HotKeyManager new];
        m.logger = ^(NSString *s) { printf("   log: %s\n", s.UTF8String); };

        [m loadFromDefaults];
        printf("① 载入并注册：items=%lu suspended=%d\n", (unsigned long)m.items.count, m.isSuspended);

        [m suspendForSettings];
        printf("② 挂起后：suspended=%d（此时不应有任何热键在册）\n", m.isSuspended);

        NSString *err = nil;
        BOOL ok = [m updateItem:m.items.firstObject withKeyCode:107 mods:(controlKey | optionKey | cmdKey) error:&err];
        printf("③ 挂起期间改键：ok=%d err=%s combo=%s\n", ok, err ? err.UTF8String : "-",
               m.items.firstObject.comboString.UTF8String);

        [m resumeAfterSettings];
        printf("④ 关窗恢复：suspended=%d（应看到重新注册的日志）\n", m.isSuspended);

        [m suspendForSettings]; [m suspendForSettings];
        [m resumeAfterSettings]; [m resumeAfterSettings];
        printf("⑤ 重复挂起/恢复：items=%lu 未报错\n", (unsigned long)m.items.count);

        // 自我冲突检测（挂起中也能生效，因为它不依赖注册）
        NSString *e2 = nil;
        [m addItemForAppAtURL:[NSURL fileURLWithPath:@"/System/Applications/TextEdit.app"] error:&e2];
        HotKeyItem *a = m.items.firstObject, *b = m.items.lastObject;
        NSString *e3 = nil;
        [m updateItem:a withKeyCode:107 mods:(controlKey | optionKey | cmdKey) error:&e3];
        NSString *e4 = nil;
        BOOL dup = [m updateItem:b withKeyCode:107 mods:(controlKey | optionKey | cmdKey) error:&e4];
        printf("⑥ 两条用同一组合键：ok=%d（应为 0）err=%s\n", dup, e4 ? e4.UTF8String : "-");
        (void)a; (void)e2; (void)e3;

        [m removeItem:b];
        printf("⑦ 删除后 items=%lu\n", (unsigned long)m.items.count);

        // ⑧ 路径失效自愈：appPath 指向不存在的位置，但 bundle id 仍可解析 → 应自动纠正
        HotKeyManager *m2 = [HotKeyManager new];
        m2.logger = ^(NSString *s) { printf("   log: %s\n", s.UTF8String); };
        NSString *e8 = nil;
        if (![m2 addItemForAppAtURL:[NSURL fileURLWithPath:@"/System/Applications/TextEdit.app"] error:&e8]) {
            printf("⑧ 跳过：添加 TextEdit 失败 %s\n", e8.UTF8String ?: "?");
        } else {
            HotKeyItem *t = m2.items.lastObject;
            t.appPath = @"/Applications/被移动过的TextEdit.app";
            printf("⑧ 人为把路径改坏 → %s\n", t.appPath.UTF8String);
            [m2 launchItem:t];
            for (int i = 0; i < 35; i++) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            printf("   自愈后 appPath = %s\n", t.appPath.UTF8String);
        }

        [d removeObjectForKey:HotKeyDefaultsKey];
    }
    return 0;
}
