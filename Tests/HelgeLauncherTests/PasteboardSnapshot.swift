import AppKit

/// Every item and type on the system pasteboard, written back by `restore()`.
@MainActor
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init() {
        items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { types[t] = d } }
            return types
        }
    }

    func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let restored = items.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
    }
}
