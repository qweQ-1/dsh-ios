import SwiftUI

enum DshTheme {
    static let background = Color(hex: 0x0B0D10)
    static let surface = Color(hex: 0x14171C)
    static let surfaceRaised = Color(hex: 0x1B1F26)
    static let border = Color(hex: 0x262B33)
    static let text = Color(hex: 0xE8EAED)
    static let textSecondary = Color(hex: 0x9AA3AF)
    static let textTertiary = Color(hex: 0x6B7280)
    static let accent = Color(hex: 0x4D6BFE)
    static let accentSoft = Color(hex: 0x4D6BFE).opacity(0.16)
    static let green = Color(hex: 0x3FB950)
    static let orange = Color(hex: 0xD29922)
    static let red = Color(hex: 0xF85149)
    static let codeBackground = Color(hex: 0x101319)

    static let mono = Font.system(size: 13, design: .monospaced)
}

extension Color {
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
}

extension View {
    func dshCard() -> some View {
        self
            .padding(12)
            .background(DshTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DshTheme.border, lineWidth: 1)
            )
    }
}

struct HairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(DshTheme.border)
            .frame(height: 1)
    }
}
