import Foundation
import AppKit
import Network

enum MailReader {
    static var addresses: [String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("accounts.json")),
              let values = try? JSONDecoder().decode([String].self, from: data),
              values.allSatisfy({ $0.contains("@") && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n\\\"")) == nil }) else { return [] }
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // Runs only after the user chooses Connect Apple Mail. macOS enforces the
    // per-app Automation permission; this code does not alter that permission.
    static func collect(since: Double, requestID: String) -> [String: Any] {
        guard !addresses.isEmpty else { return failure(requestID, "Add your Apple Mail addresses to accounts.json and restart Mail Memo.") }
        let monitor = NWPathMonitor()
        let ready = DispatchSemaphore(value: 0)
        var online = false
        monitor.pathUpdateHandler = { path in online = path.status == .satisfied; ready.signal() }
        monitor.start(queue: DispatchQueue(label: "MailMemo.Network"))
        _ = ready.wait(timeout: .now() + 3)
        monitor.cancel()
        guard online else { return failure(requestID, "The Mac is offline. No successful checkpoint was advanced.") }
        let age = max(0, Int(Date().timeIntervalSince1970 - since))
        let targets = addresses.map { "\"\($0)\"" }.joined(separator: ", ")
        let sourceURL = root.appendingPathComponent("source/mail-read.applescript")
        guard let template = try? String(contentsOf: sourceURL, encoding: .utf8) else { return failure(requestID, "The Mail reader source is missing.") }
        let script = template.replacingOccurrences(of: "{{AGE}}", with: String(age)).replacingOccurrences(of: "{{TARGETS}}", with: targets)
        var error: NSDictionary?
        guard let compiled = NSAppleScript(source: script),
              let result = compiled.executeAndReturnError(&error) as NSAppleEventDescriptor?, error == nil else {
            let message = (error?[NSAppleScript.errorMessage] as? String) ?? "Apple Mail access was not approved."
            let code = error?[NSAppleScript.errorNumber] as? Int ?? 0
            return failure(requestID, "\(message) (error \(code))")
        }
        guard result.numberOfItems >= 3, let rows = result.atIndex(1), let coverageRows = result.atIndex(2) else { return failure(requestID, "Apple Mail returned an invalid response.") }
        var messages = [[String: Any]]()
        if rows.numberOfItems > 0 {
            for i in 1...rows.numberOfItems {
                guard let row = rows.atIndex(i), row.numberOfItems == 6 else { continue }
                let received = Date().addingTimeInterval(-Double(row.atIndex(4)?.int32Value ?? 0))
                messages.append(["account": row.atIndex(1)?.stringValue ?? "", "sender": row.atIndex(2)?.stringValue ?? "", "subject": row.atIndex(3)?.stringValue ?? "", "received_at": ISO8601DateFormatter().string(from: received), "message_id": row.atIndex(5)?.stringValue ?? "", "snippet": redact(row.atIndex(6)?.stringValue ?? "")])
            }
        }
        var coverage = [[String: Any]]()
        if coverageRows.numberOfItems > 0 {
            for i in 1...coverageRows.numberOfItems {
                guard let row = coverageRows.atIndex(i) else { continue }
                coverage.append(["account": row.atIndex(1)?.stringValue ?? "", "status": row.atIndex(2)?.stringValue ?? "blocked", "detail": row.atIndex(3)?.stringValue ?? ""])
            }
        }
        let syncing = (result.atIndex(3)?.int32Value ?? -1) != 0
        let note = result.atIndex(4)?.stringValue ?? ""
        let anyChecked = coverage.contains { $0["status"] as? String == "checked" }
        return ["request_id": requestID, "success": anyChecked, "accounts": coverage, "messages": messages,
                "syncing": syncing, "detail": !anyChecked ? coverage.compactMap { $0["detail"] as? String }.joined(separator: " · ") : (syncing ? "Apple Mail is still syncing. This is a partial view of downloaded mail. " + note : "Checked messages currently downloaded by Apple Mail. " + note)]
    }
    static func redact(_ text: String) -> String {
        // Keep one-time codes and long payment identifiers out of the model input.
        text.replacingOccurrences(of: #"\b\d{4,8}\b"#, with: "[number]", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:\d[ -]?){12,19}\b"#, with: "[identifier]", options: .regularExpression)
    }
    static func failure(_ id: String, _ detail: String) -> [String: Any] {
        ["request_id": id, "success": false, "detail": detail, "messages": [],
         "accounts": addresses.map { ["account": $0, "status": "blocked", "detail": detail] }]
    }
}
