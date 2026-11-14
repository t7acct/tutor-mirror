// Draws the TutorMirror app icon and writes a 1024×1024 PNG.
//   swift Resources/make-icon.swift out.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])!
}

// Rounded-square tile with a soft shadow, in the standard macOS icon shape.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(color(40, 50, 120)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let gradient = CGGradient(colorsSpace: cs, colors: [color(92, 84, 255), color(38, 132, 255), color(22, 200, 196)] as CFArray,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// Gentle highlight across the top.
let shine = CGGradient(colorsSpace: cs, colors: [color(255, 255, 255, 0.22), color(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
ctx.restoreGState()

// Back screen (the Mac's copy), offset up and to the right.
let back = CGRect(x: 330, y: 432, width: 470, height: 340)
ctx.addPath(CGPath(roundedRect: back, cornerWidth: 44, cornerHeight: 44, transform: nil))
ctx.setFillColor(color(255, 255, 255, 0.16)); ctx.fillPath()
ctx.addPath(CGPath(roundedRect: back, cornerWidth: 44, cornerHeight: 44, transform: nil))
ctx.setStrokeColor(color(255, 255, 255, 0.55)); ctx.setLineWidth(18); ctx.strokePath()

// Front tablet (the iPad).
let front = CGRect(x: 224, y: 260, width: 500, height: 366)
let frontPath = CGPath(roundedRect: front, cornerWidth: 50, cornerHeight: 50, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(10, 20, 80, 0.45))
ctx.addPath(frontPath); ctx.setFillColor(color(255, 255, 255)); ctx.fillPath()
ctx.restoreGState()

// Handwriting stroke on the tablet.
ctx.saveGState()
ctx.addPath(frontPath); ctx.clip()
let ink = CGMutablePath()
ink.move(to: CGPoint(x: 300, y: 400))
ink.addCurve(to: CGPoint(x: 420, y: 470), control1: CGPoint(x: 330, y: 520), control2: CGPoint(x: 400, y: 540))
ink.addCurve(to: CGPoint(x: 400, y: 380), control1: CGPoint(x: 440, y: 410), control2: CGPoint(x: 360, y: 340))
ink.addCurve(to: CGPoint(x: 540, y: 470), control1: CGPoint(x: 450, y: 430), control2: CGPoint(x: 500, y: 520))
ink.addCurve(to: CGPoint(x: 650, y: 440), control1: CGPoint(x: 580, y: 420), control2: CGPoint(x: 600, y: 350))
ctx.addPath(ink)
ctx.setStrokeColor(color(64, 96, 255)); ctx.setLineWidth(30); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
