import Foundation

/// Wall-clock arithmetic in the UK's time zone.
///
/// D-TRO regulations are specified in Europe/London local time (the v4 schema
/// fixes ``timeZone`` to that value), so every "08:30 on a Saturday" is resolved
/// here, including across the changes to and from British Summer Time.
public struct LondonCalendar: Sendable {
    public static let shared = LondonCalendar()

    public let timeZone: TimeZone
    public let calendar: Calendar

    public init() {
        timeZone = TimeZone(identifier: "Europe/London")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        self.calendar = calendar
    }

    public struct LocalDay: Sendable, Hashable, Comparable {
        public let year: Int
        public let month: Int
        public let day: Int

        /// `yyyy-MM-dd`.
        public var iso: String {
            String(format: "%04d-%02d-%02d", year, month, day)
        }

        public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
            (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
        }
    }

    public func localDay(of date: Date) -> LocalDay {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return LocalDay(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    public func localDay(iso: String) -> LocalDay? {
        let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return LocalDay(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Seconds after local midnight on the wall clock.
    public func secondsOfDay(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return parts.hour! * 3600 + parts.minute! * 60 + parts.second!
    }

    /// ISO weekday, Monday = 1 ... Sunday = 7.
    public func weekday(_ day: LocalDay) -> Int {
        let weekday = calendar.component(.weekday, from: startOfDay(day))  // Sunday = 1
        return weekday == 1 ? 7 : weekday - 1
    }

    public func startOfDay(_ day: LocalDay) -> Date {
        date(day, secondsOfDay: 0)
    }

    /// The instant a wall-clock time occurs on a local day. A time skipped by the
    /// spring clock change resolves to the first valid instant after it; a time
    /// repeated in autumn resolves to its first occurrence.
    public func date(_ day: LocalDay, secondsOfDay seconds: Int) -> Date {
        var parts = DateComponents()
        parts.year = day.year
        parts.month = day.month
        parts.day = day.day + seconds / 86400
        let remainder = seconds % 86400
        parts.hour = remainder / 3600
        parts.minute = (remainder % 3600) / 60
        parts.second = remainder % 60
        return calendar.date(from: parts)!
    }

    public func day(_ day: LocalDay, addingDays count: Int) -> LocalDay {
        localDay(of: calendar.date(byAdding: .day, value: count, to: date(day, secondsOfDay: 12 * 3600))!)
    }

    /// Local days from the day before `interval` starts to the day it ends.
    public func days(covering interval: DateInterval) -> [LocalDay] {
        var result: [LocalDay] = []
        var current = day(localDay(of: interval.start), addingDays: -1)
        let last = localDay(of: interval.end)
        while current <= last {
            result.append(current)
            current = day(current, addingDays: 1)
        }
        return result
    }

    /// Clock-change instants strictly inside an interval.
    public func clockChanges(in interval: DateInterval) -> [Date] {
        var result: [Date] = []
        var cursor = interval.start
        while let next = timeZone.nextDaylightSavingTimeTransition(after: cursor), next < interval.end {
            result.append(next)
            cursor = next
        }
        return result
    }
}
