import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Normalize the edited light concept, then constrain every pixel to the tile.
// Two paths normalize the edited concept; one path clears resampling spill in place.
guard [2, 3].contains(CommandLine.arguments.count) else { fatalError("Expected one PNG path, or source and destination PNG paths") }
let normalize = CommandLine.arguments.count == 3
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = normalize ? URL(fileURLWithPath: CommandLine.arguments[2]) : input
let source = CGImageSourceCreateWithURL(input as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
guard image.width == image.height else { fatalError("Expected a square PNG") }
if normalize { precondition(image.width == 1254, "Expected the approved 1254 px edited concept") }
// Trim the generated perimeter, including its stray white and translucent pixels.
let crop = normalize ? image.cropping(to: CGRect(x: 113, y: 124, width: 1018, height: 1014))! : image
let size = normalize ? 1024 : image.width
let scale = Double(size) / 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
var pixels = [UInt8](repeating: 0, count: size * size * 4)
pixels.withUnsafeMutableBytes { bytes in
    let context = CGContext(data: bytes.baseAddress, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let tile = normalize ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: size, height: size)
    if normalize {
        context.setFillColor(CGColor(red: 245/255, green: 247/255, blue: 248/255, alpha: 1))
        context.fill(tile)
    }
    context.interpolationQuality = .high
    context.draw(crop, in: tile)
}
// An inward-only one-pixel antialias band has no alpha outside the analytic
// rounded square. Clear RGB there too, avoiding hidden white matte pixels.
let radius = 185.0
for y in 0..<size {
    for x in 0..<size {
        let dx = max(abs((Double(x) + 0.5) / scale - 512) - (412 - radius), 0)
        let dy = max(abs((Double(y) + 0.5) / scale - 512) - (412 - radius), 0)
        let distance = hypot(dx, dy) - radius
        let coverage = normalize ? min(1, max(0, -distance)) : (distance >= 0 ? 0.0 : 1.0)
        let i = (y * size + x) * 4
        for channel in 0..<4 { pixels[i + channel] = UInt8((Double(pixels[i + channel]) * coverage).rounded()) }
    }
}
let provider = CGDataProvider(data: Data(pixels) as CFData)!
let final = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: size * 4, space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, final, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("PNG write failed") }
if normalize { print("Wrote 1024 px light master: 824 px tile, 100 px margins, radius 185 px") }
