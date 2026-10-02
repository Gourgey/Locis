import Foundation

/// Something about the user the app cannot confirm.
public enum EligibilityNeed: Hashable, Sendable {
    case permit(type: String, scheme: String?)
    case resident
    case guest
    /// A planned restriction that has not been made yet.
    case plannedRestriction
    /// A bay for electric vehicles.
    case electricVehicle

    public var text: String {
        switch self {
        case .permit(let type, let scheme):
            let name = EligibilityNeed.permitName(type)
            if let scheme, !scheme.isEmpty { return "\(name) required (\(scheme))" }
            return "\(name) required"
        case .resident: return "For local residents"
        case .guest: return "For hotel guests"
        case .plannedRestriction: return "A temporary restriction is planned here"
        case .electricVehicle: return "For electric vehicles only. Check the sign for charging and time limits"
        }
    }

    static func permitName(_ type: String) -> String {
        switch type {
        case "resident", "residentExcludesNonResidentBlueBadge", "residentNotBlueBadgeHolders":
            "Resident permit"
        case "residentPlusBadgeHolders", "residentWithNonResidentBlueBadge":
            "Resident permit or Blue Badge"
        case "business": "Business permit"
        case "doctor": "Doctor permit"
        default: "Permit"
        }
    }
}

/// Whether a regulation's effect applies, at one instant.
///
/// D-TRO defines a condition tree as true for exactly the population and times
/// the regulation affects. Besides yes and no, the answer can depend on the
/// user's eligibility, or be undeterminable.
enum Applicability: Equatable, Sendable {
    case yes
    case no
    /// Applies to some road users at this instant, whoever they are. Only produced
    /// when evaluating "is this in force for anyone?".
    case someUsers
    /// Depends on eligibility the app cannot confirm.
    case eligibility(Set<EligibilityNeed>)
    /// Depends on something the engine cannot interpret.
    case unsupported(Set<String>)

    var negated: Applicability {
        switch self {
        case .yes: .no
        case .no: .yes
        default: self
        }
    }

    static func all(_ items: [Applicability]) -> Applicability {
        if items.isEmpty { return .unsupported(["an empty set of conditions"]) }
        if items.contains(.no) { return .no }
        if let merged = mergedUnsupported(items) { return merged }
        if let merged = mergedEligibility(items) { return merged }
        if items.contains(.someUsers) { return .someUsers }
        return .yes
    }

    static func any(_ items: [Applicability]) -> Applicability {
        if items.isEmpty { return .unsupported(["an empty set of conditions"]) }
        if items.contains(.yes) { return .yes }
        if let merged = mergedUnsupported(items) { return merged }
        if let merged = mergedEligibility(items) { return merged }
        if items.contains(.someUsers) { return .someUsers }
        return .no
    }

    static func exactlyOne(_ items: [Applicability]) -> Applicability {
        if items.isEmpty { return .unsupported(["an empty set of conditions"]) }
        if let merged = mergedUnsupported(items) { return merged }
        if let merged = mergedEligibility(items) { return merged }
        if items.contains(.someUsers) { return .someUsers }
        return items.filter { $0 == .yes }.count == 1 ? .yes : .no
    }

    private static func mergedUnsupported(_ items: [Applicability]) -> Applicability? {
        var reasons = Set<String>()
        for case .unsupported(let more) in items { reasons.formUnion(more) }
        return reasons.isEmpty ? nil : .unsupported(reasons)
    }

    private static func mergedEligibility(_ items: [Applicability]) -> Applicability? {
        var needs = Set<EligibilityNeed>()
        for case .eligibility(let more) in items { needs.formUnion(more) }
        return needs.isEmpty ? nil : .eligibility(needs)
    }
}

/// Evaluates a condition tree at one instant.
struct ConditionEvaluator: Sendable {
    enum Subject: Sendable {
        /// The user's own vehicle and eligibility.
        case profile(VehicleProfile)
        /// "Is the regulation in force for anybody at this time?": every condition
        /// about who the road user is counts as "some users".
        case anyone
        /// "Does the order exist at this date?": like `anyone`, but a time condition
        /// only tests its overall start...end dates, not its hours or days.
        case anyoneByDatesOnly
    }

    let time: TimeEvaluator

    func evaluate(_ node: ConditionNode, at instant: Date, subject: Subject) -> Applicability {
        switch node.kind {
        case .and(let items):
            return .all(items.map { evaluate($0, at: instant, subject: subject) })
        case .or(let items):
            return .any(items.map { evaluate($0, at: instant, subject: subject) })
        case .xor(let items):
            return .exactlyOne(items.map { evaluate($0, at: instant, subject: subject) })
        case .not(let inner):
            return evaluate(inner, at: instant, subject: subject).negated
        case .time(let validity):
            if case .anyoneByDatesOnly = subject {
                // Inside its dates the condition may or may not hold (that depends
                // on hours and days); outside them it certainly does not.
                return time.isWithinDates(validity, at: instant) ? .someUsers : .no
            }
            switch time.isActive(validity, at: instant) {
            case .yes: return .yes
            case .no: return .no
            case .unknown(let why): return .unsupported([why])
            }
        case .unsupported(let why):
            return .unsupported([why])
        case .concessions:
            // A list of exemptions does not narrow who the rule applies to.
            return .yes
        default:
            break
        }
        guard case .profile(let profile) = subject else { return .someUsers }
        switch node.kind {
        case .vehicle(let condition): return vehicle(condition, profile)
        case .permit(let condition): return permit(condition, profile)
        case .driver(let kind): return driver(kind, profile)
        case .occupant(let condition): return occupant(condition, profile)
        case .access(let kinds): return access(kinds)
        case .road: return .unsupported(["a road-type condition"])
        case .nonVehicular: return .no  // the user is in a vehicle
        case .other(let text):
            return .unsupported([text.isEmpty ? "a free-text condition" : "the condition \u{201C}\(text)\u{201D}"])
        default: return .unsupported(["an unrecognised condition"])
        }
    }

    // MARK: Leaves

    private func vehicle(_ condition: VehicleCondition, _ profile: VehicleProfile) -> Applicability {
        var parts: [Applicability] = []
        if let type = condition.type { parts.append(Self.matches(vehicleType: type, profile.vehicleType)) }
        if let usage = condition.usage { parts.append(Self.matches(vehicleUsage: usage)) }
        if let fuel = condition.fuel, !fuel.isEmpty {
            // The profile does not record fuel, so an electric-only condition is a
            // question for the user; any other fuel condition is not interpreted.
            let electric: Set<String> = ["electric", "battery", "phev", "reev", "fuelCell", "petrolBatteryHybrid", "dieselBatteryHybrid"]
            parts.append(
                fuel.allSatisfy(electric.contains)
                    ? .eligibility([.electricVehicle]) : .unsupported(["a fuel-type condition (\(fuel.joined(separator: ", ")))"]))
        }
        if let extra = condition.unsupported, !extra.isEmpty {
            parts.append(.unsupported(["vehicle characteristics (\(extra.map(Self.friendly).joined(separator: ", ")))"]))
        }
        return parts.isEmpty ? .unsupported(["an empty vehicle condition"]) : .all(parts)
    }

    /// Does a D-TRO vehicleType describe the user's vehicle?
    static func matches(vehicleType type: String, _ vehicle: VehicleType) -> Applicability {
        if vehicle == .other {
            // "Other" could be anything, so only the catch-all type is certain.
            return type == "anyVehicle" ? .yes : .unsupported(["whether your vehicle counts as \(friendly(type))"])
        }
        switch type {
        case "anyVehicle", "motorVehicle":
            return .yes
        case "car":
            return .init(vehicle == .car)
        case "motorcycle", "soloMotorcycle":
            return .init(vehicle == .motorcycle)
        case "mopedSmallMotorcycle":
            return vehicle == .motorcycle ? .unsupported(["whether your motorcycle counts as a moped"]) : .no
        case "goodsVehicle":
            return .init(vehicle == .van)
        case "heavyGoodsVehicle", "articulatedVehicle", "bus", "taxi", "ambulance", "agriculturalVehicle",
            "caravan", "vehicleWithTrailer", "horseDrawnVehicle", "lightRailTram", "pedalCycle",
            "poweredVehicleUsedByDisabledPeople", "trackedLayingVehicle":
            return .no
        default:
            return .unsupported(["the vehicle type \(friendly(type))"])
        }
    }

    /// The user is assumed to be a private motorist on ordinary business.
    static func matches(vehicleUsage usage: String) -> Applicability {
        // Uses a private motorist certainly is not engaged in.
        let official: Set<String> = [
            "authorisedVehicles", "busOperationPurpose", "coastguardVehicle", "dialARide", "diplomaticVehicle",
            "emergencyAndIncidentSupportVehicle", "emergencyServicesVehicle", "fireServiceVehicle", "guidedBuses",
            "highwayAuthorityPurpose", "localBuses", "locallyRegisteredPrivateHireVehicle", "military",
            "policeVehicle", "privateHireVehicle", "publicServiceVehicle", "schoolBus", "statutoryUndertakerPurpose",
        ]
        if official.contains(usage) { return .no }
        // Access, "other", and any use this version has not heard of.
        return .unsupported(["a vehicle-use condition (\(friendly(usage)))"])
    }

    private func permit(_ condition: PermitCondition, _ profile: VehicleProfile) -> Applicability {
        let badgeTypes: Set<String> = ["residentPlusBadgeHolders", "residentWithNonResidentBlueBadge"]
        if profile.blueBadge && badgeTypes.contains(condition.type) { return .yes }
        return .eligibility([.permit(type: condition.type, scheme: condition.scheme)])
    }

    private func driver(_ kind: String, _ profile: VehicleProfile) -> Applicability {
        switch kind {
        case "disabledWithPermit": .init(profile.blueBadge)
        case "localResident": .eligibility([.resident])
        case "hotelGuest": .eligibility([.guest])
        default: .unsupported(["a driver condition (\(Self.friendly(kind)))"])
        }
    }

    private func occupant(_ condition: OccupantCondition, _ profile: VehicleProfile) -> Applicability {
        if condition.hasCount { return .unsupported(["a number-of-occupants condition"]) }
        guard let disabled = condition.disabled else { return .unsupported(["an occupant condition"]) }
        return .init(disabled == profile.blueBadge)
    }

    private func access(_ kinds: [String]) -> Applicability {
        // The user wants to leave the vehicle parked, which is not loading.
        let loading: Set<String> = ["loadingAndUnloading", "passengerLoadingAndUnloading"]
        if !kinds.isEmpty && kinds.allSatisfy(loading.contains) { return .no }
        return .unsupported(["an access condition (\(kinds.map(Self.friendly).joined(separator: ", ")))"])
    }

    /// "maximumHeightCharacteristic" -> "maximum height characteristic".
    static func friendly(_ identifier: String) -> String {
        var out = ""
        for character in identifier {
            if character.isUppercase && !out.isEmpty { out.append(" ") }
            out.append(contentsOf: character.lowercased())
        }
        return out
    }
}

extension Applicability {
    init(_ value: Bool) { self = value ? .yes : .no }
}
