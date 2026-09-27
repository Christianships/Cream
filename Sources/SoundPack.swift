import AVFoundation

/// A Mechvibes-format sound pack: a folder with a config.json whose "defines" map
/// scan codes to sounds. Two layouts exist:
///   "multi":  defines map to a file per key ("a.wav")
///   "single": one "sound" file, defines map to [startMs, durationMs] slices of it
/// Every sound is decoded up front and converted to `SoundPack.format`, so packs
/// in any sample rate, channel count or file type (wav, mp3, ogg, flac…) play
/// through the same engine.
struct SoundPack {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    let name: String
    let sounds: [String: AVAudioPCMBuffer]    // sound id -> audio as recorded
    private(set) var crispSounds: [String: AVAudioPCMBuffer] = [:] // ringing tail cut
    let defines: [Int: String]                // scan code -> sound id
    let fallbacks: [String]                   // letter sounds for unmapped keys

    struct LoadError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    init(folder: URL, hold: Double = 0.025) throws {
        let data: Data
        do { data = try Data(contentsOf: folder.appendingPathComponent("config.json")) }
        catch { throw LoadError("No config.json in \(folder.lastPathComponent).") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError("config.json isn't a JSON object.")
        }
        name = json["name"] as? String ?? folder.lastPathComponent
        let rawDefines = json["defines"] as? [String: Any] ?? [:]

        var defines: [Int: String] = [:]
        var sounds: [String: AVAudioPCMBuffer] = [:]
        if json["key_define_type"] as? String == "single" {
            guard let file = json["sound"] as? String else {
                throw LoadError("Single-sound pack is missing its \"sound\" file.")
            }
            let whole = try Self.load(folder.appendingPathComponent(file))
            for (key, value) in rawDefines {
                guard let code = Int(key), let slice = value as? [NSNumber], slice.count >= 2 else { continue }
                let id = "\(slice[0])-\(slice[1])"
                if sounds[id] == nil {
                    sounds[id] = Self.slice(whole, startMs: slice[0].doubleValue,
                                            durationMs: slice[1].doubleValue)
                }
                if sounds[id] != nil { defines[code] = id }
            }
        } else {
            for (key, value) in rawDefines {
                guard let code = Int(key), let file = value as? String else { continue }
                if sounds[file] == nil {
                    sounds[file] = try Self.load(folder.appendingPathComponent(file))
                }
                defines[code] = file
            }
        }
        guard !sounds.isEmpty else { throw LoadError("\(name) has no playable sounds.") }
        self.defines = defines
        self.sounds = sounds.mapValues(Self.trimLeadingSilence)

        // Letter keys (set-1 rows Q–P, A–L, Z–M) make the most neutral fallbacks.
        let letterCodes = Array(16...25) + Array(30...38) + Array(44...50)
        let letters = Set(letterCodes.compactMap { defines[$0] }).sorted()
        fallbacks = letters.isEmpty ? sounds.keys.sorted() : letters
        applyTail(hold: hold)
    }

    mutating func applyTail(hold: Double) {
        crispSounds = sounds.mapValues { Self.crisp($0, hold: hold) }
    }

    func buffer(forScanCode code: Int?, keyCode: Int, crisp: Bool = true) -> AVAudioPCMBuffer? {
        let source = crisp ? crispSounds : sounds
        if let code, let id = defines[code] { return source[id] }
        // Unmapped key: pick a stable letter sound so it still clicks.
        guard !fallbacks.isEmpty else { return nil }
        return source[fallbacks[keyCode % fallbacks.count]]
    }

    // MARK: Audio processing

    /// Decodes a file and converts it to the engine format.
    static func load(_ url: URL) throws -> AVAudioPCMBuffer {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw LoadError("Can't read \(url.lastPathComponent) (missing or unsupported format).") }
        guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(max(file.length, 1)))
        else { throw LoadError("Can't decode \(url.lastPathComponent).") }
        try file.read(into: raw)
        if raw.format == format { return raw }

        guard let converter = AVAudioConverter(from: raw.format, to: format) else {
            throw LoadError("Can't convert \(url.lastPathComponent).")
        }
        if raw.format.channelCount == 1 { converter.channelMap = [0, 0] } // mono → both ears
        let ratio = format.sampleRate / raw.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(Double(raw.frameLength) * ratio) + 1024)
        else { throw LoadError("Can't convert \(url.lastPathComponent).") }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return raw
        }
        if let error { throw error }
        return out
    }

    static func slice(_ source: AVAudioPCMBuffer, startMs: Double, durationMs: Double) -> AVAudioPCMBuffer? {
        let rate = source.format.sampleRate
        let start = max(0, Int(startMs / 1000 * rate))
        let count = min(Int(source.frameLength) - start, Int(durationMs / 1000 * rate))
        guard count > 0, let input = source.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(count)),
              let output = out.floatChannelData
        else { return nil }
        out.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(source.format.channelCount) {
            output[channel].update(from: input[channel] + start, count: count)
        }
        return out
    }

    /// Drops silence before the sound starts, so the click lands the instant the
    /// key or button goes down (some files, like minecraft_click.mp3, open with
    /// ~0.5 s of nothing). Walks back from the loudest point to where the sound
    /// begins: the earliest sample within 30 dB of the peak before a 10 ms quiet
    /// gap. Stray noise ahead of that gap (Minecraft's has a blip 70 ms early) is
    /// dropped too. Backs off 2 ms and fades in over 1 ms so the cut is inaudible.
    static func trimLeadingSilence(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let input = source.floatChannelData else { return source }
        let rate = source.format.sampleRate
        let channels = Int(source.format.channelCount)
        let frames = Int(source.frameLength)
        let level = { (frame: Int) in (0..<channels).map { abs(input[$0][frame]) }.max() ?? 0 }
        var peak: Float = 0
        var peakFrame = 0
        for frame in 0..<frames where level(frame) > peak {
            peak = level(frame)
            peakFrame = frame
        }
        guard peak > 0 else { return source }
        let threshold = peak * 0.0316 // -30 dB
        let gap = Int(0.010 * rate)
        var onset = peakFrame
        var frame = peakFrame
        while frame > 0 && onset - frame < gap {
            frame -= 1
            if level(frame) >= threshold { onset = frame }
        }
        let start = max(0, onset - Int(0.002 * rate))
        guard start > Int(0.001 * rate),
              let trimmed = slice(source, startMs: Double(start) / rate * 1000,
                                  durationMs: Double(frames - start) / rate * 1000),
              let output = trimmed.floatChannelData
        else { return source }
        let fadeIn = min(Int(trimmed.frameLength), Int(0.001 * rate))
        for frame in 0..<fadeIn {
            for channel in 0..<channels { output[channel][frame] *= Float(frame) / Float(fadeIn) }
        }
        return trimmed
    }

    /// Keeps only the key-press transient. Recordings like NK Cream continue for
    /// ~200 ms after the press: a 1–3 kHz spring/plate ring plus the key's
    /// release click ~100 ms later, which at typing speed smears into a buzz.
    /// This holds the audio for `hold` after the press peak, then fades it out
    /// with a raised-cosine curve over `fade` (a hard cut would itself click).
    static func crisp(_ source: AVAudioPCMBuffer, hold: Double = 0.025,
                      fade: Double = 0.020) -> AVAudioPCMBuffer {
        guard let input = source.floatChannelData else { return source }
        let rate = source.format.sampleRate
        let channels = Int(source.format.channelCount)
        let frames = Int(source.frameLength)

        // The press peak lands in the first ~12 ms of a well-trimmed sample.
        var peakFrame = 0
        var peak: Float = 0
        for frame in 0..<min(frames, Int(0.03 * rate)) {
            for channel in 0..<channels where abs(input[channel][frame]) > peak {
                peak = abs(input[channel][frame])
                peakFrame = frame
            }
        }
        let fadeStart = min(frames, peakFrame + Int(hold * rate))
        let fadeFrames = Int(fade * rate)
        let end = min(frames, fadeStart + fadeFrames)

        guard end > 0,
              let output = AVAudioPCMBuffer(pcmFormat: source.format,
                                            frameCapacity: AVAudioFrameCount(end)),
              let samples = output.floatChannelData
        else { return source }
        output.frameLength = AVAudioFrameCount(end)
        for frame in 0..<end {
            var gain: Float = 1
            if frame >= fadeStart {
                gain = 0.5 * (1 + cos(.pi * Float(frame - fadeStart) / Float(fadeFrames)))
            }
            for channel in 0..<channels {
                samples[channel][frame] = input[channel][frame] * gain
            }
        }
        return output
    }
}
