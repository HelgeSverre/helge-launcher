import AppKit
import SwiftUI

/// Design tokens shared with Splash / Shepherd / Trace: near-black surfaces separated by hairlines,
/// one signal-yellow accent, Inter for text and JetBrains Mono for anything machine-ish (keys, ids).
/// Dark-first; every token has a light value too.
enum Theme {
    private static func dynamic(_ dark: UInt32, _ light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    static let ground = dynamic(0x0A0A0B, 0xFAFAF7)        // inputs, key caps
    static let surface = dynamic(0x111113, 0xFFFFFF)       // panel
    static let soft = dynamic(0x161718, 0xF7F7F3)          // footer, preview pane
    static let raised = dynamic(0x1B1C1F, 0xF2F2EE)        // menus, badges
    static let hover = dynamic(0x202127, 0xECECE6)
    static let border = dynamic(0x222326, 0xE2E2DC)
    static let borderStrong = dynamic(0x2E3035, 0xC9C9C2)
    static let text = dynamic(0xE6E6E6, 0x18181B)
    static let text2 = dynamic(0xA0A3A8, 0x5C5C63)
    static let muted = dynamic(0x6B6F76, 0x6E6E75)
    static let accent = dynamic(0xFACC15, 0xFACC15)
    static let accentText = dynamic(0xFACC15, 0x7A5C00)    // yellow used as text/icon; dark gold on light
    static let accentSoft = dynamic(0xFACC15, 0xFACC15, darkAlpha: 0.12, lightAlpha: 0.22)
    static let warn = dynamic(0xEAB308, 0xA9520C)
    static let err = dynamic(0xEF4444, 0xB83434)
    static let ok = dynamic(0x22C55E, 0x1F7A47)

    static let radiusPanel: CGFloat = 12
    static let radiusRow: CGFloat = 8
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

    static var nsAccent: NSColor { NSColor(hex: 0xFACC15) }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// A key cap: mono, bordered, on the darkest ground.
struct KeyCap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(Theme.mono(11, .medium))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(Theme.ground))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.borderStrong, lineWidth: 1))
    }
}
