import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut (Carbon's hot keys need no Accessibility permission and don't see other keys).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextId: UInt32 = 1

    /// ⌃⌥H is `HotKey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey))`.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        let id = Self.nextId
        Self.nextId += 1
        Self.actions[id] = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            if let action = HotKey.actions[hotKey.id] { DispatchQueue.main.async(execute: action) }
            return noErr
        }, 1, &spec, nil, &handler)
        let hotKeyId = EventHotKeyID(signature: OSType(0x5155_494C), id: id) // "QUIL"
        guard installed == noErr,
              RegisterEventHotKey(keyCode, modifiers, hotKeyId, GetApplicationEventTarget(), 0, &ref) == noErr else {
            DebugLog.write("hot key registration failed")
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
