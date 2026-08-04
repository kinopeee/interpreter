import AppKit
import Carbon

@MainActor
final class HotKeyManager {
    enum Action: Hashable {
        case toggleStartStop
    }

    var handler: ((Action) -> Void)?

    private var hotKeys: [Action: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private static var shared: HotKeyManager?

    func registerDefaults() {
        Self.shared = self
        installHandlerIfNeeded()

        // Control + Option + Space
        register(action: .toggleStartStop, keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
    }

    func unregisterAll() {
        for (_, hotKey) in hotKeys {
            UnregisterEventHotKey(hotKey)
        }
        hotKeys.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        if Self.shared === self {
            Self.shared = nil
        }
    }

    private func register(action: Action, keyCode: UInt32, modifiers: UInt32) {
        if let existing = hotKeys[action] {
            UnregisterEventHotKey(existing)
        }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5254_5231), id: UInt32(action.hotKeyID))
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            AppLogger.general.error("Failed to register hotkey \(action.hotKeyID)")
            return
        }
        hotKeys[action] = hotKeyRef
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let getStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard getStatus == noErr else { return OSStatus(eventNotHandledErr) }
                guard let action = HotKeyManager.Action(hotKeyID: Int(hotKeyID.id)) else {
                    return OSStatus(eventNotHandledErr)
                }
                Task { @MainActor in
                    HotKeyManager.shared?.handler?(action)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        if status != noErr {
            AppLogger.general.error("Failed to install hotkey handler")
        }
    }
}

private extension HotKeyManager.Action {
    var hotKeyID: Int {
        switch self {
        case .toggleStartStop: return 1
        }
    }

    init?(hotKeyID: Int) {
        switch hotKeyID {
        case 1: self = .toggleStartStop
        default: return nil
        }
    }
}
