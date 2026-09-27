import Foundation

struct PackInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let folder: URL
    let builtIn: Bool
}

/// Sound packs on disk: the built-in NK Cream inside the app bundle, plus
/// packs the user adds, stored in ~/Library/Application Support/Cream/Packs.
enum PackStore {
    static let builtInID = "builtin:nk-cream"
    static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf",
                                               "flac", "ogg", "oga", "opus"]

    static var userFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cream/Packs", isDirectory: true)
    }

    static func list() -> [PackInfo] {
        let builtInFolder = Bundle.main.resourceURL!.appendingPathComponent("Sounds/nk-cream")
        var packs = [PackInfo(id: builtInID, name: packName(builtInFolder), folder: builtInFolder, builtIn: true)]
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: userFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        packs += folders
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
            .map { PackInfo(id: "user:" + $0.lastPathComponent, name: packName($0), folder: $0, builtIn: false) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return packs
    }

    private static func packName(_ folder: URL) -> String {
        let data = try? Data(contentsOf: folder.appendingPathComponent("config.json"))
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return json?["name"] as? String ?? folder.lastPathComponent
    }

    // MARK: Import

    /// Accepts a Mechvibes pack folder, a .zip of one, a folder of loose audio
    /// files, or several audio files. Returns the new pack's folder.
    static func importItems(_ urls: [URL]) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cream-import-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        var source: URL
        var nameHint: String
        let isAudio = { (url: URL) in audioExtensions.contains(url.pathExtension.lowercased()) }
        if urls.count == 1, let url = urls.first, url.pathExtension.lowercased() == "zip" {
            source = work.appendingPathComponent("unzipped")
            try run("/usr/bin/ditto", ["-x", "-k", url.path, source.path])
            nameHint = url.deletingPathExtension().lastPathComponent
        } else if urls.count == 1, let url = urls.first, url.hasDirectoryPath {
            source = url
            nameHint = url.lastPathComponent
        } else if urls.allSatisfy(isAudio) {
            source = work.appendingPathComponent("Custom Sounds")
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            for url in urls { try fm.copyItem(at: url, to: source.appendingPathComponent(url.lastPathComponent)) }
            nameHint = "Custom Sounds"
        } else {
            throw SoundPack.LoadError("Add one pack folder or .zip at a time, or pick audio files.")
        }

        guard let root = findRoot(in: source) else {
            throw SoundPack.LoadError("No config.json or audio files found in what you picked.")
        }
        let hasConfig = fm.fileExists(atPath: root.appendingPathComponent("config.json").path)
        if root != source { nameHint = root.lastPathComponent }

        try fm.createDirectory(at: userFolder, withIntermediateDirectories: true)
        let dest = uniqueFolder(named: nameHint)
        try fm.copyItem(at: root, to: dest)
        if !hasConfig { try writeGeneratedConfig(in: dest, name: nameHint) }
        return dest
    }

    static func remove(_ pack: PackInfo) throws {
        guard !pack.builtIn else { return }
        try FileManager.default.trashItem(at: pack.folder, resultingItemURL: nil)
    }

    /// The folder holding config.json, else the folder with the most audio files.
    private static func findRoot(in source: URL) -> URL? {
        let fm = FileManager.default
        var best: (url: URL, count: Int)?
        var queue = [(source, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                          options: .skipsHiddenFiles) else { continue }
            if items.contains(where: { $0.lastPathComponent == "config.json" }) { return dir }
            let audio = items.filter { audioExtensions.contains($0.pathExtension.lowercased()) }.count
            if audio > (best?.count ?? 0) { best = (dir, audio) }
            if depth < 3 {
                queue += items.filter { $0.hasDirectoryPath && $0.lastPathComponent != "__MACOSX" }
                    .map { ($0, depth + 1) }
            }
        }
        return best?.url
    }

    private static func uniqueFolder(named name: String) -> URL {
        let base = name.replacingOccurrences(of: "/", with: "-")
        var candidate = userFolder.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = userFolder.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    // MARK: Packs without a config

    /// File names that clearly belong to a key ("space.wav", "Enter.mp3", "a.ogg").
    private static let keyNames: [String: [Int]] = {
        var map: [String: [Int]] = [:]
        for (i, c) in "1234567890".enumerated() { map[String(c)] = [2 + i] }
        for (i, c) in "qwertyuiop".enumerated() { map[String(c)] = [16 + i] }
        for (i, c) in "asdfghjkl".enumerated() { map[String(c)] = [30 + i] }
        for (i, c) in "zxcvbnm".enumerated() { map[String(c)] = [44 + i] }
        for name in ["space", "spacebar"] { map[name] = [57] }
        for name in ["enter", "return"] { map[name] = [28, 3612] }
        for name in ["backspace", "delete"] { map[name] = [14] }
        for name in ["caps lock", "capslock", "caps"] { map[name] = [58] }
        for name in ["esc", "escape"] { map[name] = [1] }
        map["tab"] = [15]
        map["shift"] = [42, 54]
        return map
    }()

    /// Matches files to keys by name; every other key cycles through all files.
    private static func writeGeneratedConfig(in folder: URL, name: String) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        guard !files.isEmpty else { throw SoundPack.LoadError("No audio files found.") }

        var defines: [String: String] = [:]
        for (i, code) in Set(KeyMap.scanCode.values).sorted().enumerated() {
            defines[String(code)] = files[i % files.count]
        }
        for file in files {
            let stem = ((file as NSString).deletingPathExtension).lowercased()
                .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            // Exact name ("space"), else a multi-letter key name among its words ("enter_key").
            let words = Set(stem.split(separator: " ").map(String.init))
            let match = keyNames[stem]
                ?? keyNames.first { $0.key.count > 1 && (words.contains($0.key) || stem.contains($0.key + " ")) }?.value
            for code in match ?? [] { defines[String(code)] = file }
        }
        let config: [String: Any] = ["name": name, "key_define_type": "multi", "defines": defines]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("config.json"))
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SoundPack.LoadError("Couldn't unzip that file.") }
    }
}
