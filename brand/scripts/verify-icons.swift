import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Run from brand/: swift scripts/verify-icons.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func load(_ path: String) -> (CGImage, [UInt8]) {
    let source = CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes {
        let c = CGContext(data: $0.baseAddress, width: image.width, height: image.height,
                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return (image, bytes)
}
func luminance(_ rgb: [Double]) -> Double {
    let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
}
func rgb(_ hex: String) -> [Double] {
    let number = Int(hex.dropFirst(), radix: 16)!
    return [Double((number >> 16) & 255), Double((number >> 8) & 255), Double(number & 255)].map { $0 / 255 }
}
func ratio(_ a: [Double], _ b: [Double]) -> Double {
    let l = [luminance(a), luminance(b)].sorted()
    return (l[1] + 0.05) / (l[0] + 0.05)
}
let (master, pixels) = load("icon/meter-icon-1024.png")
precondition(master.width == 1024 && master.height == 1024)
var exteriorCount = 0
var badAlpha = 0
var minX = 1024, minY = 1024, maxX = 0, maxY = 0
for y in 0..<1024 {
    for x in 0..<1024 {
        let px = Double(x) + 0.5, py = Double(y) + 0.5
        let cx = min(739.0, max(285.0, px)), cy = min(739.0, max(285.0, py))
        let outside = px < 100 || px >= 924 || py < 100 || py >= 924 || pow(px - cx, 2) + pow(py - cy, 2) >= 185 * 185
        let i = (y * 1024 + x) * 4
        if outside {
            exteriorCount += 1
            if pixels[i + 3] != 0 { badAlpha += 1 }
            precondition(pixels[i...i+3].allSatisfy { $0 == 0 }, "Nonzero exterior RGBA at \(x),\(y)")
        }
        if pixels[i + 3] > 0 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
    }
}
precondition([minX, minY, maxX, maxY] == [100, 100, 923, 923])
var expected = Set<String>()
for point in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
        expected.insert(filename)
        let (image, bytes) = load("icon/Meter.iconset/" + filename)
        precondition(image.width == point * scale && image.height == point * scale)
        precondition(bytes[3] == 0 && bytes[bytes.count - 1] == 0)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let px = (Double(x) + 0.5) * 1024 / Double(image.width)
                let py = (Double(y) + 0.5) * 1024 / Double(image.height)
                let cx = min(739.0, max(285.0, px)), cy = min(739.0, max(285.0, py))
                if px < 100 || px >= 924 || py < 100 || py >= 924 || pow(px - cx, 2) + pow(py - cy, 2) >= 185 * 185 {
                    let i = (y * image.width + x) * 4
                    precondition(bytes[i...i+3].allSatisfy { $0 == 0 }, "Exterior spill in \(filename) at \(x),\(y)")
                }
            }
        }
    }
}
let actual = Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("icon/Meter.iconset").path))
precondition(actual == expected, "Unexpected iconset contents")
let palette = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("palette.json"))) as! [String: Any]
let accent = palette["accent"] as! [String: String]
let contrast = palette["contrast"] as! [String: Any]
for appearance in ["light", "dark"] {
    let stored = contrast["accent_" + appearance] as! [String: Double]
    for (key, background) in [("on_white", "#FFFFFF"), ("on_near_black", "#10181C"), ("on_paper", "#F5F7F8")] {
        let measured = (ratio(rgb(accent[appearance]!), rgb(background)) * 100).rounded() / 100
        precondition(abs(stored[key]! - measured) < 0.001, "Palette ratio mismatch")
        print("\(appearance) \(key): \(measured):1")
    }
}
// Compare actual 16px glyph pixels against nearby glass pixels, on both backdrops.
let (small, smallPixels) = load("icon/Meter.iconset/icon_16x16.png")
func sample(_ x: Int, _ y: Int, _ backdrop: [Double]) -> [Double] {
    let i = (y * 16 + x) * 4, alpha = Double(smallPixels[(y * 16 + x) * 4 + 3]) / 255
    return (0..<3).map { Double(smallPixels[i + $0]) / 255 + backdrop[$0] * (1 - alpha) }
}
for background in ["#FFFFFF", "#10181C"] {
    let backdrop = rgb(background)
    let arc = ratio(sample(7, 5, backdrop), sample(7, 3, backdrop))
    let needle = ratio(sample(9, 8, backdrop), sample(8, 7, backdrop))
    precondition(arc >= 3 && needle >= 3, "16px glyph contrast below 3:1")
    print(String(format: "16px on %@: arc %.2f:1, needle %.2f:1", background, arc, needle))
}
let preview = CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8,
                        bytesPerRow: 640 * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for (column, background) in ["#FFFFFF", "#10181C"].enumerated() {
    let c = rgb(background)
    preview.setFillColor(CGColor(red: c[0], green: c[1], blue: c[2], alpha: 1))
    preview.fill(CGRect(x: column * 320, y: 0, width: 320, height: 320))
    preview.interpolationQuality = .none
    preview.draw(small, in: CGRect(x: column * 320 + 80, y: 80, width: 160, height: 160))
    preview.draw(small, in: CGRect(x: column * 320 + 152, y: 32, width: 16, height: 16))
}
let output = root.appendingPathComponent("concepts/light-gauge-size-check.png")
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, preview.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
print("PASS: \(exteriorCount) exterior pixels tested; \(badAlpha) nontransparent; 100px margins; ten iconset sizes correct")
