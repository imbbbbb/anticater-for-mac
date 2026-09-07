#!/usr/bin/env swift
//
// 生成应用图标。用代码画而不是塞一张 PNG，是为了让图标可复现、可修改，
// 也免得往仓库里放二进制资源。
//
//   swift Tools/make-icon.swift <输出目录>
//
// 产出 icon_1024.png，交给 make-icon.sh 去切各档尺寸并打包成 .icns。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: side, height: side,
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("建不了绘图上下文") }

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let S = Double(side)
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// macOS 的图标不铺满画布：内容约占 82%，四周留白给系统投影。
let inset = S * 0.09
let plate = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let corner = plate.width * 0.225

// 底板：深灰到近黑的竖向渐变，模仿旋钮的金属外壳。
let platePath = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner,
                       transform: nil)
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
if let gradient = CGGradient(colorsSpace: space,
                             colors: [rgb(58, 60, 66), rgb(24, 25, 28)] as CFArray,
                             locations: [0, 1]) {
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: plate.maxY),
                           end: CGPoint(x: 0, y: plate.minY),
                           options: [])
}
ctx.restoreGState()

// 顶部一道高光边，让底板看起来有厚度。
ctx.saveGState()
ctx.addPath(platePath)
ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
ctx.setLineWidth(S * 0.006)
ctx.strokePath()
ctx.restoreGState()

let center = CGPoint(x: S / 2, y: S / 2)

// 刻度环：一圈短线，中间留一段缺口作为「零位」。
let tickRadius = plate.width * 0.375
let tickCount = 36
ctx.setLineCap(.round)
for i in 0..<tickCount {
    // 从正下方开始逆时针排，底部留出 3 格缺口。
    let gap = 3
    if i < gap { continue }
    let t = Double(i) / Double(tickCount)
    let angle = .pi / 2 + t * 2 * .pi
    let isMajor = i % 9 == 0
    let length = plate.width * (isMajor ? 0.055 : 0.032)
    let inner = tickRadius - length
    ctx.setStrokeColor(isMajor ? rgb(255, 255, 255, 0.55) : rgb(255, 255, 255, 0.22))
    ctx.setLineWidth(plate.width * (isMajor ? 0.016 : 0.011))
    ctx.move(to: CGPoint(x: center.x + cos(angle) * inner,
                         y: center.y + sin(angle) * inner))
    ctx.addLine(to: CGPoint(x: center.x + cos(angle) * tickRadius,
                            y: center.y + sin(angle) * tickRadius))
    ctx.strokePath()
}

// 旋钮本体
let knobRadius = plate.width * 0.255
let knobRect = CGRect(x: center.x - knobRadius, y: center.y - knobRadius,
                      width: knobRadius * 2, height: knobRadius * 2)
ctx.saveGState()
ctx.addEllipse(in: knobRect)
ctx.clip()
if let gradient = CGGradient(colorsSpace: space,
                             colors: [rgb(246, 247, 250), rgb(176, 180, 190)] as CFArray,
                             locations: [0, 1]) {
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: knobRect.maxY),
                           end: CGPoint(x: 0, y: knobRect.minY),
                           options: [])
}
ctx.restoreGState()

// 旋钮边缘的暗色描边，把它和底板分开。
ctx.setStrokeColor(rgb(0, 0, 0, 0.35))
ctx.setLineWidth(plate.width * 0.010)
ctx.strokeEllipse(in: knobRect)

// 指示线：从中心指向右上 45°，表示「已旋转」而不是停在正中。
let markAngle = Double.pi * 0.25
let markInner = knobRadius * 0.30
let markOuter = knobRadius * 0.78
ctx.setStrokeColor(rgb(232, 78, 62))
ctx.setLineWidth(plate.width * 0.030)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: center.x + cos(markAngle) * markInner,
                     y: center.y + sin(markAngle) * markInner))
ctx.addLine(to: CGPoint(x: center.x + cos(markAngle) * markOuter,
                        y: center.y + sin(markAngle) * markOuter))
ctx.strokePath()

// 中心的小凹点
ctx.setFillColor(rgb(120, 124, 134, 0.9))
let dot = plate.width * 0.022
ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot,
                           width: dot * 2, height: dot * 2))

guard let image = ctx.makeImage() else { fatalError("出图失败") }
let url = URL(fileURLWithPath: outputDir).appendingPathComponent("icon_1024.png")
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                 1, nil)
else { fatalError("建不了输出文件: \(url.path)") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("写文件失败") }
print("已生成 \(url.path)")
