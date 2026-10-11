import Carbon
import Foundation

/// System-wide keyboard shortcuts via Carbon hot keys. The key press is consumed, so the
/// focused app never sees it.
final class Shortcuts {
    private var refs: [EventHotKeyRef] = []
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    /// `keyCode` is a virtual key code (e.g. kVK_ANSI_V); `modifiers` uses Carbon masks (cmdKey, controlKey...).
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandler()
        let id = UInt32(Self.actions.count + 1)
        Self.actions[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C445354), id: id)  // 'LDST'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
        } else {
            Log.info("shortcuts: could not register key \(keyCode) (status \(status)); another app may own it")
        }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            Shortcuts.actions[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
