import Carbon.HIToolbox

/// System-wide shortcuts via Carbon's RegisterEventHotKey: works in any app,
/// including full-screen ones, and needs no Accessibility permission.
@MainActor
final class HotKeys {
    struct Shortcut {
        let keyCode: Int
        let modifiers: Int
        let title: String
    }

    static let shared = HotKeys()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5049_5041), id: id) // 'PIPA'
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
        } else {
            log("could not register hotkey \(shortcut.title) (\(status)); another app may own it")
        }
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            Task { @MainActor in HotKeys.shared.fire(id) }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}

extension HotKeys.Shortcut {
    private static let ctrlOpt = controlKey | optionKey

    static let toggleStash = Self(keyCode: kVK_ANSI_P, modifiers: ctrlOpt, title: "⌃⌥P")
    static let playPause = Self(keyCode: kVK_Space, modifiers: ctrlOpt, title: "⌃⌥Space")
    static let back10 = Self(keyCode: kVK_LeftArrow, modifiers: ctrlOpt, title: "⌃⌥←")
    static let forward10 = Self(keyCode: kVK_RightArrow, modifiers: ctrlOpt, title: "⌃⌥→")
    static let ghost = Self(keyCode: kVK_ANSI_G, modifiers: ctrlOpt, title: "⌃⌥G")
    static let backToTab = Self(keyCode: kVK_ANSI_B, modifiers: ctrlOpt, title: "⌃⌥B")
    static let mute = Self(keyCode: kVK_ANSI_M, modifiers: ctrlOpt, title: "⌃⌥M")
    static let toggleBrowser = Self(keyCode: kVK_ANSI_N, modifiers: ctrlOpt, title: "⌃⌥N")
    static let floatFrontmost = Self(keyCode: kVK_ANSI_F, modifiers: ctrlOpt, title: "⌃⌥F")
    static let releaseCursor = Self(keyCode: kVK_ANSI_E, modifiers: ctrlOpt, title: "⌃⌥E")
    static let grow = Self(keyCode: kVK_ANSI_Equal, modifiers: ctrlOpt, title: "⌃⌥=")
    static let shrink = Self(keyCode: kVK_ANSI_Minus, modifiers: ctrlOpt, title: "⌃⌥-")
}
