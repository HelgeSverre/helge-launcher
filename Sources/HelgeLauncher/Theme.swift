import AppKit
import SwiftUI

/// Dark-first colour, radius and font tokens; each colour has a light value.
enum Theme {
    private static func dynamic(
        _ dark: UInt32,
        _ light: UInt32,
        darkAlpha: CGFloat = 1,
        lightAlpha: CGFloat = 1
    ) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            }
        )
    }

    static let ground = dynamic(0x0A0A0B, 0xFAFAF7)  // inputs, key caps
    static let surface = dynamic(0x111113, 0xFFFFFF)  // panel
    static let soft = dynamic(0x161718, 0xF7F7F3)  // footer, preview pane
    static let raised = dynamic(0x1B1C1F, 0xF2F2EE)  // menus, badges
    static let border = dynamic(0x222326, 0xE2E2DC)
    static let borderStrong = dynamic(0x2E3035, 0xC9C9C2)
    static let text = dynamic(0xE6E6E6, 0x18181B)
    static let text2 = dynamic(0xA0A3A8, 0x5C5C63)
    static let muted = dynamic(0x6B6F76, 0x6E6E75)
    static let accentText = dynamic(accentHex, 0x7A5C00)  // text and icons; dark gold on light
    static let accentSoft = dynamic(accentHex, accentHex, darkAlpha: 0.12, lightAlpha: 0.22)
    static let warn = dynamic(0xEAB308, 0xA9520C)
    static let err = dynamic(0xEF4444, 0xB83434)

    // Code
    static let synKeyword = dynamic(0xE8C547, 0x8A6A00)
    static let synString = dynamic(0xA8D58F, 0x3F7A2E)
    static let synType = dynamic(0x8FC1E8, 0x1F6AA5)
    static let synNumber = dynamic(0xF0A36B, 0xB4561C)
    static let synFunction = dynamic(0xC9B6F2, 0x6E48B8)
    static let synRemoved = dynamic(0xF0A3A0, 0x9B2F25)
    static let addedBackground = dynamic(0x6EBE64, 0x2F6A22, darkAlpha: 0.14, lightAlpha: 0.10)
    static let removedBackground = dynamic(0xEF4444, 0x9B2F25, darkAlpha: 0.13, lightAlpha: 0.10)
    static let note = dynamic(0x8FC1E8, 0x1F6AA5)

    static let panelSize = NSSize(width: 760, height: 480)
    static let radiusPanel: CGFloat = 12
    static let radiusRow: CGFloat = 8
    static let radiusChip: CGFloat = 6
    static let radiusSmall: CGFloat = 4

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom("Inter", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom("JetBrains Mono", size: size).weight(weight)
    }

    static func nsSans(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let desc = NSFontDescriptor(fontAttributes: [.family: "Inter"])
            .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: desc, size: size).flatMap { $0.familyName == "Inter" ? $0 : nil } ?? base
    }

    /// Text cursor colour.
    static let nsAccent = NSColor(hex: accentHex)
    private static let accentHex: UInt32 = 0xFACC15
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension View {
    /// Panel background and hairline border.
    func framedPanel() -> some View {
        background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel).strokeBorder(Theme.border, lineWidth: 1))
    }
}

extension NSImage {
    /// Stretchable rounded-rect mask for NSVisualEffectView; also shapes the window shadow.
    static func roundedMask(radius r: CGFloat) -> NSImage {
        let d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

extension NSVisualEffectView {
    /// Rounded blur container filled edge to edge by `content`.
    static func panel(containing content: NSView) -> NSVisualEffectView {
        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = .roundedMask(radius: Theme.radiusPanel)
        content.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            content.topAnchor.constraint(equalTo: fx.topAnchor),
            content.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        return fx
    }
}
