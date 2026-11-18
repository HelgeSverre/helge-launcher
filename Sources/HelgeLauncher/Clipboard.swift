import AppKit
import CryptoKit

/// Polls NSPasteboard.changeCount and keeps a persisted history of text, links, files and images.
final class ClipboardHistory {
    static let shared = ClipboardHistory()

    struct Entry: Codable {
        var id: String
        var kind: Kind
        /// The text, URL, file path, or image file name in `clipboard-images/`.
        var text: String
        var app: String?
        var date: Double
        var pinned: Bool = false
    }

    /// Stored as its raw string; kinds written by other versions round-trip unchanged.
    struct Kind: Codable, Hashable {
        let raw: String

        static let text = Kind(raw: "text")
        static let link = Kind(raw: "link")
        static let file = Kind(raw: "file")
        static let image = Kind(raw: "image")
        static let color = Kind(raw: "color")

        init(raw: String) { self.raw = raw }
        init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(raw)
        }

        /// `link` for a single http(s) URL, `color` for `#rrggbb`, else `text`.
        static func classify(_ s: String) -> Kind {
            if (s.hasPrefix("http://") || s.hasPrefix("https://")) && !s.contains(" ") { return .link }
            if s.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil { return .color }
            return .text
        }
    }

    private(set) var entries: [Entry] = []
    private var timer: Timer?
    private var lastChange = Pasteboard.board.changeCount
    private let url = Paths.supportDir.appendingPathComponent("clipboard.json")
    private let imageDir = Paths.supportDir.appendingPathComponent("clipboard-images")
    var config = ClipboardConfig()

    /// False while any set-aside history exists: its images may be referenced there, so none are removed.
    private var loadedCleanly = true
    /// False when an unreadable history couldn't be moved aside; it is then never overwritten this session.
    private var canSave = true

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: imageDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([Entry].self, from: d) {
                entries = e
            } else {
                setAside()
            }
        }
        if !setAsideFiles.isEmpty { loadedCleanly = false }
    }

    /// `clipboard.json.corrupt*` and the legacy `clipboard.json.moving`.
    private var setAsideFiles: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasPrefix("clipboard.json.corrupt") || $0 == "clipboard.json.moving" }
    }

    /// Moves an unreadable history to its own `clipboard.json.corrupt-<time>` file in one step.
    private func setAside() {
        loadedCleanly = false
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let name = "clipboard.json.corrupt-\(stamp)-\(UUID().uuidString.prefix(4))"
        let aside = url.deletingLastPathComponent().appendingPathComponent(name)
        if (try? FileManager.default.moveItem(at: url, to: aside)) == nil {
            canSave = false
            NSLog(
                "Helge Launcher: clipboard.json is unreadable and couldn't be moved aside; history won't be saved this session"
            )
        }
    }

    func removeUnreferencedImages() {
        guard loadedCleanly else { return }
        let referenced = Set(entries.filter { $0.kind == .image }.map(\.text))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: imageDir.path)) ?? []
        where !referenced.contains(name) {
            try? FileManager.default.removeItem(at: imageDir.appendingPathComponent(name))
        }
    }

    func start() {
        guard timer == nil else { return }
        removeUnreferencedImages()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        let pb = Pasteboard.board
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let types = pb.types ?? []
        if types.contains(where: { Pasteboard.skippedTypes.contains($0.rawValue) }) { return }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let app, config.ignoreApps.contains(app) { return }

        var entry: Entry?
        let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        if let f = files?.first {
            entry = Entry(id: UUID().uuidString, kind: .file, text: f.path, app: app, date: now)
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entry = Entry(id: UUID().uuidString, kind: .classify(s), text: s, app: app, date: now)
        } else if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        {
            let name = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined() + ".png"
            let file = imageDir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) { try? png.write(to: file) }
            entry = Entry(id: UUID().uuidString, kind: .image, text: name, app: app, date: now)
        }
        guard var e = entry else { return }
        if let i = entries.firstIndex(where: { $0.kind == e.kind && $0.text == e.text }) {
            e.pinned = entries[i].pinned
            entries.remove(at: i)
        }
        entries.insert(e, at: 0)
        trim()
        save()
    }

    private var now: Double { Date().timeIntervalSince1970 }

    /// Keeps every pinned entry and the newest `max_items` (at least 1) unpinned ones.
    private func trim() {
        let limit = max(1, config.maxItems)
        var unpinned = 0
        let removed = entries.filter { e in
            if e.pinned { return false }
            unpinned += 1
            return unpinned > limit
        }
        remove(Set(removed.map(\.id)))
    }

    /// Removes entries, and image files no remaining entry references unless a set-aside history exists.
    private func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let gone = entries.filter { ids.contains($0.id) }
        entries.removeAll { ids.contains($0.id) }
        guard loadedCleanly else { return }
        for e in gone where e.kind == .image && !entries.contains(where: { $0.kind == .image && $0.text == e.text }) {
            try? FileManager.default.removeItem(at: imageDir.appendingPathComponent(e.text))
        }
    }

    private func save() {
        guard canSave else { return }
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: url, options: .atomic) }
    }

    func togglePin(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].pinned.toggle()
        save()
    }

    func delete(_ id: String) {
        remove([id])
        save()
    }

    /// Puts an entry back on the pasteboard without recording a new copy. When its image file is gone,
    /// drops the entry, leaves the pasteboard alone and returns false.
    @discardableResult
    func restore(_ e: Entry) -> Bool {
        var image: NSImage?
        if e.kind == .image {
            image = NSImage(contentsOf: imageDir.appendingPathComponent(e.text))
            if image == nil {
                delete(e.id)
                return false
            }
        }
        let pb = Pasteboard.board
        pb.clearContents()
        switch e.kind {
        case .file: pb.writeObjects([URL(fileURLWithPath: e.text) as NSURL])
        case .image: pb.writeObjects([image!])
        default: pb.setString(e.text, forType: .string)
        }
        lastChange = pb.changeCount
        if let i = entries.firstIndex(where: { $0.id == e.id }) {
            var moved = entries.remove(at: i)
            moved.date = now
            entries.insert(moved, at: 0)
            save()
        }
        return true
    }

    var items: [Item] {
        let ordered = entries.filter(\.pinned) + entries.filter { !$0.pinned }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        return ordered.map { e in
            let title: String
            let icon: ItemIcon
            switch e.kind {
            case .image:
                title = "Image"
                icon = .file(imageDir.appendingPathComponent(e.text).path)
            case .file:
                title = (e.text as NSString).lastPathComponent
                icon = .file(e.text)
            case .link:
                title = e.text
                icon = .symbol("link")
            case .color:
                title = e.text
                icon = .symbol("paintpalette")
            default:
                title =
                    e.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first
                    ?? ""
                icon = .symbol("doc.plaintext")
            }
            return Item(
                id: "clip:" + e.id,
                title: String(title.prefix(200)),
                subtitle: rel.localizedString(for: Date(timeIntervalSince1970: e.date), relativeTo: Date()),
                icon: icon,
                keywords: e.kind == .text ? [e.text] : [],
                accessory: e.pinned ? "Pinned" : "",
                actions: [
                    Action(title: "Paste") {
                        guard self.restore(e) else {
                            Launcher.shared?.toast("Image no longer available")
                            return .stay
                        }
                        Pasteboard.pasteCurrent()
                        return .close
                    },
                    Action(title: "Copy") {
                        guard self.restore(e) else {
                            Launcher.shared?.toast("Image no longer available")
                            return .stay
                        }
                        return .close
                    },
                    Action(title: e.pinned ? "Unpin" : "Pin") {
                        self.togglePin(e.id)
                        return .stay
                    },
                    Action(title: "Delete") {
                        self.delete(e.id)
                        return .stay
                    },
                ],
                preview: e.kind == .image ? nil : e.text
            )
        }
    }
}
