// Draws the placeholder app icon: a street corner with coloured kerb lines.
// Usage: swift scripts/make-app-icon.swift <output.png>
import AppKit
import CoreGraphics

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Background: deep slate.
context.setFillColor(color(0x18222D))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Two roads crossing, slightly lighter.
context.setFillColor(color(0x243445))
context.fill(CGRect(x: 0, y: 392, width: size, height: 240))
context.fill(CGRect(x: 392, y: 0, width: 240, height: size))

// Kerb lines in the app's status colours.
func line(_ hex: UInt32, _ from: CGPoint, _ to: CGPoint) {
    context.setStrokeColor(color(hex))
    context.setLineWidth(46)
    context.setLineCap(.round)
    context.move(to: from)
    context.addLine(to: to)
    context.strokePath()
}
line(0x30D158, CGPoint(x: 96, y: 660), CGPoint(x: 340, y: 660))   // free
line(0x40C8E0, CGPoint(x: 684, y: 660), CGPoint(x: 928, y: 660))  // paid
line(0xFFB340, CGPoint(x: 96, y: 364), CGPoint(x: 340, y: 364))   // conditional
line(0xFF6961, CGPoint(x: 684, y: 364), CGPoint(x: 928, y: 364))  // not allowed
line(0xBF8CFF, CGPoint(x: 364, y: 720), CGPoint(x: 364, y: 928))  // reserved
line(0xA0A6B2, CGPoint(x: 660, y: 96), CGPoint(x: 660, y: 304))   // unknown

let image = context.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
