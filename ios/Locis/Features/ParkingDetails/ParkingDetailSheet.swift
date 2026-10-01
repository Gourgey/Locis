import LocisKit
import SwiftUI

/// The bottom sheet explaining one kerb section for the selected stay.
struct ParkingDetailSheet: View {
    let detail: FeatureDetail
    let selection: StaySelection
    let isDemo: Bool

    private var feature: Feature { detail.feature }
    private var evaluation: ParkingEvaluation { detail.evaluation }
    private var style: ParkingStyle { ParkingStyle.style(for: evaluation.status) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusBlock
                if evaluation.status.isAllowed || evaluation.paymentRequired { paymentBlock }
                restrictionsBlock
                if !otherConditions.isEmpty { section("Other conditions") { bullets(otherConditions) } }
                if !detail.related.isEmpty { relatedBlock }
                if !detail.zones.isEmpty { zonesBlock }
                dataBlock
                directionsButton
                Text(AppConfiguration.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 28)
        }
    }

    // MARK: Blocks

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(feature.name.isEmpty ? Describe.category(feature.cat) : feature.name)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(Describe.category(feature.cat) + (feature.temporary ? " (temporary)" : ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if isDemo {
                Label("Demo data, not a real parking rule", systemImage: "testtube.2")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.specialist)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(evaluation.status.title.uppercased(), systemImage: style.symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(style.color)
                .accessibilityLabel("Status: \(evaluation.status.title)")
            Text("Selected: \(selection.rangeDescription())")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            bullets(evaluation.reasons)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.12), in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private var paymentBlock: some View {
        section("Payment") {
            if evaluation.paymentRequired {
                Text("Paid parking").font(.body.weight(.medium))
                if let cost = evaluation.estimatedCost {
                    if let hourly = cost.hourlyRate {
                        Text("\(Describe.money(hourly, currency: cost.currency))/hour")
                    }
                    Text("Estimated total \(Describe.money(cost.amount, currency: cost.currency))")
                        .font(.body.weight(.semibold))
                    Text("For \(Describe.duration(cost.chargeableSeconds)) of charged time. Check the price on the sign or payment app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(evaluation.costNote ?? "Tariff unavailable. Check local signs or the payment provider.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No payment needed for your stay").font(.body.weight(.medium))
            }
        }
    }

    private var restrictionsBlock: some View {
        section("Restrictions") {
            let schedule = Describe.schedule(feature.cond)
            if schedule.isEmpty {
                Text("No times recorded").foregroundStyle(.secondary)
            } else {
                ForEach(schedule, id: \.self) { Text($0) }
            }
            if let maxStay = evaluation.limits.maxStay ?? Self.limits(of: feature).maxStay {
                Text("Maximum stay: \(Describe.duration(maxStay))")
            }
            if let noReturn = evaluation.limits.noReturn ?? Self.limits(of: feature).noReturn {
                Text("No return: \(Describe.duration(noReturn))")
            }
            if let from = feature.from, from > "2000" {
                Text("In force from \(from)").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var relatedBlock: some View {
        section("Also on this kerb") {
            ForEach(detail.related) { other in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Describe.category(other.cat) + Self.lifecycleSuffix(other))
                        .font(.body.weight(.medium))
                    ForEach(Describe.schedule(other.cond), id: \.self) {
                        Text($0).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !other.desc.isEmpty {
                        Text(other.desc).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var zonesBlock: some View {
        section("Zone") {
            ForEach(detail.zones) { zone in
                VStack(alignment: .leading, spacing: 2) {
                    Text(zone.name.isEmpty ? Describe.category(zone.cat) : zone.name).font(.body.weight(.medium))
                    Text((Describe.schedule(zone.cond)).joined(separator: "; "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Zone hours are context. The rules for this kerb are the ones above.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var dataBlock: some View {
        section("Data") {
            row("Source", "\(feature.auth ?? "Unknown authority") / D-TRO")
            if !feature.tro.isEmpty { row("Order", feature.tro) }
            row("Updated", feature.updated.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Not recorded")
            HStack(alignment: .firstTextBaseline) {
                Text("Confidence").foregroundStyle(.secondary)
                Spacer()
                Label(evaluation.confidence.title, systemImage: evaluation.confidence.symbol)
            }
            if !evaluation.confidenceNotes.isEmpty {
                bullets(evaluation.confidenceNotes).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var directionsButton: some View {
        if let coordinate = feature.geom.representativeCoordinate {
            Button {
                Directions.open(to: coordinate.clLocation, name: feature.name.isEmpty ? "Parking" : feature.name)
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Opens Apple Maps")
        }
    }

    // MARK: Helpers

    private var otherConditions: [String] {
        var lines = Describe.eligibility(feature.cond)
        if let offList = feature.offList, !offList.text.isEmpty { lines.append(offList.text) }
        for unresolved in evaluation.unresolvedConditions where !lines.contains(unresolved) && !evaluation.reasons.contains(unresolved) {
            lines.append(unresolved)
        }
        return lines
    }

    private static func lifecycleSuffix(_ feature: Feature) -> String {
        switch feature.lifecycle {
        case .intended?: " (planned)"
        case .revocation?: " (revocation)"
        default: feature.temporary ? " (temporary)" : ""
        }
    }

    /// Stay limits written in a feature's rules, whether or not they bite for this stay.
    static func limits(of feature: Feature) -> StayLimits {
        var limits = StayLimits()
        for case .time(let validity) in feature.cond.allNodes.map(\.kind) {
            if let value = validity.maxStay { limits.maxStay = min(limits.maxStay ?? value, value) }
            if let value = validity.noReturn { limits.noReturn = max(limits.noReturn ?? value, value) }
            for period in validity.valid ?? [] {
                if let value = period.maxStay { limits.maxStay = min(limits.maxStay ?? value, value) }
                if let value = period.noReturn { limits.noReturn = max(limits.noReturn ?? value, value) }
            }
        }
        return limits
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullets(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { line in
                Text(line).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}
