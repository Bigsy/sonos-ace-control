import AppKit

// Draw the app icon as a vector so every iconset size comes from one source.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift generate_app_icon.swift output.png\n", stderr)
    exit(1)
}

let size = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create icon bitmap")
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(deviceRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let tile = NSBezierPath(roundedRect: NSRect(x: 35, y: 35, width: 954, height: 954),
                        xRadius: 220, yRadius: 220)
NSGradient(starting: color(35, 60, 74), ending: color(10, 22, 36))!
    .draw(in: tile, angle: 115)

// A quiet inset gives the silhouette depth without losing clarity at Dock size.
let inset = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920),
                         xRadius: 204, yRadius: 204)
inset.lineWidth = 4
color(157, 208, 217, 0.16).setStroke()
inset.stroke()

let band = NSBezierPath()
band.move(to: NSPoint(x: 275, y: 433))
band.curve(to: NSPoint(x: 749, y: 433),
           controlPoint1: NSPoint(x: 264, y: 840),
           controlPoint2: NSPoint(x: 760, y: 840))
band.lineWidth = 78
band.lineCapStyle = .round
band.lineJoinStyle = .round
color(130, 194, 204, 0.20).setStroke()
band.stroke()

let innerBand = NSBezierPath()
innerBand.move(to: NSPoint(x: 275, y: 433))
innerBand.curve(to: NSPoint(x: 749, y: 433),
                controlPoint1: NSPoint(x: 264, y: 840),
                controlPoint2: NSPoint(x: 760, y: 840))
innerBand.lineWidth = 60
innerBand.lineCapStyle = .round
color(232, 243, 238).setStroke()
innerBand.stroke()

for x in [218.0, 684.0] {
    let cup = NSBezierPath(roundedRect: NSRect(x: x, y: 297, width: 122, height: 280),
                            xRadius: 59, yRadius: 59)
    color(228, 240, 235).setFill()
    cup.fill()
}

// Dark openings read as ear cushions when the icon is enlarged.
let leftCushion = NSBezierPath(roundedRect: NSRect(x: 281, y: 354, width: 28, height: 165),
                               xRadius: 14, yRadius: 14)
let rightCushion = NSBezierPath(roundedRect: NSRect(x: 715, y: 354, width: 28, height: 165),
                                xRadius: 14, yRadius: 14)
color(43, 73, 80).setFill()
leftCushion.fill()
rightCushion.fill()

// One small accent makes this icon distinct from the monochrome menu bar mark.
let accent = NSBezierPath(roundedRect: NSRect(x: 735, y: 390, width: 10, height: 84),
                          xRadius: 5, yRadius: 5)
color(245, 166, 126).setFill()
accent.fill()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode app icon")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
