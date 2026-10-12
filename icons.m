// 图标字形实现 —— App 与预览工具共用
#import "icons.h"
#include <math.h>

static NSBezierPath *rounded(NSRect r, CGFloat radius) {
    return [NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius];
}

static void strokeArcPath(NSPoint ctr, CGFloat radius, CGFloat startDeg, CGFloat endDeg,
                          NSColor *color, CGFloat lw) {
    CGContextRef c = [[NSGraphicsContext currentContext] CGContext];
    if (!c) return;
    CGContextSaveGState(c);
    CGContextSetStrokeColorWithColor(c, color.CGColor);
    CGContextSetLineWidth(c, lw);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextAddArc(c, ctr.x, ctr.y, radius, startDeg * M_PI / 180.0, endDeg * M_PI / 180.0, 1);
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
}

#pragma mark - 字形（都在 18x18 网格内设计，u = 目标高/18）

/// 壁纸：屏幕框 + 地平线 + 太阳
static void glyphWallpaper(NSRect b, NSColor *ink, CGFloat a, BOOL latched) {
    CGFloat u = b.size.height / 18.0;
    NSRect f = NSInsetRect(b, 1.5 * u, 3.0 * u);
    [[ink colorWithAlphaComponent:a] set];
    NSRect in = NSInsetRect(f, 1.3 * u, 1.3 * u);
    CGFloat hy = in.origin.y + in.size.height * 0.30;

    if (latched) {
        // 桌面已露出 = 地平线以下填成实心"地面"，而不是整块填实（18px 下整块填实会糊成一坨）
        NSBezierPath *fr = rounded(f, 1.6 * u);
        fr.lineWidth = MAX(1.2, 1.5 * u);
        [fr stroke];
        [[NSBezierPath bezierPathWithRect:NSMakeRect(in.origin.x, in.origin.y,
                                                     in.size.width, hy - in.origin.y)] fill];
        return;
    }

    NSBezierPath *fr = rounded(f, 1.6 * u);
    fr.lineWidth = MAX(1.2, 1.5 * u);
    [fr stroke];

    NSBezierPath *h = [NSBezierPath bezierPath];
    h.lineWidth = MAX(1.0, 1.4 * u);
    [h moveToPoint:NSMakePoint(in.origin.x + in.size.width * 0.14, hy)];
    [h lineToPoint:NSMakePoint(in.origin.x + in.size.width * 0.86, hy)];
    [h stroke];

    CGFloat r = 1.25 * u;
    NSRect sun = NSMakeRect(in.origin.x + in.size.width * 0.62 - r,
                            in.origin.y + in.size.height * 0.62 - r, r * 2, r * 2);
    [[NSBezierPath bezierPathWithOvalInRect:sun] fill];
}

/// 显示器：屏幕 + 支架 + 底座
static void glyphMonitor(NSRect b, NSColor *ink, CGFloat a, BOOL latched) {
    CGFloat u = b.size.height / 18.0;
    [[ink colorWithAlphaComponent:a] set];
    NSRect f = NSMakeRect(b.origin.x + 2.0 * u, b.origin.y + 4.6 * u,
                          b.size.width - 4.0 * u, b.size.height - 7.4 * u);
    if (latched) {
        [NSBezierPath fillRect:f];
    } else {
        NSBezierPath *fr = rounded(f, 1.4 * u);
        fr.lineWidth = MAX(1.2, 1.5 * u);
        [fr stroke];
    }
    CGFloat cx = NSMidX(b);
    NSBezierPath *stand = [NSBezierPath bezierPath];
    stand.lineWidth = MAX(1.2, 1.5 * u);
    [stand moveToPoint:NSMakePoint(cx, f.origin.y)];
    [stand lineToPoint:NSMakePoint(cx, b.origin.y + 2.4 * u)];
    [stand stroke];

    NSBezierPath *foot = [NSBezierPath bezierPath];
    foot.lineWidth = MAX(1.2, 1.5 * u);
    [foot moveToPoint:NSMakePoint(cx - 3.0 * u, b.origin.y + 2.2 * u)];
    [foot lineToPoint:NSMakePoint(cx + 3.0 * u, b.origin.y + 2.2 * u)];
    [foot stroke];
}

/// 进度环：外环随空闲时间增长，环内是一个带地平线的小屏幕
static void glyphRing(NSRect b, NSColor *ink, CGFloat a, BOOL latched, CGFloat progress) {
    CGFloat u = b.size.height / 18.0;
    CGFloat d = b.size.height - 0.8 * u;
    NSRect circ = NSMakeRect(b.origin.x + (b.size.width - d) / 2.0,
                             b.origin.y + (b.size.height - d) / 2.0, d, d);
    NSPoint ctr = NSMakePoint(NSMidX(circ), NSMidY(circ));

    NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:circ];
    track.lineWidth = MAX(0.9, 1.1 * u);
    [[ink colorWithAlphaComponent:a * 0.18] set];   // 轨道再淡一点，避免和进度弧混成"断掉的圆"
    [track stroke];

    if (progress > 0.005) {
        strokeArcPath(ctr, circ.size.width / 2.0, 90.0, 90.0 - 360.0 * MIN(progress, 1.0),
                      [ink colorWithAlphaComponent:a], MAX(1.1, 1.4 * u));
    }

    NSRect f = NSMakeRect(b.origin.x + (b.size.width - 9.8 * u) / 2.0,
                          b.origin.y + (b.size.height - 6.8 * u) / 2.0, 9.8 * u, 6.8 * u);
    [[ink colorWithAlphaComponent:a] set];
    if (latched) { [NSBezierPath fillRect:f]; return; }

    NSBezierPath *fr = rounded(f, 1.0 * u);
    fr.lineWidth = MAX(1.0, 1.25 * u);
    [fr stroke];

    NSBezierPath *h = [NSBezierPath bezierPath];
    h.lineWidth = MAX(0.9, 1.1 * u);
    CGFloat hy = f.origin.y + f.size.height * 0.30;
    [h moveToPoint:NSMakePoint(f.origin.x + f.size.width * 0.16, hy)];
    [h lineToPoint:NSMakePoint(NSMaxX(f) - f.size.width * 0.16, hy)];
    [h stroke];
}

static void renderGlyph(IdleIconStyle style, NSRect r, NSColor *ink, CGFloat a,
                        CGFloat progress, BOOL latched) {
    switch (style) {
        case IdleIconStyleMonitor: glyphMonitor(r, ink, a, latched); break;
        case IdleIconStyleRing:    glyphRing(r, ink, a, latched, progress); break;
        case IdleIconStyleWallpaper:
        default:                   glyphWallpaper(r, ink, a, latched); break;
    }
}

#pragma mark - 对外接口

NSString *IdleIconStyleName(IdleIconStyle style) {
    switch (style) {
        case IdleIconStyleMonitor: return @"显示器";
        case IdleIconStyleRing:    return @"进度环";
        default:                   return @"壁纸";
    }
}

NSImage *IdleIconImageInk(IdleIconStyle style, NSSize size, CGFloat progress, BOOL dimmed,
                          BOOL latched, NSColor *ink) {
    CGFloat a = dimmed ? 0.32 : 1.0;
    NSImage *img = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect r) {
        renderGlyph(style, r, ink, a, progress, latched);
        return YES;
    }];
    return img;
}

NSImage *IdleIconImage(IdleIconStyle style, NSSize size, CGFloat progress, BOOL dimmed, BOOL latched) {
    NSImage *img = IdleIconImageInk(style, size, progress, dimmed, latched,
                                    [NSColor colorWithCalibratedWhite:0 alpha:1]);
    img.template = YES;      // 关键：template 图由系统按菜单栏深浅自动反色
    return img;
}
