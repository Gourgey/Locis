import Foundation
import Testing

@testable import LocisKit

/// A provider whose behaviour the test controls.
actor ScriptedProvider: ParkingDataProviding {
    let demo = DemoDataProvider(directory: DemoData.directory)
    var manifestError: ParkingDataError?
    var fromCache = false
    var failTiles = false
    var minEngineVersion: Int?
    private(set) var loadCalls: [[TileCoordinate]] = []
    private(set) var manifestCalls = 0

    func set(manifestError: ParkingDataError? = nil, fromCache: Bool = false, failTiles: Bool = false, minEngineVersion: Int? = nil) {
        self.manifestError = manifestError
        self.fromCache = fromCache
        self.failTiles = failTiles
        self.minEngineVersion = minEngineVersion
    }

    func manifest(refresh: Bool) async throws -> ManifestState {
        manifestCalls += 1
        if let manifestError { throw manifestError }
        var state = try await demo.manifest(refresh: refresh)
        if let minEngineVersion {
            let url = DemoData.directory.appendingPathComponent("manifest.json")
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            json["minEngineVersion"] = minEngineVersion
            let manifest = try LocisDecoding.decoder().decode(Manifest.self, from: JSONSerialization.data(withJSONObject: json))
            state = ManifestState(manifest: manifest, fetchedAt: state.fetchedAt, isFromCache: false)
        }
        return ManifestState(manifest: state.manifest, fetchedAt: state.fetchedAt, isFromCache: fromCache)
    }

    func load(_ tiles: [TileCoordinate], using manifest: Manifest) async -> LoadedArea {
        loadCalls.append(tiles)
        if failTiles {
            var area = LoadedArea()
            area.failedTiles = Set(tiles.filter { manifest.tiles[$0.key] != nil })
            area.emptyTiles = Set(tiles.filter { manifest.tiles[$0.key] == nil })
            return area
        }
        return await demo.load(tiles, using: manifest)
    }
}

@MainActor
@Suite("Map model")
struct MapModelTests {
    let quarter = BoundingBox(west: -0.2800, south: 51.4365, east: -0.2724, north: 51.4399)
    let centralLondon = BoundingBox(west: -0.130, south: 51.505, east: -0.120, north: 51.510)
    let monday = StaySelection(arrival: london("2026-10-05 14:00"), departure: london("2026-10-05 16:00"))

    func makeModel(_ provider: ScriptedProvider = ScriptedProvider()) -> (ParkingMapModel, ScriptedProvider) {
        (ParkingMapModel(provider: provider, selection: monday, debounce: .zero), provider)
    }

    func item(_ model: ParkingMapModel, _ tag: String) -> MapItem? {
        model.items.first { $0.name.contains(tag) }
    }

    @Test func loadsAndEvaluatesTheVisibleArea() async {
        let (model, _) = makeModel()
        model.viewportChanged(quarter)
        await model.settle()
        #expect(model.phase == .ready)
        #expect(model.notice == nil)
        #expect(model.isDemo)
        #expect(item(model, "demo 01")?.status == .allowedFree)
        #expect(item(model, "demo 02")?.status == .allowedPaid)
        #expect(item(model, "demo 06")?.status == .prohibited)
        #expect(model.zones.count == 1)
    }

    @Test func changingTheStayReevaluatesWithoutReloading() async {
        let (model, provider) = makeModel()
        model.viewportChanged(quarter)
        await model.settle()
        let calls = await provider.loadCalls.count
        #expect(item(model, "demo 07")?.status == .prohibited)
        model.selection = StaySelection(arrival: london("2026-10-05 19:00"), departure: london("2026-10-05 21:00"))
        await model.settle()
        #expect(item(model, "demo 07")?.status == .allowedFree)
        #expect(item(model, "demo 02")?.status == .allowedFree)
        #expect(await provider.loadCalls.count == calls)
    }

    @Test func changingTheProfileReevaluates() async {
        let (model, _) = makeModel()
        model.viewportChanged(quarter)
        await model.settle()
        #expect(item(model, "demo 08")?.status == .specialist)
        model.profile = VehicleProfile(blueBadge: true)
        await model.settle()
        #expect(item(model, "demo 08")?.status == .allowedFree)
    }

    @Test func smallMapMovementsDoNotRequestAgain() async {
        let (model, provider) = makeModel()
        model.viewportChanged(quarter)
        await model.settle()
        let calls = await provider.loadCalls.count
        let nudged = BoundingBox(west: quarter.west + 0.0003, south: quarter.south, east: quarter.east + 0.0003, north: quarter.north)
        model.viewportChanged(nudged)
        await model.settle()
        #expect(await provider.loadCalls.count == calls)
    }

    @Test func rapidMovementsAreDebouncedToOneRequest() async {
        let provider = ScriptedProvider()
        let model = ParkingMapModel(provider: provider, selection: monday, debounce: .milliseconds(80))
        for step in 0..<6 {
            let shift = Double(step) * 0.01
            model.viewportChanged(BoundingBox(west: -0.3 + shift, south: 51.43, east: -0.29 + shift, north: 51.44))
        }
        model.viewportChanged(quarter)
        await model.settle()
        #expect(await provider.manifestCalls == 1)
        #expect(await provider.loadCalls.count == 1)
    }

    @Test func areaWithoutDataSaysSoAndDrawsNothing() async {
        let (model, _) = makeModel()
        model.viewportChanged(centralLondon)
        await model.settle()
        #expect(model.phase == .ready)
        #expect(model.notice == .noDataHere)
        #expect(model.items.isEmpty)
        #expect(model.notice?.message == "No reliable parking data is available here yet.")
        #expect(model.coverage == .unknown)
    }

    @Test func kerbsWithNoLineAreOnlyExplainedWhereDataIsDense() {
        typealias Model = ParkingMapModel
        let a = TileCoordinate(x: 1, y: 1, z: 15)
        let b = TileCoordinate(x: 2, y: 1, z: 15)
        let dense = Model.denseRulesPerTile
        // Plenty of rules in every visible tile.
        #expect(Model.coverage(of: [a, b], published: [a.key, b.key], ruleCount: [a: dense * 3, b: dense]) == .dense)
        // A handful of orders is not a published network.
        #expect(Model.coverage(of: [a, b], published: [a.key, b.key], ruleCount: [a: 6, b: 3]) == .sparse)
        #expect(Model.coverage(of: [a], published: [a.key], ruleCount: [a: dense - 1]) == .sparse)
        // A neighbouring tile with nothing published: the area is not covered.
        #expect(Model.coverage(of: [a, b], published: [a.key], ruleCount: [a: dense * 10]) == .sparse)
        // A published tile that has not loaded counts for nothing.
        #expect(Model.coverage(of: [a, b], published: [a.key, b.key], ruleCount: [a: dense * 2 - 1]) == .sparse)
        #expect(Model.coverage(of: [a], published: [], ruleCount: [:]) == .unknown)
        #expect(Model.coverage(of: [], published: [a.key], ruleCount: [a: dense]) == .unknown)
        // The wording never calls an unmarked kerb free.
        for coverage in [Model.Coverage.unknown, .sparse, .dense] {
            #expect(!coverage.unmarkedKerbMessage.localizedCaseInsensitiveContains("free to park"))
            #expect(!coverage.unmarkedKerbMessage.localizedCaseInsensitiveContains("you can park"))
        }
        #expect(Model.Coverage.dense.unmarkedKerbMessage.contains("Check signs"))
        #expect(Model.Coverage.sparse.unmarkedKerbMessage == "No line means no data, not free parking.")
    }

    @Test func coverageIsWithdrawnWhenDataCannotBeShown() async {
        let provider = ScriptedProvider()
        let (model, _) = makeModel(provider)
        model.viewportChanged(quarter)
        await model.settle()
        #expect(model.coverage != .unknown)
        model.viewportChanged(BoundingBox(west: -0.5, south: 51.3, east: 0.3, north: 51.7))
        await model.settle()
        #expect(model.coverage == .unknown)
        await provider.set(failTiles: true)
        model.refresh()
        model.viewportChanged(quarter)
        await model.settle()
        #expect(model.coverage == .unknown)
    }

    @Test func zoomedOutMapAsksToZoomIn() async {
        let (model, provider) = makeModel()
        model.viewportChanged(BoundingBox(west: -0.5, south: 51.3, east: 0.3, north: 51.7))
        await model.settle()
        #expect(model.phase == .zoomedOut)
        #expect(model.notice == .zoomIn)
        #expect(model.items.isEmpty)
        #expect(await provider.loadCalls.isEmpty)
    }

    @Test func backendUnavailable() async {
        let provider = ScriptedProvider()
        await provider.set(manifestError: .unavailable)
        let (model, _) = makeModel(provider)
        model.viewportChanged(quarter)
        await model.settle()
        #expect(model.phase == .failed(.unavailable))
        #expect(model.notice?.message == "Parking data is temporarily unavailable.")
        #expect(model.items.isEmpty)
    }

    @Test func offlineWithNoCache() async {
        let provider = ScriptedProvider()
        await provider.set(manifestError: .offline)
        let (model, _) = makeModel(provider)
        model.viewportChanged(quarter)
        await model.settle()
        #expect(model.phase == .failed(.offline))
        #expect(model.notice == .offline)
    }

    @Test func cachedDataIsLabelledWithItsAge() async {
        let provider = ScriptedProvider()
        await provider.set(fromCache: true)
        let (model, _) = makeModel(provider)
        model.viewportChanged(quarter)
        await model.settle()
        guard case .showingCachedData = model.notice else {
            Issue.record("expected a cached-data notice, got \(String(describing: model.notice))")
            return
        }
        #expect(!model.items.isEmpty)
    }

    @Test func failedTilesAreReportedAndRetried() async {
        let provider = ScriptedProvider()
        await provider.set(failTiles: true)
        let (model, _) = makeModel(provider)
        model.viewportChanged(quarter)
        await model.settle()
        #expect(model.notice == .partlyUnavailable)
        #expect(model.items.isEmpty)
        await provider.set(failTiles: false)
        model.viewportChanged(quarter)
        await model.settle()
        #expect(model.notice == nil)
        #expect(!model.items.isEmpty)
    }

    @Test func datasetNeedingNewerAppIsNotInterpreted() async {
        let provider = ScriptedProvider()
        await provider.set(minEngineVersion: ParkingRulesEngine.engineVersion + 1)
        let (model, _) = makeModel(provider)
        model.viewportChanged(quarter)
        await model.settle()
        #expect(model.phase == .failed(.requiresAppUpdate))
        #expect(model.notice == .requiresAppUpdate)
        #expect(model.items.isEmpty)
    }

    @Test func filtersOnlyEverHide() async {
        let (model, _) = makeModel()
        model.viewportChanged(quarter)
        await model.settle()
        let all = model.visibleItems.count
        model.filter = .free
        #expect(model.visibleItems.allSatisfy { $0.status == .allowedFree })
        #expect(!model.visibleItems.isEmpty && model.visibleItems.count < all)
        model.filter = .paid
        #expect(model.visibleItems.allSatisfy { $0.status == .allowedPaid })
        model.filter = .conditional
        #expect(model.visibleItems.allSatisfy { $0.status == .conditional })
        // Unknown items are never promoted into a filter bucket.
        for bucket in [MapFilter.free, .paid, .conditional] {
            model.filter = bucket
            #expect(!model.visibleItems.contains { $0.status == .unknown })
        }
    }

    @Test func invalidTimeRangeEvaluatesNothing() async {
        let (model, _) = makeModel()
        model.viewportChanged(quarter)
        await model.settle()
        model.selection = StaySelection(arrival: london("2026-10-05 16:00"), departure: london("2026-10-05 14:00"))
        await model.settle()
        #expect(model.items.isEmpty)
        #expect(model.selection.problem == .departureNotAfterArrival)
    }

    @Test func suspensionsAreShownThroughTheBayTheyAffect() async {
        let (model, _) = makeModel()
        model.viewportChanged(quarter)
        await model.settle()
        #expect(item(model, "demo 11: market-day suspension") == nil)
        #expect(item(model, "demo 11: paid bay") != nil)
        #expect(item(model, "demo 22: planned") == nil)
        #expect(item(model, "demo 31: revocation") == nil)
    }

    @Test func detailIncludesRelatedRulesAndZones() async {
        let (model, _) = makeModel()
        model.viewportChanged(quarter)
        await model.settle()
        let id = item(model, "demo 13: paid bay")!.id
        let detail = model.detail(for: id)!
        #expect(detail.related.contains { $0.name.contains("peak-hour") })
        #expect(detail.zones.first?.cat == .controlledParkingZone)
        #expect(model.detail(for: "missing") == nil)
    }

    @Test func onlyKerbsNearTheScreenAreEvaluatedAndDrawn() async {
        let (model, provider) = makeModel()
        model.viewportChanged(quarter)
        await model.settle()
        let everything = model.items.count
        // Zoom in on the north-west corner of the demo quarter (around demo 25).
        let corner = BoundingBox(west: -0.2796, south: 51.4393, east: -0.2786, north: 51.4398)
        let calls = await provider.loadCalls.count
        model.viewportChanged(corner)
        await model.settle()
        #expect(item(model, "demo 25") != nil)
        #expect(item(model, "demo 06") == nil)  // far end of the quarter
        #expect(model.items.count < everything / 2)
        #expect(await provider.loadCalls.count == calls)  // tiles were already loaded
        // Panning back brings the rest back without another download.
        model.viewportChanged(quarter)
        await model.settle()
        #expect(model.items.count == everything)
    }

    @Test func areasAndPointsKeepTheirShape() async {
        let (model, _) = makeModel()
        model.viewportChanged(quarter)
        await model.settle()
        if case .area = item(model, "demo 34")!.shape {} else { Issue.record("demo 34 should be an area") }
        if case .point = item(model, "demo 36")!.shape {} else { Issue.record("demo 36 should be a point") }
        if case .line = item(model, "demo 01")!.shape {} else { Issue.record("demo 01 should be a line") }
    }
}

@Suite("Stay selection")
struct StaySelectionTests {
    @Test func suggestionRoundsUpAndLastsTwoHours() {
        let suggested = StaySelection.suggested(now: london("2026-10-05 13:52"))
        #expect(suggested.arrival == london("2026-10-05 14:00"))
        #expect(suggested.departure == london("2026-10-05 16:00"))
        let onTheQuarter = StaySelection.suggested(now: london("2026-10-05 14:15"))
        #expect(onTheQuarter.arrival == london("2026-10-05 14:15"))
        #expect(suggested.problem == nil && suggested.stay != nil)
    }

    @Test func invalidRangesAreRejected() {
        var selection = StaySelection(arrival: london("2026-10-05 14:00"), departure: london("2026-10-05 14:00"))
        #expect(selection.problem == .departureNotAfterArrival)
        #expect(selection.stay == nil)
        selection.departure = london("2026-10-05 13:00")
        #expect(selection.problem == .departureNotAfterArrival)
        selection.departure = london("2026-12-25 13:00")
        #expect(selection.problem == .tooLong)
        selection.departure = london("2026-10-06 09:00")  // overnight is fine
        #expect(selection.problem == nil)
    }

    @Test func movingArrivalKeepsTheLength() {
        var selection = StaySelection(arrival: london("2026-10-05 14:00"), departure: london("2026-10-05 17:00"))
        selection.moveArrival(to: london("2026-10-06 09:00"))
        #expect(selection.departure == london("2026-10-06 12:00"))
        #expect(selection.problem == nil)
    }

    @Test func labels() {
        let now = london("2026-10-03 10:00")
        #expect(StaySelection.label(for: london("2026-10-03 14:00"), relativeTo: now) == "Today 14:00")
        #expect(StaySelection.label(for: london("2026-10-04 09:30"), relativeTo: now) == "Tomorrow 09:30")
        #expect(StaySelection.label(for: london("2026-10-09 09:30"), relativeTo: now) == "Fri 9 Oct 09:30")
        let sameDay = StaySelection(arrival: london("2026-10-03 14:00"), departure: london("2026-10-03 17:00"))
        #expect(sameDay.rangeDescription() == "14:00\u{2013}17:00, Saturday 3 October")
        let overnight = StaySelection(arrival: london("2026-10-03 22:00"), departure: london("2026-10-04 08:00"))
        #expect(overnight.rangeDescription() == "22:00 Sat 3 Oct \u{2013} 08:00 Sun 4 Oct")
    }
}

@Suite("Performance")
struct PerformanceTests {
    /// A dense viewport: 1,500 kerb sections, each overlapped by a timed
    /// restriction, evaluated for an overnight stay. Must stay interactive.
    @Test func denseViewportEvaluatesQuickly() {
        var context: [String: Feature] = [:]
        var primaries: [Feature] = []
        for index in 0..<1500 {
            let restriction = noWaiting("r\(index)", cond: time([period(monFri, [("16:00", "19:00")])]))
            let bay = relinked(
                paidBay("b\(index)", cond: time([period(monSat, [("08:30", "18:30")], extra: ["maxStay": 14400])], rate: perQuarterHour(1.2))),
                related: [restriction.id])
            context[bay.id] = bay
            context[restriction.id] = restriction
            primaries.append(bay)
        }
        let engine = ParkingRulesEngine(holidays: testHolidays)
        let overnight = stay("2026-10-05 17:00", "2026-10-06 10:00")
        let clock = ContinuousClock()
        var prohibited = 0
        let elapsed = clock.measure {
            for feature in primaries where engine.evaluate(feature, context: context, stay: overnight, profile: .standard).status == .prohibited {
                prohibited += 1
            }
        }
        #expect(prohibited == 1500)
        #expect(elapsed < .seconds(3), "evaluating 1,500 features took \(elapsed)")
        print("PERF: 1500 features in \(elapsed)")
    }
}
