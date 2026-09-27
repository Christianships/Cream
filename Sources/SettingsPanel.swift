import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A small floating settings window. Closing it (×, Esc, ⌘W) tears it down
/// completely and hands focus back to the previous app.
final class SettingsPanel: NSPanel {
    var onAddSounds: ((Device) -> Void)?

    init(model: AppModel) {
        // Borderless: no title bar at all; SwiftUI draws the rounded, frosted card.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: SettingsView(
            model: model,
            addSounds: { [weak self] in self?.onAddSounds?($0) },
            close: { [weak self] in self?.close() }))
        center()
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: close()
        case kVK_Tab: super.keyDown(with: event) // keep keyboard navigation
        default: break // swallow, so typing to preview sounds doesn't trigger the alert beep
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum Device: String, CaseIterable, Identifiable {
    case keyboard = "Keyboard", mouse = "Mouse"
    var id: String { rawValue }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    let addSounds: (Device) -> Void
    let close: () -> Void
    @State private var device: Device = .keyboard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Picker("Device", selection: $device) {
                ForEach(Device.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch device {
            case .keyboard:
                DeviceSection(
                    settings: model.keyboard, title: "Keyboard clicks", listTitle: "Sound pack",
                    choices: model.packs.map { Choice(id: $0.id, name: $0.name, builtIn: $0.builtIn) },
                    folder: PackStore.userFolder,
                    add: { addSounds(.keyboard) }, remove: model.removePack)
            case .mouse:
                DeviceSection(
                    settings: model.mouse, title: "Mouse clicks", listTitle: "Click sound",
                    choices: model.mouseSounds.map { Choice(id: $0.id, name: $0.name, builtIn: $0.builtIn) },
                    folder: MouseSoundStore.userFolder,
                    add: { addSounds(.mouse) }, remove: model.removeMouseSound)
            }

            Divider()
            Toggle("Launch at login", isOn: $model.launchAtLogin)
                .toggleStyle(.switch).controlSize(.small)
            if !model.isListening { permissionWarning }
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(18)
        .frame(width: 340)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.enabled ? "keyboard" : "speaker.slash")
                .font(.system(size: 20))
                .foregroundStyle(model.enabled ? Color.accentColor : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Cream").font(.headline)
                Text(!model.isListening ? "Waiting for permission"
                     : model.enabled ? "Type or click anywhere to hear it" : "Muted")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("All sounds", isOn: $model.enabled).toggleStyle(.switch).labelsHidden()
                .help("All sounds on/off")
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain).help("Close (Esc)")
        }
    }

    private var permissionWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Allow Input Monitoring so Cream can hear your typing.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open") { KeyListener.openSettings() }.controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Text("Esc to close").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("Quit Cream") { NSApp.terminate(nil) }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct Choice: Identifiable {
    let id: String
    let name: String
    let builtIn: Bool
}

/// The controls every device gets: on/off, sound choice, volume, tone and tail.
private struct DeviceSection: View {
    @ObservedObject var settings: DeviceSettings
    let title: String
    let listTitle: String
    let choices: [Choice]
    let folder: URL
    let add: () -> Void
    let remove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(title, isOn: $settings.enabled).toggleStyle(.switch).controlSize(.small)

            VStack(alignment: .leading, spacing: 6) {
                label(listTitle)
                VStack(spacing: 2) { ForEach(choices) { row($0) } }
                HStack(spacing: 14) {
                    Button(action: add) { Label("Add Sounds…", systemImage: "plus") }
                    Button {
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    } label: { Label("Show Folder", systemImage: "folder") }
                }
                .buttonStyle(.borderless).font(.callout).padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Volume")
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $settings.volume, in: 0...1) { editing in if !editing { settings.preview() } }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    Text("\(Int((settings.volume * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Tone")
                Picker("Tone", selection: $settings.crisp) {
                    Text("Crisp").tag(true)
                    Text("Original").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
                if settings.crisp {
                    HStack(spacing: 8) {
                        Text("Tail").foregroundStyle(.secondary)
                        Slider(value: $settings.tailMs, in: 10...150) { editing in if !editing { settings.preview() } }
                        Text("\(Int(settings.tailMs)) ms")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        }
        .opacity(settings.enabled ? 1 : 0.55)
    }

    private func row(_ choice: Choice) -> some View {
        let selected = choice.id == settings.selectedID
        return HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Text(choice.name).lineLimit(1).truncationMode(.tail)
            Spacer()
            if choice.builtIn {
                Text("Built-in").font(.caption).foregroundStyle(.secondary)
            } else {
                Button { remove(choice.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Move to Trash")
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { settings.selectedID = choice.id }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
