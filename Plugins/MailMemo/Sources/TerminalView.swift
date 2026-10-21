import OfficeHubPluginKit
import AppKit
import SwiftUI

struct TerminalView: View {
    @ObservedObject var store: Store
    @State private var page = 0
    @State private var command = ""
    @State private var response = "Ready. Type help for commands."
    @State private var showHelp = false
    @FocusState private var commandFocused: Bool

    private var theme: MemoTheme { MemoTheme(rawValue: store.settings.theme) ?? .hackerGreen }
    private var p: TerminalPalette { theme.palette }
    private var attention: [MailItem] { store.report?.recent_alerts ?? store.report?.alerts ?? [] }
    private var checked: Int { store.report?.accounts.filter { $0.status == "checked" }.count ?? 0 }
    private var path: String { ["summary", "attention", "settings"][page] }
    private var title: String { ["Inbox overview", "Attention queue", "Preferences"][page] }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    ForEach(0..<3) { index in
                        Button(["Summary", "Attention", "Preferences"][index]) { page = index }
                            .buttonStyle(ConsoleButtonStyle(palette: p, primary: page == index))
                    }
                    Spacer()
                    Button("Open Apple Mail") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app")) }
                        .buttonStyle(ConsoleButtonStyle(palette: p))
                }.padding(.horizontal, 26).padding(.top, 18)
                toolbar.padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 20)
                Rectangle().fill(p.border).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        pageHeading
                        if page == 0 { overview }
                        else if page == 1 { attentionPage }
                        else { preferences }
                    }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                }
                Rectangle().fill(p.border).frame(height: 1)
                commandBar
            }
        }
        .frame(minWidth: 760, minHeight: 640)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(p.text).background(p.background)
        .tint(p.accent).preferredColorScheme(.dark)
        .onAppear { styleWindow() }
        .onChange(of: store.settings.theme) { styleWindow() }
        .sheet(isPresented: $showHelp) { helpPanel }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Text(">_").font(.system(size: 27, weight: .bold, design: .monospaced)).foregroundStyle(p.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MAIL MEMO").font(.system(size: 14, weight: .bold, design: .monospaced)).tracking(1.3)
                    Text("INBOX CONSOLE").font(.system(size: 9, design: .monospaced)).tracking(1.4).foregroundStyle(p.muted)
                }
            }.padding(.top, 24).padding(.bottom, 28)
            Text("WORKSPACE").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(p.muted).padding(.bottom, 10)
            nav("Summary", symbol: "text.alignleft", index: 0, key: "1")
            nav("Attention", symbol: "flag", index: 1, key: "2")
            nav("Preferences", symbol: "slider.horizontal.3", index: 2, key: "3")
            Rectangle().fill(p.border).frame(height: 1).padding(.vertical, 22)
            HStack { Text("CONNECTED INBOXES").tracking(1); Spacer(); Text("\(checked)/\(MailReader.addresses.count)").foregroundStyle(p.accent) }
                .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(p.muted).padding(.bottom, 13)
            ForEach(store.report?.accounts ?? []) { account in
                HStack(alignment: .top, spacing: 8) {
                    Text(account.status == "checked" ? "+" : "!").foregroundStyle(account.status == "checked" ? p.accent : p.warning).fontWeight(.bold)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.account.components(separatedBy: "@").first ?? account.account)
                            .font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
                        Text("@" + (account.account.components(separatedBy: "@").last ?? ""))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 7).help(account.account + " · " + account.status)
            }
            Spacer(minLength: 18)
            Rectangle().fill(p.border).frame(height: 1).padding(.bottom, 16)
            HStack(spacing: 7) { Circle().fill(p.accent).frame(width: 5, height: 5); Text("GPT-6 LUNA").tracking(1) }.font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(p.accent)
            Text("every \(store.settings.interval_minutes)m · HKT").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted).padding(.top, 8)
            Text("\(clock(store.settings.start_minutes)) — \(clock(store.settings.end_minutes)) daily").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted).padding(.top, 4)
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app")) } label: {
                HStack { Text("Open Apple Mail"); Spacer(); Image(systemName: "arrow.up.right") }
            }.buttonStyle(ConsoleButtonStyle(palette: p)).keyboardShortcut("o", modifiers: .command).padding(.top, 18)
        }.padding(.horizontal, 20).padding(.bottom, 20).frame(width: 230).frame(maxHeight: .infinity).background(p.sidebar)
    }

    private func nav(_ text: String, symbol: String, index: Int, key: KeyEquivalent) -> some View {
        Button { page = index } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 15)
                Text(text).fontWeight(page == index ? .semibold : .regular)
                Spacer()
                if index == 1 && !attention.isEmpty { Text(String(attention.count)).font(.system(size: 10, design: .monospaced)) }
                else { Text("⌘" + String(index + 1)).font(.system(size: 9, design: .monospaced)).opacity(0.65) }
            }.padding(.horizontal, 11).padding(.vertical, 11)
                .foregroundStyle(page == index ? p.accent : p.muted)
                .background(page == index ? p.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .leading) { if page == index { Rectangle().fill(p.accent).frame(width: 2).padding(.vertical, 7) } }
        }.buttonStyle(.plain).keyboardShortcut(key, modifiers: .command).padding(.bottom, 3)
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) { Text("~").foregroundStyle(p.accent); Text("/ mail-memo / " + path).foregroundStyle(p.muted) }.font(.system(size: 11, design: .monospaced))
            Spacer(minLength: 12)
            Menu {
                ForEach(MemoTheme.allCases) { item in
                    Button { store.selectTheme(item) } label: {
                        if item == theme { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                    }
                }
            } label: {
                HStack(spacing: 7) { Circle().fill(p.accent).frame(width: 6, height: 6); Text(theme.title); Image(systemName: "chevron.down").font(.system(size: 8)) }
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(p.text)
                    .padding(.horizontal, 10).padding(.vertical, 7).background(p.panel, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Choose theme")
        }
    }

    private var pageHeading: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("●").foregroundStyle(store.settings.enabled || store.running ? p.accent : p.warning)
                Text(store.running ? "CHECK IN PROGRESS" : store.settings.enabled ? "SCHEDULE ON" : "SCHEDULE PAUSED")
                    .tracking(1.4).foregroundStyle(p.muted)
                Spacer()
                Text("HKT / UTC+08").foregroundStyle(p.muted)
            }.font(.system(size: 9, weight: .semibold, design: .monospaced))
            HStack(alignment: .center) {
                Text(title).font(.system(size: 27, weight: .semibold, design: .monospaced)).tracking(-1)
                Spacer()
                Button(action: store.checkNow) {
                    HStack(spacing: 8) {
                        if store.running { ProgressView().controlSize(.mini) } else { Text(">") }
                        Text(store.running ? "Checking…" : "Check now")
                    }
                }.buttonStyle(ConsoleButtonStyle(palette: p, primary: true)).disabled(store.running).keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                metric("NEW MAIL", value: store.report.map { String($0.new_count) } ?? "—", foot: "last check")
                metric("ATTENTION", value: String(attention.count), foot: "saved memos")
                metric("INBOXES", value: "\(checked)/\(MailReader.addresses.count)", foot: "checked")
            }
            block("LATEST SUMMARY", tag: store.report == nil ? "WAITING" : store.report?.complete == true ? "COMPLETE" : "INCOMPLETE") {
                VStack(alignment: .leading, spacing: 17) {
                    Text(store.report?.summary ?? "Waiting for the first inbox check. Run a check to create your summary.")
                        .font(.system(size: 14, design: .monospaced)).lineSpacing(6).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) { Text("↳").foregroundStyle(p.accent); Text(store.lastChecked).foregroundStyle(p.muted) }.font(.system(size: 10, design: .monospaced))
                }
            }
            HStack { sectionLabel("ATTENTION QUEUE"); Spacer(); if !attention.isEmpty { Button("View all →") { page = 1 }.buttonStyle(.plain).foregroundStyle(p.accent) } }
            if attention.isEmpty { emptyQueue } else { ForEach(Array(attention.prefix(3))) { item in memoRow(item) } }
        }
    }

    private func metric(_ label: String, value: String, foot: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(label).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(p.muted)
            Text(value).font(.system(size: 29, weight: .medium, design: .monospaced)).foregroundStyle(p.accent)
            Text(foot).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(p.panel, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
    }

    private var attentionPage: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Important mail and requests worth opening or replying to.").foregroundStyle(p.muted).lineSpacing(4)
            if attention.isEmpty { emptyQueue } else { ForEach(attention) { item in memoRow(item) } }
        }
    }
    private var emptyQueue: some View {
        HStack(alignment: .top, spacing: 13) {
            Text(store.report?.complete == true ? "[ok]" : "[--]").foregroundStyle(p.accent).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 7) {
                Text(store.report?.complete == true ? "Nothing needs your attention." : "Waiting for a complete check.").fontWeight(.medium)
                Text(store.report?.complete == true ? "Important messages and reply requests will appear here." : "Any account or connection issue will appear in the summary.").foregroundStyle(p.muted).font(.system(size: 11, design: .monospaced)).lineSpacing(3)
            }
            Spacer(minLength: 0)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(p.inset, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
    private func memoRow(_ item: MailItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Text(item.needs_reply ? "[reply]" : "[memo]").foregroundStyle(item.needs_reply ? p.warning : p.accent).font(.system(size: 10, weight: .semibold, design: .monospaced)).padding(.top, 2)
                Text(item.subject).font(.system(size: 14, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            Text(item.sender + " → " + item.account).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted).textSelection(.enabled)
            Text(item.summary).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(p.panel, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 20) {
            block("MAIL ACCOUNTS", tag: "ONE ADDRESS PER LINE") {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $store.accountText).font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden).frame(height: 80).padding(8).background(p.inset)
                        .accessibilityLabel("Apple Mail email addresses")
                    Text("Use accounts already configured in Apple Mail. Save, then choose Connect Apple Mail below.")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                }
            }
            block("01 / APPEARANCE", tag: "SAVES INSTANTLY") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(MemoTheme.allCases) { item in themeTile(item) }
                }
            }
            block("02 / DAILY SCHEDULE", tag: "HONG KONG TIME") {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle("Check incoming mail automatically", isOn: $store.settings.enabled).toggleStyle(.checkbox)
                    HStack(spacing: 12) {
                        Text("Check every").foregroundStyle(p.muted)
                        TextField("Minutes", value: $store.settings.interval_minutes, format: .number).labelsHidden().textFieldStyle(.plain).frame(width: 62).padding(10).background(p.inset, in: RoundedRectangle(cornerRadius: 3)).overlay(RoundedRectangle(cornerRadius: 3).stroke(p.border)).accessibilityLabel("Check interval in minutes")
                        Text("minutes").foregroundStyle(p.muted)
                        Spacer()
                    }
                    HStack(spacing: 28) {
                        MinutePicker(title: "From", minutes: $store.settings.start_minutes)
                        MinutePicker(title: "Until", minutes: $store.settings.end_minutes)
                    }
                    Text("Daily. Overnight windows are supported.").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
                }
            }
            block("03 / NOTIFICATIONS", tag: store.permission == "Enabled" ? "ENABLED" : "NEEDS PERMISSION") {
                VStack(alignment: .leading, spacing: 17) {
                    Toggle("Include the summary", isOn: $store.settings.include_summary).toggleStyle(.checkbox)
                    Toggle("Also notify for other new mail", isOn: $store.settings.notify_all).toggleStyle(.checkbox)
                    Text("Important mail and reply requests notify by default. Promotions stay quiet.").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted).lineSpacing(4)
                    HStack(spacing: 9) {
                        Button("Enable notifications", action: store.enableNotifications).buttonStyle(ConsoleButtonStyle(palette: p))
                        Button("Send test", action: store.testNotification).buttonStyle(ConsoleButtonStyle(palette: p))
                    }
                }
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 13) {
                    Text("Mail Memo reads new headers and short previews using macOS Automation, then sends the previews to Luna through your Codex sign-in. It does not send, delete or change message flags.").foregroundStyle(p.muted).lineSpacing(5)
                    Button(store.settings.mail_access ? "Reconnect Apple Mail" : "Connect Apple Mail", action: store.connectMail).buttonStyle(ConsoleButtonStyle(palette: p)).disabled(store.running)
                }.padding(.top, 14)
            } label: { sectionLabel("APPLE MAIL CONNECTION") }.padding(18).background(p.panel, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
            HStack(spacing: 15) {
                Button("Save changes", action: store.save).buttonStyle(ConsoleButtonStyle(palette: p, primary: true)).keyboardShortcut("s", modifiers: .command)
                Text(store.notice).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted).lineLimit(2)
            }
            Text("Keep this Mac awake and Mail Memo running. Summaries reflect mail downloaded by Apple Mail.").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted).lineSpacing(4)
        }
    }
    private func themeTile(_ item: MemoTheme) -> some View {
        Button { store.selectTheme(item) } label: {
            HStack(spacing: 11) {
                Text(">_").font(.system(size: 19, weight: .bold, design: .monospaced)).foregroundStyle(item.palette.accent).padding(9).background(item.palette.background, in: RoundedRectangle(cornerRadius: 3))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(p.text)
                    Text(item.subtitle).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.muted)
                }
                Spacer(minLength: 0)
                if item == theme { Text("*").foregroundStyle(p.accent).fontWeight(.bold) }
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(p.inset, in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(item == theme ? p.accent : p.border))
        }.buttonStyle(.plain).accessibilityLabel(item.title + " theme").accessibilityValue(item == theme ? "Selected" : "Not selected")
    }

    private func sectionLabel(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(p.muted) }
    private func block<Content: View>(_ title: String, tag: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { sectionLabel(title); Spacer(); Text(tag).font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(tag == "INCOMPLETE" ? p.warning : p.accent).tracking(0.5) }.padding(.horizontal, 18).padding(.vertical, 13)
            Rectangle().fill(p.border).frame(height: 1)
            content().padding(18)
        }.frame(maxWidth: .infinity, alignment: .leading).background(p.panel, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
    }

    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 11) {
                Text("❯").foregroundStyle(p.accent).fontWeight(.bold)
                TextField("Type help, check, theme ocean…", text: $command).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).focused($commandFocused).onSubmit(runCommand).accessibilityLabel("Terminal command")
                Button { commandFocused = true } label: { Text("⌘K").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted) }.buttonStyle(.plain).keyboardShortcut("k", modifiers: .command).help("Focus command line")
            }
            Text(response).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.muted).lineLimit(2)
        }.padding(.horizontal, 26).padding(.vertical, 17).background(p.inset)
    }
    private func runCommand() {
        let parts = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: " ").map(String.init)
        guard let action = parts.first else { return }
        command = ""
        switch action {
        case "help": showHelp = true; response = "Help opened. Escape to close."
        case "check":
            if store.running { response = "A check is already running." }
            else { store.checkNow(); response = "Checking your configured inboxes…" }
        case "summary": page = 0; response = "Showing the latest inbox summary."
        case "attention": page = 1; response = "Showing saved attention memos."
        case "settings", "preferences": page = 2; response = "Preferences opened."
        case "theme":
            if parts.count == 2, let value = MemoTheme.command(parts[1]) { store.selectTheme(value); response = "Theme → \(value.title). Saved." }
            else { response = "Themes: green · dark · ocean · amber. Try: theme ocean" }
        case "pause": store.settings.enabled = false; store.save(); response = "Automatic checks paused."
        case "resume": store.settings.enabled = true; store.save(); response = "Automatic checks enabled for your saved hours."
        default: response = "Unknown command: \(action). Type help to see available commands."
        }
    }
    private var helpPanel: some View {
        VStack(alignment: .leading, spacing: 19) {
            Text("> command reference").font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundStyle(p.accent)
            ForEach([("check", "Check incoming mail now · ⌘R"), ("summary / attention / settings", "Switch workspace · ⌘1 / ⌘2 / ⌘3"), ("theme green | dark | ocean | amber", "Change and save the appearance"), ("pause / resume", "Control automatic checking"), ("⌘K", "Focus the command line")], id: \.0) { row in
                VStack(alignment: .leading, spacing: 6) { Text(row.0).foregroundStyle(p.text); Text(row.1).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted) }
            }
            HStack { Spacer(); Button("Close", role: .cancel) { showHelp = false }.buttonStyle(ConsoleButtonStyle(palette: p)) }
        }.font(.system(size: 12, design: .monospaced)).padding(30).frame(width: 530).background(p.background).preferredColorScheme(.dark)
    }
    private func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    private func styleWindow() {
        for window in NSApp.windows where window.title == "Mail Memo" {
            window.backgroundColor = NSColor(p.background)
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
