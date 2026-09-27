import AVFoundation

struct MouseSoundInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let file: URL
    let builtIn: Bool
}

/// One click sound for mouse buttons, decoded, trimmed of leading silence, and
/// with a Crisp copy, just like a keyboard pack's samples.
struct ClickSound {
    let original: AVAudioPCMBuffer
    private(set) var crisp: AVAudioPCMBuffer

    init(file: URL, hold: Double = 0.025) throws {
        original = SoundPack.trimLeadingSilence(try SoundPack.load(file))
        crisp = SoundPack.crisp(original, hold: hold)
    }

    mutating func applyTail(hold: Double) {
        crisp = SoundPack.crisp(original, hold: hold)
    }

    func buffer(crisp useCrisp: Bool) -> AVAudioPCMBuffer { useCrisp ? crisp : original }
}

/// Mouse click sounds on disk: the built-in Minecraft click inside the app
/// bundle, plus audio files the user adds, stored in
/// ~/Library/Application Support/Cream/MouseSounds.
enum MouseSoundStore {
    static let builtInID = "builtin:minecraft-click"

    static var userFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cream/MouseSounds", isDirectory: true)
    }

    static func list() -> [MouseSoundInfo] {
        let builtIn = Bundle.main.resourceURL!.appendingPathComponent("Sounds/mouse/minecraft_click.mp3")
        var sounds = [MouseSoundInfo(id: builtInID, name: "Minecraft Click", file: builtIn, builtIn: true)]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: userFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        sounds += files
            .filter { PackStore.audioExtensions.contains($0.pathExtension.lowercased()) }
            .map { MouseSoundInfo(id: "user:" + $0.lastPathComponent, name: displayName($0),
                                  file: $0, builtIn: false) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return sounds
    }

    /// "minecraft_click.mp3" → "Minecraft Click"
    static func displayName(_ file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    /// Copies each audio file into the library, rejecting any that won't decode.
    /// Returns the ids of the added sounds.
    static func importFiles(_ urls: [URL]) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: userFolder, withIntermediateDirectories: true)
        var added: [String] = []
        for url in urls {
            guard PackStore.audioExtensions.contains(url.pathExtension.lowercased()) else {
                throw SoundPack.LoadError("\(url.lastPathComponent) isn't an audio file.")
            }
            var dest = userFolder.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = userFolder.appendingPathComponent(
                    "\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
                n += 1
            }
            try fm.copyItem(at: url, to: dest)
            do {
                _ = try ClickSound(file: dest)
            } catch {
                try? fm.removeItem(at: dest)
                throw error
            }
            added.append("user:" + dest.lastPathComponent)
        }
        return added
    }

    static func remove(_ sound: MouseSoundInfo) throws {
        guard !sound.builtIn else { return }
        try FileManager.default.trashItem(at: sound.file, resultingItemURL: nil)
    }
}
