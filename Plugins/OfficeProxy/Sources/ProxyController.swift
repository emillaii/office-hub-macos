import AppKit
import OfficeHubPluginKit
import Foundation
import Darwin

let fm = FileManager.default
var support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Office Hub/Plugin Data/local.officehub.office-proxy")
var settingsURL = support.appendingPathComponent("settings.json")
var runtimeURL = support.appendingPathComponent("runtime.json")
var socketPath = support.appendingPathComponent("control.sock").path
var profilePath = support.appendingPathComponent("ManagedChromeProfile").path

@discardableResult func command(_ path: String, _ args: [String]) -> (Int32, String) {
    let task = Process(); task.executableURL = URL(fileURLWithPath: path); task.arguments = args
    let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
    task.standardInput = FileHandle.nullDevice
    do {
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    } catch { return (-1, error.localizedDescription) }
}

@MainActor class ProxyController: NSObject {
    var context: OfficeHubContext!
    let contentRoot = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 770))
    var settingsStore = SettingsStore(directory: support)
    var settings = Settings()
    var window: NSWindow!
    var statusItem: NSStatusItem?
    var statusLabel = NSTextField(labelWithString: "Starting…")
    var detailLabel = NSTextField(wrappingLabelWithString: "")
    var hostField = NSTextField(); var portField = NSTextField(); var userField = NSTextField()
    var homeField = NSTextField(); var domainsText = NSTextView()
    var profilePicker = NSPopUpButton()
    var profileButtons: [NSButton] = []
    var toggleButton = NSButton(); var openButton = NSButton(); var trustButton = NSButton()
    var toggleMenu = NSMenuItem()
    var revertButton = NSButton(); var historyButton = NSButton(); var restartButton = NSButton()
    var draftLabel = NSTextField(labelWithString: "")
    var restarting = false
    var historyChoices: [SettingsSnapshot] = []
    var historyPicker: NSPopUpButton?
    var historyPreview: NSTextView?
    var proxyTask: Process?; var sshTask: Process?
    var monitor: Timer?
    var enabled = false; var connecting = false; var quitting = false; var verifying = false
    var recentError = ""
    var proxyLog: FileHandle?

    func activate(_ context: OfficeHubContext) throws {
        self.context = context; window = context.window
        support = context.dataDirectory; settingsURL = support.appendingPathComponent("settings.json")
        runtimeURL = support.appendingPathComponent("runtime.json")
        let cache = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/OfficeHub/Proxy")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        socketPath = cache.appendingPathComponent("control.sock").path
        profilePath = support.appendingPathComponent("ManagedChromeProfile").path
        settingsStore = SettingsStore(directory: support)
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        settings = try settingsStore.load()
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(updateEditingActions), name: NSControl.textDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateEditingActions), name: NSText.didChangeNotification, object: nil)
        enabled = false
        try persistRuntime(); try startProxy(); refresh()
        monitor = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkConnection() } }
    }

    func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat = 22) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.frame = NSRect(x: x, y: y, width: width, height: height)
        contentRoot.addSubview(field); return field
    }

    func buildUI() {
        let view = contentRoot
        let title = label("Your office network, from home", 28, 712, 595, 32)
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        statusLabel.frame = NSRect(x: 28, y: 678, width: 410, height: 25); statusLabel.font = .systemFont(ofSize: 15, weight: .medium); view.addSubview(statusLabel)
        toggleButton = NSButton(title: "Connect", target: self, action: #selector(toggleConnection)); toggleButton.bezelStyle = .rounded
        toggleButton.frame = NSRect(x: 486, y: 670, width: 136, height: 36); view.addSubview(toggleButton)
        _ = label("Office SSH connection", 28, 628, 590).font = .systemFont(ofSize: 14, weight: .semibold)
        trustButton = NSButton(title: "Verify office PC…", target: self, action: #selector(verifyHost))
        trustButton.bezelStyle = .rounded; trustButton.frame = NSRect(x: 438, y: 622, width: 184, height: 32)
        view.addSubview(trustButton)
        _ = label("Connection profile", 28, 587, 594)
        profilePicker.frame = NSRect(x: 28, y: 550, width: 280, height: 32)
        profilePicker.target = self; profilePicker.action = #selector(selectProfile)
        view.addSubview(profilePicker)
        for (title, action, x, width) in [("New…", #selector(addProfile), 316.0, 86.0),
                                          ("Rename…", #selector(renameProfile), 406.0, 106.0),
                                          ("Remove", #selector(removeProfile), 516.0, 106.0)] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded; button.frame = NSRect(x: x, y: 550, width: width, height: 32)
            profileButtons.append(button); view.addSubview(button)
        }
        reloadProfiles()
        _ = label("Host", 28, 517, 310); _ = label("Port", 394, 517, 70); _ = label("Username", 478, 517, 144)
        hostField.frame = NSRect(x: 28, y: 482, width: 350, height: 28); hostField.stringValue = settings.host
        portField.frame = NSRect(x: 394, y: 482, width: 68, height: 28); portField.stringValue = String(settings.port)
        userField.frame = NSRect(x: 478, y: 482, width: 144, height: 28); userField.stringValue = settings.username
        for field in [hostField, portField, userField] { view.addSubview(field) }
        _ = label("Domains through the office PC", 28, 435, 590).font = .systemFont(ofSize: 14, weight: .semibold)
        let hint = label("One domain or IP per line. Use *.example.com for that domain and its subdomains.", 28, 409, 594, 22)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let scroll = NSScrollView(frame: NSRect(x: 28, y: 231, width: 594, height: 168))
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        domainsText = NSTextView(frame: scroll.bounds); domainsText.isRichText = false; domainsText.allowsUndo = true
        domainsText.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        domainsText.textContainerInset = NSSize(width: 10, height: 10); domainsText.string = settings.domains.joined(separator: "\n")
        domainsText.isAutomaticQuoteSubstitutionEnabled = false; domainsText.isAutomaticDashSubstitutionEnabled = false
        domainsText.autoresizingMask = [.width]; domainsText.isVerticallyResizable = true
        scroll.documentView = domainsText; view.addSubview(scroll)
        _ = label("Browser start page", 28, 195, 594)
        homeField.frame = NSRect(x: 28, y: 158, width: 594, height: 28); homeField.stringValue = settings.home; view.addSubview(homeField)
        let save = NSButton(title: "Save settings", target: self, action: #selector(saveSettings)); save.bezelStyle = .rounded
        save.frame = NSRect(x: 28, y: 107, width: 142, height: 34); view.addSubview(save)
        openButton = NSButton(title: "Open proxy browser", target: self, action: #selector(openBrowser)); openButton.bezelStyle = .rounded
        openButton.frame = NSRect(x: 425, y: 65, width: 197, height: 34); view.addSubview(openButton)
        revertButton = NSButton(title: "Revert edits", target: self, action: #selector(revertEdits))
        historyButton = NSButton(title: "Saved history…", target: self, action: #selector(restoreHistory))
        restartButton = NSButton(title: "Restart plugin", target: self, action: #selector(restartApp))
        for (button, x, width) in [(revertButton, 174.0, 142.0), (historyButton, 320.0, 142.0), (restartButton, 466.0, 156.0)] {
            button.bezelStyle = .rounded; button.frame = NSRect(x: x, y: 107, width: width, height: 34); view.addSubview(button)
        }
        restartButton.toolTip = "Restart only this plugin’s local proxy; the standalone app is unaffected."
        draftLabel.frame = NSRect(x: 28, y: 71, width: 390, height: 22)
        draftLabel.font = .systemFont(ofSize: 12); draftLabel.textColor = .secondaryLabelColor; view.addSubview(draftLabel)
        detailLabel.frame = NSRect(x: 28, y: 12, width: 594, height: 44); detailLabel.font = .systemFont(ofSize: 12); detailLabel.textColor = .secondaryLabelColor
        view.addSubview(detailLabel)
    }

    func reloadProfiles() {
        profilePicker.removeAllItems()
        profilePicker.addItems(withTitles: settings.profiles.map { $0.name })
        profilePicker.selectItem(at: settings.selectedIndex)
    }

    func loadEndpointFields() {
        hostField.stringValue = settings.host
        portField.stringValue = String(settings.port)
        userField.stringValue = settings.username
        reloadProfiles()
    }

    func storeSettings(_ updated: Settings) throws {
        try settingsStore.save(updated)
        settings = updated
        updateEditingActions()
    }

    var hasUnsavedChanges: Bool {
        hostField.stringValue != settings.host || portField.stringValue != String(settings.port) ||
        userField.stringValue != settings.username || homeField.stringValue != settings.home ||
        domainsText.string != settings.domains.joined(separator: "\n")
    }

    @objc func updateEditingActions() {
        revertButton.isEnabled = hasUnsavedChanges && !connecting && !verifying
        draftLabel.stringValue = hasUnsavedChanges ? "Unsaved changes" : "All changes saved"
    }

    func loadAllFields() {
        window.endEditing(for: nil)
        loadEndpointFields()
        homeField.stringValue = settings.home
        domainsText.string = settings.domains.joined(separator: "\n")
        domainsText.undoManager?.removeAllActions()
        window.undoManager?.removeAllActions()
        updateEditingActions()
    }

    @objc func revertEdits() {
        guard !connecting && !verifying else { return }
        loadAllFields(); recentError = "Unsaved edits reverted to your last saved settings."; refresh()
    }

    func resolveUnsavedChanges(_ action: String) -> Bool {
        window.endEditing(for: nil)
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert(); alert.messageText = "Save your changes before \(action)?"
        alert.informativeText = "Save keeps a copy of your previous settings in Saved history. Discard returns to the last saved settings."
        alert.addButton(withTitle: "Save Changes"); alert.addButton(withTitle: "Discard Changes"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                try storeSettings(validatedSettings()); try persistRuntime(); loadAllFields(); return true
            } catch { showError("Could not save settings", error.localizedDescription); return false }
        case .alertSecondButtonReturn: loadAllFields(); return true
        default: return false
        }
    }

    @objc func previewHistory() {
        guard let picker = historyPicker, historyChoices.indices.contains(picker.indexOfSelectedItem) else { return }
        let saved = historyChoices[picker.indexOfSelectedItem].settings
        let profiles = saved.profiles.map { "\($0.name): \($0.username)@\($0.host):\($0.port)" }.joined(separator: "\n")
        historyPreview?.string = "Selected profile: \(saved.selectedProfile.name)\n\nProfiles:\n\(profiles)\n\nDomains:\n\(saved.domains.joined(separator: "\n"))\n\nStart page:\n\(saved.home)"
    }

    @objc func restoreHistory() {
        guard !enabled && !connecting && !verifying else { return }
        do {
            historyChoices = try settingsStore.history()
            guard !historyChoices.isEmpty else {
                showError("No saved history yet", "Your previous settings will appear here after your next change is saved."); return
            }
            guard resolveUnsavedChanges("restoring settings") else { return }
            historyChoices = try settingsStore.history()
            let alert = NSAlert(); alert.messageText = "Restore saved settings"
            alert.informativeText = "Choose a previous version. This restores all profiles, domains, and the start page. Your current saved settings will also be kept in history."
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 280))
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 248, width: 500, height: 32))
            let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .medium
            for (index, snapshot) in historyChoices.enumerated() {
                picker.addItem(withTitle: "\(index + 1). \(formatter.string(from: snapshot.savedAt)) · \(snapshot.settings.selectedProfile.name)")
            }
            picker.target = self; picker.action = #selector(previewHistory); view.addSubview(picker)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 235))
            scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
            let preview = NSTextView(frame: scroll.bounds); preview.isEditable = false; preview.isRichText = false
            preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            preview.textContainerInset = NSSize(width: 8, height: 8)
            preview.autoresizingMask = [.width]; preview.isVerticallyResizable = true
            scroll.documentView = preview; view.addSubview(scroll)
            historyPicker = picker; historyPreview = preview; previewHistory()
            defer { historyPicker = nil; historyPreview = nil; historyChoices = [] }
            alert.accessoryView = view; alert.addButton(withTitle: "Restore"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try storeSettings(historyChoices[picker.indexOfSelectedItem].settings)
            try persistRuntime(); loadAllFields()
            recentError = "Previous settings restored. Your replaced settings are available in Saved history."; refresh()
        } catch { showError("Could not restore settings", error.localizedDescription) }
    }

    @objc func restartApp() {
        guard !verifying && !connecting && resolveUnsavedChanges("restarting the plugin") else { return }
        quitting = true; disconnect()
        proxyTask?.terminationHandler = nil
        if proxyTask?.isRunning == true { proxyTask?.terminate(); proxyTask?.waitUntilExit() }
        proxyTask = nil; quitting = false
        do { try startProxy(); refresh() } catch { showError("Could not restart plugin", error.localizedDescription) }
    }

    func profileName(_ title: String, initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
        field.stringValue = initial; alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { showError("Enter a profile name", "Use a name such as Office or Home server."); return nil }
        guard !settings.profiles.contains(where: { $0.id != settings.selectedProfileID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            showError("Name already used", "Choose a different profile name."); return nil
        }
        return name
    }

    @objc func selectProfile() {
        guard !enabled && !connecting && !verifying else { reloadProfiles(); return }
        let index = profilePicker.indexOfSelectedItem
        guard settings.profiles.indices.contains(index) else { return }
        do {
            guard resolveUnsavedChanges("switching profiles") else { reloadProfiles(); return }
            var updated = settings
            updated.selectedProfileID = updated.profiles[index].id
            try storeSettings(updated)
            loadEndpointFields(); recentError = "Profile selected. Click Connect to sign in."; refresh()
        } catch { reloadProfiles(); showError("Could not switch profiles", error.localizedDescription) }
    }

    @objc func addProfile() {
        guard !enabled && !connecting && !verifying else { return }
        guard resolveUnsavedChanges("creating a profile") else { return }
        guard let name = profileName("New connection profile", initial: "") else { return }
        guard !settings.profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            showError("Name already used", "Choose a different profile name."); return
        }
        do {
            var updated = settings
            let profile = ConnectionProfile(name: name, host: updated.host, port: updated.port, username: updated.username)
            updated.profiles.append(profile); updated.selectedProfileID = profile.id
            try storeSettings(updated)
            loadEndpointFields(); recentError = "Profile added. Enter its host, port, and username, then save settings."; refresh()
        } catch { showError("Could not add profile", error.localizedDescription) }
    }

    @objc func renameProfile() {
        guard !enabled && !connecting && !verifying else { return }
        guard resolveUnsavedChanges("renaming a profile") else { return }
        guard let name = profileName("Rename connection profile", initial: settings.selectedProfile.name) else { return }
        do {
            var updated = settings
            updated.profiles[updated.selectedIndex].name = name
            try storeSettings(updated); reloadProfiles(); refresh()
        } catch { showError("Could not rename profile", error.localizedDescription) }
    }

    @objc func removeProfile() {
        guard !enabled && !connecting && !verifying && settings.profiles.count > 1 else { return }
        guard resolveUnsavedChanges("removing a profile") else { return }
        do {
            var updated = settings
            updated.profiles.remove(at: updated.selectedIndex)
            updated.selectedProfileID = updated.profiles[0].id
            try storeSettings(updated)
            loadEndpointFields(); recentError = "Profile removed."; refresh()
        } catch { showError("Could not remove profile", error.localizedDescription) }
    }

    @objc func showWindow() { context.host?.revealPlugin(context.identifier) }

    func showError(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }

    func validatedSettings() throws -> Settings {
        var result = settings
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedHost = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        let allowedUser = allowedHost.union(CharacterSet(charactersIn: "_\\"))
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy({ allowedHost.contains($0) }),
              !user.isEmpty, !user.hasPrefix("-"), user.unicodeScalars.allSatisfy({ allowedUser.contains($0) }),
              let port = Int(portField.stringValue), (1...65535).contains(port) else {
            throw NSError(domain: "OfficeProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a valid SSH host, port (1–65535), and username."])
        }
        var rules: [String] = []
        for line in domainsText.string.components(separatedBy: .newlines) {
            var value = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.isEmpty { continue }
            if value.contains("://") {
                guard let url = URLComponents(string: value), let hostname = url.host else { throw invalidDomain(value) }
                value = hostname
            } else {
                value = String(value.split(separator: "/", omittingEmptySubsequences: false)[0])
                if value.filter({ $0 == ":" }).count == 1 { value = String(value.split(separator: ":")[0]) }
            }
            while value.hasSuffix(".") { value.removeLast() }
            if value.hasPrefix(".") { value = "*" + value }
            let bare = value.hasPrefix("*.") ? String(value.dropFirst(2)) : value
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
            guard !bare.isEmpty, !bare.hasPrefix("-"), !bare.hasPrefix("."), !bare.contains(".."),
                  bare.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw invalidDomain(value) }
            if !rules.contains(value) { rules.append(value) }
        }
        let home = homeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: home), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw NSError(domain: "OfficeProxy", code: 2, userInfo: [NSLocalizedDescriptionKey: "The start page must be a full http:// or https:// URL."])
        }
        result.host = host; result.port = port; result.username = user; result.domains = rules; result.home = home
        return result
    }

    func invalidDomain(_ value: String) -> NSError {
        NSError(domain: "OfficeProxy", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid domain: \(value). Use a hostname, IPv4 address, or *.example.com, one per line."])
    }

    @objc func saveSettings() {
        do {
            try storeSettings(validatedSettings()); try persistRuntime()
            loadAllFields()
            recentError = "Settings saved. New connections use the updated domain list; reload your pages."
            refresh()
        } catch { showError("Check your settings", error.localizedDescription) }
    }

    func persistRuntime() throws {
        let data: [String: Any] = ["enabled": enabled, "domains": settings.domains, "socksPort": 1081]
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: runtimeURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeURL.path)
    }

    func masterArgs(_ op: String) -> [String] { ["-S", socketPath, "-O", op, "-p", String(settings.port), "\(settings.username)@\(settings.host)"] }
    func masterRunning() -> Bool { command("/usr/bin/ssh", masterArgs("check")).0 == 0 }

    @objc func verifyHost() {
        guard !enabled && !connecting && !verifying else { return }
        do { try storeSettings(validatedSettings()) }
        catch { showError("Check your settings", error.localizedDescription); return }
        verifying = true
        recentError = "Fetching the office PC's public host key…"; refresh()
        let host = settings.host; let port = settings.port
        let connectionProfile = settings.selectedProfile
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scan = command("/usr/bin/ssh-keyscan", ["-T", "5", "-t", "ed25519", "-p", String(port), host])
            let parts = scan.1.components(separatedBy: .newlines)
                .filter { !$0.hasPrefix("#") }.map { $0.split(whereSeparator: { $0.isWhitespace }) }
                .first { $0.count == 3 && $0[1] == "ssh-ed25519" }
            guard scan.0 == 0, let parts = parts else {
                DispatchQueue.main.async {
                    self?.verifying = false
                    self?.recentError = "Could not retrieve an Ed25519 SSH host key. Check the endpoint and office PC."
                    self?.refresh(); self?.showError("Host key lookup failed", "No supported host key was returned. Check the SSH host and port; the app does not disable host verification.")
                }; return
            }
            let key = "\(connectionProfile.hostKeyAlias) \(parts[1]) \(parts[2])\n"
            let temporary = support.appendingPathComponent(".host-check-\(UUID().uuidString).pub")
            do {
                try Data(key.utf8).write(to: temporary, options: .atomic)
                defer { try? fm.removeItem(at: temporary) }
                let fingerprint = command("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", temporary.path])
                guard fingerprint.0 == 0 else { throw NSError(domain: "OfficeProxy", code: 4, userInfo: [NSLocalizedDescriptionKey: "The returned host key is invalid."]) }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.verifying = false
                    let alert = NSAlert(); alert.messageText = "Verify your office PC's identity"
                    alert.informativeText = "SSH endpoint: \(host):\(port)\n\n\(fingerprint.1.trimmingCharacters(in: .whitespacesAndNewlines))\n\nCompare this fingerprint with one obtained directly from the office PC or a trusted administrator. A network key lookup alone does not verify the server's identity. Trusting this key replaces the trusted key for this connection profile."
                    alert.addButton(withTitle: "Trust This Key"); alert.addButton(withTitle: "Cancel")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        do {
                            let target = support.appendingPathComponent(connectionProfile.knownHostsFilename)
                            try Data(key.utf8).write(to: target, options: .atomic)
                            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                            self.recentError = "Office PC key saved. Click Connect to sign in."
                        } catch { self.showError("Could not save the trusted key", error.localizedDescription) }
                    } else { self.recentError = "Host key was not changed." }
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async { self?.verifying = false; self?.recentError = error.localizedDescription; self?.refresh() }
            }
        }
    }

    func startProxy() throws {
        if proxyTask?.isRunning == true { return }
        guard let script = Optional(context.resourceDirectory.appendingPathComponent("proxy.py").path) else { throw invalidDomain("Missing proxy resource") }
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-u", script, runtimeURL.path, "18181"]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe; task.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: bytes, as: UTF8.self)
            if text.contains("Address already in use") {
                DispatchQueue.main.async { self?.showError("Local proxy port is busy", "Port 18181 is already in use. Close the other proxy app and reopen Office Proxy.") }
            }
        }
        task.terminationHandler = { [weak self, weak task] _ in DispatchQueue.main.async {
            guard let self = self, let task = task, self.proxyTask === task, !self.quitting else { return }
            self.recentError = "Local browser proxy stopped. Click Restart plugin to start it again."; self.refresh()
        }}
        try task.run(); proxyTask = task
    }

    @objc func toggleConnection() {
        if connecting || verifying { return }
        if enabled || masterRunning() { disconnect(); return }
        do { try storeSettings(validatedSettings()); try startProxy() }
        catch { showError("Cannot connect", error.localizedDescription); return }
        guard fm.fileExists(atPath: support.appendingPathComponent(settings.selectedProfile.knownHostsFilename).path) else {
            verifyHost(); return
        }
        connecting = true; recentError = ""; refresh()
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-NT", "-M", "-S", socketPath, "-D", "127.0.0.1:1081", "-p", String(settings.port),
                          "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
                          "-o", "ConnectTimeout=15", "-o", "NumberOfPasswordPrompts=1", "-o", "StrictHostKeyChecking=yes",
                          "-o", "HostKeyAlias=\(settings.selectedProfile.hostKeyAlias)", "-o", "UserKnownHostsFile=\"\(support.appendingPathComponent(settings.selectedProfile.knownHostsFilename).path)\"",
                          "\(settings.username)@\(settings.host)"]
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = context.resourceDirectory.appendingPathComponent("askpass.sh").path
        env["SSH_ASKPASS_REQUIRE"] = "force"; env["DISPLAY"] = "office-proxy"
        task.environment = env; task.standardInput = FileHandle.nullDevice; task.standardOutput = FileHandle.nullDevice
        let errors = Pipe(); task.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: bytes, as: UTF8.self)
            DispatchQueue.main.async { self?.recentError = String(text.suffix(1500)) }
        }
        task.terminationHandler = { [weak self, weak task] _ in DispatchQueue.main.async {
            guard let self = self, let task = task, self.sshTask === task, !self.quitting else { return }
            let wasConnecting = self.connecting
            self.connecting = false; self.enabled = false; try? self.persistRuntime(); self.refresh()
            if wasConnecting { self.showError("Office connection failed", self.recentError.isEmpty ? "Check the office PC, ngrok endpoint, and password." : self.recentError) }
        }}
        do { try task.run(); sshTask = task }
        catch { connecting = false; showError("Could not start SSH", error.localizedDescription); refresh() }
    }

    func checkConnection() {
        if connecting {
            if masterRunning() { connecting = false; enabled = true; recentError = ""; try? persistRuntime(); refresh() }
        } else if enabled && !masterRunning() {
            enabled = false; recentError = "Office connection was lost. Click Connect to try again."; try? persistRuntime(); refresh()
        }
    }

    func disconnect() {
        connecting = false; enabled = false
        try? persistRuntime()
        _ = command("/usr/bin/ssh", masterArgs("exit"))
        let previousTask = sshTask; sshTask = nil
        if previousTask?.isRunning == true { previousTask?.terminate() }
        recentError = ""; refresh()
    }

    func refresh() {
        let healthy = proxyTask?.isRunning == true
        statusLabel.stringValue = !healthy ? "Local proxy is not running" : connecting ? "Connecting to office…" : enabled ? "On · listed domains use your office PC" : "Off · browsing uses your home connection"
        statusLabel.textColor = !healthy ? .systemRed : enabled ? .systemGreen : .secondaryLabelColor
        toggleButton.title = connecting ? "Connecting…" : enabled ? "Disconnect" : "Connect"
        toggleButton.isEnabled = !connecting && !verifying && healthy
        toggleMenu.title = toggleButton.title; toggleMenu.isEnabled = toggleButton.isEnabled
        // A standard-width network icon fits crowded menu bars better than a text title.
        let indicator = NSImage(size: NSSize(width: 18, height: 18))
        indicator.lockFocus()
        let color: NSColor = connecting ? .systemOrange : enabled ? .systemGreen : .systemRed
        color.setStroke(); color.setFill()
        let links = NSBezierPath(); links.lineWidth = 1.6; links.lineCapStyle = .round
        links.move(to: NSPoint(x: 9, y: 5)); links.line(to: NSPoint(x: 9, y: 12))
        links.move(to: NSPoint(x: 3, y: 5)); links.line(to: NSPoint(x: 15, y: 5)); links.stroke()
        for rect in [NSRect(x: 6, y: 11, width: 6, height: 5),
                     NSRect(x: 0, y: 0, width: 6, height: 5),
                     NSRect(x: 12, y: 0, width: 6, height: 5)] {
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
        indicator.unlockFocus()
        indicator.isTemplate = false
        let connectionState = connecting ? "Connecting" : enabled ? "Connected" : "Disconnected"
        indicator.accessibilityDescription = "Office Proxy · \(connectionState)"
        statusItem?.button?.title = ""
        statusItem?.button?.image = indicator
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.setAccessibilityLabel("Office Proxy")
        statusItem?.button?.toolTip = "Office Proxy · \(connectionState) · \(settings.selectedProfile.name)"
        for field in [hostField, portField, userField] { field.isEnabled = !enabled && !connecting && !verifying }
        profilePicker.isEnabled = !enabled && !connecting && !verifying
        for button in profileButtons { button.isEnabled = profilePicker.isEnabled }
        profileButtons.last?.isEnabled = profilePicker.isEnabled && settings.profiles.count > 1
        trustButton.isEnabled = !enabled && !connecting && !verifying
        openButton.isEnabled = healthy
        historyButton.isEnabled = !enabled && !connecting && !verifying
        restartButton.isEnabled = !verifying && !restarting
        updateEditingActions()
        detailLabel.stringValue = recentError.isEmpty ? "Use Open proxy browser for these rules. Other Chrome windows keep their own settings.\nKeep Office Hub open; switching plugins keeps this connection running.\nPasswords are never saved. Update the SSH endpoint while disconnected." : recentError
    }

    @objc func openBrowser() {
        guard proxyTask?.isRunning == true else { showError("Proxy is not running", "Reopen Office Proxy to restart the local browser proxy."); return }
        let args = ["-na", "Google Chrome", "--args", "--user-data-dir=\(profilePath)",
                    "--proxy-server=http://127.0.0.1:18181", "--disable-quic", "--no-first-run", "--no-default-browser-check", settings.home]
        _ = command("/usr/bin/open", args)
    }

    func prepareToStop() -> Bool {
        guard !connecting && !verifying else { showError("Connection in progress", "Finish the current connection action before disabling this plugin."); return false }
        return resolveUnsavedChanges("disabling Office Proxy")
    }
    func stop() {
        quitting = true; monitor?.invalidate(); monitor = nil
        NotificationCenter.default.removeObserver(self)
        disconnect()
        proxyTask?.terminationHandler = nil
        if proxyTask?.isRunning == true { proxyTask?.terminate(); proxyTask?.waitUntilExit() }
        proxyTask = nil
    }
}
