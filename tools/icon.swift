// Renders assets/AppIcon.png in the Helge Terminal icon style (dark tile, thin rim, yellow glyph).
// usage: swift tools/icon.swift <variant> <out.png> [size]
import AppKit

let args = CommandLine.arguments
let variant = args.count > 1 ? args[1] : "magnifier"
let out = args.count > 2 ? args[2] : "assets/AppIcon.png"
let S = CGFloat(args.count > 3 ? Double(args[3])! : 1024)

let fill = CGColor(srgbRed: 16/255, green: 16/255, blue: 19/255, alpha: 1)
let rim = CGColor(srgbRed: 42/255, green: 44/255, blue: 46/255, alpha: 1)
let yellow = CGColor(srgbRed: 252/255, green: 208/255, blue: 1/255, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
// Flip to top-left origin so coordinates read like the source art.
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)

let templateOnly = variant == "template"
let glyphVariant = templateOnly ? "magnifier" : variant

// Tile: same proportions as Helge Terminal (82% of canvas, ~22% corner radius, rim ~0.65%).
let inset = S * 0.088
let tile = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let radius = tile.width * 0.215
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
if !templateOnly { ctx.addPath(tilePath); ctx.setFillColor(rim); ctx.fillPath() }
let rimW = S * 0.0068
let innerRect = tile.insetBy(dx: rimW, dy: rimW)
ctx.addPath(CGPath(roundedRect: innerRect, cornerWidth: radius - rimW, cornerHeight: radius - rimW, transform: nil))
ctx.setFillColor(fill)
if templateOnly { ctx.beginPath() } else { ctx.fillPath() }

// Glyph geometry in "tile units": u = tile width.
let u = tile.width
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * u, y: tile.minY + y * u) }
let stroke = u * 0.066           // matches the terminal chevron
let ink = templateOnly ? CGColor(gray: 0, alpha: 1) : yellow
ctx.setStrokeColor(ink); ctx.setFillColor(ink)
if templateOnly {
    // Fill the menu-bar height: undo the tile inset so the glyph spans the canvas.
    let k: CGFloat = 1.0 / 0.62
    ctx.translateBy(x: S / 2, y: S / 2); ctx.scaleBy(x: k, y: k); ctx.translateBy(x: -S / 2, y: -S / 2)
}
ctx.setLineWidth(stroke); ctx.setLineCap(.round); ctx.setLineJoin(.round)

/// The terminal's cursor bar: square-ended, same thickness family (0.068u tall).
func bar(from a: CGPoint, to b: CGPoint, thickness: CGFloat) {
    ctx.saveGState(); ctx.setLineCap(.butt); ctx.setLineWidth(thickness)
    ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath(); ctx.restoreGState()
}

switch glyphVariant {
case "magnifier":
    // Lens ring (terminal stroke weight) + square-cut handle echoing the terminal's cursor bar,
    // optically centered: the whole glyph's bounding box sits in the middle of the tile.
    let r = u * 0.150, handle = u * 0.160, thick = u * 0.068
    let d = 1 / sqrt(2.0)
    let left = r + stroke / 2
    let right = (r + stroke * 0.42 + handle) * d + thick / 2 * d
    let cc = 0.5 - (left + right) / u / 2 + left / u
    let c = P(cc, cc)
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.strokePath()
    let start = CGPoint(x: c.x + (r + stroke * 0.42) * d, y: c.y + (r + stroke * 0.42) * d)
    bar(from: start, to: CGPoint(x: start.x + handle * d, y: start.y + handle * d), thickness: thick)
case "prompt":
    // Search prompt: the terminal's ">" chevron shrunk, followed by a lens.
    ctx.move(to: P(0.25, 0.34)); ctx.addLine(to: P(0.40, 0.49)); ctx.addLine(to: P(0.25, 0.64)); ctx.strokePath()
    let c = P(0.60, 0.46), r = u * 0.10
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.strokePath()
    let d = 1 / sqrt(2.0)
    let s0 = CGPoint(x: c.x + (r + stroke * 0.5) * d, y: c.y + (r + stroke * 0.5) * d)
    bar(from: s0, to: CGPoint(x: s0.x + u * 0.12 * d, y: s0.y + u * 0.12 * d), thickness: u * 0.068)
case "prompt2":
    // Same optical size as the terminal's ">_" (glyph spans ~0.25–0.75 of the tile).
    let k: CGFloat = 0.86
    ctx.translateBy(x: tile.midX, y: tile.midY); ctx.scaleBy(x: k, y: k); ctx.translateBy(x: -tile.midX, y: -tile.midY)
    ctx.setLineWidth(stroke / k * 0.95)
    // ">" at Helge Terminal's size; a lens takes the cursor's place.
    ctx.move(to: P(0.225, 0.305)); ctx.addLine(to: P(0.415, 0.495)); ctx.addLine(to: P(0.225, 0.685)); ctx.strokePath()
    let c = P(0.645, 0.475), r = u * 0.110
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.strokePath()
    let d = 1 / sqrt(2.0)
    let s0 = CGPoint(x: c.x + (r + stroke * 0.42) * d, y: c.y + (r + stroke * 0.42) * d)
    bar(from: s0, to: CGPoint(x: s0.x + u * 0.105 * d, y: s0.y + u * 0.105 * d), thickness: u * 0.068)
case "launch":
    // "^_": the terminal's ">_" turned upward — launch.
    ctx.move(to: P(0.25, 0.56)); ctx.addLine(to: P(0.43, 0.38)); ctx.addLine(to: P(0.61, 0.56)); ctx.strokePath()
    bar(from: P(0.25, 0.70), to: P(0.75, 0.70), thickness: u * 0.068)
default:
    fatalError("unknown variant")
}

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
