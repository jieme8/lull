//
//  make_icon.m —— 生成 App 图标（.icns 用的 PNG 集）+ 候选方案预览图
//
//  用法：
//    make_icon --preview <输出png>        三种设计画在一张图上，供肉眼评审
//    make_icon --write <设计号> <iconset目录>   产出 icon_16x16.png … icon_512x512@2x.png
//
//  设计语言和菜单栏图标同源：屏幕框 + 地平线 + 太阳（= 露出壁纸）。
//  全部代码绘制，不依赖外部素材，改配色/形状重跑即可复现。
//
#import <AppKit/AppKit.h>
#include <math.h>

static NSBitmapImageRep *canvas(NSUInteger px) {
    return [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)px pixelsHigh:(NSInteger)px
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
}

static void beginCtx(NSBitmapImageRep *rep) {
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
}
static void endCtx(void) { [NSGraphicsContext restoreGraphicsState]; }

/// NSBitmapImageRep 本身不能 drawInRect:，得先包一层 NSImage
static void drawRep(NSBitmapImageRep *rep, NSRect dst) {
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(rep.pixelsWide, rep.pixelsHigh)];
    [img addRepresentation:rep];
    [img drawInRect:dst fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
}

static void writePNG(NSBitmapImageRep *rep, NSString *path) {
    NSData *d = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [d writeToFile:path atomically:YES];
}

/// Apple 图标栅格：画布 1024，图形占 80%，圆角比例约 0.2237
static NSRect gArt;
static void setArtRect(void) { CGFloat s = 1024 * 0.80; gArt = NSMakeRect((1024 - s) / 2, (1024 - s) / 2, s, s); }
static CGFloat AX(CGFloat t) { return gArt.origin.x + gArt.size.width * t; }
static CGFloat AY(CGFloat t) { return gArt.origin.y + gArt.size.height * t; }
static CGFloat AS(CGFloat t) { return gArt.size.width * t; }

static NSBezierPath *squircle(NSRect r) {
    CGFloat rad = r.size.width * 0.2237;
    return [NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad];
}

static void circleAt(NSPoint ctr, CGFloat radius, NSColor *color) {
    NSRect r = NSMakeRect(ctr.x - radius, ctr.y - radius, radius * 2, radius * 2);
    [color set];
    [[NSBezierPath bezierPathWithOvalInRect:r] fill];
}

/// 带光晕的太阳。用径向渐变一次画成 —— 早期用叠加同心圆模拟柔光，
/// 在 1024px 下会露出明显的同心色带（环状 banding），很难看。
static void sunWithGlow(NSPoint ctr, CGFloat radius, NSColor *core) {
    NSGradient *glow = [[NSGradient alloc] initWithColors:
        @[[core colorWithAlphaComponent:0.34], [core colorWithAlphaComponent:0.0]]];
    [glow drawFromCenter:ctr radius:radius * 0.55 toCenter:ctr radius:radius * 3.4 options:0];
    circleAt(ctr, radius, core);
}

/// 一条从左缘到右缘的山脊，下方填成实心。
/// 关键点：折线必须单调覆盖整个宽度并闭合到底边，否则会画出自交的怪形状。
static void ridge(NSArray<NSValue *> *topPts, NSColor *color) {
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:topPts.firstObject.pointValue];
    for (NSUInteger i = 1; i < topPts.count; i++) [p lineToPoint:topPts[i].pointValue];
    [p lineToPoint:NSMakePoint(NSMaxX(gArt), NSMinY(gArt))];
    [p lineToPoint:NSMakePoint(NSMinX(gArt), NSMinY(gArt))];
    [p closePath];
    [color set];
    [p fill];
}

static NSColor *rgb(double r, double g, double b) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1]; }
static NSColor *rgba(double r, double g, double b, double a) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }

/// 黄昏天空：紫蓝在上，暖橙落到地平线附近
static void skyGradient(void) {
    NSBezierPath *clip = squircle(gArt);
    [clip addClip];
    NSGradient *sky = [[NSGradient alloc] initWithColorsAndLocations:
                       rgb(0.07, 0.09, 0.24), 0.00,
                       rgb(0.20, 0.18, 0.42), 0.38,
                       rgb(0.62, 0.32, 0.36), 0.62,
                       rgb(0.96, 0.60, 0.33), 0.80,
                       rgb(1.00, 0.79, 0.48), 1.00, nil];
    [sky drawInBezierPath:clip angle:-90];
}

#pragma mark - 设计 A：黄昏壁纸（远山 + 近山 + 山脊之上的太阳）

static void landscape(void) {
    skyGradient();
    sunWithGlow(NSMakePoint(AX(0.66), AY(0.66)), AS(0.062), rgb(1.0, 0.95, 0.80));

    ridge(@[ [NSValue valueWithPoint:NSMakePoint(AX(0.00), AY(0.40))],
             [NSValue valueWithPoint:NSMakePoint(AX(0.22), AY(0.52))],
             [NSValue valueWithPoint:NSMakePoint(AX(0.40), AY(0.36))],
             [NSValue valueWithPoint:NSMakePoint(AX(0.62), AY(0.50))],
             [NSValue valueWithPoint:NSMakePoint(AX(0.82), AY(0.33))],
             [NSValue valueWithPoint:NSMakePoint(AX(1.00), AY(0.44)) ] ],
          rgba(0.33, 0.24, 0.42, 0.92));

    ridge(@[ [NSValue valueWithPoint:NSMakePoint(AX(0.00), AY(0.24))],
             [NSValue valueWithPoint:NSMakePoint(AX(0.18), AY(0.10))],
             [NSValue valueWithPoint:NSMakePoint(AX(0.38), AY(0.30))],
             [NSValue valueWithPoint:NSMakePoint(AX(0.58), AY(0.06))],
             [NSValue valueWithPoint:NSMakePoint(AX(0.78), AY(0.26))],
             [NSValue valueWithPoint:NSMakePoint(AX(1.00), AY(0.12)) ] ],
          rgb(0.07, 0.06, 0.13));
}

static void designWallpaper(void) { landscape(); }

#pragma mark - 设计 B：壁纸 + 一片被推开的玻璃窗

static void designReveal(void) {
    landscape();

    NSRect win = NSMakeRect(AX(0.20), AY(0.42), AS(0.50), AS(0.36));
    NSBezierPath *wp = squircle(win);
    [rgba(1, 1, 1, 0.14) set]; [wp fill];
    [[NSColor colorWithWhite:1 alpha:0.40] set]; wp.lineWidth = AS(0.006); [wp stroke];

    CGFloat titleH = win.size.height * 0.20;
    CGFloat dot = win.size.width * 0.022;
    for (int i = 0; i < 3; i++)
        circleAt(NSMakePoint(win.origin.x + win.size.width * 0.06 + i * dot * 3.2,
                             NSMaxY(win) - titleH * 0.5), dot, rgba(1, 1, 1, 0.75));

    NSBezierPath *sep = [NSBezierPath bezierPath];
    [sep moveToPoint:NSMakePoint(win.origin.x, NSMaxY(win) - titleH)];
    [sep lineToPoint:NSMakePoint(NSMaxX(win), NSMaxY(win) - titleH)];
    [[NSColor colorWithWhite:1 alpha:0.26] set]; sep.lineWidth = AS(0.0035); [sep stroke];

    for (int i = 0; i < 3; i++) {
        NSRect line = NSMakeRect(win.origin.x + win.size.width * 0.07,
                                 NSMaxY(win) - titleH - win.size.height * (0.16 + i * 0.17),
                                 win.size.width * (i == 2 ? 0.44 : 0.74), win.size.height * 0.055);
        NSBezierPath *lp = [NSBezierPath bezierPathWithRoundedRect:line xRadius:4 yRadius:4];
        [[NSColor colorWithWhite:1 alpha:0.22] set];
        [lp fill];
    }
}

#pragma mark - 设计 C：石墨底 + 线稿风景（笔画比例按图标尺度重画，不是放大菜单栏字形）

static void lineRidge(NSArray<NSValue *> *topPts, NSColor *color, CGFloat lw) {
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:topPts.firstObject.pointValue];
    for (NSUInteger i = 1; i < topPts.count; i++) [p lineToPoint:topPts[i].pointValue];
    [color set];
    p.lineWidth = lw; p.lineJoinStyle = NSRoundLineJoinStyle; p.lineCapStyle = NSRoundLineCapStyle;
    [p stroke];
}

static void designGlyph(void) {
    NSBezierPath *clip = squircle(gArt);
    [clip addClip];
    NSGradient *bg = [[NSGradient alloc] initWithColorsAndLocations:
                      rgb(0.20, 0.21, 0.25), 0.0, rgb(0.05, 0.06, 0.08), 1.0, nil];
    [bg drawInBezierPath:clip angle:-90];

    // 空闲进度环
    NSPoint ctr = NSMakePoint(512, 512);
    CGFloat ringR = AS(0.34);
    NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:
                           NSMakeRect(ctr.x - ringR, ctr.y - ringR, ringR * 2, ringR * 2)];
    [[NSColor colorWithWhite:1 alpha:0.10] set]; track.lineWidth = AS(0.020); [track stroke];

    CGContextRef c = [[NSGraphicsContext currentContext] CGContext];
    CGContextSaveGState(c);
    CGContextSetStrokeColorWithColor(c, rgba(0.45, 0.80, 1.0, 1).CGColor);
    CGContextSetLineWidth(c, AS(0.020));
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextAddArc(c, ctr.x, ctr.y, ringR, M_PI_2, M_PI_2 - M_PI * 1.30, 1);
    CGContextStrokePath(c);
    CGContextRestoreGState(c);

    // 线稿：屏幕框 + 地平线 + 太阳，笔画按图标尺度取 1.4%
    CGFloat lw = AS(0.014);
    NSRect frame = NSMakeRect(AX(0.26), AY(0.34), AS(0.48), AS(0.32));
    NSBezierPath *fr = [NSBezierPath bezierPathWithRoundedRect:frame xRadius:AS(0.026) yRadius:AS(0.026)];
    [[NSColor colorWithWhite:0.97 alpha:1] set]; fr.lineWidth = lw; [fr stroke];

    lineRidge(@[ [NSValue valueWithPoint:NSMakePoint(frame.origin.x + frame.size.width * 0.12, frame.origin.y + frame.size.height * 0.34)],
                 [NSValue valueWithPoint:NSMakePoint(frame.origin.x + frame.size.width * 0.36, frame.origin.y + frame.size.height * 0.72)],
                 [NSValue valueWithPoint:NSMakePoint(frame.origin.x + frame.size.width * 0.56, frame.origin.y + frame.size.height * 0.40)],
                 [NSValue valueWithPoint:NSMakePoint(frame.origin.x + frame.size.width * 0.78, frame.origin.y + frame.size.height * 0.66)],
                 [NSValue valueWithPoint:NSMakePoint(NSMaxX(frame) - frame.size.width * 0.12, frame.origin.y + frame.size.height * 0.34)] ],
              [NSColor colorWithWhite:0.97 alpha:1], lw);
    circleAt(NSMakePoint(frame.origin.x + frame.size.width * 0.72, NSMaxY(frame) - frame.size.height * 0.26),
             AS(0.022), [NSColor colorWithWhite:0.97 alpha:1]);
}

typedef void (*DesignFn)(void);
static DesignFn designFor(int n) {
    if (n == 2) return designGlyph;
    if (n == 1) return designReveal;
    return designWallpaper;
}
static const char *designName(int n) {
    if (n == 2) return "C 石墨底+菜单栏字形";
    if (n == 1) return "B 壁纸+被推走的窗口";
    return "A 纯壁纸";
}

static NSBitmapImageRep *render(int design) {
    NSBitmapImageRep *rep = canvas(1024);
    beginCtx(rep);
    setArtRect();
    designFor(design)();
    endCtx();
    return rep;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 3 && strcmp(argv[1], "--preview") == 0) {
            int cells = 3;
            CGFloat pad = 26, label = 46, cell = 470;
            CGFloat W = pad * 2 + cells * cell + (cells - 1) * pad;
            CGFloat H = pad * 2 + cell + label;
            NSBitmapImageRep *sheet = [[NSBitmapImageRep alloc]
                initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)W pixelsHigh:(NSInteger)H
                bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            beginCtx(sheet);
            [[NSColor colorWithCalibratedWhite:0.90 alpha:1] set];
            [NSBezierPath fillRect:NSMakeRect(0, 0, W, H)];
            for (int i = 0; i < cells; i++) {
                NSRect dst = NSMakeRect(pad + i * (cell + pad), pad + label, cell, cell);
                [[NSColor colorWithCalibratedWhite:0.78 alpha:1] set];
                [NSBezierPath fillRect:NSInsetRect(dst, -1, -1)];
                drawRep(render(i), dst);
                NSDictionary *attrs = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:19],
                                         NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.15 alpha:1] };
                [[NSString stringWithFormat:@"%s", designName(i)]
                    drawAtPoint:NSMakePoint(dst.origin.x, pad + 8) withAttributes:attrs];
            }
            endCtx();
            writePNG(sheet, [NSString stringWithUTF8String:argv[2]]);
            printf("预览已写出：%s\n", argv[2]);
            return 0;
        }

        if (argc >= 4 && strcmp(argv[1], "--write") == 0) {
            int design = atoi(argv[2]);
            NSString *dir = [NSString stringWithUTF8String:argv[3]];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            NSBitmapImageRep *big = render(design);
            struct { int px; NSString *name; } sizes[] = {
                {16, @"icon_16x16.png"}, {32, @"icon_16x16@2x.png"},
                {32, @"icon_32x32.png"}, {64, @"icon_32x32@2x.png"},
                {128, @"icon_128x128.png"}, {256, @"icon_128x128@2x.png"},
                {256, @"icon_256x256.png"}, {512, @"icon_256x256@2x.png"},
                {512, @"icon_512x512.png"}, {1024, @"icon_512x512@2x.png"},
            };
            for (unsigned i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
                NSBitmapImageRep *out = canvas(sizes[i].px);
                beginCtx(out);
                [[NSColor clearColor] set];
                [NSBezierPath fillRect:NSMakeRect(0, 0, sizes[i].px, sizes[i].px)];
                drawRep(big, NSMakeRect(0, 0, sizes[i].px, sizes[i].px));
                endCtx();
                writePNG(out, [dir stringByAppendingPathComponent:sizes[i].name]);
            }
            printf("已写出 10 个尺寸到 %s（设计 %s）\n", dir.UTF8String, designName(design));
            return 0;
        }

        printf("用法：make_icon --preview <png> | make_icon --write <0|1|2> <iconset目录>\n");
        return 2;
    }
}
