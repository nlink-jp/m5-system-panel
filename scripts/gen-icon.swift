import AppKit

// Renders the m5-system-panel app icon (1024x1024 PNG): the panel itself — a dark
// M5Stack body whose screen shows the overview page's four quadrants (CPU cyan,
// GPU orange, memory purple, network upload red above / download green below) in
// the colours the firmware draws them, with the three buttons underneath.
// Run: swift scripts/gen-icon.swift [out.png]

let size = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/AppIcon-1024.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!

let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
let S = CGFloat(size)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}
func fillRounded(_ rect: CGRect, _ radius: CGFloat, _ color: CGColor) {
    cg.setFillColor(color)
    cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.fillPath()
}
func gradient(_ rect: CGRect, _ radius: CGFloat, top: CGColor, bottom: CGColor) {
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    cg.restoreGState()
}

// The firmware's colours (display.cpp), as sRGB.
let cpu = rgb(0.00, 1.00, 1.00)
let gpu = rgb(1.00, 0.64, 0.00)
let mem = rgb(0.74, 0.56, 1.00)
let up = rgb(1.00, 0.42, 0.42)
let down = rgb(0.37, 0.83, 0.55)
let frame = rgb(0.16, 0.17, 0.20)

// Rounded-rect plate (macOS squircle proportions), as net-meter's gen-icon.swift.
let inset: CGFloat = 96
let plate = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let plateRadius = plate.width * 0.2237

// A filled area graph along `rect`'s bottom (or hanging from its top when `hang`).
func area(_ rect: CGRect, _ values: [CGFloat], _ color: CGColor, hang: Bool = false) {
    let step = rect.width / CGFloat(values.count - 1)
    let path = CGMutablePath()
    let base = hang ? rect.maxY : rect.minY
    path.move(to: CGPoint(x: rect.minX, y: base))
    for (i, v) in values.enumerated() {
        let y = hang ? rect.maxY - v * rect.height : rect.minY + v * rect.height
        path.addLine(to: CGPoint(x: rect.minX + CGFloat(i) * step, y: y))
    }
    path.addLine(to: CGPoint(x: rect.maxX, y: base))
    path.closeSubpath()
    cg.setFillColor(color)
    cg.addPath(path)
    cg.fillPath()
}

// The overview screen: four quadrants with a graph each.
func screen(_ rect: CGRect, radius: CGFloat) {
    fillRounded(rect, radius, rgb(0, 0, 0))
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.clip()
    let pad = rect.width * 0.045
    let gap = rect.width * 0.035
    let qw = (rect.width - 2 * pad - gap) / 2
    let qh = (rect.height - 2 * pad - gap) / 2
    let tl = CGRect(x: rect.minX + pad, y: rect.minY + pad + qh + gap, width: qw, height: qh)
    let tr = CGRect(x: tl.maxX + gap, y: tl.minY, width: qw, height: qh)
    let bl = CGRect(x: tl.minX, y: rect.minY + pad, width: qw, height: qh)
    let br = CGRect(x: tr.minX, y: bl.minY, width: qw, height: qh)
    let r = qw * 0.08
    for q in [tl, tr, bl, br] { fillRounded(q, r, frame) }
    let inner: (CGRect) -> CGRect = { $0.insetBy(dx: $0.width * 0.08, dy: $0.height * 0.12) }
    area(inner(tl), [0.20, 0.35, 0.30, 0.55, 0.45, 0.70, 0.62, 0.85], cpu)
    area(inner(tr), [0.15, 0.20, 0.45, 0.40, 0.30, 0.55, 0.75, 0.60], gpu)
    area(inner(bl), [0.55, 0.56, 0.58, 0.60, 0.61, 0.63, 0.64, 0.66], mem)
    let n = inner(br)
    let mid = n.midY
    let lineHalf = n.height * 0.03
    area(CGRect(x: n.minX, y: mid + lineHalf, width: n.width, height: n.maxY - mid - lineHalf),
         [0.25, 0.60, 0.40, 0.85, 0.50, 0.30, 0.70, 0.45], up)
    area(CGRect(x: n.minX, y: n.minY, width: n.width, height: mid - lineHalf - n.minY),
         [0.50, 0.30, 0.75, 0.45, 0.90, 0.60, 0.35, 0.55], down, hang: true)
    cg.restoreGState()
}

gradient(plate, plateRadius, top: rgb(0.86, 0.88, 0.91), bottom: rgb(0.66, 0.69, 0.74))
// The M5Stack body: nearly square, dark, with the screen above the buttons.
let body = CGRect(x: plate.minX + 96, y: plate.minY + 86, width: plate.width - 192, height: plate.height - 172)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: rgb(0, 0, 0, 0.35))
fillRounded(body, 70, rgb(0.13, 0.14, 0.16))
cg.restoreGState()
gradient(body, 70, top: rgb(0.22, 0.23, 0.26), bottom: rgb(0.10, 0.11, 0.13))
let screenRect = CGRect(x: body.minX + 58, y: body.minY + 150, width: body.width - 116, height: (body.width - 116) * 0.75)
screen(screenRect, radius: 22)
// Three buttons under the screen.
let bw: CGFloat = 96, bh: CGFloat = 30
let by = body.minY + 62
for i in 0..<3 {
    let cx = screenRect.minX + screenRect.width * (CGFloat(i) + 0.5) / 3
    fillRounded(CGRect(x: cx - bw / 2, y: by, width: bw, height: bh), bh / 2, rgb(0.55, 0.57, 0.62))
}

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
