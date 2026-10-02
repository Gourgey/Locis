import LocisKit
import SwiftUI

/// A compact legend that expands to explain each colour.
struct LegendButton: View {
    @Binding var isExpanded: Bool
    var coverage: ParkingMapModel.Coverage = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isExpanded {
                ForEach(ParkingStyle.legendOrder, id: \.self) { status in
                    let style = ParkingStyle.style(for: status)
                    HStack(spacing: 10) {
                        LegendSwatch(status: status)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(style.label).font(.footnote.weight(.semibold))
                            Text(style.explanation).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Divider()
                Text("Dashed lines: lower confidence.\n\(coverage.unmarkedKerbMessage)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 5) {
                    ForEach(ParkingStyle.legendOrder, id: \.self) { status in
                        Capsule()
                            .fill(ParkingStyle.style(for: status).color)
                            .frame(width: 14, height: 5)
                    }
                    Text("Key").font(.footnote.weight(.semibold))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: isExpanded ? 270 : nil, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .contentShape(.rect)
        .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
        .accessibilityElement(children: isExpanded ? .contain : .ignore)
        .accessibilityLabel("Map key")
        .accessibilityHint(isExpanded ? "Double tap to collapse" : "Double tap to show what the colours mean")
        .accessibilityAddTraits(.isButton)
    }
}

/// A short sample of the line used on the map for a status.
struct LegendSwatch: View {
    let status: ParkingStatus

    var body: some View {
        let style = ParkingStyle.style(for: status)
        Path { path in
            path.move(to: CGPoint(x: 2, y: 8))
            path.addLine(to: CGPoint(x: 30, y: 8))
        }
        .stroke(style.color, style: StrokeStyle(lineWidth: style.lineWidth, lineCap: .round, dash: style.dash))
        .frame(width: 32, height: 16)
        .accessibilityHidden(true)
    }
}
