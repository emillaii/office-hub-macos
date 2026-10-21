import SwiftUI

public enum HubTheme: String, CaseIterable, Identifiable {
    case hackerGreen = "hacker-green"
    case dark = "dark"
    case ocean = "ocean"
    case amber = "amber"
    public var id: String { rawValue }
    public var title: String {
        switch self { case .hackerGreen: return "Hacker Green"; case .dark: return "Dark"; case .ocean: return "Ocean"; case .amber: return "Amber" }
    }
    public var subtitle: String {
        switch self { case .hackerGreen: return "Phosphor / midnight"; case .dark: return "Graphite / silver"; case .ocean: return "Deep sea / cyan"; case .amber: return "Warm CRT / gold" }
    }
    public var palette: HubPalette {
        switch self {
        case .hackerGreen: return HubPalette(background: "080E0B", sidebar: "0C1510", panel: "101D15", inset: "09130D", border: "253D2D", accent: "75F4A1", text: "D6EBDD", muted: "91AB9A", warning: "F3C578")
        case .dark: return HubPalette(background: "101115", sidebar: "16171D", panel: "1B1D25", inset: "12141A", border: "343844", accent: "D2D9F1", text: "E4E6ED", muted: "A0A5B8", warning: "F1BD76")
        case .ocean: return HubPalette(background: "071522", sidebar: "0A1D2D", panel: "0E2638", inset: "081B2B", border: "23465C", accent: "68DDFA", text: "D9EDF5", muted: "95B4C5", warning: "F6C97D")
        case .amber: return HubPalette(background: "151009", sidebar: "1C160E", panel: "261E12", inset: "191209", border: "493820", accent: "FFD080", text: "F0E3CC", muted: "B9A588", warning: "FF9F78")
        }
    }
    public static func command(_ text: String) -> HubTheme? {
        if text == "green" || text == "hacker" { return .hackerGreen }
        return HubTheme(rawValue: text)
    }
}

public struct HubPalette {
    public let background: Color
    public let sidebar: Color
    public let panel: Color
    public let inset: Color
    public let border: Color
    public let accent: Color
    public let text: Color
    public let muted: Color
    public let warning: Color
    public init(background: String, sidebar: String, panel: String, inset: String, border: String, accent: String, text: String, muted: String, warning: String) {
        self.background = Color(hex: background); self.sidebar = Color(hex: sidebar)
        self.panel = Color(hex: panel); self.inset = Color(hex: inset)
        self.border = Color(hex: border); self.accent = Color(hex: accent)
        self.text = Color(hex: text); self.muted = Color(hex: muted); self.warning = Color(hex: warning)
    }
}
extension Color {
    public init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

public struct HubButtonStyle: ButtonStyle {
    let palette: HubPalette
    var primary = false
    public init(palette: HubPalette, primary: Bool = false) { self.palette = palette; self.primary = primary }
    @Environment(\.isEnabled) private var enabled
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(primary ? palette.background : palette.text)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(primary ? palette.accent.opacity(configuration.isPressed ? 0.7 : 1) : palette.panel.opacity(configuration.isPressed ? 0.5 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(primary ? palette.accent : palette.border, lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
    }
}
