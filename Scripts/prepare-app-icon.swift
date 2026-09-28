import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: prepare-app-icon.swift source.png output.png")
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: 1_024, height: 1_024,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not read the source icon")
}

let bounds = CGRect(x: 0, y: 0, width: 1_024, height: 1_024)
// Preserve the original white-backed artwork. macOS supplies the outer shape.
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(bounds)
context.interpolationQuality = .high
context.draw(image, in: bounds)

guard let flattened = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create the app icon")
}
CGImageDestinationAddImage(destination, flattened, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not save the app icon")
}
