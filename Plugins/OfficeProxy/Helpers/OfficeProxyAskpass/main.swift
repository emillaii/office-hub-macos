import AppKit
import Foundation
if CommandLine.arguments.contains("--askpass") {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let alert = NSAlert(); alert.messageText = "Connect to your office PC"
    alert.informativeText = CommandLine.arguments.dropFirst(2).joined(separator: " ") + "\nYour password is used for this connection only."
    let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
    password.placeholderString = "SSH password"; alert.accessoryView = password
    alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = password
    app.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
        FileHandle.standardOutput.write(Data((password.stringValue + "\n").utf8)); exit(0)
    }
    exit(1)
}
