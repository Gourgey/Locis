import Foundation

/// The dataset index the app downloads first.
public struct Manifest: Sendable, Decodable, Equatable {
    public struct Counts: Sendable, Decodable, Equatable {
        public let records: Int
        public let features: Int
        public let tiles: Int
        public let bySchemaVersion: [String: Int]?
    }

    public struct Authority: Sendable, Decodable, Equatable, Identifiable {
        public let name: String
        public let features: Int
        public var id: String { name }
    }

    public struct Source: Sendable, Decodable, Equatable {
        public let name: String
        public let url: String
        public let licence: String
        public let licenceUrl: String
        public let attribution: String
    }

    public let formatVersion: Int
    /// Lowest rules-engine version allowed to interpret this dataset.
    public let minEngineVersion: Int
    public let dataset: String
    public let synthetic: Bool
    public let generatedAt: Date
    public let lastSync: Date?
    public let tileZoom: Int
    /// west, south, east, north of the published features.
    public let bounds: [Double]?
    public let counts: Counts
    public let authorities: [Authority]?
    public let holidays: HolidayCalendar
    public let source: Source
    public let notice: String?
    public let transformation: String?
    /// "x/y" -> content hash of that tile.
    public let tiles: [String: String]
}

/// Bank holidays used to resolve "except bank holidays" style periods.
public struct HolidayCalendar: Sendable, Decodable, Equatable {
    public let division: String
    public let source: String
    /// The calendar is complete for local dates in `from...to` (`yyyy-MM-dd`).
    public let from: String
    public let to: String
    public let dates: [String]
    public let goodFridays: [String]?

    public init(from: String, to: String, dates: [String], goodFridays: [String]? = nil, source: String = "test") {
        division = "england-and-wales"
        self.source = source
        self.from = from
        self.to = to
        self.dates = dates
        self.goodFridays = goodFridays
    }

    public static let empty = HolidayCalendar(from: "0000-00-00", to: "0000-00-00", dates: [])

    /// Whether a local date is a bank holiday; nil when the date is outside the
    /// range the calendar covers.
    public func isBankHoliday(_ day: String) -> Bool? {
        guard day >= from, day <= to else { return nil }
        return dates.contains(day)
    }

    public func isGoodFriday(_ day: String) -> Bool? {
        guard let goodFridays, day >= from, day <= to else { return nil }
        return goodFridays.contains(day)
    }
}
