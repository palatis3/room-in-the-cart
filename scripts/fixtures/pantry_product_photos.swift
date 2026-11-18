// Generate three fictional packages for the explicitly seeded Photos-picker acceptance test.
// Usage: swift scripts/fixtures/pantry_product_photos.swift <output-directory>
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (index, (name, quantity)) in [("LENTILS", "500 g"), ("RICE", "1 kg"), ("JAR", "900 g")].enumerated() {
    let bounds = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let image = NSImage(size: bounds.size)
    image.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: bounds).fill()
    let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black]
    (name as NSString).draw(at: NSPoint(x: 80, y: 650), withAttributes: style)
    (quantity as NSString).draw(at: NSPoint(x: 80, y: 540), withAttributes: style)
    if index == 2 {
        let generator = CIFilter(name: "CIQRCodeGenerator")!
        generator.setValue(Data("3017620422003".utf8), forKey: "inputMessage")
        generator.setValue("M", forKey: "inputCorrectionLevel")
        let symbol = generator.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let cg = CIContext().createCGImage(symbol, from: symbol.extent)!
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: cg, size: symbol.extent.size).draw(at: NSPoint(x: 80, y: 100), from: .zero, operation: .copy, fraction: 1)
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!.cgImage!
    let url = directory.appendingPathComponent(name + ".jpg")
    let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let sourceDate = "2024:03:" + String(10 + index) + " 12:00:00"
    CGImageDestinationAddImage(output, bitmap, [
        kCGImageDestinationLossyCompressionQuality: 0.94,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: sourceDate, kCGImagePropertyExifDateTimeDigitized: sourceDate]
    ] as CFDictionary)
    precondition(CGImageDestinationFinalize(output))
}
