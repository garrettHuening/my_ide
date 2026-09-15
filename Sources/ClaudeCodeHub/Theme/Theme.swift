import SwiftUI

// Minimal monochrome palette. No blues or purples — pure blacks, grays,
// off-white text. Single warm-white accent for emphasis. Signal colors
// (red/green/yellow) kept but desaturated.
enum Theme {
    // Backgrounds — layered near-black with subtle elevation
    static let bg1 = Color(hex: 0x0a0a0a)   // app base
    static let bg2 = Color(hex: 0x111111)   // sidebar / panels
    static let bg3 = Color(hex: 0x070707)   // deepest (headers, terminal)
    static let bgS = Color(hex: 0x171717)   // surface (cards, inputs)
    static let bgSh = Color(hex: 0x1d1d1d)  // surface hover
    static let bgT = Color(hex: 0x000000)   // pure black for terminal

    // Accent — soft warm white, used sparingly
    static let accent = Color(hex: 0xf5f5f5)
    static let accentDim = Color(hex: 0xa3a3a3)
    static let accentGlow = Color(white: 1.0).opacity(0.06)

    // Text
    static let text1 = Color(hex: 0xf5f5f5)
    static let text2 = Color(hex: 0xa3a3a3)
    static let textMuted = Color(hex: 0x6b6b6b)

    // Borders
    static let border = Color(hex: 0x1f1f1f)
    static let borderActive = Color(hex: 0x3a3a3a)

    // Signals — desaturated, only used where status semantics matter
    static let green = Color(hex: 0x86c98a)
    static let yellow = Color(hex: 0xd4c280)
    static let red = Color(hex: 0xd47878)
    static let blue = Color(hex: 0x9aa6b8)   // neutral cool gray, replaces "blue" semantic
    static let peach = Color(hex: 0xc9a484)
    static let teal = Color(hex: 0x8db5a8)
    static let pink = Color(hex: 0xb87d97)

    // Layout
    static let sidebarWidth: CGFloat = 272
    static let rightPanelWidth: CGFloat = 380
    static let topbarHeight: CGFloat = 40
    static let planbarHeight: CGFloat = 32

    // Radii
    static let rs: CGFloat = 6
    static let rm: CGFloat = 10
    static let rl: CGFloat = 14

    // Fonts
    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let monoXSmall = Font.system(size: 9, design: .monospaced)
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}
