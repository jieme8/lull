// 图标字形定义 —— App 与预览工具共用同一份绘制代码，保证"看到的即装上的"
#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, IdleIconStyle) {
    IdleIconStyleWallpaper = 0,  // 屏幕框 + 地平线 + 太阳（默认，语义=壁纸）
    IdleIconStyleMonitor   = 1,  // 显示器 + 支架（最易认）
    IdleIconStyleRing      = 2,  // 进度环 + 小屏（表达空闲倒计时）
};

NSString *IdleIconStyleName(IdleIconStyle style);

/// App 用：纯黑 + 透明度的 template 图，系统按深浅菜单栏自动反色
/// @param progress 仅 Ring 样式使用：0..1 空闲进度
/// @param dimmed   已暂停 → 整枚降到 32% 不透明度
/// @param latched  桌面已露出 → 屏幕框填实
NSImage *IdleIconImage(IdleIconStyle style, NSSize size, CGFloat progress, BOOL dimmed, BOOL latched);

/// 预览用：直接以指定墨色绘制（离屏给 template 图染色不可靠，所以走这条路）
/// 绘制内容与 IdleIconImage 完全一致，只是不做 template 反色
NSImage *IdleIconImageInk(IdleIconStyle style, NSSize size, CGFloat progress, BOOL dimmed,
                          BOOL latched, NSColor *ink);
