#import "showdesktop.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <unistd.h>

// 系统 Show Desktop 的默认键是 F11（symbolichotkeys 槽位 36，你这台机器上没被改也没被关）
static const CGKeyCode kShowDesktopKeyCode = 103;

BOOL DesktopAccessibilityTrusted(void) { return AXIsProcessTrusted(); }

NSString *DesktopRevealModeName(DesktopRevealMode mode) {
    return mode == DesktopRevealModeNative ? @"原生显示桌面" : @"隐藏所有窗口";
}

void DesktopOpenAccessibilitySettings(void) {
    // 带 prompt 的检查会让系统弹授权框，并把本 App 列进 辅助功能 列表（勾选仍需用户一下）
    const void *keys[] = { kAXTrustedCheckOptionPrompt };
    const void *vals[] = { kCFBooleanTrue };
    CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
                                              &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    AXIsProcessTrustedWithOptions(opts);
    CFRelease(opts);

    NSURL *url = [NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

BOOL DesktopPostShowDesktopKey(NSString **reason) {
    if (!AXIsProcessTrusted()) {
        if (reason) *reason = @"未授予辅助功能权限";
        return NO;
    }

    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef down = CGEventCreateKeyboardEvent(src, kShowDesktopKeyCode, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(src, kShowDesktopKeyCode, false);
    if (src) CFRelease(src);
    if (!down || !up) {
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        if (reason) *reason = @"创建按键事件失败";
        return NO;
    }

    // 关键：这台机器 F1-F12 默认是媒体键，必须带 SecondaryFn 才会被当作真正的 F11，
    // 否则发出去的是"降低亮度"
    CGEventSetFlags(down, kCGEventFlagMaskSecondaryFn);
    CGEventSetFlags(up,   kCGEventFlagMaskSecondaryFn);

    CGEventPost(kCGHIDEventTap, down);
    usleep(40 * 1000);
    CGEventPost(kCGHIDEventTap, up);

    CFRelease(down);
    CFRelease(up);
    return YES;
}
