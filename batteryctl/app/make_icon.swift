import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 生成 AppIcon.icns。
//
// 用 Swift/CoreGraphics 而不是 Python，因为 Homebrew 的 python3 不含 PyObjC，
// 而 Command Line Tools 自带 Swift 与 CoreGraphics。

func makePNG(size: Int, paper: CGColor, ink: CGColor, accent: CGColor) -> Data? {
    let s = CGFloat(size)
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else { return nil }

    // 圆角方形底
    let radius = s * 0.22
    let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                    cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bg)
    ctx.setFillColor(paper)
    ctx.fillPath()

    // 电池外壳
    let bw = s * 0.56, bh = s * 0.30
    let bx = (s - bw) / 2.0, by = (s - bh) / 2.0
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(max(s * 0.035, 1.0))
    let body = CGPath(roundedRect: CGRect(x: bx, y: by, width: bw, height: bh),
                      cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil)
    ctx.addPath(body)
    ctx.strokePath()

    // 正极凸起
    let tipW = s * 0.05, tipH = s * 0.12
    let tip = CGPath(roundedRect: CGRect(x: bx + bw, y: by + (bh - tipH) / 2.0,
                                         width: tipW, height: tipH),
                     cornerWidth: tipW * 0.4, cornerHeight: tipW * 0.4, transform: nil)
    ctx.addPath(tip)
    ctx.setFillColor(ink)
    ctx.fillPath()

    // 电量条
    let pad = s * 0.045
    let fw = (bw - pad * 2) * 0.72
    let fh = bh - pad * 2
    let fill = CGPath(roundedRect: CGRect(x: bx + pad, y: by + pad, width: fw, height: fh),
                      cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil)
    ctx.addPath(fill)
    ctx.setFillColor(accent)
    ctx.fillPath()

    guard let img = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

func icnsEntry(_ type: String, _ payload: Data) -> Data {
    var out = Data(type.utf8)
    var len = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
    out.append(payload)
    return out
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

let paper = CGColor(red: 0.16, green: 0.19, blue: 0.24, alpha: 1.0)
let ink = CGColor(red: 0.92, green: 0.94, blue: 0.97, alpha: 1.0)
let accent = CGColor(red: 0.30, green: 0.80, blue: 0.45, alpha: 1.0)

// (ICNS 类型码, 像素尺寸)
let specs: [(String, Int)] = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64),
    ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
]

var entries = Data()
for (type, size) in specs {
    guard let png = makePNG(size: size, paper: paper, ink: ink, accent: accent) else {
        FileHandle.standardError.write(Data("无法生成 \(size)px 图标\n".utf8))
        exit(1)
    }
    entries.append(icnsEntry(type, png))
}

var out = Data("icns".utf8)
var total = UInt32(entries.count + 8).bigEndian
withUnsafeBytes(of: &total) { out.append(contentsOf: $0) }
out.append(entries)

do {
    try out.write(to: URL(fileURLWithPath: outPath))
    print("已生成 \(outPath) (\(out.count) 字节)")
} catch {
    FileHandle.standardError.write(Data("写入失败: \(error)\n".utf8))
    exit(1)
}
