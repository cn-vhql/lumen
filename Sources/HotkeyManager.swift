import Foundation
import Carbon.HIToolbox
import AppKit

/// Registers global hotkeys through Carbon's `RegisterEventHotKey`.
///
/// This API needs NO Accessibility permission and NO Input Monitoring permission,
/// which is why it was chosen over `CGEventTap` — verified returning `status: 0`
/// and firing callbacks on macOS 27 without any TCC prompt.
final class HotkeyManager {

    private struct Registration {
        let ref: EventHotKeyRef
        let id: UInt32
        let action: HotkeyAction
    }

    private var registrations: [Registration] = []
    private var handler: EventHandlerRef?
    private var onFire: ((HotkeyAction) -> Void)?

    private static let signature: OSType = 0x4C4D454E // 'LMEN'

    var isInstalled: Bool { handler != nil }

    /// Installs the Carbon event handler. Call once at launch.
    @discardableResult
    func installHandler(onFire: @escaping (HotkeyAction) -> Void) -> Bool {
        self.onFire = onFire
        guard handler == nil else { return true }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotkeyID = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID)
                guard result == noErr else { return OSStatus(eventNotHandledErr) }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                guard let action = manager.action(forRawID: hotkeyID.id) else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async { manager.onFire?(action) }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler)
        return status == noErr
    }

    private func action(forRawID rawID: UInt32) -> HotkeyAction? {
        registrations.first { $0.id == rawID }?.action
    }

    /// Deterministic ID for an action: its position in `allCases`. Enum `hashValue`
    /// is seeded per process, so it must not be used as an event identifier.
    private static func identifier(for action: HotkeyAction) -> UInt32 {
        let index = HotkeyAction.allCases.firstIndex(of: action) ?? 0
        return UInt32(index &+ 1)
    }

    /// Removes every registration so the config can be reloaded.
    func unregisterAll() {
        for registration in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    /// Registers all bindings from the configuration. Returns the actions that failed
    /// (typically because another app already owns that combination).
    @discardableResult
    func apply(_ configuration: Configuration) -> [HotkeyAction] {
        unregisterAll()
        var failures: [HotkeyAction] = []

        for action in HotkeyAction.allCases {
            guard let binding = configuration.binding(for: action) else { continue }
            let identifier = HotkeyManager.identifier(for: action)
            let hotkeyID = EventHotKeyID(signature: HotkeyManager.signature, id: identifier)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.key.rawValue,
                binding.modifiers.rawValue,
                hotkeyID,
                GetApplicationEventTarget(),
                0,
                &ref)
            if status == noErr, let ref {
                registrations.append(Registration(ref: ref, id: identifier, action: action))
            } else {
                failures.append(action)
            }
        }
        return failures
    }

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }
}
