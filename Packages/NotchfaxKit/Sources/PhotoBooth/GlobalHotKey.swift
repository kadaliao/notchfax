import Carbon.HIToolbox

/// A system-wide keyboard shortcut through Carbon's hot-key API, which needs no
/// accessibility permission. Only events for this hot key are handled; others pass on
/// to whichever handler registered them.
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let identifier: EventHotKeyID
    private let action: @MainActor () -> Void

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `kVK_ANSI_B`.
    ///   - modifiers: Carbon modifier flags, e.g. `cmdKey | optionKey | controlKey`.
    init?(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        identifier = EventHotKeyID(signature: OSType(0x4E46_5842) /* 'NFXB' */, id: id)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed
                )
                guard status == noErr else { return status }
                // Carbon delivers application-target events on the main thread.
                return MainActor.assumeIsolated {
                    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                    guard pressed.signature == hotKey.identifier.signature, pressed.id == hotKey.identifier.id else {
                        return OSStatus(eventNotHandledErr)
                    }
                    hotKey.action()
                    return noErr
                }
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard installed == noErr else { return nil }
        let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), identifier, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    /// Releases the shortcut. The owner calls this; the feature keeps it for the app's life.
    func invalidate() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
