import Foundation
import Testing

@testable import LocisKit

/// A diagnostic, not a test of fixed expectations: evaluates a real dataset built by
/// the pipeline and prints what the app would show. It only runs when
/// LOCIS_DATASET_DIR points at a folder containing manifest.json, for example
///
///     LOCIS_DATASET_DIR=$PWD/../../pipeline/dist swift test --filter RealDataset
///
/// It still asserts the safety properties, which must hold for any data.
@Suite("Real dataset diagnostics")
struct RealDatasetDiagnostics {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["LOCIS_DATASET_DIR"].map { URL(fileURLWithPath: $0) }
    }

    @Test(.enabled(if: RealDatasetDiagnostics.directory != nil))
    func evaluateEveryFeature() throws {
        let root = try #require(Self.directory)
        let decoder = LocisDecoding.decoder()
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let engine = ParkingRulesEngine(holidays: manifest.holidays)
        // A weekday afternoon and a Sunday morning, relative to when the data was built.
        let calendar = LondonCalendar.shared
        var day = calendar.localDay(of: manifest.generatedAt)
        while calendar.weekday(day) != 2 { day = calendar.day(day, addingDays: 1) }  // next Tuesday
        let weekday = try Stay(arrival: calendar.date(day, secondsOfDay: 14 * 3600), departure: calendar.date(day, secondsOfDay: 16 * 3600))
        let sunday = calendar.day(day, addingDays: 5)
        let weekend = try Stay(arrival: calendar.date(sunday, secondsOfDay: 10 * 3600), departure: calendar.date(sunday, secondsOfDay: 12 * 3600))

        var statuses: [String: [ParkingStatus: Int]] = ["weekday": [:], "sunday": [:]]
        var confidence: [Confidence: Int] = [:]
        var unknownReasons: [String: Int] = [:]
        var conditionalReasons: [String: Int] = [:]
        var undecodable = 0, drawn = 0, largestTile = 0, tiles = 0, withCost = 0, paid = 0, hidden = 0
        var seen = Set<String>()
        let clock = ContinuousClock()
        var evaluating = Duration.zero

        for (key, hash) in manifest.tiles {
            let parts = key.split(separator: "/")
            let url = root.appendingPathComponent("tiles/\(manifest.tileZoom)/\(parts[0])/\(parts[1])-\(hash).json")
            let tile = try decoder.decode(Tile.self, from: Data(contentsOf: url))
            tiles += 1
            undecodable += tile.undecodable
            largestTile = max(largestTile, tile.features.count)
            let context = Dictionary((tile.features + tile.context).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for feature in tile.features where ParkingMapModel.isDrawn(feature) && seen.insert(feature.id).inserted {
                drawn += 1
                for (name, stay) in [("weekday", weekday), ("sunday", weekend)] {
                    var result: ParkingEvaluation!
                    evaluating += clock.measure {
                        result = engine.evaluate(feature, context: context, stay: stay, profile: .standard)
                    }
                    if result.noRuleInForce { if name == "weekday" { hidden += 1 }; continue }
                    statuses[name]![result.status, default: 0] += 1
                    if result.status.isAllowed {
                        #expect(result.confidence >= .medium)
                        #expect(result.segments.allSatisfy { $0.status.isAllowed })
                    }
                    if result.estimatedCost != nil { #expect(result.status == .allowedPaid) }
                    guard name == "weekday" else { continue }
                    confidence[result.confidence, default: 0] += 1
                    if result.status == .allowedPaid { paid += 1; if result.estimatedCost != nil { withCost += 1 } }
                    if result.status == .unknown { unknownReasons[result.reasons.last ?? "?", default: 0] += 1 }
                    if result.status == .conditional { conditionalReasons[result.reasons.first ?? "?", default: 0] += 1 }
                }
            }
        }

        func line(_ counts: [ParkingStatus: Int]) -> String {
            ParkingStatus.allCases.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined(separator: "  ")
        }
        print("REAL tiles=\(tiles) drawn=\(drawn) undecodable=\(undecodable) largestTileFeatures=\(largestTile)")
        print("REAL weekday 14:00-16:00  \(line(statuses["weekday"]!))")
        print("REAL sunday  10:00-12:00  \(line(statuses["sunday"]!))")
        print("REAL confidence \(confidence.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: "  "))")
        print("REAL paid=\(paid) withCost=\(withCost) hiddenNoRuleInForce=\(hidden)")
        print("REAL evaluation time \(evaluating) for \(drawn * 2) evaluations")
        for (reason, count) in unknownReasons.sorted(by: { $0.value > $1.value }).prefix(12) {
            print("REAL unknown \(count): \(reason.prefix(150))")
        }
        for (reason, count) in conditionalReasons.sorted(by: { $0.value > $1.value }).prefix(8) {
            print("REAL conditional \(count): \(reason.prefix(150))")
        }
    }
}
