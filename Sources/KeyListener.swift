import Carbon.HIToolbox
import CoreGraphics
import AppKit

/// Listens to every key press and mouse-button press system-wide with a
/// listen-only event tap.
/// Requires the Input Monitoring permission (System Settings → Privacy & Security).
final class KeyListener {
    var onPress: ((_ keyCode: Int) -> Void)?
    var onMouseDown: (() -> Void)?
    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt (first time only) and adds the app to the list.
    static func requestPermission() { _ = CGRequestListenEventAccess() }

    static func openSettings() {
        requestPermission()
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        // Without Input Monitoring the tap is still created, but macOS silently
        // withholds ordinary keystrokes and delivers only modifier changes.
        guard Self.hasPermission else { return false }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(0) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            let listener = Unmanaged<KeyListener>.fromOpaque(info!).takeUnretainedValue()
            listener.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switches off taps it considers slow; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            onPress?(Int(event.getIntegerValueField(.keyboardEventKeycode)))
        case .flagsChanged:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == kVK_CapsLock {
                onPress?(keyCode)
            } else if let mask = KeyMap.modifierMask[keyCode],
                      event.flags.rawValue & mask != 0 {
                onPress?(keyCode) // bit set → key went down (ignore the release)
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onMouseDown?()
        default:
            break
        }
    }
}
