import Foundation

/// Three-valued answer to "does this hold at this instant?".
enum Tri: Equatable, Sendable {
    case yes
    case no
    /// Cannot be determined; the text says why.
    case unknown(String)

    init(_ value: Bool) { self = value ? .yes : .no }

    static func or(_ a: Tri, _ b: Tri) -> Tri {
        if a == .yes || b == .yes { return .yes }
        if case .unknown = a { return a }
        if case .unknown = b { return b }
        return .no
    }

    static func and(_ a: Tri, _ b: Tri) -> Tri {
        if a == .no || b == .no { return .no }
        if case .unknown = a { return a }
        if case .unknown = b { return b }
        return .yes
    }

    var negated: Tri {
        switch self {
        case .yes: .no
        case .no: .yes
        case .unknown: self
        }
    }
}

/// Resolves D-TRO time validity against real instants in London time.
struct TimeEvaluator: Sendable {
    let calendar: LondonCalendar
    let holidays: HolidayCalendar

    init(holidays: HolidayCalendar, calendar: LondonCalendar = .shared) {
        self.holidays = holidays
        self.calendar = calendar
    }

    // MARK: Activity at an instant

    func isActive(_ validity: TimeValidity, at instant: Date) -> Tri {
        if instant < validity.start { return .no }
        if let end = validity.end, instant >= end { return .no }
        var valid: Tri = .yes
        if let periods = validity.valid, !periods.isEmpty {
            valid = periods.reduce(Tri.no) { Tri.or($0, matches($1, at: instant)) }
        }
        if valid == .no { return .no }
        var excepted: Tri = .no
        if let periods = validity.except, !periods.isEmpty {
            excepted = periods.reduce(Tri.no) { Tri.or($0, matches($1, at: instant)) }
        }
        return Tri.and(valid, excepted.negated)
    }

    /// The valid periods in force at an instant (used for stay limits).
    func activePeriods(_ validity: TimeValidity, at instant: Date) -> [Period] {
        (validity.valid ?? []).filter { matches($0, at: instant) == .yes }
    }

    func matches(_ period: Period, at instant: Date) -> Tri {
        if let from = period.from, instant < from { return .no }
        if let to = period.to, instant >= to { return .no }
        let unsupported = period.unsupportedTiming
        if !unsupported.isEmpty {
            return .unknown("a recurrence that cannot be interpreted (\(unsupported.joined(separator: ", ")))")
        }

        // Day rules apply to the local day on which a time window starts, so an
        // overnight window that began yesterday is tested against yesterday.
        let today = calendar.localDay(of: instant)
        var windowDays: [LondonCalendar.LocalDay] = []
        if let windows = period.times, !windows.isEmpty {
            let seconds = calendar.secondsOfDay(instant)
            for window in windows where window.count == 2 {
                let (start, end) = (window[0], window[1])
                if start == end {
                    windowDays.append(today)
                } else if start < end {
                    if seconds >= start && seconds < end { windowDays.append(today) }
                } else {
                    if seconds >= start { windowDays.append(today) }
                    if seconds < end { windowDays.append(calendar.day(today, addingDays: -1)) }
                }
            }
            if windowDays.isEmpty { return .no }
        } else {
            windowDays = [today]
        }
        return windowDays.reduce(Tri.no) { Tri.or($0, dayMatches(period, $1)) }
    }

    private func dayMatches(_ period: Period, _ day: LondonCalendar.LocalDay) -> Tri {
        let regular: Bool? = period.days.map { rules in rules.contains { ruleMatches($0, day) } }
        guard let special = period.special, !special.isEmpty else {
            return Tri(regular ?? true)
        }
        // Ordinary days count on their own only when no special day narrows them.
        var result = Tri(regular == true && special.allSatisfy { !$0.intersect })
        for entry in special {
            let isSpecial = isSpecialDay(entry, day)
            let term = entry.intersect ? Tri.and(Tri(regular ?? true), isSpecial) : isSpecial
            result = Tri.or(result, term)
        }
        return result
    }

    private func ruleMatches(_ rule: DayRule, _ day: LondonCalendar.LocalDay) -> Bool {
        if let dow = rule.dow, !dow.contains(calendar.weekday(day)) { return false }
        if let months = rule.months, !months.contains(day.month) { return false }
        if let dom = rule.dom, !dom.contains(day.day) { return false }
        if let instance = rule.instance, (day.day - 1) / 7 + 1 != instance { return false }
        return true
    }

    private func isSpecialDay(_ entry: SpecialDay, _ day: LondonCalendar.LocalDay) -> Tri {
        guard entry.name == nil else {
            return .unknown("a named holiday (\(entry.name ?? ""))")
        }
        let answer: Bool?
        switch entry.type {
        case "publicHoliday": answer = holidays.isBankHoliday(day.iso)
        case "goodFriday": answer = holidays.isGoodFriday(day.iso)
        default: return .unknown("days that depend on a local calendar (\(entry.type))")
        }
        guard let answer else {
            return .unknown("bank holidays beyond the published calendar")
        }
        return Tri(answer)
    }

    // MARK: Boundaries

    /// Every instant inside `interval` at which the validity could change state.
    func boundaries(_ validity: TimeValidity, in interval: DateInterval) -> [Date] {
        var result: [Date] = [validity.start]
        if let end = validity.end { result.append(end) }
        let periods = (validity.valid ?? []) + (validity.except ?? [])
        var seconds: Set<Int> = [0]
        for period in periods {
            if let from = period.from { result.append(from) }
            if let to = period.to { result.append(to) }
            for window in period.times ?? [] where window.count == 2 {
                seconds.insert(window[0])
                seconds.insert(window[1])
            }
        }
        let clockChanges = calendar.clockChanges(in: DateInterval(
            start: interval.start.addingTimeInterval(-86400), end: interval.end.addingTimeInterval(86400)))
        for day in calendar.days(covering: interval) {
            for second in seconds {
                let instant = calendar.date(day, secondsOfDay: second)
                result.append(instant)
                // Around a clock change a wall-clock time can occur twice or not
                // at all; also test an hour either side so no change is missed.
                if clockChanges.contains(where: { abs($0.timeIntervalSince(instant)) <= 2 * 3600 }) {
                    result.append(instant.addingTimeInterval(3600))
                    result.append(instant.addingTimeInterval(-3600))
                }
            }
        }
        result.append(contentsOf: clockChanges)
        return result.filter { $0 > interval.start && $0 < interval.end }
    }
}
