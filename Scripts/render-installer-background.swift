import AppKit
import CoreText

// Render the approved warm-white installer artwork at Retina resolution.
// Finder supplies the real draggable icons; artwork contains no fake controls.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: render-installer-background.swift font.ttf output.png")
}
let fontURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil),
      let font = NSFont(name: "IslandMoments-Regular", size: 72) else {
    fatalError("Island Moments could not be registered")
}
let size = NSSize(width: 700, height: 422)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 844,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(srgbRed: 252/255, green: 250/255, blue: 246/255, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
let wordmark = NSAttributedString(string: "Muses · Polyhymnia", attributes: [
    .font: font,
    .foregroundColor: NSColor(srgbRed: 109/255, green: 82/255, blue: 44/255, alpha: 1)
])
let textSize = wordmark.size()
wordmark.draw(at: NSPoint(x: (size.width - textSize.width)/2, y: 275))
NSColor(srgbRed: 165/255, green: 138/255, blue: 86/255, alpha: 1).setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 2
arrow.move(to: NSPoint(x: 330, y: 185))
arrow.line(to: NSPoint(x: 370, y: 185))
arrow.move(to: NSPoint(x: 360, y: 193))
arrow.line(to: NSPoint(x: 370, y: 185))
arrow.line(to: NSPoint(x: 360, y: 177))
arrow.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: CommandLine.arguments[2]))
