import Foundation

/// Estimates a parking charge from a D-TRO rate table.
///
/// The D-TRO rate model is flexible and publishers use it inconsistently, so only
/// structures with one unambiguous reading are priced. Anything else returns nil
/// and the app says the tariff is unavailable. A price is never guessed.
enum CostCalculator {
    static let unavailable = "Tariff unavailable. Check local signs or the payment provider."

    static func estimate(
        rate: RateTable, chargeableSeconds: Int, sessionStart: Date, sessionEnd: Date,
        calendar: LondonCalendar = .shared
    ) -> CostEstimate? {
        guard chargeableSeconds > 0 else { return nil }
        let current = rate.collections.filter { collection in
            if let from = collection.from, sessionStart < from { return false }
            if let to = collection.to, sessionStart >= to { return false }
            return true
        }
        guard current.count == 1, let collection = current.first else { return nil }
        guard collection.currency == "GBP" else { return nil }
        if let maxTime = collection.maxTime, chargeableSeconds > maxTime { return nil }
        let billable = max(chargeableSeconds, collection.minTime ?? 0)
        let lines = collection.lines.sorted { ($0.seq ?? 0) < ($1.seq ?? 0) }
        guard !lines.isEmpty else { return nil }

        var amount: Decimal
        var hourly: Decimal?
        if lines.allSatisfy({ $0.type == "flatRateTier" }) {
            // Each tier covers a band of session lengths; exactly one must match.
            let matching = lines.filter { line in
                guard let start = line.start, let end = line.end, line.value != nil else { return false }
                return billable >= start && billable <= end
            }
            guard matching.count == 1, let value = matching[0].value else { return nil }
            amount = clamp(value, matching[0])
        } else if lines.count == 1, let line = lines.first, let value = line.value {
            switch line.type {
            case "incrementingRate", "perUnit":
                guard let increment = line.increment, increment > 0 else { return nil }
                let units = (billable + increment - 1) / increment
                amount = clamp(value * Decimal(units), line)
                hourly = value * Decimal(3600) / Decimal(increment)
            case "flatRate":
                // One charge per day: only certain when the stay is within one day.
                guard calendar.localDay(of: sessionStart) == calendar.localDay(of: sessionEnd.addingTimeInterval(-1))
                else { return nil }
                amount = clamp(value, line)
            default:
                return nil
            }
        } else {
            return nil
        }

        if let minimum = collection.minValue { amount = max(amount, minimum) }
        if let maximum = collection.maxValue { amount = min(amount, maximum) }
        guard amount >= 0 else { return nil }
        return CostEstimate(
            amount: rounded(amount), currency: "GBP", hourlyRate: hourly.map(rounded),
            chargeableSeconds: chargeableSeconds)
    }

    private static func clamp(_ value: Decimal, _ line: RateLine) -> Decimal {
        var result = value
        if let minimum = line.min { result = max(result, minimum) }
        if let maximum = line.max { result = min(result, maximum) }
        return result
    }

    /// Round to whole pence (also removes binary noise from JSON numbers).
    static func rounded(_ value: Decimal) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 2, .plain)
        return output
    }
}
