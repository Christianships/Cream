import AppKit
import Combine
import UniformTypeIdentifiers

// The settings panel is its own short-lived process (`Cream --panel`) that quits
// when it closes. SwiftUI costs the menu bar agent ~15 MB that it never gives
// back once loaded, so the agent never shows any SwiftUI itself.

/// Keeps one process's AppModel in step with the other's, over distributed
/// notifications. Each side sends its whole snapshot when anything changes, so
/// there's no waiting on UserDefaults to sync between processes.
final class SettingsSync {
    private static let settings = Notification.Name("dev.christianaguilar.cream.settings")
    private static let request = Notification.Name("dev.christianaguilar.cream.settings.request")
    private static let show = Notification.Name("dev.christianaguilar.cream.panel.show")
    private static let me = ProcessInfo.processInfo.processIdentifier

    private let model: AppModel
    private var subscriptions: Set<AnyCancellable> = []
    private var applying = false
    private var pending = false
    private var lastSent: NSDictionary?

    /// Called when the other side asks to hear a device ("keyboard"/"mouse").
    var onPreview: ((DeviceSettings) -> Void)?
    /// Called on the panel when the agent asks it to come to the front.
    var onShow: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        for publisher in [model.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                          model.keyboard.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                          model.mouse.objectWillChange.map { _ in () }.eraseToAnyPublisher()] {
            publisher.sink { [weak self] in self?.changed() }.store(in: &subscriptions)
        }
        observe(Self.settings) { [weak self] info in
            guard let self, let snapshot = info["snapshot"] as? [String: Any] else { return }
            self.applying = true
            self.model.apply(snapshot)
            self.applying = false
            self.lastSent = self.model.snapshot as NSDictionary
            switch info["preview"] as? String {
            case "keyboard": self.onPreview?(self.model.keyboard)
            case "mouse": self.onPreview?(self.model.mouse)
            default: break
            }
        }
        observe(Self.request) { [weak self] _ in self?.send(force: true) }
        observe(Self.show) { [weak self] _ in self?.onShow?() }
    }

    /// The panel asks the agent for its current state (listening, notices).
    func requestState() { Self.post(Self.request, [:]) }
    func showPanel() { Self.post(Self.show, [:]) }

    /// Sends the current settings and asks the other side to play `device`.
    func preview(_ device: DeviceSettings) {
        send(force: true, preview: device === model.keyboard ? "keyboard" : "mouse")
    }

    private func changed() {
        // objectWillChange fires before the value is set, so send on the next turn.
        guard !applying, !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.send()
        }
    }

    private func send(force: Bool = false, preview: String? = nil) {
        let snapshot = model.snapshot as NSDictionary
        guard force || snapshot != lastSent else { return }
        lastSent = snapshot
        var info: [String: Any] = ["snapshot": snapshot]
        if let preview { info["preview"] = preview }
        Self.post(Self.settings, info)
    }

    private static func post(_ name: Notification.Name, _ info: [String: Any]) {
        var info = info
        info["from"] = me
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info,
                                                                     deliverImmediately: true)
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping ([AnyHashable: Any]) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            guard info["from"] as? Int32 != Self.me else { return }
            handler(info)
        }
    }
}

/// Starts the panel process from the agent, or brings the open one forward.
enum PanelProcess {
    private static var process: Process?

    static func open(sync: SettingsSync) {
        if process?.isRunning == true { sync.showPanel(); return }
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--panel"]
        do { try p.run(); process = p } catch { NSSound.beep() }
    }
}

/// `Cream --panel`: the settings panel on its own. Sounds still play from the
/// agent, which hears every key and click; this process only edits settings.
func runPanelProcess() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let model = AppModel()
    let sync = SettingsSync(model: model)
    for device in [model.keyboard, model.mouse] {
        device.preview = { [weak sync, weak device] in
            if let sync, let device { sync.preview(device) }
        }
    }
    let panel = SettingsPanel(model: model)
    let delegate = PanelDelegate()
    panel.delegate = delegate
    panel.onAddSounds = { [weak panel, weak model] device in
        guard let panel, let model else { return }
        chooseSounds(for: device, in: panel, model: model)
    }
    sync.onShow = { [weak panel] in
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }
    // Never outlive the agent.
    let parent = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
    parent.setEventHandler { exit(0) }
    parent.resume()
    DispatchQueue.main.async {
        sync.requestState()
        sync.onShow?()
    }
    withExtendedLifetime((sync, panel, delegate, parent)) { app.run() }
    exit(0)
}

private final class PanelDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ note: Notification) {
        // Let the last settings change go out before quitting.
        DispatchQueue.main.async { exit(0) }
    }
}

private func chooseSounds(for device: Device, in panel: NSWindow, model: AppModel) {
    let picker = NSOpenPanel()
    picker.prompt = "Add"
    picker.canChooseFiles = true
    picker.allowsMultipleSelection = true
    switch device {
    case .keyboard:
        picker.message = "Choose a Mechvibes sound pack (folder or .zip) or some audio files"
        picker.canChooseDirectories = true
        picker.allowedContentTypes = [.folder, .zip, .audio]
    case .mouse:
        picker.message = "Choose one or more click sounds (each becomes an option)"
        picker.canChooseDirectories = false
        picker.allowedContentTypes = [.audio]
    }
    picker.beginSheetModal(for: panel) { response in
        guard response == .OK else { return }
        switch device {
        case .keyboard: model.importSounds(picker.urls)
        case .mouse: model.importMouseSounds(picker.urls)
        }
    }
}
