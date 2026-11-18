import Carbon
import Foundation

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).
final class Hotkeys {
    static let shared = Hotkeys()
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private static let keyCodes: [String: UInt32] = {
        var m: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let f: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (i, c) in f.enumerated() { m["f\(i + 1)"] = c }
        return m
    }()

    /// Parses "cmd+shift+v", "alt+space", "f13".
    static func parse(_ s: String) -> (key: UInt32, mods: UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        for part in s.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            case "alt", "opt", "option", "⌥": mods |= UInt32(optionKey)
            case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
            case "hyper": mods |= UInt32(cmdKey | shiftKey | optionKey | controlKey)
            default: key = keyCodes[part]
            }
        }
        guard let key else { return nil }
        return (key, mods)
    }

    /// Unregisters every hotkey, then registers `bindings` in order. Returns one message per binding
    /// that is invalid or already taken by another app.
    func replace(with bindings: [(String, () -> Void)]) -> [String] {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
        return bindings.compactMap { register($0.0, $0.1) }
    }

    private func register(_ combo: String, _ action: @escaping () -> Void) -> String? {
        installHandler()
        guard let (key, mods) = Hotkeys.parse(combo) else { return "invalid hotkey \"\(combo)\"" }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            key,
            mods,
            EventHotKeyID(signature: OSType(0x484C4E43), id: id),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return "\(combo) is already in use (\(status))" }
        refs.append(ref)
        actions[id] = action
        return nil
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { Hotkeys.shared.actions[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
