import Foundation

/// A node of the normalised D-TRO condition tree.
///
/// D-TRO semantics are preserved exactly: a tree is true for the road users and
/// times to which the regulation's effect applies. Exceptions are expressed with
/// `.not`. See docs/RULES_ENGINE.md.
public struct ConditionNode: Sendable, Equatable {
    public indirect enum Kind: Sendable, Equatable {
        case and([ConditionNode])
        case or([ConditionNode])
        case xor([ConditionNode])
        case not(ConditionNode)
        case time(TimeValidity)
        case vehicle(VehicleCondition)
        case permit(PermitCondition)
        case driver(String)
        case occupant(OccupantCondition)
        case access([String])
        case road(String)
        case nonVehicular(String)
        case other(String)
        case unsupported(String)
    }

    public let kind: Kind
    /// Tariff attached to this node, charged while the node applies.
    public let rate: RateTable?
    /// The source had a rate table that could not be read.
    public let rateUnusable: Bool

    public init(_ kind: Kind, rate: RateTable? = nil, rateUnusable: Bool = false) {
        self.kind = kind
        self.rate = rate
        self.rateUnusable = rateUnusable
    }

    /// Every node of the tree, this one included.
    public var allNodes: [ConditionNode] {
        switch kind {
        case .and(let items), .or(let items), .xor(let items):
            return [self] + items.flatMap(\.allNodes)
        case .not(let inner):
            return [self] + inner.allNodes
        default:
            return [self]
        }
    }

    public var containsPermit: Bool {
        allNodes.contains { if case .permit = $0.kind { true } else { false } }
    }
}

extension ConditionNode: Decodable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        func has(_ name: String) -> Bool { container.contains(Key(name)) }
        func value<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
            try container.decode(type, forKey: Key(name))
        }

        rate = has("rate") ? try? value(RateTable.self, "rate") : nil
        // A rate we cannot decode is treated like one the pipeline could not read.
        rateUnusable = ((try? value(Bool.self, "rateUnusable")) ?? false) || (has("rate") && rate == nil)

        if has("op") {
            let items = try value([ConditionNode].self, "items")
            switch try value(String.self, "op") {
            case "and": kind = .and(items)
            case "or": kind = .or(items)
            case "xor": kind = .xor(items)
            case let other: kind = .unsupported("unknown operator \(other)")
            }
        } else if has("not") {
            kind = .not(try value(ConditionNode.self, "not"))
        } else if has("time") {
            // A time condition this version cannot read must not vanish.
            if let time = try? value(TimeValidity.self, "time") {
                kind = .time(time)
            } else {
                kind = .unsupported("unreadable time condition")
            }
        } else if has("vehicle") {
            kind = (try? value(VehicleCondition.self, "vehicle")).map(Kind.vehicle) ?? .unsupported("unreadable vehicle condition")
        } else if has("permit") {
            kind = (try? value(PermitCondition.self, "permit")).map(Kind.permit) ?? .unsupported("unreadable permit condition")
        } else if has("driver") {
            kind = .driver((try? value(String.self, "driver")) ?? "")
        } else if has("occupant") {
            kind = (try? value(OccupantCondition.self, "occupant")).map(Kind.occupant) ?? .unsupported("unreadable occupant condition")
        } else if has("access") {
            kind = .access((try? value([String].self, "access")) ?? [])
        } else if has("road") {
            kind = .road((try? value(String.self, "road")) ?? "")
        } else if has("nonVehicular") {
            kind = .nonVehicular((try? value(String.self, "nonVehicular")) ?? "")
        } else if has("other") {
            kind = .other((try? value(String.self, "other")) ?? "")
        } else if has("unsupported") {
            kind = .unsupported((try? value(String.self, "unsupported")) ?? "unsupported condition")
        } else {
            kind = .unsupported("unrecognised condition")
        }
    }
}

public struct VehicleCondition: Sendable, Decodable, Equatable {
    /// D-TRO vehicleType.
    public let type: String?
    /// D-TRO vehicleUsage.
    public let usage: String?
    /// Characteristics present in the source that the engine does not evaluate.
    public let unsupported: [String]?

    public init(type: String? = nil, usage: String? = nil, unsupported: [String]? = nil) {
        self.type = type
        self.usage = usage
        self.unsupported = unsupported
    }
}

public struct PermitCondition: Sendable, Decodable, Equatable {
    /// D-TRO permitType.
    public let type: String
    public let scheme: String?
    public let identifier: String?
    public let authority: String?
    public let applyUrl: String?
    public let phone: String?
    public let `extension`: String?
    public let maxStay: Int?
    public let noReturn: Int?

    public init(type: String, scheme: String? = nil) {
        self.type = type
        self.scheme = scheme
        identifier = nil
        authority = nil
        applyUrl = nil
        phone = nil
        `extension` = nil
        maxStay = nil
        noReturn = nil
    }
}

public struct OccupantCondition: Sendable, Decodable, Equatable {
    public let disabled: Bool?
    public let hasCount: Bool

    private enum Keys: String, CodingKey { case disabled, count }

    public init(disabled: Bool?, hasCount: Bool = false) {
        self.disabled = disabled
        self.hasCount = hasCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
        hasCount = container.contains(.count)
    }
}

/// D-TRO timeValidity: when a condition holds.
public struct TimeValidity: Sendable, Decodable, Equatable {
    public let start: Date
    public let end: Date?
    public let placeholder: Bool?
    /// Periods within start...end when the condition holds. Empty means always.
    public let valid: [Period]?
    /// Periods carved out of `valid`.
    public let except: [Period]?
    public let maxStay: Int?
    public let noReturn: Int?
    public let unsupported: [String]?

    public init(
        start: Date, end: Date? = nil, valid: [Period]? = nil, except: [Period]? = nil,
        maxStay: Int? = nil, noReturn: Int? = nil
    ) {
        self.start = start
        self.end = end
        placeholder = nil
        self.valid = valid
        self.except = except
        self.maxStay = maxStay
        self.noReturn = noReturn
        unsupported = nil
    }
}

public struct DayRule: Sendable, Decodable, Equatable {
    /// ISO weekdays, Monday = 1 ... Sunday = 7.
    public let dow: [Int]?
    public let months: [Int]?
    /// Days of the month.
    public let dom: [Int]?
    /// "The nth such weekday of the month".
    public let instance: Int?

    public init(dow: [Int]? = nil, months: [Int]? = nil, dom: [Int]? = nil, instance: Int? = nil) {
        self.dow = dow
        self.months = months
        self.dom = dom
        self.instance = instance
    }
}

public struct SpecialDay: Sendable, Decodable, Equatable {
    public let type: String
    /// True: the special day must also be an applicable day. False: it applies on
    /// the special day whatever the day rules say.
    public let intersect: Bool
    public let name: String?

    public init(type: String, intersect: Bool, name: String? = nil) {
        self.type = type
        self.intersect = intersect
        self.name = name
    }
}

public struct Period: Sendable, Decodable, Equatable {
    public let from: Date?
    public let to: Date?
    public let name: String?
    /// Time-of-day windows as [start, end) seconds after local midnight.
    public let times: [[Int]]?
    public let days: [DayRule]?
    public let special: [SpecialDay]?
    public let maxStay: Int?
    public let noReturn: Int?
    /// Parts of the source period that could not be interpreted.
    public let unsupported: [String]?

    public init(
        from: Date? = nil, to: Date? = nil, times: [[Int]]? = nil, days: [DayRule]? = nil,
        special: [SpecialDay]? = nil, maxStay: Int? = nil, noReturn: Int? = nil, unsupported: [String]? = nil
    ) {
        self.from = from
        self.to = to
        name = nil
        self.times = times
        self.days = days
        self.special = special
        self.maxStay = maxStay
        self.noReturn = noReturn
        self.unsupported = unsupported
    }

    /// Unsupported parts that affect *when* the period applies (as opposed to
    /// stay limits, which are reported separately).
    public var unsupportedTiming: [String] {
        (unsupported ?? []).filter { $0 != "maxStay" && $0 != "noReturn" }
    }
}

public struct RateTable: Sendable, Decodable, Equatable {
    public let type: String?
    public let info: String?
    public let collections: [RateCollection]
}

public struct RateCollection: Sendable, Decodable, Equatable {
    public let currency: String?
    public let seq: Int?
    public let from: Date?
    public let to: Date?
    /// Longest and shortest chargeable session, in seconds.
    public let maxTime: Int?
    public let minTime: Int?
    public let maxValue: Decimal?
    public let minValue: Decimal?
    public let resetTime: Int?
    public let lines: [RateLine]
}

public struct RateLine: Sendable, Decodable, Equatable {
    public let seq: Int?
    /// flatRate, flatRateTier, incrementingRate or perUnit.
    public let type: String?
    public let value: Decimal?
    /// Session-duration band this line covers, in seconds.
    public let start: Int?
    public let end: Int?
    /// Charging increment in seconds.
    public let increment: Int?
    public let min: Decimal?
    public let max: Decimal?
    public let usage: String?
}
