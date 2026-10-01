import LocisKit
import SwiftUI

/// The app's map language: one colour, label and symbol per parking status.
///
/// Colour is never the only cue. Statuses also differ in line weight and dash
/// pattern on the map, and every status is written out in the details sheet.
struct ParkingStyle: Equatable {
    let color: Color
    /// Short label for the legend and filter.
    let label: String
    /// Longer explanation for the legend.
    let explanation: String
    let symbol: String
    let lineWidth: CGFloat
    /// Dash pattern for the map line; empty for a solid line.
    let dash: [CGFloat]

    static func style(for status: ParkingStatus) -> ParkingStyle {
        switch status {
        case .allowedFree:
            ParkingStyle(
                color: Palette.free, label: "Free", explanation: "Legal for your whole stay, nothing to pay",
                symbol: "checkmark.circle.fill", lineWidth: 6, dash: [])
        case .allowedPaid:
            ParkingStyle(
                color: Palette.paid, label: "Paid", explanation: "Legal for your whole stay, payment needed",
                symbol: "sterlingsign.circle.fill", lineWidth: 6, dash: [])
        case .conditional:
            ParkingStyle(
                color: Palette.conditional, label: "Conditional", explanation: "Depends on a permit or other condition",
                symbol: "exclamationmark.circle.fill", lineWidth: 5, dash: [])
        case .prohibited:
            ParkingStyle(
                color: Palette.prohibited, label: "Not allowed", explanation: "Not legal for your whole stay",
                symbol: "xmark.circle.fill", lineWidth: 3.5, dash: [])
        case .specialist:
            ParkingStyle(
                color: Palette.specialist, label: "Reserved", explanation: "Disabled, loading, motorcycle or taxi bay",
                symbol: "star.circle.fill", lineWidth: 5, dash: [])
        case .unknown:
            ParkingStyle(
                color: Palette.unknown, label: "Unknown", explanation: "Not enough reliable data to say",
                symbol: "questionmark.circle.fill", lineWidth: 4, dash: [0.5, 8])
        }
    }

    /// Stroke for a map line. Results the app is less sure of are long-dashed.
    static func stroke(for status: ParkingStatus, confidence: Confidence, selected: Bool = false) -> StrokeStyle {
        let base = style(for: status)
        var dash = base.dash
        if dash.isEmpty && status.isAllowed && confidence < .high { dash = [9, 10] }
        // Round caps turn the short dashes of "unknown" into dots.
        return StrokeStyle(lineWidth: base.lineWidth + (selected ? 3 : 0), lineCap: .round, lineJoin: .round, dash: dash)
    }

    /// Order statuses appear in the legend.
    static let legendOrder: [ParkingStatus] = [.allowedFree, .allowedPaid, .conditional, .specialist, .prohibited, .unknown]
}

/// Colours chosen to stay apart in both appearances and for common colour-vision
/// deficiencies (free and prohibited also differ strongly in lightness and weight).
enum Palette {
    static let free = Color(light: 0x12A150, dark: 0x30D158)
    static let paid = Color(light: 0x0086A8, dark: 0x40C8E0)
    static let conditional = Color(light: 0xD98200, dark: 0xFFB340)
    static let prohibited = Color(light: 0xC81E2B, dark: 0xFF6961)
    static let specialist = Color(light: 0x7B3FC4, dark: 0xBF8CFF)
    static let unknown = Color(light: 0x6E7480, dark: 0xA0A6B2)
    static let zone = Color(light: 0x4A5568, dark: 0xCBD5E0)
    /// Dark enough for white text in both appearances.
    static let demoBanner = Color(light: 0x6B2FB5, dark: 0x6B2FB5)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(
            uiColor: UIColor { traits in
                let hex = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            })
    }
}

extension Confidence {
    var symbol: String {
        switch self {
        case .high: "checkmark.seal.fill"
        case .medium: "seal"
        case .low: "exclamationmark.triangle"
        case .unknown: "questionmark.diamond"
        }
    }
}
