import AppKit

struct IconError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
        green: CGFloat((rgb >> 8) & 0xff) / 255,
        blue: CGFloat(rgb & 0xff) / 255,
        alpha: alpha
    )
}

func fillPolygon(_ points: [CGPoint], color: CGColor, in context: CGContext) {
    context.beginPath()
    context.addLines(between: points)
    context.closePath()
    context.setFillColor(color)
    context.fillPath()
}

func drawIcon(in context: CGContext, pixels: Int) throws {
    let charcoal = color(0x22252B)
    let tileHighlight = color(0x343941)
    let paper = color(0xF5F0E6)
    let yellow = color(0xE7B84B)
    let graphite = color(0x42464E)
    let paperDetail = color(0xBBB6AB)
    let small = pixels <= 32
    // Core Graphics shadows use device-space dimensions, unlike the artwork paths.
    let shadowScale = CGFloat(pixels) / 1024

    context.scaleBy(x: shadowScale, y: shadowScale)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)

    let tile = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
        cornerWidth: 184, cornerHeight: 184, transform: nil
    )
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: 12 * shadowScale),
        blur: 20 * shadowScale, color: color(0, alpha: 0.24)
    )
    context.addPath(tile)
    context.setFillColor(charcoal)
    context.fillPath()
    context.restoreGState()

    guard let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [tileHighlight, charcoal] as CFArray,
        locations: [0, 1]
    ) else {
        throw IconError(message: "Could not create the icon background gradient.")
    }
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 230, y: 100), end: CGPoint(x: 720, y: 924),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

    context.saveGState()
    context.translateBy(x: 288, y: 254)
    context.rotate(by: -0.09)

    let sheet = CGMutablePath()
    sheet.move(to: CGPoint(x: 28, y: 0))
    sheet.addLine(to: CGPoint(x: 326, y: 0))
    sheet.addLine(to: CGPoint(x: 410, y: 84))
    sheet.addLine(to: CGPoint(x: 410, y: 492))
    sheet.addQuadCurve(to: CGPoint(x: 382, y: 520), control: CGPoint(x: 410, y: 520))
    sheet.addLine(to: CGPoint(x: 28, y: 520))
    sheet.addQuadCurve(to: CGPoint(x: 0, y: 492), control: CGPoint(x: 0, y: 520))
    sheet.addLine(to: CGPoint(x: 0, y: 28))
    sheet.addQuadCurve(to: CGPoint(x: 28, y: 0), control: .zero)
    sheet.closeSubpath()

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: 10 * shadowScale),
        blur: 18 * shadowScale, color: color(0, alpha: 0.28)
    )
    context.addPath(sheet)
    context.setFillColor(paper)
    context.fillPath()
    context.restoreGState()

    if !small {
        let fold = CGMutablePath()
        fold.move(to: CGPoint(x: 326, y: 0))
        fold.addLine(to: CGPoint(x: 326, y: 64))
        fold.addQuadCurve(to: CGPoint(x: 346, y: 84), control: CGPoint(x: 326, y: 84))
        fold.addLine(to: CGPoint(x: 410, y: 84))
        fold.closeSubpath()
        context.addPath(fold)
        context.setFillColor(color(0xBBB6AB, alpha: 0.55))
        context.fillPath()
    }

    context.setStrokeColor(paperDetail)
    context.setLineWidth(small ? 22 : 16)
    context.setLineCap(.round)
    let lineLengths: [CGFloat] = small ? [222, 164] : [230, 194, 122]
    for (index, length) in lineLengths.enumerated() {
        let y = CGFloat(166 + index * 72)
        context.move(to: CGPoint(x: 76, y: y))
        context.addLine(to: CGPoint(x: 76 + length, y: y))
        context.strokePath()
    }
    context.restoreGState()

    context.saveGState()
    context.translateBy(x: 520, y: 798)
    context.rotate(by: -0.94)

    let pencil = CGMutablePath()
    pencil.move(to: .zero)
    pencil.addLine(to: CGPoint(x: 78, y: -38))
    pencil.addLine(to: CGPoint(x: 490, y: -38))
    pencil.addQuadCurve(to: CGPoint(x: 502, y: -26), control: CGPoint(x: 502, y: -38))
    pencil.addLine(to: CGPoint(x: 502, y: 26))
    pencil.addQuadCurve(to: CGPoint(x: 490, y: 38), control: CGPoint(x: 502, y: 38))
    pencil.addLine(to: CGPoint(x: 78, y: 38))
    pencil.closeSubpath()

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: 8 * shadowScale),
        blur: 12 * shadowScale, color: color(0, alpha: 0.36)
    )
    context.addPath(pencil)
    context.setFillColor(yellow)
    context.fillPath()
    context.restoreGState()

    context.addPath(pencil)
    context.clip()
    context.setFillColor(paper)
    context.fill(CGRect(x: 0, y: -38, width: 78, height: 76))
    context.setFillColor(color(0xE7B84B, alpha: 0.3))
    context.fill(CGRect(x: 0, y: -38, width: 78, height: 76))
    fillPolygon(
        [.zero, CGPoint(x: 29, y: -14), CGPoint(x: 29, y: 14)],
        color: graphite, in: context
    )

    if !small {
        context.setFillColor(color(0xF5F0E6, alpha: 0.25))
        context.fill(CGRect(x: 78, y: -38, width: 374, height: 20))
        context.setFillColor(color(0x22252B, alpha: 0.16))
        context.fill(CGRect(x: 78, y: 19, width: 374, height: 19))
    }
    context.setFillColor(graphite)
    context.fill(CGRect(x: 454, y: -38, width: 48, height: 76))
    context.restoreGState()
}

func png(pixels: Int) throws -> Data {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        throw IconError(message: "Could not create a \(pixels)-pixel icon bitmap.")
    }
    try drawIcon(in: context, pixels: pixels)
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw IconError(message: "Could not encode the \(pixels)-pixel icon as PNG.")
    }
    return data
}

func generateIcon() throws {
    let manager = FileManager.default
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let support = root.appendingPathComponent("Support", isDirectory: true)
    let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try manager.createDirectory(at: iconset, withIntermediateDirectories: true)

    do {
        var images: [Int: Data] = [:]
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let data: Data
                if let cached = images[pixels] {
                    data = cached
                } else {
                    data = try png(pixels: pixels)
                    images[pixels] = data
                }
                let suffix = scale == 2 ? "@2x" : ""
                try data.write(
                    to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                )
            }
        }

        let icns = temporary.appendingPathComponent("AppIcon.icns")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["--convert", "icns", "--output", icns.path, iconset.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IconError(message: "iconutil failed with exit code \(process.terminationStatus).")
        }
        try Data(contentsOf: icns).write(to: support.appendingPathComponent("AppIcon.icns"), options: .atomic)
        guard let preview = images[1024] else {
            throw IconError(message: "The 1024-pixel icon preview was not rendered.")
        }
        try preview.write(to: support.appendingPathComponent("AppIcon.png"), options: .atomic)
    } catch {
        try manager.removeItem(at: temporary)
        throw error
    }
    try manager.removeItem(at: temporary)
}

do {
    try generateIcon()
    print("Generated Support/AppIcon.png and Support/AppIcon.icns")
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
