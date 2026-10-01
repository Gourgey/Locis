// Renders the app icon and the in-app logo from the artwork in Logo/logo.png.
// Usage: swift scripts/make-app-icon.swift   (run from the repository root)
//
// App Store icons must be 1024 x 1024 with no transparency, so the artwork is
// drawn onto an opaque canvas filled with its own background colour.
import AppKit
import CoreGraphics

let source = URL(fileURLWithPath: "Logo/logo.png")
guard let image = NSImage(contentsOf: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Cannot read \(source.path)")
}
guard image.width == image.height else { fatalError("The logo must be square") }

func render(_ size: Int, to path: String) {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // The artwork's background (#27292C), in case of any transparent edge pixels.
    context.setFillColor(CGColor(red: 0x27 / 255.0, green: 0x29 / 255.0, blue: 0x2C / 255.0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(size) px)")
}

let assets = "ios/Locis/Resources/Assets.xcassets"
render(1024, to: "\(assets)/AppIcon.appiconset/AppIcon.png")
for (scale, pixels) in [(1, 72), (2, 144), (3, 216)] {
    render(pixels, to: "\(assets)/Logo.imageset/logo@\(scale)x.png")
}
