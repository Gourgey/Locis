import Foundation

/// The arrival and departure times the user has chosen.
public struct StaySelection: Equatable, Sendable {
    public var arrival: Date
    public var departure: Date

    public init(arrival: Date, departure: Date) {
        self.arrival = arrival
        self.departure = departure
    }

    /// Arrival now, rounded up to the next quarter hour; departure two hours later.
    public static func suggested(now: Date = Date()) -> StaySelection {
        let quarter: TimeInterval = 15 * 60
        let rounded = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / quarter).rounded(.up) * quarter)
        return StaySelection(arrival: rounded, departure: rounded.addingTimeInterval(2 * 3600))
    }

    public enum Problem: Equatable, Sendable {
        case departureNotAfterArrival
        case tooLong

        public var message: String {
            switch self {
            case .departureNotAfterArrival: "Leave time must be after arrive time."
            case .tooLong: "Stays longer than 31 days cannot be checked."
            }
        }
    }

    public var problem: Problem? {
        if departure <= arrival { return .departureNotAfterArrival }
        if departure.timeIntervalSince(arrival) > Stay.maximumDuration { return .tooLong }
        return nil
    }

    /// The validated stay, or nil when the range is invalid.
    public var stay: Stay? { try? Stay(arrival: arrival, departure: departure) }

    public var duration: TimeInterval { departure.timeIntervalSince(arrival) }

    /// Move the arrival, keeping the length of the stay.
    public mutating func moveArrival(to newArrival: Date) {
        let length = max(duration, 15 * 60)
        arrival = newArrival
        departure = newArrival.addingTimeInterval(length)
    }

    // MARK: Display

    /// "Today 14:00", "Tomorrow 09:30", "Sat 3 Oct 14:00" (London time).
    public static func label(for date: Date, relativeTo now: Date = Date(), calendar: LondonCalendar = .shared) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_GB")
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        let today = calendar.localDay(of: now)
        let day = calendar.localDay(of: date)
        let prefix: String
        if day == today {
            prefix = "Today"
        } else if day == calendar.day(today, addingDays: 1) {
            prefix = "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_GB")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = day.year == today.year ? "EEE d MMM" : "EEE d MMM yyyy"
            prefix = formatter.string(from: date)
        }
        return "\(prefix) \(time.string(from: date))"
    }

    /// "14:00–17:00, Saturday 3 October" or a two-date range for overnight stays.
    public func rangeDescription(calendar: LondonCalendar = .shared) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_GB")
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_GB")
        day.timeZone = calendar.timeZone
        day.dateFormat = "EEEE d MMMM"
        if calendar.localDay(of: arrival) == calendar.localDay(of: departure) {
            return "\(time.string(from: arrival))\u{2013}\(time.string(from: departure)), \(day.string(from: arrival))"
        }
        day.dateFormat = "EEE d MMM"
        return "\(time.string(from: arrival)) \(day.string(from: arrival)) \u{2013} \(time.string(from: departure)) \(day.string(from: departure))"
    }
}
