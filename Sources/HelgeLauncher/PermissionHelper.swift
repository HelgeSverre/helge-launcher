import AppKit
import ApplicationServices
import SwiftUI

/// Opens System Settings → Privacy & Security → Accessibility and pins a small panel to the
/// Settings window with the app icon, which can be dragged straight into the list.
/// Closes itself once the permission is granted or Settings is closed.
@MainActor
final class PermissionHelper {
    static let shared = PermissionHelper()

    private var panel: NSPanel?
    private var timer: Timer?
    private var sawSettings = false
    private var started = Date()

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Opens the helper unless Accessibility is already granted.
    func requestIfNeeded() {
        guard !isTrusted else { return }
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
        if panel == nil { panel = makePanel() }
        sawSettings = false
        started = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func tick() {
        if isTrusted {
            stop()
            Launcher.shared?.toast("Accessibility enabled")
            return
        }
        guard let frame = settingsWindowFrame() else {
            // Give Settings a few seconds to open; close the helper when the user closes Settings.
            if sawSettings || Date().timeIntervalSince(started) > 8 { stop() } else { panel?.orderOut(nil) }
            return
        }
        sawSettings = true
        place(panel, below: frame)
    }

    /// System Settings' main window in Cocoa coordinates. Window bounds need no Screen Recording permission.
    private func settingsWindowFrame() -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  owner == "System Settings" || owner == "System Preferences",
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 300, height > 200 else { continue }
            return NSRect(x: x, y: primaryHeight - y - height, width: width, height: height)
        }
        return nil
    }

    /// Centers under the content (right-hand) side of the Settings window; overlaps its bottom edge
    /// when there is no room below.
    private func place(_ p: NSPanel?, below s: NSRect) {
        guard let p else { return }
        let sidebar: CGFloat = min(260, s.width * 0.32)
        let contentMidX = s.minX + sidebar + (s.width - sidebar) / 2
        var origin = NSPoint(x: contentMidX - p.frame.width / 2, y: s.minY - p.frame.height - 10)
        let screen = NSScreen.screens.first { $0.frame.intersects(s) } ?? NSScreen.main
        if let vf = screen?.visibleFrame, origin.y < vf.minY { origin.y = s.minY + 16 }
        if p.frame.origin != origin { p.setFrameOrigin(origin) }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    /// Debug: renders the helper content to a PNG (visual-effect blur replaced by a flat dark fill).
    func renderPreview(to path: String) {
        let host = NSHostingView(rootView: HelperView(onClose: {})
            .background(Theme.surface))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        CLI.writePNG(host, to: path)
        print("helper size \(host.fittingSize)")
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 68),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = .roundedMask(radius: Theme.radiusPanel)

        let host = NSHostingView(rootView: HelperView(onClose: { [weak self] in self?.stop() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        p.contentView = fx
        // Size the panel to its content so the text never clips or wraps awkwardly.
        p.setContentSize(host.fittingSize)
        p.invalidateShadow()
        return p
    }
}

private struct HelperView: View {
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            DragIcon().frame(width: 44, height: 44)
            Text("Drag Helge Launcher into the list")
                .font(Theme.sans(13, .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .fixedSize()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
        .padding(.vertical, 12)
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .fixedSize()
        .background(Color.panelFill)
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// The app icon as a drag source carrying the bundle's file URL, which the Accessibility list accepts.
private struct DragIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }
    func updateNSView(_ v: DragSourceView, context: Context) {}
}

final class DragSourceView: NSView, NSDraggingSource {
    private let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
