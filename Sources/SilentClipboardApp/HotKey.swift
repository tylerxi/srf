import Carbon
import ClipboardCore

@MainActor final class HotKeyService {
    private var hotkey: EventHotKeyRef?
    private let id: UInt32
    private let onRelease: Bool
    private var handler: EventHandlerRef?
    private var held = false
    private let action: @MainActor () -> Void
    private(set) var lastError: OSStatus = noErr
    var registered: Bool { hotkey != nil }
    init(id: UInt32 = 1, onRelease: Bool = false, action: @escaping @MainActor () -> Void) {
        self.id = id; self.onRelease = onRelease; self.action = action
    }

    func register(_ config: Configuration) {
        register(code: config.hotKeyCode, modifiers: config.hotKeyModifiers)
    }
    func register(code: UInt32, modifiers: UInt32) {
        stop()
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        lastError = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let service = Unmanaged<HotKeyService>.fromOpaque(context).takeUnretainedValue()
                var id = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard result == noErr, id.signature == 0x53434C50, id.id == service.id else { return OSStatus(eventNotHandledErr) }
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    let wasHeld = service.held; service.held = false
                    if wasHeld && service.onRelease { service.action() }
                } else if !service.held {
                    service.held = true
                    if !service.onRelease { service.action() }
                }
                return noErr
            }
        }, events.count, &events, pointer, &handler)
        guard lastError == noErr else { return }
        lastError = RegisterEventHotKey(code, modifiers,
                                       EventHotKeyID(signature: 0x53434C50, id: id),
                                       GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotkey)
        if lastError != noErr { stop() }
    }
    func stop() {
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        held = false
    }
    func resetPressedState() { held = false }
}
