import AppKit
import SwiftUI
import OfficeHubPluginKit

@MainActor final class PluginManager: NSObject, ObservableObject, OfficeHubHostServices {
    @Published var plugins: [PluginDescriptor] = []
    @Published var enabled = Set<String>()
    @Published var selected = "home"
    @Published var theme = HubTheme.hackerGreen
    @Published var message = ""
    @Published var statuses: [String: String] = [:]
    private var loaded: [String: OfficeHubPlugin] = [:]
    private var bundles: [String: Bundle] = [:]
    private var contexts: [String: OfficeHubContext] = [:]
    var controllers: [String: NSViewController] = [:]
    weak var window: NSWindow?
    private var timer: Timer?
    let support: URL
    var pluginDirectory: URL { support.appendingPathComponent("Plugins") }

    init(support: URL) {
        self.support = support
        super.init()
        do {
            try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let data = try? Data(contentsOf: support.appendingPathComponent("appearance.json")),
               let value = try? JSONDecoder().decode([String: String].self, from: data) {
                theme = HubTheme(rawValue: value["theme"] ?? "") ?? .hackerGreen
            }
            try rescan()
        } catch { message = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatuses() }
        }
    }
    func rescan() throws {
        var descriptors: [PluginDescriptor] = []
        for (directory, bundled) in [(Bundle.main.builtInPlugInsURL, true), (Optional(pluginDirectory), false)] {
            guard let directory, FileManager.default.fileExists(atPath: directory.path) else { continue }
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where url.pathExtension == "officeplugin" {
                do {
                    let manifest = try PluginManifest.read(at: url)
                    guard !descriptors.contains(where: { $0.id == manifest.id }) else { throw PluginError.invalid("Duplicate plugin ID: \(manifest.id)") }
                    descriptors.append(PluginDescriptor(manifest: manifest, url: url, bundled: bundled))
                } catch { message = "Skipped \(url.lastPathComponent): \(error.localizedDescription)" }
            }
        }
        plugins = descriptors.sorted { $0.manifest.name < $1.manifest.name }
    }
    private func saveEnabled() {
        do { try JSONEncoder().encode(Array(enabled).sorted()).write(to: support.appendingPathComponent("enabled.json"), options: .atomic) }
        catch { message = "Could not save plugin choices: \(error.localizedDescription)" }
    }
    func restoreEnabledPlugins() {
        guard let data = try? Data(contentsOf: support.appendingPathComponent("enabled.json")),
              let identifiers = try? JSONDecoder().decode([String].self, from: data) else { return }
        for identifier in identifiers {
            if let descriptor = plugins.first(where: { $0.id == identifier }) { enable(descriptor) }
        }
        selected = "home"
    }
    func refreshStatuses() {
        statuses = Dictionary(uniqueKeysWithValues: enabled.compactMap { id in loaded[id].map { (id, $0.statusSummary) } })
    }
    func revealPlugin(_ identifier: String) {
        guard enabled.contains(identifier) else { return }
        selected = identifier; window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func selectTheme(_ identifier: String) {
        guard let next = HubTheme(rawValue: identifier), next != theme else { return }
        theme = next
        do { try JSONEncoder().encode(["theme": identifier]).write(to: support.appendingPathComponent("appearance.json"), options: .atomic) }
        catch { message = "Could not save appearance: \(error.localizedDescription)" }
        for id in enabled {
            contexts[id]?.themeIdentifier = identifier
            loaded[id]?.applyTheme(identifier)
        }
    }
    func enable(_ descriptor: PluginDescriptor) {
        guard !enabled.contains(descriptor.id), let window else { return }
        do {
            let plugin: OfficeHubPlugin
            if let existing = loaded[descriptor.id] { plugin = existing }
            else {
                try verifySignature(descriptor.url)
                guard let bundle = Bundle(url: descriptor.url),
                      let principal = bundle.principalClass as? OfficeHubPlugin.Type else {
                    throw PluginError.invalid("The plugin entry point does not implement OfficeHubPlugin API v1.")
                }
                plugin = principal.init(); loaded[descriptor.id] = plugin; bundles[descriptor.id] = bundle
            }
            let directory = support.appendingPathComponent("Plugin Data").appendingPathComponent(descriptor.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let context = OfficeHubContext(identifier: descriptor.id,
                resourceDirectory: descriptor.url.appendingPathComponent("Contents/Resources"), dataDirectory: directory,
                window: window, themeIdentifier: theme.rawValue, host: self)
            let controller: NSViewController
            do { controller = try plugin.activate(context: context) }
            catch { plugin.deactivate(); throw error }
            contexts[descriptor.id] = context; controllers[descriptor.id] = controller
            enabled.insert(descriptor.id); saveEnabled(); selected = descriptor.id; refreshStatuses()
            message = "\(descriptor.manifest.name) enabled."
        } catch { message = "Could not enable \(descriptor.manifest.name): \(error.localizedDescription)" }
    }
    func disable(_ descriptor: PluginDescriptor) {
        guard enabled.contains(descriptor.id), loaded[descriptor.id]?.prepareToDeactivate() == true else { return }
        loaded[descriptor.id]?.deactivate()
        enabled.remove(descriptor.id); controllers.removeValue(forKey: descriptor.id); contexts.removeValue(forKey: descriptor.id)
        if selected == descriptor.id { selected = "plugins" }
        saveEnabled(); refreshStatuses(); message = "\(descriptor.manifest.name) disabled. Settings have been kept."
    }
    func importPreviousSettings() { loaded[selected]?.importPreviousSettings?() }
    var canImport: Bool { enabled.contains(selected) && loaded[selected]?.responds(to: #selector(OfficeHubPlugin.importPreviousSettings)) == true }

    func verifySignature(_ url: URL) throws {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--verify", "--deep", "--strict", url.path]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw PluginError.invalid("Plugin signature verification failed. Rebuild or obtain a complete signed plugin.") }
    }
    func install() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = true
        picker.treatsFilePackagesAsDirectories = false; picker.allowsMultipleSelection = false
        picker.message = "Choose a trusted Office Hub .officeplugin bundle."
        guard picker.runModal() == .OK, let source = picker.url else { return }
        do {
            let manifest = try PluginManifest.read(at: source)
            guard !plugins.contains(where: { $0.id == manifest.id }) else {
                throw PluginError.invalid("That plugin is already installed. Disable and remove an external plugin, then restart Office Hub before replacing its code.")
            }
            guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
                throw PluginError.invalid("Cannot read this plugin.")
            }
            for case let file as URL in enumerator {
                if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw PluginError.invalid("Plugin bundles must not contain symbolic links.")
                }
            }
            try verifySignature(source)
            let prompt = NSAlert(); prompt.messageText = "Install \(manifest.name)?"
            prompt.informativeText = "\(manifest.summary)\n\nDeclared features: \(manifest.capabilities.joined(separator: ", ")).\n\nNative plugins run with Office Hub’s user access. Install code only from sources you trust. It will remain disabled until you enable it."
            prompt.addButton(withTitle: "Install Plugin"); prompt.addButton(withTitle: "Cancel")
            guard prompt.runModal() == .alertFirstButtonReturn else { return }
            let destination = pluginDirectory.appendingPathComponent(manifest.id + ".officeplugin")
            let staging = pluginDirectory.appendingPathComponent(".install-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: source, to: staging)
            try verifySignature(staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            try rescan(); message = "Installed \(manifest.name). Enable it when ready."
        } catch { message = error.localizedDescription }
    }
    func remove(_ descriptor: PluginDescriptor) {
        guard !descriptor.bundled else { message = "Included plugins can be disabled; their code stays inside Office Hub."; return }
        guard !enabled.contains(descriptor.id), loaded[descriptor.id] == nil else {
            message = "Disable this plugin and restart Office Hub before removing loaded native code."; return
        }
        let prompt = NSAlert(); prompt.messageText = "Remove \(descriptor.manifest.name)?"
        prompt.informativeText = "The plugin code will be removed. Its settings and reports will be kept."
        prompt.addButton(withTitle: "Remove Plugin"); prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        do { try FileManager.default.removeItem(at: descriptor.url); try rescan(); message = "Plugin removed. Saved data has been kept." }
        catch { message = error.localizedDescription }
    }
    func prepareToQuit() -> Bool { enabled.allSatisfy { loaded[$0]?.prepareToDeactivate() == true } }
    func stopAll() { timer?.invalidate(); for id in enabled { loaded[id]?.deactivate() }; enabled.removeAll() }
}
