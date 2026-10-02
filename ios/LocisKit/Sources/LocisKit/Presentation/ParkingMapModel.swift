import Foundation
import Observation

/// Something drawn on the map, with its evaluated status.
public struct MapItem: Identifiable, Sendable, Equatable {
    public enum Shape: Sendable, Equatable {
        case line([[Coordinate]])
        case area([[[Coordinate]]])
        case point(Coordinate)
    }

    public let id: String
    public let shape: Shape
    public let status: ParkingStatus
    public let confidence: Confidence
    public let category: Category
    public let name: String
    public let summary: String
}

/// A contextual zone outline (controlled parking zone and similar).
public struct ZoneItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let category: Category
    public let polygons: [[[Coordinate]]]
}

public enum MapFilter: String, CaseIterable, Identifiable, Sendable {
    case all, free, paid, conditional

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .free: "Free"
        case .paid: "Paid"
        case .conditional: "Conditional"
        }
    }

    func includes(_ status: ParkingStatus) -> Bool {
        switch self {
        case .all: true
        case .free: status == .allowedFree
        case .paid: status == .allowedPaid
        case .conditional: status == .conditional
        }
    }
}

/// Everything the details sheet needs for one selected feature.
public struct FeatureDetail: Sendable, Equatable {
    public let feature: Feature
    public let evaluation: ParkingEvaluation
    /// Other rules on the same kerb that took part.
    public let related: [Feature]
    public let zones: [Feature]
}

/// Loads parking data for the visible map area and evaluates it for the selected stay.
@MainActor
@Observable
public final class ParkingMapModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        /// The map shows too large an area to draw kerb rules.
        case zoomedOut
        case failed(ParkingDataError)
    }

    /// Message shown over the map when the data is missing, stale or unusable.
    public enum Notice: Equatable, Sendable {
        case noDataHere
        case temporarilyUnavailable
        case offline
        case showingCachedData(asOf: Date)
        case partlyUnavailable
        case requiresAppUpdate
        case zoomIn

        public var message: String {
            switch self {
            case .noDataHere: "No reliable parking data is available here yet."
            case .temporarilyUnavailable: "Parking data is temporarily unavailable."
            case .offline: "You're offline. Parking data can't be loaded."
            case .showingCachedData(let date):
                "You're offline. Showing parking data saved on \(date.formatted(date: .abbreviated, time: .shortened))."
            case .partlyUnavailable: "Some parking data for this area couldn't be loaded."
            case .requiresAppUpdate: "Update the app to read the latest parking data."
            case .zoomIn: "Zoom in to see parking rules."
            }
        }
    }

    // MARK: State

    public private(set) var phase: Phase = .idle
    public private(set) var notice: Notice?
    public private(set) var items: [MapItem] = []
    public private(set) var zones: [ZoneItem] = []
    public private(set) var manifestState: ManifestState?
    public private(set) var isEvaluating = false

    public var selection: StaySelection {
        didSet { if selection != oldValue { scheduleEvaluation() } }
    }
    public var profile: VehicleProfile {
        didSet { if profile != oldValue { scheduleEvaluation() } }
    }
    public var filter: MapFilter = .all
    public var selectedID: String?

    /// Items passing the current filter. The filter only hides things: an empty
    /// result never means parking is unrestricted.
    public var visibleItems: [MapItem] { items.filter { filter.includes($0.status) } }

    public var isDemo: Bool { manifestState?.manifest.synthetic ?? false }

    // MARK: Configuration

    /// Tallest map area (degrees of latitude) for which kerb rules are loaded: about 4 km.
    public static let maximumSpanDegrees = 0.036
    static let maximumTilesPerRequest = 30
    static let maximumLoadedTiles = 120

    private let provider: ParkingDataProviding
    private let debounce: Duration
    private var area = LoadedArea()
    private var loadedTiles = Set<TileCoordinate>()
    private var evaluations: [String: ParkingEvaluation] = [:]
    private var viewport: BoundingBox?
    private var loadTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var generation = 0

    public init(
        provider: ParkingDataProviding, selection: StaySelection = .suggested(), profile: VehicleProfile = .standard,
        debounce: Duration = .milliseconds(350)
    ) {
        self.provider = provider
        self.selection = selection
        self.profile = profile
        self.debounce = debounce
    }

    // MARK: Viewport

    /// Call when the visible map region settles. Requests are debounced, and
    /// nothing is fetched when the area is already loaded.
    public func viewportChanged(_ box: BoundingBox) {
        viewport = box
        loadTask?.cancel()
        loadTask = Task { [weak self, debounce] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            await self?.load(box)
        }
    }

    /// Reload the current viewport, asking the source for a fresh manifest.
    public func refresh() {
        guard let viewport else { return }
        loadedTiles.removeAll()
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load(viewport, refreshManifest: true) }
    }

    /// Wait for pending loading and evaluation (used by tests).
    public func settle() async {
        await loadTask?.value
        await evaluationTask?.value
    }

    private func load(_ box: BoundingBox, refreshManifest: Bool = false) async {
        guard box.heightDegrees <= Self.maximumSpanDegrees else {
            phase = .zoomedOut
            notice = .zoomIn
            items = []
            zones = []
            return
        }

        let state: ManifestState
        do {
            state = try await provider.manifest(refresh: refreshManifest)
        } catch let error as ParkingDataError {
            guard !Task.isCancelled else { return }
            fail(error)
            return
        } catch {
            fail(.unavailable)
            return
        }
        guard !Task.isCancelled else { return }
        if manifestState?.manifest.tiles != state.manifest.tiles {
            // The dataset changed: drop everything loaded from the old one.
            area = LoadedArea()
            loadedTiles.removeAll()
            evaluations.removeAll()
        }
        manifestState = state
        guard state.isCompatible else {
            phase = .failed(.requiresAppUpdate)
            notice = .requiresAppUpdate
            items = []
            zones = []
            return
        }

        // Load a margin around the viewport so small pans need no request.
        let wanted = TileCoordinate.covering(box.expanded(by: 0.25), zoom: state.manifest.tileZoom)
        guard wanted.count <= Self.maximumTilesPerRequest else {
            phase = .zoomedOut
            notice = .zoomIn
            items = []
            zones = []
            return
        }
        let missing = wanted.filter { !loadedTiles.contains($0) }
        if !missing.isEmpty {
            if loadedTiles.count + missing.count > Self.maximumLoadedTiles {
                area = LoadedArea()
                loadedTiles.removeAll()
                evaluations.removeAll()
            }
            phase = .loading
            let needed = wanted.filter { !loadedTiles.contains($0) }
            let loaded = await provider.load(needed, using: state.manifest)
            guard !Task.isCancelled else { return }
            area.merge(loaded)
            // Failed tiles are retried next time; the rest are done.
            loadedTiles.formUnion(Set(needed).subtracting(loaded.failedTiles))
        }

        phase = .ready
        // Tiles that failed earlier and have now loaded are no longer failed.
        area.failedTiles.subtract(loadedTiles)
        let visible = Set(TileCoordinate.covering(box, zoom: state.manifest.tileZoom))
        let failedHere = !area.failedTiles.isDisjoint(with: visible)
        let hasData = visible.contains { state.manifest.tiles[$0.key] != nil }
        if failedHere {
            notice = state.isFromCache ? .offline : .partlyUnavailable
        } else if !hasData {
            notice = .noDataHere
        } else if state.isFromCache {
            notice = .showingCachedData(asOf: state.fetchedAt)
        } else {
            notice = nil
        }
        scheduleEvaluation()
        await evaluationTask?.value
    }

    private func fail(_ error: ParkingDataError) {
        phase = .failed(error)
        switch error {
        case .offline: notice = .offline
        case .unavailable: notice = .temporarilyUnavailable
        case .requiresAppUpdate: notice = .requiresAppUpdate
        }
        items = []
        zones = []
    }

    // MARK: Evaluation

    /// Whether a feature gets its own shape on the map. Suspensions, planned
    /// orders and revocations that sit on top of another rule are shown through
    /// that rule instead of being drawn twice.
    nonisolated static func isDrawn(_ feature: Feature) -> Bool {
        if feature.role == .zone || feature.geomQuality == .zoneLine { return false }
        let hasRelated = !(feature.related ?? []).isEmpty
        if hasRelated {
            if feature.role == .baySuspension || feature.role == .restrictionSuspension { return false }
            if feature.lifecycle != nil { return false }
        }
        return true
    }

    private func scheduleEvaluation() {
        evaluationTask?.cancel()
        guard let state = manifestState, state.isCompatible else { return }
        guard let stay = selection.stay else {
            // An invalid time range evaluates nothing; the UI explains the problem.
            items = []
            return
        }
        generation += 1
        let generation = generation
        let area = area
        let profile = profile
        let holidays = state.manifest.holidays
        isEvaluating = true
        evaluationTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.evaluate(area: area, stay: stay, profile: profile, holidays: holidays)
            }.value
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.evaluations = result.evaluations
            self.items = result.items
            self.zones = result.zones
            self.isEvaluating = false
            if let selectedID = self.selectedID, result.evaluations[selectedID] == nil {
                self.selectedID = nil
            }
        }
    }

    private struct Evaluated: Sendable {
        var evaluations: [String: ParkingEvaluation] = [:]
        var items: [MapItem] = []
        var zones: [ZoneItem] = []
    }

    nonisolated private static func evaluate(
        area: LoadedArea, stay: Stay, profile: VehicleProfile, holidays: HolidayCalendar
    ) -> Evaluated {
        let engine = ParkingRulesEngine(holidays: holidays)
        var result = Evaluated()
        for feature in area.features.values.sorted(by: { $0.id < $1.id }) {
            if feature.role == .zone {
                if case .polygon(let polygons) = feature.geom {
                    result.zones.append(ZoneItem(id: feature.id, name: feature.name, category: feature.cat, polygons: polygons))
                }
                continue
            }
            guard area.memberIDs.contains(feature.id), isDrawn(feature) else { continue }
            let incomplete =
                area.isIncomplete(around: feature.id)
                || (feature.related ?? []).contains { area.features[$0] == nil }
            let evaluation = engine.evaluate(
                feature, context: area.features, stay: stay, profile: profile, dataIncomplete: incomplete)
            // A kerb whose only records do not exist during the stay is the same
            // as a kerb with no data: nothing is drawn.
            if evaluation.noRuleInForce { continue }
            result.evaluations[feature.id] = evaluation
            let shape: MapItem.Shape
            switch feature.geom {
            case .line(let parts): shape = .line(parts)
            case .polygon(let polygons): shape = .area(polygons)
            case .point(let points):
                guard let first = points.first else { continue }
                shape = .point(first)
            }
            result.items.append(
                MapItem(
                    id: feature.id, shape: shape, status: evaluation.status, confidence: evaluation.confidence,
                    category: feature.cat, name: feature.name, summary: evaluation.summary))
        }
        return result
    }

    // MARK: Lookup

    public func evaluation(for id: String) -> ParkingEvaluation? { evaluations[id] }

    public func detail(for id: String) -> FeatureDetail? {
        guard let feature = area.features[id], let evaluation = evaluations[id] else { return nil }
        let related = evaluation.applicableRuleIDs.filter { $0 != id }.compactMap { area.features[$0] }
        let others = (feature.related ?? []).compactMap { area.features[$0] }.filter { other in !related.contains { $0.id == other.id } }
        let zones = (feature.zones ?? []).compactMap { area.features[$0] }
        return FeatureDetail(feature: feature, evaluation: evaluation, related: related + others, zones: zones)
    }
}
