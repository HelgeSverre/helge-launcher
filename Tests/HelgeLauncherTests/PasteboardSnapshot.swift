import AppKit

/// Every item and type on the system pasteboard, written back by `restore()`.
@MainActor
struct PasteboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init() {
        items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
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
