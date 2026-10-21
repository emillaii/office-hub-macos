import AppKit
import SwiftUI
import OfficeHubPluginKit

@MainActor @objc(OfficeHubOfficeProxyPlugin) final class ProxyPlugin: NSObject, OfficeHubPlugin {
    override init() { super.init() }
    private var controller: ProxyController?
    private var scroll: NSScrollView?
    var statusSummary: String { controller?.statusLabel.stringValue ?? "Disabled" }

    func activate(context: OfficeHubContext) throws -> NSViewController {
        let proxy = ProxyController()
        do { try proxy.activate(context) }
        catch { proxy.stop(); throw error }
        controller = proxy
        let viewController = ProxyViewController()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.documentView = proxy.contentRoot
        self.scroll = scroll; viewController.view = scroll
        applyTheme(context.themeIdentifier)
        return viewController
    }
    func applyTheme(_ identifier: String) {
        let palette = (HubTheme(rawValue: identifier) ?? .hackerGreen).palette
        scroll?.drawsBackground = true; scroll?.backgroundColor = NSColor(palette.background)
        func apply(_ view: NSView) {
            if let text = view as? NSTextField {
                text.font = .monospacedSystemFont(ofSize: min(text.font?.pointSize ?? 12, 21), weight: .regular)
                text.textColor = NSColor(text.isEditable ? palette.text : palette.muted)
                if text.isEditable { text.drawsBackground = true; text.backgroundColor = NSColor(palette.inset) }
            }
            if let editor = view as? NSTextView {
                editor.backgroundColor = NSColor(palette.inset); editor.textColor = NSColor(palette.text)
                editor.insertionPointColor = NSColor(palette.accent)
            }
            if let button = view as? NSButton { button.contentTintColor = NSColor(palette.accent) }
            view.subviews.forEach(apply)
        }
        if let root = controller?.contentRoot { apply(root) }
    }
    func prepareToDeactivate() -> Bool { controller?.prepareToStop() ?? true }
    func deactivate() { controller?.stop(); controller = nil; scroll = nil }

    func importPreviousSettings() {
        guard let controller, !controller.enabled, !controller.connecting, !controller.verifying else { return }
        guard controller.resolveUnsavedChanges("importing settings") else { return }
        let prompt = NSAlert()
        prompt.messageText = "Import standalone Office Proxy settings?"
        prompt.informativeText = "This copies saved connection profiles, domain rules and trusted public host keys. Office Hub uses its own browser profile, ports and tunnel. The standalone app is not changed."
        prompt.addButton(withTitle: "Import Settings"); prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        let original = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OfficeProxy")
        do {
            let settings = try SettingsStore(directory: original).load()
            try controller.storeSettings(settings)
            for file in try FileManager.default.contentsOfDirectory(at: original, includingPropertiesForKeys: [.isRegularFileKey])
                where file.lastPathComponent.hasPrefix("office_known_hosts") {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let destination = controller.context.dataDirectory.appendingPathComponent(file.lastPathComponent)
                try Data(contentsOf: file).write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            controller.loadAllFields(); try controller.persistRuntime(); controller.refresh()
        } catch { controller.showError("Import failed", error.localizedDescription) }
    }
}

/// AppKit document coordinates start at the bottom; show the form heading on first layout.
@MainActor private final class ProxyViewController: NSViewController {
    private var positioned = false
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !positioned, let scroll = view as? NSScrollView,
              let document = scroll.documentView, scroll.contentSize.height > 0 else { return }
        positioned = true
        document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentSize.height)))
    }
}
