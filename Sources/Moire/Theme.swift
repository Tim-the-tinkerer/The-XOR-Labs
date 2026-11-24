import AppKit
import SwiftUI

enum Theme {
    static let bg = Color(red: 0.04, green: 0.03, blue: 0.06)
    static let panel = Color(red: 0.09, green: 0.06, blue: 0.12)
    static let elevated = Color(red: 0.14, green: 0.09, blue: 0.18)
    static let field = Color(red: 0.06, green: 0.04, blue: 0.09)
    static let border = Color(red: 0.42, green: 0.18, blue: 0.48)
    static let magenta = Color(red: 0.95, green: 0.28, blue: 0.72)
    static let magentaDim = Color(red: 0.72, green: 0.18, blue: 0.52)
    static let cyan = Color(red: 0.28, green: 0.92, blue: 0.95)
    static let cyanDim = Color(red: 0.18, green: 0.62, blue: 0.70)
    static let text = Color(red: 0.94, green: 0.90, blue: 0.96)
    static let muted = Color(red: 0.62, green: 0.52, blue: 0.68)
    static let ink = Color(red: 0.06, green: 0.03, blue: 0.08)

    static let windowNS = NSColor(calibratedRed: 0.04, green: 0.03, blue: 0.06, alpha: 1)
    static let stageNS = NSColor(calibratedRed: 0.02, green: 0.015, blue: 0.03, alpha: 1)
}

struct MoireButtonStyle: ButtonStyle {
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
        case .primary: return Theme.cyan
        case .secondary: return Theme.elevated
        case .ghost: return Color.clear
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary: return Theme.cyan
        case .secondary: return Theme.border
        case .ghost: return Theme.border.opacity(0.6)
        }
    }
}
