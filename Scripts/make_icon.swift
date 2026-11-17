import AppKit
import Foundation
let size = NSSize(width: 1024, height: 1024)
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSColor(red: 0.27, green: 0.39, blue: 0.33, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
let left = NSBezierPath()
left.move(to: NSPoint(x: 225, y: 300))
left.line(to: NSPoint(x: 225, y: 720))
left.curve(to: NSPoint(x: 500, y: 660), controlPoint1: NSPoint(x: 320, y: 760), controlPoint2: NSPoint(x: 435, y: 724))
left.line(to: NSPoint(x: 500, y: 240))
left.curve(to: NSPoint(x: 225, y: 300), controlPoint1: NSPoint(x: 405, y: 304), controlPoint2: NSPoint(x: 310, y: 336))
left.close()
NSColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1).setFill()
left.fill()
let right = NSBezierPath()
right.move(to: NSPoint(x: 524, y: 240))
right.line(to: NSPoint(x: 524, y: 660))
right.curve(to: NSPoint(x: 799, y: 720), controlPoint1: NSPoint(x: 589, y: 724), controlPoint2: NSPoint(x: 704, y: 760))
right.line(to: NSPoint(x: 799, y: 300))
right.curve(to: NSPoint(x: 524, y: 240), controlPoint1: NSPoint(x: 714, y: 336), controlPoint2: NSPoint(x: 619, y: 304))
right.close()
right.fill()
NSColor(red: 0.48, green: 0.59, blue: 0.49, alpha: 1).setStroke()
for y in stride(from: 375.0, through: 620.0, by: 64.0) {
 let line = NSBezierPath(); line.lineWidth = 14
 line.move(to: NSPoint(x: 575, y: y)); line.line(to: NSPoint(x: 746, y: y + 25)); line.stroke()
}
NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
