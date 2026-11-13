import Foundation
import ImageIO
import CoreGraphics

struct Crop: Encodable {
    let file: String
    let width: Int
    let height: Int
    let luminanceP01: Double
    let luminanceP99: Double
    let contrastEstimate: Double
    let darkInkRows: [[Int]]
}
let linear = (0...255).map { byte -> Double in
    let v = Double(byte) / 255
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}
var results: [Crop] = []
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
          let data = context.data else { fatalError("Cannot decode " + path) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    let pixels = (0..<(image.width * image.height)).map { pixel -> Double in
        let i = pixel * 4
        return 0.2126 * linear[Int(bytes[i])] + 0.7152 * linear[Int(bytes[i+1])] + 0.0722 * linear[Int(bytes[i+2])]
    }
    let sorted = pixels.sorted(), trim = sorted.count / 100
    let low = sorted[trim], high = sorted[sorted.count-1-trim]
    // Descriptive dark-ink row bands only, in bitmap order; decorations can contribute.
    let occupied = (0..<image.height).filter { y in
        (0..<image.width).filter { pixels[y*image.width+$0] < high - 0.2 }.count >= 3
    }
    var bands: [[Int]] = []
    for row in occupied {
        if let last = bands.last, row == last[1]+1 { bands[bands.count-1][1] = row }
        else { bands.append([row,row]) }
    }
    results.append(Crop(file:path,width:image.width,height:image.height,luminanceP01:low,luminanceP99:high,
        contrastEstimate:(high+0.05)/(low+0.05),darkInkRows:bands))
}
let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(results))
