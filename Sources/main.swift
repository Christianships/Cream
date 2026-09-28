import AppKit
import Combine
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = AppModel()
    private let listener = KeyListener()
    private let clicks = ClickEngine(format: SoundPack.format)
    private var pack: SoundPack!
    private var mouseSound: ClickSound!
    private var statusItem: NSStatusItem!
    private var settingsPanel: SettingsPanel?
    private var permissionTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private let menu = NSMenu()
    private var volumeLabels: [ObjectIdentifier: NSTextField] = [:] // device -> menu % label
    private var sliderDevices: [ObjectIdentifier: DeviceSettings] = [:] // menu slider -> device
    private var showSettingsOnLaunch = false

    func applicationWillFinishLaunching(_ note: Notification) {
        // Open the panel when you launch Cream yourself, but not when it starts at
        // login (no "open app" event, or one flagged as a login item) or from build.sh.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        showSettingsOnLaunch = event?.eventID == kAEOpenApplication && !loginItem
            && !CommandLine.arguments.contains("--background")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        loadSelectedPack()
        loadMouseSound()
        observeModel()

        let keyboard = model.keyboard, mouse = model.mouse
        listener.onPress = { [weak self] keyCode in
            guard let self, self.model.enabled, keyboard.enabled,
                  let buffer = self.pack.buffer(forScanCode: KeyMap.scanCode[keyCode], keyCode: keyCode,
                                                crisp: keyboard.crisp)
            else { return }
            // Slight gain variation so repeated keys don't sound machine-gunned.
            self.clicks.play(buffer, gain: Float(keyboard.volume) * .random(in: 0.88...1.0))
        }
        listener.onMouseDown = { [weak self] in
            guard let self, self.model.enabled, mouse.enabled else { return }
            self.clicks.play(self.mouseSound.buffer(crisp: mouse.crisp),
                             gain: Float(mouse.volume) * .random(in: 0.88...1.0))
        }
        keyboard.preview = { [weak self] in
            guard let self, let space = self.pack.buffer(forScanCode: 57, keyCode: 0, crisp: keyboard.crisp)
            else { return }
            self.clicks.play(space, gain: Float(keyboard.volume))
        }
        mouse.preview = { [weak self] in
            guard let self else { return }
            self.clicks.play(self.mouseSound.buffer(crisp: mouse.crisp), gain: Float(mouse.volume))
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        // Left-click opens the menu; right-click or ⌥-click toggles sound instantly.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshIcon()

        model.syncLaunchAtLogin()
        startListening()

        if showSettingsOnLaunch {
            showSettings()
        } else {
            // A windowless app that is frontmost receives keystrokes and answers each
            // with the system alert sound, so never hold focus without a window.
            NSApp.deactivate()
        }
    }

    /// Launching Cream again (Spotlight, Raycast, Finder) while it runs opens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: Model → audio

    private func observeModel() {
        // Per-device volume is applied per click (see onPress / onMouseDown).
        clicks.volume = 1
        model.$enabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshIcon() }
        }.store(in: &subscriptions)

        let keyboard = model.keyboard, mouse = model.mouse
        keyboard.$tailMs.dropFirst().sink { [weak self] in self?.pack.applyTail(hold: $0 / 1000) }
            .store(in: &subscriptions)
        keyboard.$selectedID.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.loadSelectedPack(); keyboard.preview() }
        }.store(in: &subscriptions)
        mouse.$tailMs.dropFirst().sink { [weak self] in self?.mouseSound.applyTail(hold: $0 / 1000) }
            .store(in: &subscriptions)
        mouse.$selectedID.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.loadMouseSound(); mouse.preview() }
        }.store(in: &subscriptions)
        for device in [keyboard, mouse] {
            device.$crisp.dropFirst().sink { _ in DispatchQueue.main.async { device.preview() } }
                .store(in: &subscriptions)
            device.$volume.dropFirst().sink { [weak self] in
                self?.volumeLabels[ObjectIdentifier(device)]?.stringValue = "\(Int(($0 * 100).rounded()))%"
            }.store(in: &subscriptions)
        }
    }

    private func loadSelectedPack() {
        let info = model.currentPack
        do {
            pack = try SoundPack(folder: info.folder, hold: model.keyboard.tailMs / 1000)
            model.notice = nil
        } catch {
            model.notice = "Couldn't load \(info.name): \(error.localizedDescription)"
            if info.id != PackStore.builtInID {
                model.keyboard.selectedID = PackStore.builtInID
                loadSelectedPack()
            } else {
                fatal("The built-in sound pack is damaged:\n\(error.localizedDescription)")
            }
        }
    }

    private func loadMouseSound() {
        let info = model.currentMouseSound
        do {
            mouseSound = try ClickSound(file: info.file, hold: model.mouse.tailMs / 1000)
        } catch {
            model.notice = "Couldn't load \(info.name): \(error.localizedDescription)"
            if info.id != MouseSoundStore.builtInID {
                model.mouse.selectedID = MouseSoundStore.builtInID
                loadMouseSound()
            } else {
                fatal("The built-in mouse sound is damaged:\n\(error.localizedDescription)")
            }
        }
    }

    // MARK: Permission

    private func startListening() {
        if listener.start() { model.isListening = true; return }
        KeyListener.requestPermission()
        // Poll until the user grants Input Monitoring, then start without a relaunch.
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self, self.listener.start() else { return }
            timer.invalidate()
            self.model.isListening = true
            self.refreshIcon()
        }
        refreshIcon()
    }

    // MARK: Settings panel

    @objc private func showSettings() {
        if settingsPanel == nil {
            let panel = SettingsPanel(model: model)
            panel.delegate = self
            panel.onAddSounds = { [weak self] in self?.addSounds(for: $0) }
            settingsPanel = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ note: Notification) {
        guard (note.object as? SettingsPanel) === settingsPanel else { return }
        settingsPanel = nil
        model.notice = nil
        DispatchQueue.main.async { NSApp.hide(nil) } // hand focus back to the previous app
    }

    private func addSounds(for device: Device) {
        guard let panel = settingsPanel else { return }
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
        picker.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let self else { return }
            switch device {
            case .keyboard: self.model.importSounds(picker.urls)
            case .mouse: self.model.importMouseSounds(picker.urls)
            }
        }
    }

    // MARK: Menu

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            model.enabled.toggle()
        } else {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil // detach so the next click comes back here
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        sliderDevices.removeAll()

        let title = NSMenuItem(title: pack.name, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        if !listener.isRunning {
            let warn = NSMenuItem(title: "⚠︎ Needs Input Monitoring permission…",
                                  action: #selector(openPermissionSettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: "Sound On", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = model.enabled ? .on : .off
        menu.addItem(toggle)
        let hint = NSMenuItem(title: "Right-click the icon to mute or unmute", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        for (title, device) in [("Keyboard", model.keyboard), ("Mouse", model.mouse)] {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "\(title) Clicks", action: #selector(toggleDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.state = device.enabled ? .on : .off
            menu.addItem(item)
            let sliderItem = NSMenuItem()
            sliderItem.view = makeVolumeRow(device)
            menu.addItem(sliderItem)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Cream", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    @objc private func toggleEnabled() { model.enabled.toggle() }

    @objc private func toggleDevice(_ item: NSMenuItem) {
        (item.representedObject as? DeviceSettings)?.enabled.toggle()
    }

    private func makeVolumeRow(_ device: DeviceSettings) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 30))

        let quiet = NSImageView(image: NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Quieter")!)
        quiet.contentTintColor = .secondaryLabelColor
        quiet.frame = NSRect(x: 14, y: 5, width: 16, height: 18)
        row.addSubview(quiet)

        let slider = NSSlider(value: device.volume, minValue: 0, maxValue: 1,
                              target: self, action: #selector(volumeChanged(_:)))
        slider.frame = NSRect(x: 34, y: 4, width: 160, height: 22)
        row.addSubview(slider)
        sliderDevices[ObjectIdentifier(slider)] = device

        let percent = NSTextField(labelWithString: "\(Int((device.volume * 100).rounded()))%")
        percent.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.alignment = .right
        percent.frame = NSRect(x: 196, y: 6, width: 42, height: 17)
        row.addSubview(percent)
        volumeLabels[ObjectIdentifier(device)] = percent
        return row
    }

    @objc private func volumeChanged(_ slider: NSSlider) {
        guard let device = sliderDevices[ObjectIdentifier(slider)] else { return }
        device.volume = slider.doubleValue
        // Preview on mouse-up so you can hear the level you picked.
        if NSApp.currentEvent?.type == .leftMouseUp { device.preview() }
    }

    @objc private func openPermissionSettings() { KeyListener.openSettings() }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        // The keycap while sound is on; system symbols flag the other states.
        button.image = !listener.isRunning
            ? NSImage(systemSymbolName: "keyboard.badge.exclamationmark", accessibilityDescription: "Cream")
            : model.enabled ? MenuIcon.keycap
            : NSImage(systemSymbolName: "speaker.slash", accessibilityDescription: "Cream")
        button.appearsDisabled = !model.enabled
        button.toolTip = model.enabled ? "Cream: sound on (right-click to mute)"
                                       : "Cream: muted (right-click to unmute)"
    }

    // MARK: Helpers

    private func fatal(_ message: String) -> Never {
        let alert = NSAlert()
        alert.messageText = "Cream can't start"
        alert.informativeText = message
        alert.runModal()
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
