import Foundation

/// Plain-English descriptions of rules, for reasons and the details sheet.
public enum Describe {
    public static func duration(_ seconds: Int) -> String {
        if seconds % 86400 == 0, seconds >= 86400 {
            let days = seconds / 86400
            return days == 1 ? "1 day" : "\(days) days"
        }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        switch (hours, minutes) {
        case (0, let m): return m == 1 ? "1 minute" : "\(m) minutes"
        case (let h, 0): return h == 1 ? "1 hour" : "\(h) hours"
        case (let h, let m): return "\(h) hr \(m) min"
        }
    }

    public static func timeOfDay(_ seconds: Int) -> String {
        let clamped = seconds >= 86400 ? 0 : seconds
        return String(format: "%02d:%02d", clamped / 3600, (clamped % 3600) / 60)
    }

    private static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// [1,2,3,4,5] -> "Mon-Fri", [1,3] -> "Mon, Wed", all seven -> "Every day".
    public static func days(_ weekdays: [Int]) -> String {
        let sorted = Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
        if sorted.count == 7 { return "Every day" }
        var runs: [[Int]] = []
        for day in sorted {
            if let last = runs.last?.last, last + 1 == day {
                runs[runs.count - 1].append(day)
            } else {
                runs.append([day])
            }
        }
        return runs.map { run in
            run.count >= 3
                ? "\(dayNames[run[0] - 1])\u{2013}\(dayNames[run[run.count - 1] - 1])"
                : run.map { dayNames[$0 - 1] }.joined(separator: ", ")
        }.joined(separator: ", ")
    }

    public static func period(_ period: Period) -> String {
        var parts: [String] = []
        var dayParts: [String] = []
        for rule in period.days ?? [] {
            var text = rule.dow.map(days) ?? ""
            if let instance = rule.instance {
                let ordinal = ["1st", "2nd", "3rd", "4th", "5th"][max(0, min(4, instance - 1))]
                text = "\(ordinal) \(text)"
            }
            if let dom = rule.dom { text += (text.isEmpty ? "" : ", ") + "day \(dom.map(String.init).joined(separator: ", "))" }
            if let months = rule.months {
                text += (text.isEmpty ? "" : " in ") + months.compactMap { (1...12).contains($0) ? monthNames[$0 - 1] : nil }.joined(separator: ", ")
            }
            if !text.isEmpty { dayParts.append(text) }
        }
        for special in period.special ?? [] {
            switch special.type {
            case "publicHoliday": dayParts.append(special.name ?? "Bank holidays")
            case "goodFriday": dayParts.append("Good Friday")
            default: dayParts.append(ConditionEvaluator.friendly(special.type).capitalizedFirst)
            }
        }
        if !dayParts.isEmpty { parts.append(dayParts.joined(separator: "; ")) }
        let windows = (period.times ?? []).filter { $0.count == 2 }
        if !windows.isEmpty {
            let allDay = windows.contains { $0[0] == 0 && $0[1] >= 86400 }
            parts.append(allDay ? "all day" : windows.map { "\(timeOfDay($0[0]))\u{2013}\(timeOfDay($0[1]))" }.joined(separator: ", "))
        }
        if parts.isEmpty { return "At all times" }
        return parts.joined(separator: " ")
    }

    /// One line per period of every time condition in a feature's rules.
    public static func schedule(_ node: ConditionNode) -> [String] {
        var lines: [String] = []
        for case .time(let validity) in node.allNodes.map(\.kind) {
            let periods = validity.valid ?? []
            if periods.isEmpty {
                lines.append("At all times")
            } else {
                lines.append(contentsOf: merged(periods.map(period)))
            }
            for exception in validity.except ?? [] {
                lines.append("Except \(period(exception).lowercasedFirst)")
            }
        }
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }

    /// Overnight rules are published as two windows; show them as written.
    private static func merged(_ lines: [String]) -> [String] { lines }

    public static func money(_ amount: Decimal, currency: String = "GBP") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "en_GB")
        return formatter.string(from: amount as NSDecimalNumber) ?? "\u{00A3}\(amount)"
    }

    public static func category(_ category: Category) -> String {
        switch category {
        case .standard: "Parking bay"
        case .paid: "Paid parking"
        case .permit: "Permit holders' bay"
        case .limitedWaiting: "Limited waiting"
        case .disabled: "Disabled (Blue Badge) bay"
        case .motorcycle: "Motorcycle bay"
        case .loading: "Loading bay"
        case .taxi: "Taxi rank"
        case .cycle: "Cycle parking"
        case .noWaiting: "No waiting"
        case .noStopping: "No stopping"
        case .noLoading: "No loading"
        case .redRoute: "Red route"
        case .clearway: "Clearway"
        case .zigzag: "Keep clear markings"
        case .busStop: "Bus stop"
        case .crossing: "Pedestrian crossing"
        case .footway: "Footway parking rule"
        case .suspension: "Suspension"
        case .controlledParkingZone: "Controlled parking zone"
        case .restrictedParkingZone: "Restricted parking zone"
        case .permitParkingArea: "Permit parking area"
        case .other: "Other regulation"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

extension Describe {
    /// Plain-English lines for the "who" conditions of a rule (vehicle, permit,
    /// badge...), for display. Time conditions are covered by `schedule`.
    public static func eligibility(_ node: ConditionNode) -> [String] {
        var lines: [String] = []
        collect(node, negated: false, into: &lines)
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }

    private static func collect(_ node: ConditionNode, negated: Bool, into lines: inout [String]) {
        let prefix = negated ? "Does not apply to" : "Applies to"
        switch node.kind {
        case .and(let items), .or(let items), .xor(let items):
            for item in items { collect(item, negated: negated, into: &lines) }
        case .not(let inner):
            collect(inner, negated: !negated, into: &lines)
        case .time:
            break
        case .vehicle(let vehicle):
            var parts: [String] = []
            if let type = vehicle.type { parts.append(vehicleName(type)) }
            if let usage = vehicle.usage { parts.append("\(ConditionEvaluator.friendly(usage)) use") }
            if let extra = vehicle.unsupported, !extra.isEmpty {
                parts.append("vehicles meeting other limits (\(extra.map(ConditionEvaluator.friendly).joined(separator: ", ")))")
            }
            if !parts.isEmpty { lines.append("\(prefix): \(parts.joined(separator: ", "))") }
        case .permit(let permit):
            var text = EligibilityNeed.permitName(permit.type)
            if let scheme = permit.scheme, !scheme.isEmpty { text += " (\(scheme))" }
            lines.append(negated ? "Exempt: \(text.lowercasedFirst) holders" : "Permit holders: \(text.lowercasedFirst)")
        case .driver(let kind):
            let who = kind == "disabledWithPermit" ? "Blue Badge holders" : ConditionEvaluator.friendly(kind) + "s"
            lines.append("\(prefix): \(who)")
        case .occupant(let occupant):
            if occupant.disabled == true { lines.append("\(prefix): Blue Badge holders") }
            if occupant.hasCount { lines.append("A number-of-occupants condition applies") }
        case .access(let kinds):
            lines.append("\(prefix): \(kinds.map(ConditionEvaluator.friendly).joined(separator: ", "))")
        case .road(let type):
            lines.append("\(prefix): \(ConditionEvaluator.friendly(type)) roads")
        case .nonVehicular(let type):
            lines.append("\(prefix): \(ConditionEvaluator.friendly(type))")
        case .other(let text):
            lines.append("Other condition: \(text)")
        case .unsupported(let why):
            lines.append("A condition that could not be read (\(why))")
        }
    }

    static func vehicleName(_ type: String) -> String {
        switch type {
        case "anyVehicle": "all vehicles"
        case "motorVehicle": "motor vehicles"
        case "car": "cars"
        case "motorcycle", "soloMotorcycle": "motorcycles"
        case "goodsVehicle": "goods vehicles"
        case "heavyGoodsVehicle": "heavy goods vehicles"
        case "bus": "buses"
        case "taxi": "taxis"
        default: ConditionEvaluator.friendly(type) + "s"
        }
    }
}
