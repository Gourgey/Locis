import Foundation

public enum VehicleType: String, Sendable, Codable, CaseIterable, Identifiable {
    case car
    case motorcycle
    case van
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .car: "Car"
        case .motorcycle: "Motorcycle"
        case .van: "Van / light commercial"
        case .other: "Other"
        }
    }
}

/// What the app knows about the user's eligibility. Deliberately small for V1:
/// the app never assumes a resident or business permit.
public struct VehicleProfile: Sendable, Codable, Equatable {
    public var vehicleType: VehicleType
    public var blueBadge: Bool

    public init(vehicleType: VehicleType = .car, blueBadge: Bool = false) {
        self.vehicleType = vehicleType
        self.blueBadge = blueBadge
    }

    public static let standard = VehicleProfile()
}

/// The period the user intends to be parked: arrival up to departure.
public struct Stay: Sendable, Equatable {
    public let arrival: Date
    public let departure: Date

    /// The longest stay the engine evaluates.
    public static let maximumDuration: TimeInterval = 31 * 24 * 3600

    public enum ValidationError: Error, Equatable {
        case departureNotAfterArrival
        case tooLong
    }

    public init(arrival: Date, departure: Date) throws {
        guard departure > arrival else { throw ValidationError.departureNotAfterArrival }
        guard departure.timeIntervalSince(arrival) <= Stay.maximumDuration else { throw ValidationError.tooLong }
        self.arrival = arrival
        self.departure = departure
    }

    public var duration: TimeInterval { departure.timeIntervalSince(arrival) }
}
