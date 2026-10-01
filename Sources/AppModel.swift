import Foundation
import ServiceManagement

/// The adjustable settings one input device (keyboard or mouse) gets.
final class DeviceSettings: ObservableObject {
    struct Keys { let enabled, volume, crisp, tailMs, selected: String }
    private let defaults = UserDefaults.standard
    private let keys: Keys

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: keys.enabled) } }
    @Published var volume: Double { didSet { defaults.set(volume, forKey: keys.volume) } }
    /// Crisp trims each sample's ringing tail; Original plays the recording as-is.
    @Published var crisp: Bool { didSet { defaults.set(crisp, forKey: keys.crisp) } }
    /// How long Crisp keeps sound after the peak, in milliseconds.
    @Published var tailMs: Double { didSet { defaults.set(tailMs, forKey: keys.tailMs) } }
    /// The chosen sound pack (keyboard) or click sound (mouse).
    @Published var selectedID: String { didSet { defaults.set(selectedID, forKey: keys.selected) } }

    /// Plays a sample at the current settings (wired up by the AppDelegate).
    var preview: () -> Void = {}

    init(keys: Keys, defaultID: String, defaultVolume: Double) {
        self.keys = keys
        enabled = defaults.object(forKey: keys.enabled) as? Bool ?? true
        volume = defaults.object(forKey: keys.volume) as? Double ?? defaultVolume
        crisp = defaults.object(forKey: keys.crisp) as? Bool ?? true
        tailMs = defaults.object(forKey: keys.tailMs) as? Double ?? 25
        selectedID = defaults.string(forKey: keys.selected) ?? defaultID
    }

    /// These settings by their defaults keys, for sending to the other process.
    var snapshot: [String: Any] {
        [keys.enabled: enabled, keys.volume: volume, keys.crisp: crisp, keys.tailMs: tailMs, keys.selected: selectedID]
    }

    /// Takes whatever differs from a snapshot (assigning equal values would
    /// still fire the publishers, and with them a preview click).
    func apply(_ s: [String: Any]) {
        if let v = s[keys.enabled] as? Bool, v != enabled { enabled = v }
        if let v = s[keys.volume] as? Double, v != volume { volume = v }
        if let v = s[keys.crisp] as? Bool, v != crisp { crisp = v }
        if let v = s[keys.tailMs] as? Double, v != tailMs { tailMs = v }
        if let v = s[keys.selected] as? String, v != selectedID { selectedID = v }
    }
}

/// All user settings plus live status, shared by the menu bar menu and the
/// settings panel. Settings persist to UserDefaults as they change; the
/// AppDelegate observes them to drive the audio.
final class AppModel: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Master switch for all sounds (the menu bar right-click toggles this).
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    /// The preference is ours; the system registration is re-applied on every
    /// launch because re-signing a rebuilt app can drop it.
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin"); syncLaunchAtLogin() }
    }

    // Keyboard keys keep their original names so earlier settings carry over.
    let keyboard = DeviceSettings(
        keys: .init(enabled: "keys.enabled", volume: "volume", crisp: "crisp", tailMs: "tailMs", selected: "pack"),
        defaultID: PackStore.builtInID, defaultVolume: 0.6)
    let mouse = DeviceSettings(
        keys: .init(enabled: "mouse.enabled", volume: "mouse.volume", crisp: "mouse.crisp",
                    tailMs: "mouse.tailMs", selected: "mouse.sound"),
        defaultID: MouseSoundStore.builtInID, defaultVolume: 0.5)

    @Published private(set) var packs: [PackInfo] = []
    @Published private(set) var mouseSounds: [MouseSoundInfo] = []
    @Published var isListening = false
    @Published var notice: String?

    init() {
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
        reloadPacks()
        reloadMouseSounds()
    }

    var currentPack: PackInfo { packs.first { $0.id == keyboard.selectedID } ?? packs[0] }
    var currentMouseSound: MouseSoundInfo { mouseSounds.first { $0.id == mouse.selectedID } ?? mouseSounds[0] }

    // MARK: Keyboard packs

    func reloadPacks() {
        packs = PackStore.list()
        if !packs.contains(where: { $0.id == keyboard.selectedID }) { keyboard.selectedID = PackStore.builtInID }
    }

    func importSounds(_ urls: [URL]) {
        do {
            let folder = try PackStore.importItems(urls)
            do {
                _ = try SoundPack(folder: folder) // make sure it actually plays
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            reloadPacks()
            keyboard.selectedID = "user:" + folder.lastPathComponent
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func removePack(id: String) {
        guard let pack = packs.first(where: { $0.id == id }) else { return }
        do {
            try PackStore.remove(pack)
            reloadPacks()
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: Mouse sounds

    func reloadMouseSounds() {
        mouseSounds = MouseSoundStore.list()
        if !mouseSounds.contains(where: { $0.id == mouse.selectedID }) { mouse.selectedID = MouseSoundStore.builtInID }
    }

    func importMouseSounds(_ urls: [URL]) {
        do {
            let added = try MouseSoundStore.importFiles(urls)
            reloadMouseSounds()
            if let first = added.first { mouse.selectedID = first }
            notice = nil
        } catch {
            reloadMouseSounds()
            notice = error.localizedDescription
        }
    }

    func removeMouseSound(id: String) {
        guard let sound = mouseSounds.first(where: { $0.id == id }) else { return }
        do {
            try MouseSoundStore.remove(sound)
            reloadMouseSounds()
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: Between processes

    /// Settings and status by key, sent between the menu bar agent and the
    /// settings panel process (see SettingsSync).
    var snapshot: [String: Any] {
        var s: [String: Any] = ["enabled": enabled, "launchAtLogin": launchAtLogin, "isListening": isListening,
                                "notice": notice ?? ""]
        s.merge(keyboard.snapshot) { a, _ in a }
        s.merge(mouse.snapshot) { a, _ in a }
        return s
    }

    func apply(_ s: [String: Any]) {
        // The other process may have added or removed sounds.
        reloadPacks()
        reloadMouseSounds()
        if let v = s["enabled"] as? Bool, v != enabled { enabled = v }
        if let v = s["launchAtLogin"] as? Bool, v != launchAtLogin { launchAtLogin = v }
        if let v = s["isListening"] as? Bool, v != isListening { isListening = v }
        if let v = s["notice"] as? String, v != (notice ?? "") { notice = v.isEmpty ? nil : v }
        keyboard.apply(s)
        mouse.apply(s)
    }

    func syncLaunchAtLogin() {
        let registered = SMAppService.mainApp.status == .enabled
        do {
            if launchAtLogin && !registered { try SMAppService.mainApp.register() }
            if !launchAtLogin && registered { try SMAppService.mainApp.unregister() }
        } catch {
            notice = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
    }
}
