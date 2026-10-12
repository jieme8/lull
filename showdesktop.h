// 原生「显示桌面」：发一次系统 Show Desktop 按键（F11），效果等同手动按
// 与"隐藏所有窗口"的区别：窗口只是被移开，不丢现场，再按一次或点任意窗口就回来
// 代价：CGEventPost 需要「辅助功能」授权（唯一需要授权的功能）
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DesktopRevealMode) {
    DesktopRevealModeHide = 0,     // 零权限：hide 掉所有普通 App（访达窗口会留下）
    DesktopRevealModeNative = 1,   // 原生显示桌面（需辅助功能授权）
};

/// 本进程是否已被授予辅助功能权限
BOOL DesktopAccessibilityTrusted(void);

/// 弹出系统授权提示，并打开 隐私与安全 → 辅助功能 面板
void DesktopOpenAccessibilitySettings(void);

/// 发出 Show Desktop 按键。未授权时返回 NO 并给出原因
BOOL DesktopPostShowDesktopKey(NSString **reason);

NSString *DesktopRevealModeName(DesktopRevealMode mode);
