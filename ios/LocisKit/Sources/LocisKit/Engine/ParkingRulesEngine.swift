import Foundation

/// Decides whether a vehicle may legally park on a kerb feature for a whole stay.
///
/// The stay is cut into segments at every instant where any applicable rule could
/// change (a time window opening, a clock change, an order commencing). Each
/// segment is resolved across all provisions covering the kerb, and the worst
/// segment decides the result. See docs/RULES_ENGINE.md.
public struct ParkingRulesEngine: Sendable {
    /// Version of the evaluation semantics. A dataset whose manifest requires a
    /// newer engine must not be interpreted by this one.
    public static let engineVersion = 1

    let provisions: ProvisionEvaluator
    let calendar: LondonCalendar

    public init(holidays: HolidayCalendar, calendar: LondonCalendar = .shared) {
        self.calendar = calendar
        provisions = ProvisionEvaluator(holidays: holidays, calendar: calendar)
    }

    /// Outcome of one segment of the stay.
    struct SegmentOutcome: Equatable {
        var status: ParkingStatus
        var paid = false
        var note = ""
        var needs = Set<EligibilityNeed>()
        var unknowns = Set<String>()
        var limits = StayLimits()
        /// Feature whose tariff applies, when exactly one does.
        var rateSource: String?
        var rate: RateTable?
        var rateUnusable = false
        var deciding: [String] = []
        var inferred = false
        var shared = false
        var partial = false
    }

    // MARK: Public API

    /// Evaluate one feature.
    ///
    /// - Parameters:
    ///   - feature: The kerb feature the user selected or that is being drawn.
    ///   - context: Loaded features by id; must contain everything in
    ///     `feature.related` for a confident answer.
    ///   - dataIncomplete: True when some rules for this area could not be read.
    public func evaluate(
        _ feature: Feature, context: [String: Feature], stay: Stay, profile: VehicleProfile,
        dataIncomplete: Bool = false
    ) -> ParkingEvaluation {
        let relatedIDs = feature.related ?? []
        let related = relatedIDs.compactMap { context[$0] }
        if dataIncomplete || related.count != relatedIDs.count {
            return unknownEvaluation(
                feature, reason: "Some rules for this location could not be read, so no reliable answer is possible")
        }
        if feature.role == .zone {
            return unknownEvaluation(
                feature, reason: "This is a zone, not a kerb. It does not say where parking is allowed")
        }

        let all = [feature] + related
        let interval = DateInterval(start: stay.arrival, end: stay.departure)
        var cuts = Set(all.flatMap { provisions.boundaries($0, in: interval) })
        cuts.insert(interval.start)
        cuts.insert(interval.end)
        let instants = cuts.sorted()

        var parts: [(DateInterval, SegmentOutcome)] = []
        for (start, end) in zip(instants, instants.dropFirst()) {
            let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let snapshots = all.map { provisions.snapshot($0, at: middle, profile: profile) }
            let outcome = resolve(primary: feature, snapshots: snapshots)
            if let last = parts.last, last.1 == outcome {
                parts[parts.count - 1].0 = DateInterval(start: last.0.start, end: end)
            } else {
                parts.append((DateInterval(start: start, end: end), outcome))
            }
        }
        return summarise(feature, all: all, parts: parts, stay: stay)
    }

    // MARK: One segment across overlapping provisions

    func resolve(primary: Feature, snapshots input: [Snapshot]) -> SegmentOutcome {
        // 1. A temporary provision, or a suspension of a restriction, replaces the
        //    provisions it names for as long as it is itself active.
        var overridden = Set<String>()
        for snapshot in input where snapshot.effect.isActive || snapshot.effect == .liftsRestrictions {
            overridden.formUnion(snapshot.feature.overrides ?? [])
        }
        // Provisions that do not exist at this time take no part at all.
        let snapshots = input.filter { !overridden.contains($0.feature.prov) && $0.effect != .absent }
        let partialIDs = Set(primary.partial ?? [])

        func ids(_ matching: (Snapshot) -> Bool) -> [String] {
            snapshots.filter(matching).map(\.feature.id)
        }
        func touchesPartial(_ ids: [String]) -> Bool { ids.contains(where: partialIDs.contains) }

        // 2. An explicit prohibition is never hidden by a parking place.
        let prohibiting = snapshots.filter { $0.effect == .prohibits }
        if let first = prohibiting.first {
            let deciding = prohibiting.map(\.feature.id)
            return SegmentOutcome(
                status: .prohibited, note: Self.prohibitionNote(first.feature), deciding: deciding,
                partial: touchesPartial(deciding))
        }

        // 3. An active suspension overrides ordinary parking permissions.
        let permissions = snapshots.filter { $0.feature.role == .permission && $0.feature.lifecycle != .intended }
        let suspending = snapshots.filter { $0.effect == .suspendsBays }
        if !suspending.isEmpty && !permissions.isEmpty {
            let deciding = suspending.map(\.feature.id)
            return SegmentOutcome(
                status: .prohibited, note: "Bay suspended", deciding: deciding, partial: touchesPartial(deciding))
        }

        // 4. Anything undeterminable makes the segment unknown.
        var unknowns = Set<String>()
        for case .unknown(let reasons) in snapshots.map(\.effect) { unknowns.formUnion(reasons) }
        if !unknowns.isEmpty {
            return SegmentOutcome(
                status: .unknown, note: "Cannot be determined", unknowns: unknowns,
                deciding: ids { if case .unknown = $0.effect { true } else { false } })
        }

        // Eligibility questions raised by restrictions (permit exemptions, planned orders).
        var restrictionNeeds = Set<EligibilityNeed>()
        for snapshot in snapshots where snapshot.feature.role != .permission {
            if case .needs(let needs) = snapshot.effect { restrictionNeeds.formUnion(needs) }
        }

        // 5. Parking places.
        var outcome: SegmentOutcome
        let inForce = permissions.filter { $0.effect != .inactive }
        if inForce.isEmpty {
            if !permissions.isEmpty {
                // Bays exist but none is operating: outside their hours.
                if permissions.contains(where: { $0.feature.cat.isSpecialist }) {
                    outcome = SegmentOutcome(
                        status: .conditional,
                        note: "This bay's restriction is not in force at this time. Check the sign before parking",
                        deciding: permissions.map(\.feature.id), inferred: true)
                } else {
                    outcome = SegmentOutcome(
                        status: .allowedFree, note: "Outside controlled hours",
                        deciding: permissions.map(\.feature.id), inferred: true)
                }
            } else if snapshots.contains(where: { $0.feature.role == .prohibition && $0.feature.lifecycle != .intended }) {
                // A recorded restriction that is not in force now (single yellow at night).
                let exempt = snapshots.contains { $0.effect == .notAffected }
                outcome = SegmentOutcome(
                    status: .allowedFree,
                    note: exempt ? "The restriction here does not apply to you" : "Restriction not in force",
                    deciding: ids { $0.feature.role == .prohibition }, inferred: true)
            } else {
                outcome = SegmentOutcome(
                    status: .unknown, note: "Cannot be determined",
                    unknowns: [
                        snapshots.isEmpty
                            ? "No rule recorded for this kerb is in force at this time"
                            : "No rule about waiting is recorded for this kerb"
                    ])
            }
        } else {
            let specialist = inForce.filter { $0.feature.cat.isSpecialist }
            let standard = inForce.filter { !$0.feature.cat.isSpecialist }
            if !specialist.isEmpty && !standard.isEmpty || Set(specialist.map(\.feature.cat)).count > 1 {
                // The source does not say which bay type wins: do not invent a rule.
                return SegmentOutcome(
                    status: .unknown, note: "Cannot be determined",
                    unknowns: ["Overlapping records describe different kinds of bay on this kerb"],
                    deciding: inForce.map(\.feature.id))
            }
            let group = specialist.isEmpty ? standard : specialist
            let permitting = group.filter { if case .permits = $0.effect { true } else { false } }
            var needs = Set<EligibilityNeed>()
            for case .needs(let more) in group.map(\.effect) { needs.formUnion(more) }

            if !permitting.isEmpty {
                // Parking places are grants: any one that applies is enough. Prefer a
                // free grant; limits are taken from every grant in force (the tightest).
                let free = permitting.filter { !$0.isPaid }
                let used = free.isEmpty ? permitting : free
                outcome = SegmentOutcome(status: free.isEmpty ? .allowedPaid : .allowedFree)
                outcome.paid = free.isEmpty
                outcome.note = free.isEmpty ? "Paid parking" : "Parking permitted"
                outcome.deciding = used.map(\.feature.id)
                for snapshot in permitting { outcome.limits.tighten(with: snapshot.limits) }
                if outcome.paid {
                    let tariffs = used.filter { $0.rate != nil }
                    if used.count == 1, let only = tariffs.first, !only.rateUnusable {
                        outcome.rateSource = only.feature.id
                        outcome.rate = only.rate
                    } else {
                        outcome.rateUnusable = true
                    }
                }
                if permitting.contains(where: \.limitsUnreadable) {
                    outcome.status = .conditional
                    outcome.note = "A stay limit applies here but could not be read. Check the sign"
                }
                outcome.shared = group.count > 1
            } else if !needs.isEmpty {
                outcome = SegmentOutcome(
                    status: .conditional, note: needs.map(\.text).sorted().joined(separator: "; "), needs: needs,
                    deciding: group.map(\.feature.id))
            } else if !specialist.isEmpty {
                outcome = SegmentOutcome(
                    status: .specialist, note: Describe.category(specialist[0].feature.cat),
                    deciding: specialist.map(\.feature.id))
            } else {
                outcome = SegmentOutcome(
                    status: .prohibited, note: "This bay is not available to your vehicle",
                    deciding: standard.map(\.feature.id))
            }
        }

        if !restrictionNeeds.isEmpty && outcome.status.isAllowed {
            outcome.status = .conditional
            outcome.note = restrictionNeeds.map(\.text).sorted().joined(separator: "; ")
            outcome.needs = restrictionNeeds
        }
        outcome.partial = touchesPartial(outcome.deciding)
        return outcome
    }

    private static func prohibitionNote(_ feature: Feature) -> String {
        switch feature.cat {
        case .noWaiting: feature.temporary ? "Temporary no waiting" : "No waiting"
        case .noStopping: "No stopping"
        case .redRoute: "Red route: no stopping"
        case .clearway: "Clearway: no stopping"
        case .zigzag: "Keep clear: no stopping"
        case .busStop: "Bus stop: no stopping"
        case .crossing: "Pedestrian crossing: no stopping"
        case .footway: "Parking on the footway is prohibited"
        default: "Waiting prohibited"
        }
    }

    // MARK: Whole stay

    private func summarise(
        _ feature: Feature, all: [Feature], parts: [(DateInterval, SegmentOutcome)], stay: Stay
    ) -> ParkingEvaluation {
        var status = parts.map(\.1.status).max(by: { $0.severity < $1.severity }) ?? .unknown
        var reasons: [String] = []
        var needs = Set<EligibilityNeed>()
        var unknowns = Set<String>()
        var limits = StayLimits()
        var confidenceNotes: [String] = []

        for (_, outcome) in parts {
            needs.formUnion(outcome.needs)
            unknowns.formUnion(outcome.unknowns)
            limits.tighten(with: outcome.limits)
        }

        // Maximum stay: time parked while a limit is in force must not exceed it.
        // Time before or after the controlled period does not count.
        var limitedRuns: [(seconds: TimeInterval, limit: Int)] = []
        var current: (seconds: TimeInterval, limit: Int)?
        for (interval, outcome) in parts {
            if outcome.status.isAllowed, let limit = outcome.limits.maxStay {
                current = (
                    (current?.seconds ?? 0) + interval.duration, Swift.min(current?.limit ?? limit, limit)
                )
            } else if let run = current {
                limitedRuns.append(run)
                current = nil
            }
        }
        if let run = current { limitedRuns.append(run) }
        let overstay = limitedRuns.first { $0.seconds > Double($0.limit) + 0.5 }
        if let overstay, status.severity < ParkingStatus.prohibited.severity {
            status = .prohibited
            reasons.append(
                "Your stay is longer than the maximum stay of \(Describe.duration(overstay.limit)) "
                    + "(\(Describe.duration(Int(overstay.seconds.rounded()))) fall within the restricted hours)")
        } else if limitedRuns.count > 1, status.isAllowed {
            status = .conditional
            reasons.append(
                "Your stay runs through more than one period with a maximum stay. "
                    + "Whether that is allowed without moving the vehicle depends on the order; check the sign")
        }

        // Reasons from the segments that produced the final status, in time order.
        let multiple = parts.count > 1
        for (interval, outcome) in parts where outcome.status == status {
            var line = outcome.note
            if outcome.partial { line += " (recorded for part of this section)" }
            if multiple { line += " \(Self.timeRange(interval, calendar: calendar))" }
            if !line.isEmpty && !reasons.contains(line) { reasons.append(line) }
        }
        if status == .unknown {
            reasons.append(contentsOf: unknowns.sorted().map { Self.unknownSentence($0) })
        }

        // Payment and cost.
        let paidParts = parts.filter { $0.1.paid && $0.1.status.isAllowed }
        let chargeable = Int(paidParts.reduce(0) { $0 + $1.0.duration }.rounded())
        let paymentRequired = !paidParts.isEmpty && status.isAllowed
        var cost: CostEstimate?
        var costNote: String?
        if paymentRequired {
            if status == .allowedFree { status = .allowedPaid }
            let sources = Set(paidParts.map(\.1.rateSource))
            let contiguous = zip(paidParts, paidParts.dropFirst()).allSatisfy { $0.0.end == $1.0.start }
            if sources.count == 1, let source = sources.first, source != nil, contiguous,
                !paidParts.contains(where: \.1.rateUnusable), let rate = paidParts[0].1.rate,
                let start = paidParts.first?.0.start, let end = paidParts.last?.0.end
            {
                cost = CostCalculator.estimate(
                    rate: rate, chargeableSeconds: chargeable, sessionStart: start, sessionEnd: end,
                    calendar: calendar)
            }
            if cost == nil { costNote = CostCalculator.unavailable }
            if parts.contains(where: { !$0.1.paid && $0.1.status.isAllowed }) {
                reasons.append("Payment is needed for \(Describe.duration(chargeable)) of your stay; the rest is outside charging hours")
            }
        }

        // Confidence.
        if feature.geomQuality != .kerb {
            confidenceNotes.append(Self.geometryNote(feature.geomQuality))
        }
        if parts.contains(where: { $0.1.inferred && $0.1.status.isAllowed }) {
            confidenceNotes.append(
                "For part of your stay no restriction is in force. The app has no positive record that parking is allowed then")
        }
        if parts.contains(where: \.1.shared) {
            confidenceNotes.append("More than one parking rule is recorded on this kerb")
        }
        if !(feature.partial ?? []).isEmpty {
            confidenceNotes.append("Another rule covers part of this section; its exact extent may differ on the street")
        }
        if all.contains(where: { $0.hasIssue("legacyConditionNesting") }) {
            confidenceNotes.append("Published in an older data format whose conditions can be ambiguous")
        }
        var confidence: Confidence
        switch confidenceNotes.count {
        case 0: confidence = .high
        case 1, 2: confidence = .medium
        default: confidence = .low
        }
        if status == .unknown { confidence = .unknown }
        // Safety rule: low confidence is never presented as available.
        if confidence == .low && status.isAllowed {
            status = .unknown
            confidence = .unknown
            reasons = ["The information for this kerb is too uncertain to rely on"]
            cost = nil
            costNote = nil
        }

        let segments = parts.map { interval, outcome in
            StaySegment(interval: interval, status: outcome.status, paymentRequired: outcome.paid, note: outcome.note)
        }
        var seenIDs = Set<String>()
        let applicable = ([feature.id] + parts.flatMap(\.1.deciding)).filter { seenIDs.insert($0).inserted }

        return ParkingEvaluation(
            featureID: feature.id,
            status: status,
            confidence: confidence,
            category: feature.cat,
            summary: reasons.first ?? status.title,
            reasons: reasons,
            confidenceNotes: confidenceNotes,
            paymentRequired: paymentRequired && status.isAllowed,
            chargeableSeconds: status.isAllowed ? chargeable : 0,
            estimatedCost: status.isAllowed ? cost : nil,
            costNote: status.isAllowed ? costNote : nil,
            limits: limits,
            applicableRuleIDs: applicable,
            unresolvedConditions: (unknowns.sorted() + needs.map(\.text).sorted()),
            segments: segments)
    }

    private func unknownEvaluation(_ feature: Feature, reason: String) -> ParkingEvaluation {
        ParkingEvaluation(
            featureID: feature.id, status: .unknown, confidence: .unknown, category: feature.cat,
            summary: reason, reasons: [reason], confidenceNotes: [], paymentRequired: false,
            chargeableSeconds: 0, estimatedCost: nil, costNote: nil, limits: StayLimits(),
            applicableRuleIDs: [feature.id], unresolvedConditions: [reason], segments: [])
    }

    private static func geometryNote(_ quality: GeometryQuality) -> String {
        switch quality {
        case .centreline: "Recorded along the middle of the road, so the side it applies to is not certain"
        case .area: "Recorded as an area, not as a kerb line"
        case .point: "Recorded as a single point, not as a kerb line"
        case .zoneLine: "Recorded as a line standing for a zone"
        default: "The location of this rule is imprecise"
        }
    }

    private static func unknownSentence(_ reason: String) -> String {
        // Reasons from conditions are noun phrases; full sentences pass through.
        guard let first = reason.first, first.isLowercase else { return reason }
        return "This rule depends on \(reason), which the app cannot interpret"
    }

    static func timeRange(_ interval: DateInterval, calendar: LondonCalendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        let sameDay = calendar.localDay(of: interval.start) == calendar.localDay(of: interval.end.addingTimeInterval(-1))
        formatter.dateFormat = sameDay ? "HH:mm" : "EEE HH:mm"
        return "(\(formatter.string(from: interval.start))\u{2013}\(formatter.string(from: interval.end)))"
    }
}
