import Foundation
import Testing

@testable import LocisKit

private func rate(_ json: JSON) -> RateTable {
    try! LocisDecoding.decoder().decode(RateTable.self, from: JSONSerialization.data(withJSONObject: json))
}

private func cost(_ table: RateTable, hours: Double, from start: String = "2026-10-05 10:00") -> CostEstimate? {
    let begin = london(start)
    let seconds = Int(hours * 3600)
    return CostCalculator.estimate(
        rate: table, chargeableSeconds: seconds, sessionStart: begin, sessionEnd: begin.addingTimeInterval(Double(seconds)))
}

@Suite("Tariffs")
struct CostTests {
    let tiers = rate([
        "collections": [
            [
                "currency": "GBP", "seq": 1, "maxTime": 14400,
                "lines": [
                    ["seq": 1, "type": "flatRateTier", "start": 0, "end": 3600, "value": 2.5],
                    ["seq": 2, "type": "flatRateTier", "start": 3601, "end": 7200, "value": 4.5],
                    ["seq": 3, "type": "flatRateTier", "start": 7201, "end": 14400, "value": 8.0],
                ],
            ]
        ]
    ])

    @Test func incrementsRoundUpToTheNextUnit() {
        let table = rate(perQuarterHour(1.2))
        #expect(cost(table, hours: 1)?.amount == Decimal(string: "4.80"))
        #expect(cost(table, hours: 1.01)?.amount == Decimal(string: "6.00"))
        #expect(cost(table, hours: 0.1)?.amount == Decimal(string: "1.20"))
    }

    @Test func tiersPickTheBandContainingTheStay() {
        #expect(cost(tiers, hours: 0.5)?.amount == Decimal(string: "2.5"))
        #expect(cost(tiers, hours: 1)?.amount == Decimal(string: "2.5"))
        #expect(cost(tiers, hours: 1.5)?.amount == Decimal(string: "4.5"))
        #expect(cost(tiers, hours: 4)?.amount == 8)
    }

    @Test func stayBeyondTheTariffIsNotPriced() {
        #expect(cost(tiers, hours: 4.5) == nil)
    }

    @Test func overlappingTiersAreAmbiguousSoNotPriced() {
        // The shape of DfT's own example: two tiers both cover 1h30.
        let ambiguous = rate([
            "collections": [
                [
                    "currency": "GBP",
                    "lines": [
                        ["seq": 1, "type": "flatRateTier", "start": 60, "end": 7200, "value": 3.2],
                        ["seq": 2, "type": "flatRateTier", "start": 3600, "end": 7200, "value": 4.2],
                    ],
                ]
            ]
        ])
        #expect(cost(ambiguous, hours: 1.5) == nil)
        #expect(cost(ambiguous, hours: 0.5)?.amount == Decimal(string: "3.2"))
    }

    @Test func dailyFlatRateOnlyWithinOneDay() {
        let daily = rate(["type": "daily", "collections": [["currency": "GBP", "lines": [["seq": 1, "type": "flatRate", "value": 6]]]]])
        #expect(cost(daily, hours: 5)?.amount == 6)
        #expect(cost(daily, hours: 20) == nil)  // runs into the next day
    }

    @Test func minimumAndMaximumChargesApply() {
        var json = perQuarterHour(1.0)
        var collection = (json["collections"] as! [JSON])[0]
        collection["minValue"] = 3.0
        collection["maxValue"] = 10.0
        collection["minTime"] = 1800
        json["collections"] = [collection]
        let table = rate(json)
        #expect(cost(table, hours: 0.25)?.amount == 3)  // 2 units by minimum time, then minimum charge
        #expect(cost(table, hours: 2)?.amount == 8)
        #expect(cost(table, hours: 5)?.amount == 10)
    }

    @Test func unsupportedTariffsAreNotPriced() {
        let euros = rate(["collections": [["currency": "EUR", "lines": [["seq": 1, "type": "flatRate", "value": 6]]]]])
        #expect(cost(euros, hours: 1) == nil)
        let noIncrement = rate(["collections": [["currency": "GBP", "lines": [["seq": 1, "type": "incrementingRate", "value": 2]]]]])
        #expect(cost(noIncrement, hours: 1) == nil)
        // "perUnit" does not say what the unit is.
        let perUnit = rate(["collections": [["currency": "GBP", "lines": [["seq": 1, "type": "perUnit", "increment": 900, "value": 2]]]]])
        #expect(cost(perUnit, hours: 1) == nil)
        let mixed = rate([
            "collections": [
                [
                    "currency": "GBP",
                    "lines": [
                        ["seq": 1, "type": "flatRate", "value": 1], ["seq": 2, "type": "incrementingRate", "increment": 900, "value": 1],
                    ],
                ]
            ]
        ])
        #expect(cost(mixed, hours: 1) == nil)
        let expired = rate([
            "collections": [["currency": "GBP", "to": "2026-01-01T00:00:00Z", "lines": [["seq": 1, "type": "flatRate", "value": 6]]]]
        ])
        #expect(cost(expired, hours: 1) == nil)
        let two = rate([
            "collections": [
                ["currency": "GBP", "lines": [["seq": 1, "type": "flatRate", "value": 6]]],
                ["currency": "GBP", "lines": [["seq": 1, "type": "flatRate", "value": 7]]],
            ]
        ])
        #expect(cost(two, hours: 1) == nil)
    }

    @Test func tariffThatResetsOrEndsDuringTheStayIsNotPriced() {
        var json = perQuarterHour(1.0)
        var collection = (json["collections"] as! [JSON])[0]
        collection["resetTime"] = 12 * 3600
        json["collections"] = [collection]
        let resets = rate(json)
        #expect(cost(resets, hours: 1, from: "2026-10-05 10:00")?.amount == 4)
        #expect(cost(resets, hours: 3, from: "2026-10-05 10:00") == nil)  // crosses 12:00

        collection["resetTime"] = nil
        collection["to"] = "2026-10-05T10:30:00Z"  // 11:30 in London
        json["collections"] = [collection]
        let ends = rate(json)
        #expect(cost(ends, hours: 1, from: "2026-10-05 10:00")?.amount == 4)
        #expect(cost(ends, hours: 2, from: "2026-10-05 10:00") == nil)
    }

    @Test func lineLimitedToABandOnlyPricesStaysInsideIt() {
        var json = perQuarterHour(1.0)
        var collection = (json["collections"] as! [JSON])[0]
        var line = (collection["lines"] as! [JSON])[0]
        line["start"] = 0
        line["end"] = 7200
        collection["lines"] = [line]
        json["collections"] = [collection]
        let banded = rate(json)
        #expect(cost(banded, hours: 2)?.amount == 8)
        #expect(cost(banded, hours: 3) == nil)
    }

    @Test func twoDifferentTariffsAtOnceAreNotPriced() {
        let bay = paidBay(
            cond: [
                "op": "and",
                "items": [time([period(monSat, [("08:30", "18:30")])], rate: perQuarterHour(1.0))],
                "rate": perQuarterHour(2.0),
            ])
        let result = evaluate(bay, stay("2026-10-05 10:00", "2026-10-05 11:00"))
        #expect(result.status == .allowedPaid)
        #expect(result.estimatedCost == nil)
    }
}

@Suite("Decoding tiles and manifests")
struct DecodingTests {
    @Test func tileWithAnUnreadableFeatureReportsIt() throws {
        let good = try JSONSerialization.jsonObject(
            with: JSONSerialization.data(withJSONObject: [
                "id": "a", "dtro": "d", "prov": "p", "reg": "kerbsideParkingPlace", "role": "permission",
                "cat": "standard", "name": "n", "desc": "", "tro": "", "temporary": false,
                "cond": ["time": ["start": "2020-01-01T00:00:00Z"]], "geomQuality": "kerb",
                "geom": ["type": "line", "coords": [[[-0.1, 51.5], [-0.11, 51.5]]]],
            ]))
        let bad: JSON = ["id": "b", "geom": ["type": "hexagon", "coords": []]]
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "z": 15, "x": 1, "y": 2, "features": [good, bad]])
        let tile = try LocisDecoding.decoder().decode(Tile.self, from: data)
        #expect(tile.features.count == 1)
        #expect(tile.undecodable == 1)
    }

    @Test func outOfRangeCoordinatesAreRejected() {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "line", "coords": [[[530000.0, 180000.0], [530100.0, 180000.0]]]])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Geometry.self, from: data) }
    }

    @Test func geometryKinds() throws {
        func decode(_ json: JSON) throws -> Geometry {
            try JSONDecoder().decode(Geometry.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let line = try decode(["type": "line", "coords": [[[-0.1, 51.5], [-0.11, 51.5]], [[-0.12, 51.5], [-0.13, 51.5]]]])
        guard case .line(let parts) = line else { Issue.record("expected a line"); return }
        #expect(parts.count == 2)
        let polygon = try decode(["type": "polygon", "coords": [[[[-0.1, 51.5], [-0.11, 51.5], [-0.11, 51.51], [-0.1, 51.5]]]]])
        #expect(polygon.representativeCoordinate != nil)
        let point = try decode(["type": "point", "coords": [[-0.1, 51.5]]])
        #expect(point.representativeCoordinate == Coordinate(longitude: -0.1, latitude: 51.5))
    }

    @Test func unknownEnumValuesDecodeToSafeFallbacks() throws {
        let unknown = feature(cat: "hoverBay", cond: always, ["geomQuality": "wormhole", "lifecycle": "limbo"])
        #expect(unknown.cat == .other)
        #expect(unknown.geomQuality == .unrecognised)
        #expect(unknown.lifecycle == .unrecognised)
        #expect(evaluate(unknown, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .unknown)
    }

    @Test func holidayCalendarKnowsItsLimits() {
        #expect(testHolidays.isBankHoliday("2026-12-25") == true)
        #expect(testHolidays.isBankHoliday("2026-12-24") == false)
        #expect(testHolidays.isBankHoliday("2031-12-25") == nil)
        #expect(HolidayCalendar.empty.isBankHoliday("2026-12-25") == nil)
    }
}
