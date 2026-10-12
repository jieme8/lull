// 预览图渲染器 —— 直接调用 App 用的 IdleIconImage()，所以这张图就是产品本身
//   clang ... render_icons.m ../icons.m  →  /tmp/icons_sheet.png
#import <AppKit/AppKit.h>
#import "icons.h"

#define W 1000
#define ROW_H 96
#define HEADER 92
#define LABEL_X 12
#define BIG_X 300
#define SMALL_X 640

static NSColor *INK, *PAPER, *DARK_BAR, *LIGHT_BAR, *BG, *GRID;

static void fillRect(NSRect r, NSColor *c) { [c set]; [NSBezierPath fillRect:r]; }
static void drawText(NSString *s, NSPoint p, NSDictionary *a) { [s drawAtPoint:p withAttributes:a]; }

/// 直接贴图，不做任何染色（染色由 IdleIconImageInk 的 ink 参数在绘制阶段完成）
static void blit(NSImage *img, NSRect box) {
    if (!img) return;
    NSSize s = img.size;
    CGFloat k = MIN(box.size.width / s.width, box.size.height / s.height);
    NSSize d = NSMakeSize(s.width * k, s.height * k);
    NSRect dst = NSMakeRect(box.origin.x + (box.size.width - d.width) / 2,
                            box.origin.y + (box.size.height - d.height) / 2, d.width, d.height);
    [img drawInRect:dst fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
}

typedef struct { IdleIconStyle style; BOOL dimmed; BOOL latched; CGFloat progress; NSString *label; } Variant;

int main(void) {
    @autoreleasepool {
        INK       = [NSColor colorWithCalibratedWhite:0.08 alpha:1];
        PAPER     = [NSColor colorWithCalibratedWhite:0.99 alpha:1];
        DARK_BAR  = [NSColor colorWithCalibratedWhite:0.17 alpha:1];
        LIGHT_BAR = [NSColor colorWithCalibratedWhite:0.94 alpha:1];
        BG        = [NSColor colorWithCalibratedWhite:0.99 alpha:1];
        GRID      = [NSColor colorWithCalibratedWhite:0.86 alpha:1];

        Variant vs[] = {
            {IdleIconStyleWallpaper, NO,  NO,  0.00, @"壁纸 · 运行中"},
            {IdleIconStyleWallpaper, NO,  YES, 0.00, @"壁纸 · 桌面已露出"},
            {IdleIconStyleWallpaper, YES, NO,  0.00, @"壁纸 · 已暂停"},
            {IdleIconStyleMonitor,   NO,  NO,  0.00, @"显示器 · 运行中"},
            {IdleIconStyleMonitor,   NO,  YES, 0.00, @"显示器 · 桌面已露出"},
            {IdleIconStyleRing,      NO,  NO,  0.25, @"进度环 · 空闲 25%"},
            {IdleIconStyleRing,      NO,  NO,  0.60, @"进度环 · 空闲 60%"},
            {IdleIconStyleRing,      NO,  NO,  0.95, @"进度环 · 空闲 95%"},
            {IdleIconStyleRing,      NO,  YES, 1.00, @"进度环 · 已触发"},
        };
        int n = sizeof(vs) / sizeof(vs[0]);

        CGFloat total = HEADER + n * ROW_H + 30;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)W pixelsHigh:(NSInteger)total
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        fillRect(NSMakeRect(0, 0, W, total), BG);

        NSFont *tf = [NSFont boldSystemFontOfSize:14];
        NSFont *sf = [NSFont systemFontOfSize:11];
        NSDictionary *TA = @{ NSFontAttributeName: tf, NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.12 alpha:1] };
        NSDictionary *SA = @{ NSFontAttributeName: sf, NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.45 alpha:1] };

        drawText(@"Lull 图标预览 · 由 App 实际使用的 IdleIconImage() 直接渲染", NSMakePoint(LABEL_X, total - 28), TA);
        drawText(@"列：78px 放大（左深底=深色菜单栏 / 右浅底=浅色菜单栏） → 18px 真实尺寸 → 模拟菜单栏连续排布（本图标在第 3 格）",
                 NSMakePoint(LABEL_X, total - 48), SA);
        drawText(@"三种状态：运行中 / 桌面已露出（屏幕框填实）/ 已暂停（整枚半透明）。进度环样式会随空闲时间实时增长。",
                 NSMakePoint(LABEL_X, total - 68), SA);

        drawText(@"状态", NSMakePoint(LABEL_X, total - HEADER + 14), SA);
        drawText(@"放大 78px", NSMakePoint(BIG_X, total - HEADER + 14), SA);
        drawText(@"真实 18px / 菜单栏模拟", NSMakePoint(SMALL_X, total - HEADER + 14), SA);

        for (int i = 0; i < n; i++) {
            Variant v = vs[i];
            CGFloat bottom = total - HEADER - (i + 1) * ROW_H;
            CGFloat prog = (v.latched && v.style == IdleIconStyleRing) ? 1.0 : v.progress;
            NSImage *imgWhite = IdleIconImageInk(v.style, NSMakeSize(18, 18), prog, v.dimmed, v.latched, PAPER);
            NSImage *imgBlack = IdleIconImageInk(v.style, NSMakeSize(18, 18), prog, v.dimmed, v.latched, INK);
            NSImage *imgTpl   = IdleIconImage(v.style, NSMakeSize(18, 18), prog, v.dimmed, v.latched);

            drawText(v.label, NSMakePoint(LABEL_X, bottom + ROW_H / 2.0 - 20), TA);

            NSRect bDark  = NSMakeRect(BIG_X, bottom + 9, 78, 78);
            NSRect bLight = NSMakeRect(BIG_X + 84, bottom + 9, 78, 78);
            fillRect(bDark, DARK_BAR); fillRect(bLight, LIGHT_BAR);
            blit(imgWhite, NSInsetRect(bDark, 4, 4));
            blit(imgBlack, NSInsetRect(bLight, 4, 4));

            NSRect sDark  = NSMakeRect(SMALL_X, bottom + 9, 26, 26);
            NSRect sLight = NSMakeRect(SMALL_X + 30, bottom + 9, 26, 26);
            fillRect(sDark, DARK_BAR); fillRect(sLight, LIGHT_BAR);
            blit(imgWhite, NSInsetRect(sDark, 4, 4));
            blit(imgBlack, NSInsetRect(sLight, 4, 4));

            // template 原图（不染色，浅底上应显示为黑色笔画）→ 证明交给系统的 alpha 遮罩是对的
            NSRect sTpl = NSMakeRect(SMALL_X + 62, bottom + 9, 26, 26);
            fillRect(sTpl, LIGHT_BAR);
            blit(imgTpl, NSInsetRect(sTpl, 4, 4));

            CGFloat barY = bottom + 46;
            NSRect bar = NSMakeRect(SMALL_X, barY, 330, 22);
            fillRect(bar, DARK_BAR);
            for (int k = 0; k < 7; k++) {
                NSRect slot = NSMakeRect(bar.origin.x + 12 + k * 28, bar.origin.y + 2, 18, 18);
                if (k == 2) blit(imgWhite, slot);
                else { [[INK colorWithAlphaComponent:0.35] set]; [NSBezierPath fillRect:NSInsetRect(slot, 6, 6)]; }
            }
            drawText(@"18px · 最右为 template 原图", NSMakePoint(SMALL_X + 94, bottom + 14), SA);
            if (i < n - 1) { [GRID set]; NSBezierPath *ln = [NSBezierPath bezierPath];
                ln.lineWidth = 1; [ln moveToPoint:NSMakePoint(LABEL_X, bottom)];
                [ln lineToPoint:NSMakePoint(W - LABEL_X, bottom)]; [ln stroke]; }
        }

        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:@"/tmp/icons_sheet.png" atomically:YES];
        printf("写出 /tmp/icons_sheet.png (%dx%.0f)\n", (int)W, total);
    }
    return 0;
}
