#import "probes.h"
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#include <math.h>
#include <stdlib.h>

@implementation ProbeSnapshot
- (instancetype)init {
    if ((self = [super init])) _regularAppNames = @[];
    return self;
}
@end

#pragma mark 空闲时间

double ProbeIdleSeconds(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("IOHIDSystem"));
    if (!svc) return -1;
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, kNilOptions);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS || !props) return -1;

    double seconds = -1;
    CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(props, CFSTR("HIDIdleTime"));
    if (n) {
        int64_t ns = 0;
        if (CFNumberGetValue(n, kCFNumberSInt64Type, &ns)) seconds = (double)ns / 1e9;
    }
    CFRelease(props);
    return seconds;
}

#pragma mark 屏幕

static uint32_t *ActiveDisplayList(uint32_t *outCount) {
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) {
        *outCount = 0;
        return NULL;
    }
    uint32_t *ids = (uint32_t *)calloc(count, sizeof(uint32_t));
    if (!ids) { *outCount = 0; return NULL; }
    if (CGGetActiveDisplayList(count, ids, &count) != kCGErrorSuccess) {
        free(ids);
        *outCount = 0;
        return NULL;
    }
    *outCount = count;
    return ids;
}

BOOL ProbeAnyDisplayAwake(void) {
    uint32_t count = 0;
    uint32_t *ids = ActiveDisplayList(&count);
    if (!ids) return YES;                       // 拿不到列表时按"醒着"处理，宁可多触发一次也别漏
    BOOL awake = NO;
    for (uint32_t i = 0; i < count; i++)
        if (!CGDisplayIsAsleep(ids[i])) { awake = YES; break; }
    free(ids);
    return awake;
}

BOOL ProbeScreensaverActive(void) {
    for (NSRunningApplication *a in [NSWorkspace sharedWorkspace].runningApplications) {
        NSString *bid = a.bundleIdentifier ?: @"";
        NSString *nm = a.localizedName ?: @"";
        if ([bid rangeOfString:@"creensaver"].location != NSNotFound ||
            [nm rangeOfString:@"creensaver"].location != NSNotFound) return YES;
    }
    return NO;
}

#pragma mark 窗口

static BOOL BoundsTouchesAnyDisplay(CGRect b, const uint32_t *ids, uint32_t count) {
    for (uint32_t i = 0; i < count; i++)
        if (CGRectIntersectsRect(b, CGDisplayBounds(ids[i]))) return YES;
    return NO;
}

/// 取窗口某个键的 NSNumber 值
static NSInteger NumField(CFDictionaryRef w, CFStringRef key) {
    NSNumber *n = (NSNumber *)CFDictionaryGetValue(w, key);
    return n ? n.integerValue : NSIntegerMin;
}

static NSRunningApplication *OwnerOf(CFDictionaryRef w) {
    NSNumber *pid = (NSNumber *)CFDictionaryGetValue(w, kCGWindowOwnerPID);
    return pid ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue] : nil;
}

static BOOL IsFinder(NSRunningApplication *a) {
    return [a.bundleIdentifier isEqualToString:@"com.apple.finder"];
}

ProbeSnapshot *ProbeWindows(void) {
    ProbeSnapshot *snap = [ProbeSnapshot new];
    uint32_t dcount = 0;
    uint32_t *dids = ActiveDisplayList(&dcount);
    CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    NSMutableSet<NSString *> *names = [NSMutableSet set];

    for (CFIndex i = 0; wins && i < CFArrayGetCount(wins); i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
        if (NumField(w, kCGWindowLayer) != 0) {          // 非普通层：壁纸/桌面图标/Dock/菜单栏
            NSRunningApplication *owner = OwnerOf(w);
            if (IsFinder(owner)) snap.desktopLayerAlive = YES;
            continue;
        }
        NSRunningApplication *a = OwnerOf(w);
        if (!a || a.activationPolicy != NSApplicationActivationPolicyRegular) continue;

        // 窗口被移到屏幕外 = 已经收起，不算"还在屏上"
        NSDictionary *bd = (__bridge NSDictionary *)CFDictionaryGetValue(w, kCGWindowBounds);
        CGRect b;
        if (bd && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bd, &b) && dids) {
            if (!BoundsTouchesAnyDisplay(b, dids, dcount)) continue;
        }
        if (IsFinder(a)) { snap.finderWindows++; continue; }
        snap.regularWindows++;
        [names addObject:(a.localizedName ?: a.bundleIdentifier ?: @"?")];
    }
    if (wins) CFRelease(wins);
    if (dids) free(dids);
    snap.regularAppNames = [names.allObjects sortedArrayUsingSelector:@selector(compare:)];
    return snap;
}

NSInteger ProbeWindowsOwnedBy(NSString *bundleID) {
    uint32_t dcount = 0;
    uint32_t *dids = ActiveDisplayList(&dcount);
    CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    NSInteger n = 0;
    for (CFIndex i = 0; wins && i < CFArrayGetCount(wins); i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
        if (NumField(w, kCGWindowLayer) != 0) continue;
        NSRunningApplication *a = OwnerOf(w);
        if (![a.bundleIdentifier isEqualToString:bundleID]) continue;
        NSDictionary *bd = (__bridge NSDictionary *)CFDictionaryGetValue(w, kCGWindowBounds);
        CGRect b;
        if (bd && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bd, &b) && dids &&
            !BoundsTouchesAnyDisplay(b, dids, dcount)) continue;   // 已被移出屏幕
        n++;
    }
    if (wins) CFRelease(wins);
    if (dids) free(dids);
    return n;
}

BOOL ProbeHasFullscreenRegularWindow(void) {
    uint32_t dcount = 0;
    uint32_t *dids = ActiveDisplayList(&dcount);
    CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    BOOL full = NO;

    for (CFIndex i = 0; wins && i < CFArrayGetCount(wins) && !full; i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
        if (NumField(w, kCGWindowLayer) != 0) continue;
        NSRunningApplication *a = OwnerOf(w);
        if (!a || a.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        if (IsFinder(a)) continue;                        // 访达的桌面层本来就铺满屏
        if ([a.bundleIdentifier isEqualToString:@"com.hujie.lull"]) continue;

        NSDictionary *bd = (__bridge NSDictionary *)CFDictionaryGetValue(w, kCGWindowBounds);
        CGRect b;
        if (!bd || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bd, &b)) continue;
        for (uint32_t d = 0; d < dcount; d++) {
            CGRect f = CGDisplayBounds(dids[d]);
            if (fabs(b.size.width - f.size.width) < 2 && fabs(b.size.height - f.size.height) < 2 &&
                fabs(b.origin.x - f.origin.x) < 2 && fabs(b.origin.y - f.origin.y) < 2) { full = YES; break; }
        }
    }
    if (wins) CFRelease(wins);
    if (dids) free(dids);
    return full;
}

#pragma mark 前台

static NSRunningApplication *Frontmost(void) {
    return [NSWorkspace sharedWorkspace].frontmostApplication;
}

NSString *ProbeFrontmostBundleID(void) { return Frontmost().bundleIdentifier ?: @""; }
NSString *ProbeFrontmostName(void)     { NSRunningApplication *a = Frontmost(); return a.localizedName ?: (a.bundleIdentifier ?: @"?"); }

#pragma mark 文本输出

NSString *ProbeSnapshotDescription(ProbeSnapshot *snap) {
    return [NSString stringWithFormat:@"普通 App 窗口=%ld 访达窗口=%ld 桌面图标层=%@ 残留 App=[%@]",
           (long)snap.regularWindows, (long)snap.finderWindows,
           snap.desktopLayerAlive ? @"在" : @"没了",
           snap.regularAppNames.count ? [snap.regularAppNames componentsJoinedByString:@"、"] : @"无"];
}
