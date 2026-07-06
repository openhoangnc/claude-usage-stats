import AppKit

// Renders the app icon at a given pixel size. Usage: generate_icon <size> <out.png>
let size = CGFloat(Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "1024") ?? 1024)
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "icon.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let S = size
func rrect(_ r: NSRect, _ rad: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad)
}

// Rounded-square background with a subtle vertical depth gradient.
let inset = S * 0.086
let bgRect = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let bg = rrect(bgRect, S * 0.184)
NSGradient(starting: NSColor(srgbRed: 0.145, green: 0.160, blue: 0.208, alpha: 1),
           ending:   NSColor(srgbRed: 0.082, green: 0.094, blue: 0.130, alpha: 1))!
    .draw(in: bg, angle: -90)

// Three usage bars (green → gold → orange), increasing length — the app's motif.
let barH = S * 0.088
let gap = S * 0.052
let leftX = inset + S * 0.135
let maxW = (S - inset - S * 0.135) - leftX
let startY = (S - (3 * barH + 2 * gap)) / 2
let fracs: [CGFloat] = [0.52, 0.70, 0.88]
let colors = [
    NSColor(srgbRed: 0.000, green: 0.820, blue: 0.298, alpha: 1),  // green  #00D14C
    NSColor(srgbRed: 0.816, green: 0.706, blue: 0.000, alpha: 1),  // gold   #D0B400
    NSColor(srgbRed: 1.000, green: 0.620, blue: 0.239, alpha: 1),  // orange #FF9E3D
]
for i in 0..<3 {
    let y = startY + CGFloat(2 - i) * (barH + gap)   // i = 0 is the top bar
    NSColor(white: 1, alpha: 0.12).setFill()
    rrect(NSRect(x: leftX, y: y, width: maxW, height: barH), barH / 2).fill()
    colors[i].setFill()
    rrect(NSRect(x: leftX, y: y, width: maxW * fracs[i], height: barH), barH / 2).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(Int(size))px)")
