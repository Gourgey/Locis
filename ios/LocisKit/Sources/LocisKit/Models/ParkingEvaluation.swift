import Foundation

/// Whether the user may park for the whole selected stay.
public enum ParkingStatus: String, Sendable, CaseIterable, Equatable {
    /// Legal for the whole stay, nothing to pay.
    case allowedFree
    /// Legal for the whole stay, payment required for at least part of it.
    case allowedPaid
    /// May be legal, but depends on something the app cannot confirm (a permit,
    /// eligibility, a planned restriction).
    case conditional
    /// Not legal for the whole stay.
    case prohibited
    /// A bay reserved for a kind of user the profile is not (disabled, loading...).
    case specialist
    /// The app cannot tell reliably.
    case unknown

    public var isAllowed: Bool { self == .allowedFree || self == .allowedPaid }

    /// Ordering used to combine parts of a stay: the worst part decides.
    var severity: Int {
        switch self {
        case .allowedFree: 0
        case .allowedPaid: 1
        case .conditional: 2
        case .specialist: 3
        case .unknown: 4
        case .prohibited: 5
        }
    }

    public var title: String {
        switch self {
        case .allowedFree: "Available for your stay"
        case .allowedPaid: "Available for your stay (paid)"
        case .conditional: "Conditions apply"
        case .prohibited: "Not available for your stay"
        case .specialist: "Reserved bay"
        case .unknown: "Cannot be determined"
        }
    }
}

public enum Confidence: String, Sendable, Comparable, Equatable {
    case unknown, low, medium, high

    private var rank: Int {
        switch self {
        case .unknown: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }

    public var title: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .unknown: "Unknown"
        }
    }
}

/// One contiguous part of the stay with a single outcome.
public struct StaySegment: Sendable, Equatable {
    public let interval: DateInterval
    public let status: ParkingStatus
    public let paymentRequired: Bool
    public let note: String
}

/// A stay limit taken from the source data.
public struct StayLimits: Sendable, Equatable {
    public var maxStay: Int?
    public var noReturn: Int?

    public init(maxStay: Int? = nil, noReturn: Int? = nil) {
        self.maxStay = maxStay
        self.noReturn = noReturn
    }

    mutating func tighten(with other: StayLimits) {
        if let value = other.maxStay { maxStay = Swift.min(maxStay ?? value, value) }
        if let value = other.noReturn { noReturn = Swift.max(noReturn ?? value, value) }
    }

    public var isEmpty: Bool { maxStay == nil && noReturn == nil }
}

public struct CostEstimate: Sendable, Equatable {
    public let amount: Decimal
    public let currency: String
    /// A per-hour figure when the tariff has a single simple rate.
    public let hourlyRate: Decimal?
    public let chargeableSeconds: Int
}

/// The engine's answer for one kerb feature and one stay.
public struct ParkingEvaluation: Sendable, Equatable {
    public let featureID: String
    public let status: ParkingStatus
    public let confidence: Confidence
    public let category: Category
    /// One sentence for the map summary.
    public let summary: String
    /// Why the status is what it is, most important first.
    public let reasons: [String]
    /// Why confidence is not high.
    public let confidenceNotes: [String]
    public let paymentRequired: Bool
    public let chargeableSeconds: Int
    public let estimatedCost: CostEstimate?
    /// Why no cost could be calculated, when payment is required.
    public let costNote: String?
    public let limits: StayLimits
    /// Features (this one and overlapping ones) that took part.
    public let applicableRuleIDs: [String]
    /// Conditions in the source that could not be resolved.
    public let unresolvedConditions: [String]
    public let segments: [StaySegment]
    /// True when no recorded rule exists at any point of the stay (for example the
    /// only record is a temporary order that has ended, or not yet begun). Such a
    /// kerb is the same as one with no data, so the map does not draw it.
    public let noRuleInForce: Bool

    /// Free, paid or conditional, for the map filter. Unknown is never "free".
    public var filterBucket: FilterBucket? {
        switch status {
        case .allowedFree: .free
        case .allowedPaid: .paid
        case .conditional: .conditional
        case .prohibited, .specialist, .unknown: nil
        }
    }
}

public enum FilterBucket: String, Sendable, CaseIterable, Identifiable {
    case free, paid, conditional
    public var id: String { rawValue }
}
