import Carbon.HIToolbox

// System-wide ⌥⌘N for a new note from any app. Carbon hot keys need no accessibility permission.
enum GlobalHotKey {
    nonisolated(unsafe) static var action: (() -> Void)?
    nonisolated(unsafe) static var reference: EventHotKeyRef?
    @discardableResult static func register(_ handler: @escaping () -> Void) -> Bool {
        action = handler
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.action?() }
            return noErr
        }, 1, &type, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x534E_4F54), id: 1) // "SNOT"
        return RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &reference) == noErr
    }
}
