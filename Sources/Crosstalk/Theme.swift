import AppKit
import SwiftUI

enum Theme {
    static let bg = Color(red: 0.05, green: 0.055, blue: 0.062)
    static let bgElev = Color(red: 0.078, green: 0.086, blue: 0.096)
    static let card = Color(red: 0.105, green: 0.118, blue: 0.130)
    static let line = Color(red: 0.24, green: 0.30, blue: 0.34)
    static let text = Color(red: 0.93, green: 0.94, blue: 0.92)
    static let muted = Color(red: 0.58, green: 0.66, blue: 0.68)
    static let copper = Color(red: 0.93, green: 0.55, blue: 0.32)
    static let steel = Color(red: 0.55, green: 0.78, blue: 0.80)
    static let lilac = Color(red: 0.74, green: 0.64, blue: 0.88)
    static let erase = Color(red: 0.55, green: 0.78, blue: 0.64)
    static let danger = Color(red: 0.88, green: 0.42, blue: 0.34)
    static let chip = Color(red: 0.14, green: 0.17, blue: 0.19)

    static var windowNS: NSColor {
        NSColor(srgbRed: 0.05, green: 0.055, blue: 0.062, alpha: 1)
    }
}
