import AVFoundation

/// Plays short samples with minimal latency. Every sample is preloaded, and a
/// round-robin pool of player nodes lets fast keystrokes overlap instead of
/// cutting each other off. The engine pauses after a few idle seconds: an open
/// output stream keeps coreaudiod busy (~9% of a core) even when silent, and
/// resuming takes only ~3–6 ms.
final class ClickEngine {
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private let format: AVAudioFormat
    private let idleTimeout: TimeInterval = 15
    private var idlePause: DispatchWorkItem?

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    init(format: AVAudioFormat, voices: Int = 16) {
        self.format = format
        for _ in 0..<voices {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
        // Output device changed (headphones, AirPods, display audio): restart.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.start() }
        start()
    }

    func start() {
        scheduleIdlePause()
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
            players.forEach { $0.play() }
        } catch {
            NSLog("Cream: audio engine failed to start: \(error)")
        }
    }

    private func scheduleIdlePause() {
        idlePause?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.engine.pause() }
        idlePause = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: work)
    }

    func play(_ buffer: AVAudioPCMBuffer, gain: Float = 1) {
        start()
        let player = players[next]
        next = (next + 1) % players.count
        player.volume = gain
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }
}
