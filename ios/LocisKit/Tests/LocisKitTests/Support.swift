import Foundation
import Testing

@testable import LocisKit

// MARK: Dates

/// A London wall-clock time, "yyyy-MM-dd HH:mm".
func london(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_GB_POSIX")
    formatter.timeZone = TimeZone(identifier: "Europe/London")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

func stay(_ arrival: String, _ departure: String) -> Stay {
    try! Stay(arrival: london(arrival), departure: london(departure))
}

/// "08:30" -> seconds after midnight.
func at(_ clock: String) -> Int {
    let parts = clock.split(separator: ":").map { Int($0)! }
    return parts[0] * 3600 + parts[1] * 60
}

// Reference dates in 2026: Thu 1 Oct, Fri 2 Oct, Sat 3 Oct, Sun 4 Oct, Mon 5 Oct,
// Tue 6 Oct, Wed 7 Oct. Clocks go back on Sun 25 Oct and forward on Sun 29 Mar.
let monFri = [1, 2, 3, 4, 5]
let monSat = [1, 2, 3, 4, 5, 6]
let everyDay = [1, 2, 3, 4, 5, 6, 7]

// MARK: Condition builders (the JSON shapes published in tiles)

typealias JSON = [String: Any]

func period(_ days: [Int]? = nil, _ windows: [(String, String)] = [], extra: JSON = [:]) -> JSON {
    var out: JSON = extra
    if let days { out["days"] = [["dow": days]] }
    if !windows.isEmpty { out["times"] = windows.map { [at($0.0), $0.1 == "24:00" ? 86400 : at($0.1)] } }
    return out
}

func time(_ periods: [JSON] = [], start: String = "2020-01-01T00:00:00Z", end: String? = nil, except: [JSON] = [], rate: JSON? = nil) -> JSON {
    var validity: JSON = ["start": start]
    if let end { validity["end"] = end }
    if !periods.isEmpty { validity["valid"] = periods }
    if !except.isEmpty { validity["except"] = except }
    var node: JSON = ["time": validity]
    if let rate { node["rate"] = rate }
    return node
}

var always: JSON { time() }
func allOf(_ items: JSON...) -> JSON { ["op": "and", "items": items] }
func anyOf(_ items: JSON...) -> JSON { ["op": "or", "items": items] }
func oneOf(_ items: JSON...) -> JSON { ["op": "xor", "items": items] }
func not(_ item: JSON) -> JSON { ["not": item] }
func vehicle(_ type: String) -> JSON { ["vehicle": ["type": type]] }
func permit(_ type: String = "resident", scheme: String? = "Zone D") -> JSON {
    var body: JSON = ["type": type]
    if let scheme { body["scheme"] = scheme }
    return ["permit": body]
}

func perQuarterHour(_ value: Double) -> JSON {
    [
        "type": "hourly",
        "collections": [
            [
                "currency": "GBP", "seq": 1, "from": "2020-01-01T00:00:00Z",
                "lines": [["seq": 1, "type": "incrementingRate", "increment": 900, "value": value]],
            ]
        ],
    ]
}

// MARK: Feature builder

func feature(
    _ id: String = "primary", reg: String = "kerbsideParkingPlace", role: String = "permission",
    cat: String = "standard", cond: JSON, _ extra: JSON = [:]
) -> Feature {
    var body: JSON = [
        "id": id, "dtro": "dtro-\(id)", "prov": "prov-\(id)", "reg": reg, "role": role, "cat": cat,
        "name": "Test Street (\(id))", "desc": "", "tro": "Test order", "auth": "Test Authority",
        "authCode": 9001, "orp": "permanentNoticeOfMaking", "temporary": false, "cond": cond,
        "schema": "4.0.0", "geomQuality": "kerb",
        "geom": ["type": "line", "coords": [[[-0.1, 51.5], [-0.1005, 51.5]]]],
    ]
    for (key, value) in extra { body[key] = value }
    let data = try! JSONSerialization.data(withJSONObject: body)
    return try! LocisDecoding.decoder().decode(Feature.self, from: data)
}

func bay(_ id: String = "primary", cond: JSON = always, _ extra: JSON = [:]) -> Feature {
    feature(id, cond: cond, extra)
}

func paidBay(_ id: String = "primary", cond: JSON, _ extra: JSON = [:]) -> Feature {
    feature(id, reg: "kerbsidePaymentParkingPlace", cat: "paid", cond: cond, extra)
}

func noWaiting(_ id: String = "primary", cond: JSON = always, _ extra: JSON = [:]) -> Feature {
    feature(id, reg: "kerbsideNoWaiting", role: "prohibition", cat: "noWaiting", cond: cond, extra)
}

// MARK: Evaluation

let testHolidays = HolidayCalendar(
    from: "2025-01-01", to: "2028-12-31",
    dates: ["2026-04-03", "2026-04-06", "2026-05-04", "2026-05-25", "2026-08-31", "2026-12-25", "2026-12-28"],
    goodFridays: ["2026-04-03"])

/// Evaluate `primary` with `others` covering the same kerb.
func evaluate(
    _ primary: Feature, with others: [Feature] = [], _ stay: Stay,
    profile: VehicleProfile = .standard, incomplete: Bool = false
) -> ParkingEvaluation {
    let linked = relinked(primary, related: others.map(\.id))
    var context: [String: Feature] = [linked.id: linked]
    for other in others { context[other.id] = other }
    return ParkingRulesEngine(holidays: testHolidays)
        .evaluate(linked, context: context, stay: stay, profile: profile, dataIncomplete: incomplete)
}

/// A copy of a feature whose `related` list names the given features.
func relinked(_ feature: Feature, related: [String], partial: [String] = []) -> Feature {
    Feature(
        id: feature.id, dtro: feature.dtro, prov: feature.prov, reg: feature.reg, role: feature.role,
        cat: feature.cat, name: feature.name, desc: feature.desc, tro: feature.tro, auth: feature.auth,
        authCode: feature.authCode, orp: feature.orp, temporary: feature.temporary, cond: feature.cond,
        schema: feature.schema, lifecycle: feature.lifecycle, offList: feature.offList, from: feature.from,
        until: feature.until, overrides: feature.overrides, activity: feature.activity,
        updated: feature.updated, published: feature.published, geom: feature.geom,
        geomQuality: feature.geomQuality, lateral: feature.lateral, issues: feature.issues,
        related: related.isEmpty ? feature.related : related,
        partial: partial.isEmpty ? feature.partial : partial, zones: feature.zones)
}

func seconds(_ evaluation: ParkingEvaluation, _ status: ParkingStatus) -> Int {
    Int(evaluation.segments.filter { $0.status == status }.reduce(0) { $0 + $1.interval.duration })
}
