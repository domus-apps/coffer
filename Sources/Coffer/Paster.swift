import AppKit
import Carbon.HIToolbox

/* What Return does to the selected item: copy it back to the pasteboard,
   or copy it and paste it into the app the user was in. ⌘ flips the
   choice the Paste with Return setting makes, so both stay one key away.
   ⌥ (a file row's path instead of the files) is separate and works with
   either. */
enum ReturnAction: Equatable {
    case copy
    case paste

    static func forReturn(commandHeld: Bool, pastesWithReturn: Bool) -> ReturnAction {
        commandHeld != pastesWithReturn ? .paste : .copy
    }
}

/* Pasting for the user: ⌘V posted once the panel is gone. The panel never
   makes Coffer the active app, so the app in front is still the one the
   user was typing in, unless that is Coffer itself (its Settings window
   in front): then the item is only copied, rather than pasted into a
   Settings field. Posting keystrokes takes Accessibility access; while
   Coffer doesn't have it the item is only copied too, and the attempt
   asks for access: the system's prompt the first time, the settings pane
   once per launch after that (every Return opening it would be worse
   than the missing paste), and from then on only Settings' Allow button. */
enum Paster {
    private static let askedKey = "pref.askedForAccessibility"
    private static var openedSettingsThisLaunch = false

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Asked for from Settings: always shows the way to the permission.
    static func requestAccess() {
        if UserDefaults.standard.bool(forKey: askedKey) {
            openAccessibilitySettings()
        } else {
            UserDefaults.standard.set(true, forKey: askedKey)
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    /// A paste without access: asks, but no more than once per launch.
    private static func remindOfAccess() {
        guard !openedSettingsThisLaunch else { return }
        openedSettingsThisLaunch = true
        requestAccess()
    }

    static func openAccessibilitySettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Pastes what's on the pasteboard into the app in front.
    static func paste() {
        guard !NSApp.isActive else { return }
        guard isAllowed else { return remindOfAccess() }
        // A moment for the panel to hand the keyboard back to that app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { postCommandV() }
    }

    /* ⌘ plus whichever key types "v" in the current ASCII-capable layout
       (the one shortcuts use, also under Korean input): on Dvorak that's
       not the ANSI V key. Apps match shortcuts on the event's own flags,
       set here to ⌘ alone, so a ⌥ still held from ⌘⌥Return doesn't turn
       it into ⌘⌥V (which moves files in Finder) and the paste needn't wait
       for the key to come up. The source keeps a state of its own, so
       nothing the user holds leaks in, and local keys aren't suppressed:
       that would swallow the ⌥ being let go meanwhile and leave it stuck. */
    private static func postCommandV() {
        let source = CGEventSource(stateID: .privateState)
        let key = keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cgSessionEventTap)
        }
    }

    private static func keyCode(for character: String) -> CGKeyCode? {
        guard
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, String(utf16CodeUnits: chars, count: length) == character {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
