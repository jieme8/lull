// 只读审计：按 App 的隐藏规则，列出"显示桌面之后仍会留在屏上"的窗口
// 不隐藏任何东西，纯测量
#import <AppKit/AppKit.h>

int main(void) {
    @autoreleasepool {
        CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        NSMutableDictionary<NSString *, NSMutableArray *> *leftovers = [NSMutableDictionary dictionary];
        long totalNormal = 0, wouldHide = 0;

        for (CFIndex i = 0; wins && i < CFArrayGetCount(wins); i++) {
            CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
            NSNumber *ly = (NSNumber *)CFDictionaryGetValue(w, kCGWindowLayer);
            if (ly.longValue != 0) continue;                 // 只看普通窗口层（壁纸/Dock/菜单层不算）
            totalNormal++;

            NSNumber *p = (NSNumber *)CFDictionaryGetValue(w, kCGWindowOwnerPID);
            NSString *owner = (__bridge NSString *)CFDictionaryGetValue(w, kCGWindowOwnerName);
            NSRunningApplication *a = [NSRunningApplication runningApplicationWithProcessIdentifier:p.intValue];
            NSApplicationActivationPolicy pol = a ? a.activationPolicy : -1;
            NSString *bid = a.bundleIdentifier ?: @"(无 bundle id)";

            BOOL hide = (pol == NSApplicationActivationPolicyRegular)
                     && ![bid isEqualToString:@"com.hujie.lull"];
            if ([bid isEqualToString:@"com.apple.finder"]) hide = NO;   // App 不藏访达：它必须当那个前台
            if (hide) { wouldHide++; continue; }

            NSString *key = [NSString stringWithFormat:@"%@  [%@]  policy=%ld",
                             owner ?: @"?", bid, (long)pol];
            if (!leftovers[key]) leftovers[key] = [NSMutableArray array];
            [leftovers[key] addObject:(a && a.hidden ? @"已hidden但仍有窗口" : @"可见")];
        }
        if (wins) CFRelease(wins);

        printf("屏上普通层窗口共 %ld 个；按当前规则会隐藏 %ld 个；剩下这些藏不住：\n\n",
               totalNormal, wouldHide);
        if (!leftovers.count) printf("  （无 —— 桌面能完全露出来）\n");
        for (NSString *k in [leftovers.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            printf("  %-62s × %lu\n", k.UTF8String, (unsigned long)leftovers[k].count);
        }
    }
    return 0;
}
