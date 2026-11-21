#!/usr/bin/env swift
// Builds the macOS app icon set from square artwork.
// Usage: swift Scripts/make-icon.swift Support/Icon/icon-art.png Sources/FluidPlay/Resources/Assets.xcassets/AppIcon.appiconset
//
// The artwork is masked to Apple's macOS icon grid (an 824 pt continuous-corner squircle centred on a
// 1024 pt canvas) with a soft drop shadow, then rendered at every size the asset catalog needs.

import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count == 3, let art = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write("usage: make-icon.swift <artwork.png> <AppIcon.appiconset>\n".data(using: .utf8)!)
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Renders the icon at `pixels` × `pixels`.
func render(pixels: Int) -> Data? {
    let scale = CGFloat(pixels) / 1024
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: tile).cgPath

    // Shadow under the tile (Apple grid: about 10 pt down, 20 pt blur).
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.32))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 0.05, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Artwork clipped to the tile.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    var rect = tile
    if let cgArt = art.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
        context.draw(cgArt, in: tile)
    }
    // Thin inner highlight along the edge, like system icons.
    context.addPath(shape)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    guard let image = context.makeImage() else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: image)
    return bitmap.representation(using: .png, properties: [:])
}

struct Entry: Encodable {
    let size: String
    let idiom = "mac"
    let filename: String
    let scale: String
}

var entries: [Entry] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        guard let data = render(pixels: pixels) else { exit(1) }
        try data.write(to: output.appendingPathComponent(name))
        entries.append(Entry(size: "\(points)x\(points)", filename: name, scale: "\(scale)x"))
    }
}

struct Contents: Encodable {
    struct Info: Encodable {
        let author = "xcode"
        let version = 1
    }
    let images: [Entry]
    let info = Info()
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(Contents(images: entries)).write(to: output.appendingPathComponent("Contents.json"))
print("Icon set written to \(output.path)")
