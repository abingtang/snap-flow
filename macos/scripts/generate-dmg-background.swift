#!/usr/bin/env swift
/// 生成 DMG 安装窗口背景：提示用户将 App 拖到「应用程序」。
/// 用法：
///   swift scripts/generate-dmg-background.swift [输出.png]
import AppKit

let width = 640
let height = 400
let args = CommandLine.arguments
let outPath: String = {
    if args.count >= 2 { return args[1] }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("dmg-resources/background.png")
        .path
}()

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("无法创建位图\n", stderr)
    exit(1)
}

// 固定 1x 像素，避免 lockFocus 在 Retina 上放大
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let bounds = NSRect(x: 0, y: 0, width: width, height: height)

// 深色底
let bg = NSGradient(
    starting: srgb(0.10, 0.11, 0.14),
    ending: srgb(0.14, 0.16, 0.20)
)
bg?.draw(in: bounds, angle: -35)

// 中部浅提示带
srgb(1, 1, 1, 0.04).setFill()
NSBezierPath(roundedRect: NSRect(x: 40, y: 70, width: width - 80, height: 220), xRadius: 16, yRadius: 16).fill()

// 箭头：左 App → 右 Applications
let arrowY = CGFloat(height) * 0.48
let arrowStartX: CGFloat = 250
let arrowEndX: CGFloat = 390
let arrowColor = srgb(0.45, 0.72, 1.0, 0.95)
arrowColor.setStroke()
arrowColor.setFill()
let line = NSBezierPath()
line.lineWidth = 4
line.lineCapStyle = .round
line.move(to: NSPoint(x: arrowStartX, y: arrowY))
line.line(to: NSPoint(x: arrowEndX - 8, y: arrowY))
line.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: arrowEndX, y: arrowY))
head.line(to: NSPoint(x: arrowEndX - 16, y: arrowY + 10))
head.line(to: NSPoint(x: arrowEndX - 16, y: arrowY - 10))
head.close()
head.fill()

// 主标题
let title = "将 SnapFlow 拖到「应用程序」"
let subtitle = "拖拽左侧应用图标 → 右侧文件夹，即可完成安装"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
    .foregroundColor: srgb(0.95, 0.96, 0.98),
]
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
    .foregroundColor: srgb(0.72, 0.76, 0.82),
]
let titleSize = title.size(withAttributes: titleAttrs)
let subSize = subtitle.size(withAttributes: subAttrs)
title.draw(
    at: NSPoint(x: (CGFloat(width) - titleSize.width) / 2, y: CGFloat(height) - 56),
    withAttributes: titleAttrs
)
subtitle.draw(
    at: NSPoint(x: (CGFloat(width) - subSize.width) / 2, y: CGFloat(height) - 84),
    withAttributes: subAttrs
)

// 底部轻提示
let foot = "安装后可从启动台或「应用程序」打开"
let footAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: srgb(0.55, 0.58, 0.64),
]
let footSize = foot.size(withAttributes: footAttrs)
foot.draw(
    at: NSPoint(x: (CGFloat(width) - footSize.width) / 2, y: 28),
    withAttributes: footAttrs
)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("PNG 编码失败\n", stderr)
    exit(1)
}

let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(
    at: outURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
do {
    try png.write(to: outURL, options: .atomic)
    fputs("Wrote \(outURL.path) (\(width)x\(height))\n", stderr)
} catch {
    fputs("写入失败: \(error)\n", stderr)
    exit(1)
}
