import AppKit
import OfficeHubPluginKit
import SwiftUI
import UserNotifications

var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Office Hub/Plugin Data/local.officehub.mail-memo")
var runtime = root.appendingPathComponent("runtime")
typealias MemoTheme = HubTheme
typealias TerminalPalette = HubPalette
typealias ConsoleButtonStyle = HubButtonStyle

struct Settings: Codable {
    var enabled = false
    var mail_access = false
    var interval_minutes = 10
    var start_minutes = 420
    var end_minutes = 720
    var notify_all = false
    var include_summary = true
    var theme = "hacker-green"

    enum CodingKeys: String, CodingKey {
        case enabled, mail_access, interval_minutes, start_minutes, end_minutes, notify_all, include_summary, theme
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        mail_access = try c.decodeIfPresent(Bool.self, forKey: .mail_access) ?? false
        interval_minutes = try c.decodeIfPresent(Int.self, forKey: .interval_minutes) ?? 10
        start_minutes = try c.decodeIfPresent(Int.self, forKey: .start_minutes) ?? 420
        end_minutes = try c.decodeIfPresent(Int.self, forKey: .end_minutes) ?? 720
        notify_all = try c.decodeIfPresent(Bool.self, forKey: .notify_all) ?? false
        include_summary = try c.decodeIfPresent(Bool.self, forKey: .include_summary) ?? true
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "hacker-green"
    }
}
struct Coverage: Codable, Identifiable {
    var account: String
    var status: String
    var detail: String
    var id: String { account }
}
struct MailItem: Codable, Identifiable {
    var id: String
    var account: String
    var sender: String
    var subject: String
    var received_at: String
    var summary: String
    var important: Bool
    var needs_reply: Bool
    var category: String
}
struct Report: Codable {
    var checked_at: String
    var status: String
    var complete: Bool
    var summary: String
    var accounts: [Coverage]
    var new_count: Int
    var alerts: [MailItem]
    var recent_alerts: [MailItem]?
    var notification_id: String?
}

@MainActor final class Store: ObservableObject {
    @Published var settings = Settings()
    @Published var accountText = ""
    var onThemeChange: ((String) -> Void)?
    private var scheduledTimer: Timer?
    private var runnerProcess: Process?
    private var lastSaveSucceeded = true
    var isBusy: Bool { running || collecting || runnerProcess?.isRunning == true }
    @Published var report: Report?
    @Published var running = false
    @Published var permission = "Not enabled"
    @Published var notice = ""
    private var lastData: Data?
    private var timer: Timer?
    private var notified = Set<String>()
    private var lastFailureDay = ""
    private var collecting = false
    private var pendingConnection = false
    private var lastRequest = ""

    init() {
        if let data = try? Data(contentsOf: root.appendingPathComponent("accounts.json")),
           let accounts = try? JSONDecoder().decode([String].self, from: data) { accountText = accounts.joined(separator: "\n") }
        if let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
           let value = try? JSONDecoder().decode(Settings.self, from: data) { settings = value }
        if let data = try? Data(contentsOf: runtime.appendingPathComponent("notified.json")),
           let value = try? JSONDecoder().decode([String].self, from: data) { notified = Set(value) }
        poll()
        refreshPermission()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        scheduledTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.settings.enabled, self.settings.mail_access else { return }
                self.startRunner(manual: false)
            }
        }
    }
    func save() {
        lastSaveSucceeded = false
        settings.interval_minutes = max(1, min(1440, settings.interval_minutes))
        do {
            let addresses = accountText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard addresses.allSatisfy({ $0.contains("@") && !$0.contains(" ") && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "\\\"")) == nil }) else {
                notice = "Enter valid email addresses, one per line."; return
            }
            try JSONEncoder().encode(Array(Set(addresses)).sorted()).write(to: root.appendingPathComponent("accounts.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("accounts.json").path)
            let data = try JSONEncoder().encode(settings)
            try data.write(to: root.appendingPathComponent("settings.json"), options: .atomic)
            lastSaveSucceeded = true
            notice = "Saved. The schedule uses Hong Kong time."
        } catch { notice = "Could not save: \(error.localizedDescription)" }
    }
    func selectTheme(_ theme: MemoTheme) {
        settings.theme = theme.rawValue
        onThemeChange?(theme.rawValue)
        do {
            // Save appearance immediately, without committing unfinished schedule edits.
            var saved = settings
            if let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
               let current = try? JSONDecoder().decode(Settings.self, from: data) { saved = current }
            saved.theme = theme.rawValue
            try JSONEncoder().encode(saved).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
            notice = "Theme saved: " + theme.title
        } catch { notice = "Could not save theme: " + error.localizedDescription }
    }
    func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { value in
            Task { @MainActor in
                self.permission = value.authorizationStatus == .authorized ? "Enabled" :
                    value.authorizationStatus == .denied ? "Disabled in System Settings" : "Not enabled"
            }
        }
    }
    func enableNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refreshPermission() }
        }
    }
    func testNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { value in
            guard value.authorizationStatus == .authorized else {
                Task { @MainActor in self.notice = "Enable notifications first." }
                return
            }
            let content = UNMutableNotificationContent()
            content.userInfo = ["officeHubPluginID": "local.officehub.mail-memo"]
            content.title = "Mail Memo is ready"
            content.body = "Important incoming mail and reply reminders will appear here."
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "mail-memo-test", content: content, trigger: nil))
        }
    }
    func checkNow() {
        save()
        guard lastSaveSucceeded else { return }
        startRunner(manual: true)
    }
    private func startRunner(manual: Bool) {
        guard !isBusy else { return }
        if manual && MailReader.addresses.isEmpty { notice = "Add email accounts in Preferences before checking Mail."; return }
        running = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("source/runner.py").path] + (manual ? ["--manual"] : [])
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.runnerProcess = nil; self?.running = false }
        }
        do { try process.run(); runnerProcess = process }
        catch { running = false; notice = error.localizedDescription }
    }
    func connectMail() {
        // This is a user-invoked action. macOS presents its own Automation prompt.
        settings.mail_access = true
        pendingConnection = true
        checkNow()
    }
    func collectIfRequested() {
        guard !collecting,
              let data = try? Data(contentsOf: runtime.appendingPathComponent("collect-request.json")),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["request_id"] as? String, id != lastRequest,
              let since = request["since"] as? Double else { return }
        lastRequest = id
        collecting = true
        let allowed = settings.mail_access
        DispatchQueue.global(qos: .utility).async {
            let result = allowed ? MailReader.collect(since: since, requestID: id) : MailReader.failure(id, "Choose Connect Apple Mail to approve native macOS Automation access.")
            if let response = try? JSONSerialization.data(withJSONObject: result) {
                try? response.write(to: runtime.appendingPathComponent("collect-result.json"), options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtime.appendingPathComponent("collect-result.json").path)
            }
            Task { @MainActor in
                self.collecting = false
                if self.pendingConnection {
                    self.pendingConnection = false
                    if result["success"] as? Bool == true {
                        self.settings.enabled = true
                        self.notice = "Apple Mail connected. Automatic checks are enabled."
                        self.save()
                    } else { self.notice = result["detail"] as? String ?? "Mail access needs approval." }
                }
            }
        }
    }
    func poll() {
        collectIfRequested()
        if let data = try? Data(contentsOf: runtime.appendingPathComponent("activity.json")),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let started = value["started_at"] as? Double ?? 0
            running = value["running"] as? Bool == true && Date().timeIntervalSince1970 - started < 520
        }
        guard let data = try? Data(contentsOf: runtime.appendingPathComponent("report.json")), data != lastData,
              let value = try? JSONDecoder().decode(Report.self, from: data) else { return }
        lastData = data
        report = value
        notify(value)
    }
    func notify(_ report: Report) {
        guard let event = report.notification_id, !notified.contains(event) else { return }
        let isError = !report.complete
        let day = String(report.checked_at.prefix(10))
        let shouldSend = isError ? lastFailureDay != day : (!report.alerts.isEmpty || (settings.notify_all && report.new_count > 0))
        guard shouldSend else { return }
        UNUserNotificationCenter.current().getNotificationSettings { value in
            guard value.authorizationStatus == .authorized else { return }
            Task { @MainActor in
                let content = UNMutableNotificationContent()
                content.userInfo = ["officeHubPluginID": "local.officehub.mail-memo"]
                content.title = isError ? "Mail check needs attention" :
                    report.alerts.isEmpty ? "\(report.new_count) new messages" : "\(report.alerts.count) messages need attention"
                content.body = isError ? "A mail check could not cover every account. Open Mail Memo for details." :
                    self.settings.include_summary ? String(report.summary.prefix(350)) : "Open Mail Memo to review the latest messages."
                content.sound = .default
                do {
                    try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event, content: content, trigger: nil))
                    self.notified.insert(event)
                    if isError { self.lastFailureDay = day }
                    if let data = try? JSONEncoder().encode(Array(self.notified).suffix(500)) {
                        try? data.write(to: runtime.appendingPathComponent("notified.json"), options: .atomic)
                    }
                } catch { self.notice = "Notification delivery failed: \(error.localizedDescription)" }
            }
        }
    }
    func stop() { timer?.invalidate(); scheduledTimer?.invalidate(); timer = nil; scheduledTimer = nil }
    var lastChecked: String {
        guard let text = report?.checked_at,
              let date = ISO8601DateFormatter().date(from: text.replacingOccurrences(of: #"\.\d+(?=[+Z])"#, with: "", options: .regularExpression)) else { return "Waiting for the first check" }
        let format = DateFormatter()
        format.dateStyle = .medium; format.timeStyle = .short
        format.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
        return "Last check: " + format.string(from: date)
    }
}

struct MinutePicker: View {
    let title: String
    @Binding var minutes: Int
    var date: Binding<Date> {
        Binding(get: {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!
            return calendar.startOfDay(for: Date()).addingTimeInterval(Double(minutes * 60))
        }, set: { date in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!
            minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        })
    }
    var body: some View { DatePicker(title, selection: date, displayedComponents: .hourAndMinute).environment(\.timeZone, TimeZone(identifier: "Asia/Hong_Kong")!) }
}
