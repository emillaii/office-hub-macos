import AppKit
import SwiftUI
import OfficeHubPluginKit

@MainActor @objc(OfficeHubMailMemoPlugin) final class MailPlugin: NSObject, OfficeHubPlugin {
    override init() { super.init() }
    private var store: Store?
    private var context: OfficeHubContext?
    var statusSummary: String { store?.hasAccounts != true ? "Setup needed · no mail accounts" : store?.isBusy == true ? "Checking inboxes…" : store?.settings.enabled == true ? "Schedule enabled · HKT" : "Automatic checks paused" }

    func activate(context: OfficeHubContext) throws -> NSViewController {
        self.context = context
        root = context.dataDirectory; runtime = root.appendingPathComponent("runtime")
        let source = root.appendingPathComponent("source")
        for directory in [root, runtime, source] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for name in ["runner.py", "mail-read.applescript", "check-instructions.txt", "report-schema.json"] {
            try Data(contentsOf: context.resourceDirectory.appendingPathComponent(name)).write(to: source.appendingPathComponent(name), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.appendingPathComponent(name).path)
        }
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("accounts.json").path) {
            try Data("[]".utf8).write(to: root.appendingPathComponent("accounts.json"), options: .atomic)
        }
        let model = Store(); store = model
        model.onThemeChange = { [weak context] identifier in context?.host?.selectTheme(identifier) }
        applyTheme(context.themeIdentifier)
        return NSHostingController(rootView: TerminalView(store: model))
    }
    func applyTheme(_ identifier: String) {
        store?.selectTheme(HubTheme(rawValue: identifier) ?? .hackerGreen)
    }
    func prepareToDeactivate() -> Bool {
        if store?.isBusy == true {
            let alert = NSAlert(); alert.messageText = "Mail check is still running"
            alert.informativeText = "Wait for the current check to finish before disabling Mail Memo or quitting Office Hub."
            alert.runModal(); return false
        }
        return true
    }
    func deactivate() { store?.stop(); store = nil; context = nil }
    func importPreviousSettings() {
        guard let store, !store.isBusy else { return }
        let prompt = NSAlert(); prompt.messageText = "Import standalone Mail Memo settings?"
        prompt.informativeText = "Copy accounts and preferences into Office Hub. Automatic checks and Mail access start paused. Pause the standalone Mail Memo before enabling this plugin to avoid duplicate checks. The standalone app and its reports are not changed."
        prompt.addButton(withTitle: "Import Settings"); prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        let original = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mail Memo")
        do {
            let accounts = try JSONDecoder().decode([String].self, from: Data(contentsOf: original.appendingPathComponent("accounts.json")))
            var settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: original.appendingPathComponent("settings.json")))
            settings.enabled = false; settings.mail_access = false
            store.settings = settings; store.accountText = accounts.joined(separator: "\n"); store.save()
            context?.host?.selectTheme(settings.theme)
            store.notice = "Imported. Choose Connect Apple Mail to approve Office Hub’s access."
        } catch { store.notice = "Import failed: \(error.localizedDescription)" }
    }
}
