import Foundation

/// What one provision does to the user's vehicle at one instant.
enum Effect: Equatable, Sendable {
    /// The provision does not exist at this time: not yet commenced, ended, or
    /// outside its validity dates. It says nothing about the kerb, so it must not
    /// be read as "restriction lifted" or "outside hours".
    case absent
    /// A current provision that is outside its hours at this time.
    case inactive
    /// In force, but the user is outside the population it restricts.
    case notAffected
    /// Waiting is prohibited.
    case prohibits
    /// Waiting is permitted here.
    case permits(paid: Bool)
    /// A bay in force for other users only.
    case reserved
    /// Depends on eligibility the app cannot confirm.
    case needs(Set<EligibilityNeed>)
    /// Cannot be determined.
    case unknown(Set<String>)
    /// Bays here are suspended.
    case suspendsBays
    /// A restriction here is suspended.
    case liftsRestrictions
    /// Context only: never decides.
    case info

    var isActive: Bool {
        switch self {
        case .absent, .inactive, .info: false
        default: true
        }
    }
}

/// One provision's state at one instant.
struct Snapshot: Sendable {
    let feature: Feature
    let effect: Effect
    var limits = StayLimits()
    var rate: RateTable?
    var rateUnusable = false
    /// The source gives a stay limit that could not be read.
    var limitsUnreadable = false

    /// Whether parking under this provision must be paid for right now.
    var isPaid: Bool {
        guard case .permits(let paid) = effect else { return false }
        return paid || rate != nil || rateUnusable
    }
}

/// Turns a single provision into an `Effect` for an instant.
struct ProvisionEvaluator: Sendable {
    let conditions: ConditionEvaluator
    let calendar: LondonCalendar

    init(holidays: HolidayCalendar, calendar: LondonCalendar = .shared) {
        self.calendar = calendar
        conditions = ConditionEvaluator(time: TimeEvaluator(holidays: holidays, calendar: calendar))
    }

    func snapshot(_ feature: Feature, at instant: Date, profile: VehicleProfile) -> Snapshot {
        let effect = effect(feature, at: instant, profile: profile)
        var snapshot = Snapshot(feature: feature, effect: effect)
        if case .permits = effect {
            collectTerms(feature.cond, at: instant, profile: profile, into: &snapshot)
        }
        return snapshot
    }

    // MARK: Effect

    private func effect(_ feature: Feature, at instant: Date, profile: VehicleProfile) -> Effect {
        guard hasCommenced(feature, at: instant), isSwitchedOn(feature, at: instant),
            isWithinValidityDates(feature, at: instant)
        else { return .absent }

        switch feature.lifecycle {
        case .revocation?:
            return .unknown(["A revocation is recorded for this kerb, so the current rule cannot be determined"])
        case .unrecognised?:
            return .unknown(["This rule has a status this version of the app does not understand"])
        case .intended?, nil:
            break
        }

        let inForce = conditions.evaluate(feature.cond, at: instant, subject: .anyone)
        if inForce == .no { return .inactive }

        if feature.hasIssue("dynamic") {
            return .unknown(["This rule varies and is shown on signs, not in the published order"])
        }
        if feature.hasIssue("placeholder") {
            return .unknown(["The published record is a placeholder for an order whose content is not recorded"])
        }
        if feature.hasIssue("timeZone") || feature.hasIssue("oversized") {
            return .unknown(["The published record could not be interpreted reliably"])
        }

        let applies = conditions.evaluate(feature.cond, at: instant, subject: .profile(profile))
        let intended = feature.lifecycle == .intended

        switch feature.role {
        case .prohibition:
            switch applies {
            case .yes: return intended ? .needs([.plannedRestriction]) : .prohibits
            case .no: return .notAffected
            case .eligibility(let needs): return .needs(intended ? [.plannedRestriction] : needs)
            case .unsupported(let reasons): return intended ? .needs([.plannedRestriction]) : .unknown(reasons)
            case .someUsers: return .unknown(["an unresolved condition"])
            }

        case .permission:
            if intended { return .absent }  // a planned bay grants nothing yet
            if case .unsupported(let reasons) = inForce { return .unknown(reasons) }
            // Eligibility implied by the kind of bay, whatever the conditions say.
            switch feature.cat {
            case .disabled:
                if !profile.blueBadge { return .reserved }
            case .motorcycle:
                switch profile.vehicleType {
                case .motorcycle: break
                case .other: return .unknown(["whether your vehicle may use a motorcycle bay"])
                case .car, .van: return .reserved
                }
            case .loading, .taxi, .cycle:
                return .reserved
            default:
                break
            }
            switch applies {
            case .yes:
                if feature.cat == .permit && !feature.cond.containsPermit {
                    // A permit bay whose permit is not described: still needs one.
                    return .needs([.permit(type: "other", scheme: nil)])
                }
                return .permits(paid: feature.cat == .paid)
            case .no: return .reserved
            case .eligibility(let needs): return .needs(needs)
            case .unsupported(let reasons): return .unknown(reasons)
            case .someUsers: return .unknown(["an unresolved condition"])
            }

        case .baySuspension:
            switch inForce {
            case .unsupported(let reasons): return intended ? .needs([.plannedRestriction]) : .unknown(reasons)
            default: return intended ? .needs([.plannedRestriction]) : .suspendsBays
            }

        case .restrictionSuspension:
            // Only relied on when it certainly applies; otherwise nothing is lifted.
            return (inForce == .yes && !intended) ? .liftsRestrictions : .info

        case .zone, .info:
            return .info

        case .unsupported:
            let name = feature.offList?.name ?? ConditionEvaluator.friendly(feature.reg)
            return .unknown(["A regulation the app cannot interpret applies here (\(name))"])
        }
    }

    private func hasCommenced(_ feature: Feature, at instant: Date) -> Bool {
        if let from = feature.from, let day = calendar.localDay(iso: from), instant < calendar.startOfDay(day) {
            return false
        }
        if let until = feature.until, let day = calendar.localDay(iso: until),
            instant >= calendar.startOfDay(calendar.day(day, addingDays: 1))
        {
            return false
        }
        return true
    }

    /// False when every time condition's start...end range excludes the instant:
    /// the order has expired or has not started, as opposed to being outside its
    /// daily hours.
    private func isWithinValidityDates(_ feature: Feature, at instant: Date) -> Bool {
        var sawTime = false
        for case .time(let validity) in feature.cond.allNodes.map(\.kind) {
            sawTime = true
            if instant >= validity.start, validity.end.map({ instant < $0 }) ?? true { return true }
        }
        return !sawTime
    }

    /// Orders with recorded on-street start/stop events are in force only between them.
    private func isSwitchedOn(_ feature: Feature, at instant: Date) -> Bool {
        guard let events = feature.activity, let first = events.first else { return true }
        guard let latest = events.last(where: { $0.at <= instant }) else {
            return first.type == .stop  // before a first "stop" it was on; before a first "start", off
        }
        return latest.type == .start
    }

    // MARK: Limits and tariff

    /// Gather stay limits and the tariff from the parts of the tree that hold now.
    private func collectTerms(_ node: ConditionNode, at instant: Date, profile: VehicleProfile, into snapshot: inout Snapshot) {
        let holds = conditions.evaluate(node, at: instant, subject: .profile(profile)) == .yes
        switch node.kind {
        case .and(let items), .or(let items), .xor(let items):
            guard holds else { return }
            for item in items { collectTerms(item, at: instant, profile: profile, into: &snapshot) }
        case .time(let validity):
            guard holds else { return }
            snapshot.limits.tighten(with: StayLimits(maxStay: validity.maxStay, noReturn: validity.noReturn))
            if (validity.unsupported ?? []).contains(where: { $0 == "maxStay" || $0 == "noReturn" }) {
                snapshot.limitsUnreadable = true
            }
            for period in conditions.time.activePeriods(validity, at: instant) {
                snapshot.limits.tighten(with: StayLimits(maxStay: period.maxStay, noReturn: period.noReturn))
                if (period.unsupported ?? []).contains(where: { $0 == "maxStay" || $0 == "noReturn" }) {
                    snapshot.limitsUnreadable = true
                }
            }
        case .permit(let permit):
            guard holds else { return }
            snapshot.limits.tighten(with: StayLimits(maxStay: permit.maxStay, noReturn: permit.noReturn))
        default:
            break
        }
        guard holds else { return }
        if let rate = node.rate {
            if snapshot.rate == nil {
                snapshot.rate = rate
            } else if snapshot.rate != rate {
                snapshot.rateUnusable = true  // more than one tariff applies at once
            }
        }
        if node.rateUnusable { snapshot.rateUnusable = true }
    }

    // MARK: Boundaries

    /// Instants inside `interval` at which this provision's effect could change.
    func boundaries(_ feature: Feature, in interval: DateInterval) -> [Date] {
        var result: [Date] = []
        for case .time(let validity) in feature.cond.allNodes.map(\.kind) {
            result.append(contentsOf: conditions.time.boundaries(validity, in: interval))
        }
        if let from = feature.from, let day = calendar.localDay(iso: from) {
            result.append(calendar.startOfDay(day))
        }
        if let until = feature.until, let day = calendar.localDay(iso: until) {
            result.append(calendar.startOfDay(calendar.day(day, addingDays: 1)))
        }
        result.append(contentsOf: (feature.activity ?? []).map(\.at))
        return result.filter { $0 > interval.start && $0 < interval.end }
    }
}
