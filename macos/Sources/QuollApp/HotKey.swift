import Carbon
import AppKit

/// System-wide hotkey through Carbon `RegisterEventHotKey`: needs no
/// Accessibility or Input Monitoring permission and swallows the keystroke.
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    let display: String

    /// `spec` like `hyper+s`, `control+option+space`, `cmd+shift+f`. Nil if it cannot be
    /// parsed or registered (another app holds it).
    init?(spec: String, action: @escaping () -> Void) {
        guard let (key, modifiers, display) = Self.parse(spec) else { return nil }
        self.action = action
        self.display = display

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x5155_4C4C), id: 1)   // 'QULL'
        guard RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    static func parse(_ spec: String) -> (UInt32, UInt32, String)? {
        var modifiers: UInt32 = 0
        var display = ""
        var key: UInt32?
        var keyLabel = ""
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": modifiers |= UInt32(controlKey); display += "⌃"
            case "alt", "opt", "option": modifiers |= UInt32(optionKey); display += "⌥"
            case "shift": modifiers |= UInt32(shiftKey); display += "⇧"
            case "cmd", "command": modifiers |= UInt32(cmdKey); display += "⌘"
            case "super":   // ⌃⌥⌘, Vorssaint's "super key" (Caps Lock)
                modifiers |= UInt32(controlKey | optionKey | cmdKey)
                display += "Super+"
            case "hyper":   // ⌃⌥⇧⌘, usually Caps Lock remapped
                modifiers |= UInt32(controlKey | optionKey | shiftKey | cmdKey)
                display += "Hyper+"
            default:
                guard let code = keys[part] else { return nil }
                key = code
                keyLabel = part == "space" ? "Space" : part.uppercased()
            }
        }
        guard let key, modifiers != 0 else { return nil }
        return (key, modifiers, display + keyLabel)
    }

    static let keys: [String: UInt32] = {
        var map: [String: UInt32] = ["space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "tab": UInt32(kVK_Tab)]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9), ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4), ("f5", kVK_F5),
            ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8), ("f9", kVK_F9), ("f10", kVK_F10), ("f11", kVK_F11),
            ("f12", kVK_F12)
        ]
        for (name, code) in letters { map[name] = UInt32(code) }
        return map
    }()
}
