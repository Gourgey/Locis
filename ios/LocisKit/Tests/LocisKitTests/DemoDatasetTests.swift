import Foundation
import Testing

@testable import LocisKit

/// End-to-end tests: the synthetic dataset built by the Python pipeline, read and
/// evaluated by the Swift engine. Regenerate with `scripts/build-demo-data.sh`.
struct DemoDataset {
    let manifest: Manifest
    let features: [String: Feature]
    let undecodable: Int

    static let shared: DemoDataset = {
        let root = DemoData.directory
        let decoder = LocisDecoding.decoder()
        let manifest = try! decoder.decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        var features: [String: Feature] = [:]
        var undecodable = 0
        for (key, hash) in manifest.tiles {
            let parts = key.split(separator: "/")
            let url = root.appendingPathComponent("tiles/\(manifest.tileZoom)/\(parts[0])/\(parts[1])-\(hash).json")
            let tile = try! decoder.decode(Tile.self, from: Data(contentsOf: url))
            undecodable += tile.undecodable
            for feature in tile.features + tile.context { features[feature.id] = feature }
        }
        return DemoDataset(manifest: manifest, features: features, undecodable: undecodable)
    }()

    /// The feature for a numbered scenario, e.g. `scenario(13, "paid bay")`.
    func scenario(_ number: Int, _ label: String = "") -> Feature {
        let tag = String(format: "demo %02d: %@", number, label)
        let matches = features.values.filter { $0.name.contains(tag) }
        precondition(matches.count == 1, "expected one feature for \(tag), found \(matches.count)")
        return matches[0]
    }

    func evaluate(_ feature: Feature, _ stay: Stay, profile: VehicleProfile = .standard) -> ParkingEvaluation {
        ParkingRulesEngine(holidays: manifest.holidays).evaluate(feature, context: features, stay: stay, profile: profile)
    }

    func status(_ number: Int, _ label: String = "", _ arrival: String, _ departure: String, profile: VehicleProfile = .standard) -> ParkingStatus {
        evaluate(scenario(number, label), stay(arrival, departure), profile: profile).status
    }
}

@Suite("Demo dataset end to end")
struct DemoDatasetTests {
    let demo = DemoDataset.shared
    // Monday 5 October 2026, mid-afternoon.
    let monday = ("2026-10-05 14:00", "2026-10-05 16:00")

    @Test func datasetIsReadableAndLabelledSynthetic() {
        #expect(demo.manifest.synthetic)
        #expect(demo.manifest.notice != nil)
        #expect(demo.manifest.formatVersion == 1)
        #expect(demo.manifest.minEngineVersion <= ParkingRulesEngine.engineVersion)
        #expect(demo.undecodable == 0)
        #expect(demo.features.count == demo.manifest.counts.features)
        #expect(demo.manifest.source.attribution == "Contains public sector information licensed under the Open Government Licence v3.0.")
    }

    @Test func everyStatusIsRepresented() {
        let statuses = Set(demo.features.values.filter(\.isKerbLine).map { demo.evaluate($0, stay(monday.0, monday.1)).status })
        #expect(statuses == Set(ParkingStatus.allCases))
    }

    @Test func freePaidAndPermit() {
        #expect(demo.status(1, "", monday.0, monday.1) == .allowedFree)
        #expect(demo.status(2, "", monday.0, monday.1) == .allowedPaid)
        #expect(demo.status(3, "", monday.0, monday.1) == .allowedPaid)
        #expect(demo.status(4, "", monday.0, monday.1) == .conditional)
        #expect(demo.status(6, "", monday.0, monday.1) == .prohibited)
        #expect(demo.status(7, "", monday.0, monday.1) == .prohibited)
        #expect(demo.status(7, "", "2026-10-05 19:00", "2026-10-05 22:00") == .allowedFree)
    }

    @Test func briefExamplePaidUntilSaturdayLunchtime() {
        let result = demo.evaluate(demo.scenario(2), stay("2026-10-03 12:00", "2026-10-03 15:00"))
        #expect(result.status == .allowedPaid)
        #expect(result.chargeableSeconds == 5400)
        #expect(result.estimatedCost?.amount == Decimal(string: "7.20"))
        #expect(result.estimatedCost?.hourlyRate == Decimal(string: "4.80"))
        #expect(result.limits.maxStay == 4 * 3600)
        #expect(result.limits.noReturn == 3600)
        #expect(result.confidence == .medium)
    }

    @Test func tariffAndMaxStay() {
        let twoHours = demo.evaluate(demo.scenario(2), stay(monday.0, monday.1))
        #expect(twoHours.estimatedCost?.amount == Decimal(string: "9.60"))
        #expect(twoHours.confidence == .high)
        #expect(demo.status(2, "", "2026-10-05 10:00", "2026-10-05 14:30") == .prohibited)  // over 4 hours
        let noTariff = demo.evaluate(demo.scenario(3), stay(monday.0, monday.1))
        #expect(noTariff.estimatedCost == nil && noTariff.costNote != nil)
        #expect(demo.status(5, "", "2026-10-05 10:00", "2026-10-05 12:00") == .allowedFree)
        #expect(demo.status(5, "", "2026-10-05 10:00", "2026-10-05 12:01") == .prohibited)
        #expect(demo.status(27, "", "2026-10-05 10:00", "2026-10-05 10:45") == .prohibited)
    }

    @Test func specialistBays() {
        let badge = VehicleProfile(blueBadge: true)
        let rider = VehicleProfile(vehicleType: .motorcycle)
        #expect(demo.status(8, "", monday.0, monday.1) == .specialist)
        #expect(demo.status(8, "", monday.0, monday.1, profile: badge) == .allowedFree)
        #expect(demo.status(8, "", "2026-10-05 10:00", "2026-10-05 14:00", profile: badge) == .prohibited)  // 3 hour limit
        #expect(demo.status(9, "", monday.0, monday.1) == .specialist)
        #expect(demo.status(10, "", monday.0, monday.1) == .specialist)
        #expect(demo.status(10, "", monday.0, monday.1, profile: rider) == .allowedFree)
        #expect(demo.status(23, "", monday.0, monday.1) == .specialist)
    }

    @Test func suspensionAndTemporaryRestriction() {
        let paid = demo.evaluate(demo.scenario(11, "paid bay"), stay(monday.0, monday.1))
        #expect(paid.status == .allowedPaid)
        // Exactly two hours falls in the band that starts at 02:00:00.
        #expect(paid.estimatedCost?.amount == 8)
        let shorter = demo.evaluate(demo.scenario(11, "paid bay"), stay("2026-10-05 14:00", "2026-10-05 15:59"))
        #expect(shorter.estimatedCost?.amount == Decimal(string: "4.50"))
        #expect(demo.status(11, "paid bay", "2026-10-07 14:00", "2026-10-07 16:00") == .prohibited)  // Wednesday
        #expect(demo.status(12, "free bay", monday.0, monday.1) == .prohibited)
        #expect(demo.status(12, "free bay", "2026-10-05 18:00", "2026-10-05 20:00") == .allowedFree)
        #expect(demo.status(12, "free bay", "2027-07-05 14:00", "2027-07-05 16:00") == .allowedFree)  // after the works
        #expect(demo.status(22, "free bay", monday.0, monday.1) == .conditional)
    }

    @Test func overlapsAndConflicts() {
        #expect(demo.status(13, "paid bay", "2026-10-05 10:00", "2026-10-05 12:00") == .allowedPaid)
        #expect(demo.status(13, "paid bay", "2026-10-05 15:00", "2026-10-05 17:00") == .prohibited)
        #expect(demo.status(14, "shared-use paid bay", monday.0, monday.1) == .allowedPaid)
        #expect(demo.status(14, "shared-use permit bay", monday.0, monday.1) == .allowedPaid)
        #expect(demo.status(15, "paid bay", monday.0, monday.1) == .unknown)
        #expect(demo.status(33, "bay partly", monday.0, monday.1) == .prohibited)
    }

    @Test func unsupportedAndUnknown() {
        #expect(demo.status(16, "", monday.0, monday.1) == .unknown)
        #expect(demo.status(17, "", monday.0, monday.1) == .unknown)
        #expect(demo.status(24, "", monday.0, monday.1) == .unknown)
        #expect(demo.status(28, "", monday.0, monday.1) == .unknown)
        #expect(demo.status(30, "", monday.0, monday.1) == .unknown)
        #expect(demo.status(31, "bay with", monday.0, monday.1) == .unknown)
    }

    @Test func remainingScenarios() {
        #expect(demo.status(18, "", "2026-12-25 10:00", "2026-12-25 12:00") == .allowedFree)  // bank holiday
        #expect(demo.status(18, "", monday.0, monday.1) == .allowedPaid)
        #expect(demo.status(19, "", monday.0, monday.1) == .allowedFree)
        #expect(demo.status(19, "", monday.0, monday.1, profile: VehicleProfile(vehicleType: .van)) == .prohibited)
        #expect(demo.status(20, "", monday.0, monday.1) == .prohibited)
        #expect(demo.status(21, "", "2026-10-05 10:00", "2026-10-05 14:00") == .allowedFree)
        #expect(demo.status(21, "", monday.0, "2026-10-05 15:00") == .prohibited)
        #expect(demo.status(25, "", "2026-10-05 21:00", "2026-10-06 07:00") == .prohibited)
        #expect(demo.status(25, "", "2026-10-05 08:00", "2026-10-05 20:00") == .allowedFree)
        #expect(demo.evaluate(demo.scenario(26), stay(monday.0, monday.1)).estimatedCost?.amount == 6)
        #expect(demo.status(29, "", monday.0, monday.1) == .conditional)  // legacy v3.5.1 record
        #expect(demo.status(32, "", monday.0, monday.1) == .conditional)
        #expect(demo.status(32, "", monday.0, monday.1, profile: VehicleProfile(blueBadge: true)) == .allowedFree)
        let centreline = demo.evaluate(demo.scenario(35), stay(monday.0, monday.1))
        #expect(centreline.status == .prohibited && centreline.confidence == .medium)
    }

    @Test func realWorldPublishingHabits() {
        // 39: "No stopping except buses" published as "applies to buses".
        #expect(demo.status(39, "", monday.0, monday.1) == .prohibited)
        // 40: no waiting with an exemption list; not relaxed even for a Blue Badge.
        #expect(demo.status(40, "", monday.0, monday.1) == .prohibited)
        #expect(demo.status(40, "", monday.0, monday.1, profile: VehicleProfile(blueBadge: true)) == .prohibited)
        #expect(demo.scenario(40).hasIssue("exemptionList"))
        // 41: electric vehicle bay.
        #expect(demo.status(41, "", monday.0, monday.1) == .conditional)
    }

    @Test func areasPointsAndZonesAreNotKerbLines() {
        #expect(!demo.scenario(34).isKerbLine)
        #expect(!demo.scenario(36).isKerbLine)
        #expect(!demo.scenario(37).isKerbLine)
        #expect(demo.scenario(1).zones == [demo.scenario(37).id])
    }

    /// The core safety property, checked across every feature, many stays and
    /// every profile: an "available" answer is never built on doubt.
    @Test func availableIsNeverBuiltOnUncertainty() {
        let stays = [
            stay("2026-10-05 14:00", "2026-10-05 16:00"), stay("2026-10-03 12:00", "2026-10-03 15:00"),
            stay("2026-10-04 09:00", "2026-10-04 23:00"), stay("2026-10-05 17:00", "2026-10-06 09:00"),
            stay("2026-10-07 05:00", "2026-10-07 21:00"), stay("2026-10-24 22:00", "2026-10-25 06:00"),
            stay("2026-12-25 00:00", "2026-12-26 00:00"), stay("2026-10-05 08:29", "2026-10-05 08:31"),
            stay("2025-06-02 10:00", "2025-06-02 11:00"), stay("2031-06-02 10:00", "2031-06-09 10:00"),
        ]
        var profiles: [VehicleProfile] = []
        for type in VehicleType.allCases {
            for badge in [false, true] { profiles.append(VehicleProfile(vehicleType: type, blueBadge: badge)) }
        }
        var evaluated = 0
        for feature in demo.features.values {
            for period in stays {
                for profile in profiles {
                    let result = demo.evaluate(feature, period, profile: profile)
                    evaluated += 1
                    if result.status.isAllowed {
                        #expect(result.confidence >= .medium, "\(feature.name)")
                        #expect(result.segments.allSatisfy { $0.status.isAllowed }, "\(feature.name)")
                        // Some rule that is actually in force must stand behind it.
                        let deciding = result.applicableRuleIDs.compactMap { demo.features[$0] }
                        #expect(
                            deciding.contains { ($0.role == .permission || $0.role == .prohibition) && $0.lifecycle == nil },
                            "\(feature.name)")
                    }
                    if result.status == .unknown { #expect(result.confidence == .unknown) }
                    if result.estimatedCost != nil { #expect(result.status == .allowedPaid) }
                    if result.status == .allowedFree { #expect(!result.paymentRequired) }
                    // Segments tile the stay exactly.
                    if !result.segments.isEmpty {
                        #expect(result.segments.first?.interval.start == period.arrival)
                        #expect(result.segments.last?.interval.end == period.departure)
                    }
                }
            }
        }
        #expect(evaluated > 3000)
    }

    @Test func beforeTheDemoOrdersCommenceNothingIsAvailable() {
        // Every demo order came into force on 1 January 2026.
        for feature in demo.features.values where feature.isKerbLine {
            let result = demo.evaluate(feature, stay("2025-06-02 10:00", "2025-06-02 11:00"))
            #expect(result.status == .unknown, "\(feature.name)")
        }
    }
}
