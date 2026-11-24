import AppKit
import SwiftUI

enum Theme {
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.125)
    static let elevated = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let field = Color(red: 0.055, green: 0.055, blue: 0.065)
    static let stage = Color(red: 0.09, green: 0.09, blue: 0.105)
    static let line = Color(red: 0.30, green: 0.29, blue: 0.32)
    static let paper = Color(red: 0.95, green: 0.94, blue: 0.91)
    static let amber = Color(red: 0.95, green: 0.64, blue: 0.22)
    static let steel = Color(red: 0.46, green: 0.70, blue: 0.95)
    static let text = Color(red: 0.94, green: 0.93, blue: 0.91)
    static let muted = Color(red: 0.62, green: 0.61, blue: 0.58)
    static let ink = Color(red: 0.09, green: 0.08, blue: 0.07)

    static let windowNS = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
}

struct ParityButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background(background.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(stroke, lineWidth: 1))
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.ink
        case .secondary, .ghost: return Theme.text
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Theme.amber
        case .secondary: return Theme.elevated
        case .ghost: return Color.clear
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary: return Theme.amber
        case .secondary: return Theme.line
        case .ghost: return Theme.line.opacity(0.7)
        }
    }
}
