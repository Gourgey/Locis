import CoreLocation
import LocisKit
import SwiftUI
import Testing

@testable import Locis

@MainActor
final class FakePlaceSearch: PlaceSearching {
    var onSuggestions: (([PlaceSuggestion]) -> Void)?
    var queries: [String] = []
    var result: Result<ResolvedPlace, PlaceSearchError> = .failure(.notFound)

    func updateQuery(_ query: String) {
        queries.append(query)
        if query.isEmpty {
            onSuggestions?([])
        } else {
            onSuggestions?([
                PlaceSuggestion(id: "1", title: "\(query) Place", subtitle: "London"),
                PlaceSuggestion(id: "2", title: "\(query) Street", subtitle: "London"),
            ])
        }
    }

    func resolve(_ suggestion: PlaceSuggestion) async throws -> ResolvedPlace { try result.get() }
    func resolve(query: String) async throws -> ResolvedPlace { try result.get() }
}

@MainActor
@Suite("Search")
struct SearchViewModelTests {
    let portlandPlace = ResolvedPlace(
        name: "Portland Place", coordinate: CLLocationCoordinate2D(latitude: 51.5206, longitude: -0.1447))

    @Test func typingProducesSuggestions() {
        let service = FakePlaceSearch()
        let model = SearchViewModel(service: service)
        model.query = "Portland"
        #expect(service.queries == ["Portland"])
        #expect(model.suggestions.map(\.title) == ["Portland Place", "Portland Street"])
        model.query = ""
        #expect(model.suggestions.isEmpty)
    }

    @Test func choosingASuggestionSetsTheDestination() async {
        let service = FakePlaceSearch()
        service.result = .success(portlandPlace)
        let model = SearchViewModel(service: service)
        model.query = "Portland"
        let place = await model.choose(model.suggestions[0])
        #expect(place == portlandPlace)
        #expect(model.destination == portlandPlace)
        #expect(model.suggestions.isEmpty)
        #expect(model.status == .idle && model.message == nil)
    }

    @Test func noResultsAndFailuresAreReported() async {
        let service = FakePlaceSearch()
        let model = SearchViewModel(service: service)
        model.query = "zzzz"
        service.result = .failure(.notFound)
        #expect(await model.submit() == nil)
        #expect(model.status == .noResults)
        #expect(model.message == "No places found. Try a street name or postcode.")
        #expect(model.destination == nil)
        service.result = .failure(.failed)
        #expect(await model.submit() == nil)
        #expect(model.status == .failed)
        #expect(model.message?.contains("isn't available") == true)
    }

    @Test func emptyQueryIsNotSubmitted() async {
        let model = SearchViewModel(service: FakePlaceSearch())
        model.query = "   "
        #expect(await model.submit() == nil)
        #expect(model.status == .idle)
    }

    @Test func clearRemovesTheDestination() async {
        let service = FakePlaceSearch()
        service.result = .success(portlandPlace)
        let model = SearchViewModel(service: service)
        model.query = "Portland"
        await model.submit()
        model.clear()
        #expect(model.destination == nil && model.query.isEmpty)
    }
}

@Suite("Map language")
struct ParkingStyleTests {
    @Test func everyStatusHasADistinctColourLabelAndSymbol() {
        let styles = ParkingStatus.allCases.map(ParkingStyle.style(for:))
        #expect(Set(styles.map(\.label)).count == ParkingStatus.allCases.count)
        #expect(Set(styles.map(\.symbol)).count == ParkingStatus.allCases.count)
        #expect(Set(styles.map { "\($0.color)" }).count == ParkingStatus.allCases.count)
        #expect(Set(ParkingStyle.legendOrder) == Set(ParkingStatus.allCases))
    }

    @Test func statusesMapToTheIntendedColours() {
        #expect(ParkingStyle.style(for: .allowedFree).color == Palette.free)
        #expect(ParkingStyle.style(for: .allowedPaid).color == Palette.paid)
        #expect(ParkingStyle.style(for: .conditional).color == Palette.conditional)
        #expect(ParkingStyle.style(for: .prohibited).color == Palette.prohibited)
        #expect(ParkingStyle.style(for: .specialist).color == Palette.specialist)
        #expect(ParkingStyle.style(for: .unknown).color == Palette.unknown)
    }

    @Test func colourIsNotTheOnlyCue() {
        // Allowed lines are the heaviest, unknown is dashed, prohibited is thinner.
        let free = ParkingStyle.style(for: .allowedFree)
        let prohibited = ParkingStyle.style(for: .prohibited)
        let unknown = ParkingStyle.style(for: .unknown)
        #expect(free.lineWidth > prohibited.lineWidth)
        #expect(free.dash.isEmpty && !unknown.dash.isEmpty)
    }

    @Test func lowerConfidenceAllowedLinesAreDashed() {
        #expect(ParkingStyle.stroke(for: .allowedFree, confidence: .high).dash.isEmpty)
        #expect(!ParkingStyle.stroke(for: .allowedFree, confidence: .medium).dash.isEmpty)
        #expect(!ParkingStyle.stroke(for: .allowedPaid, confidence: .medium).dash.isEmpty)
        #expect(ParkingStyle.stroke(for: .prohibited, confidence: .medium).dash.isEmpty)
        #expect(ParkingStyle.stroke(for: .allowedFree, confidence: .high, selected: true).lineWidth > ParkingStyle.style(for: .allowedFree).lineWidth)
    }
}

@Suite("Configuration and hit testing")
struct ConfigurationTests {
    @Test func dataURLMustBeHTTPS() {
        #expect(AppConfiguration.url(forKey: "k", in: ["k": "https://example.org/data"])?.host() == "example.org")
        #expect(AppConfiguration.url(forKey: "k", in: ["k": ""]) == nil)
        #expect(AppConfiguration.url(forKey: "k", in: ["k": "   "]) == nil)
        #expect(AppConfiguration.url(forKey: "k", in: ["k": "http://example.org/data"]) == nil)
        #expect(AppConfiguration.url(forKey: "k", in: ["k": "not a url"]) == nil)
        #expect(AppConfiguration.url(forKey: "k", in: [:]) == nil)
    }

    @Test func attributionAndDisclaimerWording() {
        #expect(AppConfiguration.attribution == "Contains public sector information licensed under the Open Government Licence v3.0.")
        #expect(AppConfiguration.disclaimer.contains("Always check local signs"))
    }

    @MainActor
    @Test func settingsPersistOnTheDeviceOnly() {
        let defaults = UserDefaults(suiteName: "locis-tests-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        #expect(store.profile == .standard)
        store.vehicleType = .motorcycle
        store.blueBadge = true
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.profile == VehicleProfile(vehicleType: .motorcycle, blueBadge: true))
    }

    @Test func tapDistanceToALine() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        #expect(Geometry2D.distance(from: CGPoint(x: 50, y: 10), toPolyline: line) == 10)
        #expect(Geometry2D.distance(from: CGPoint(x: 110, y: 50), toPolyline: line) == 10)
        #expect(Geometry2D.distance(from: CGPoint(x: -30, y: 40), toPolyline: line) == 50)
        #expect(Geometry2D.distance(from: CGPoint(x: 3, y: 4), toPolyline: [.zero]) == 5)
        #expect(Geometry2D.distance(from: .zero, toPolyline: []) == .infinity)
    }

    @Test func pointInPolygon() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        #expect(Geometry2D.contains(CGPoint(x: 5, y: 5), polygon: square))
        #expect(!Geometry2D.contains(CGPoint(x: 15, y: 5), polygon: square))
    }
}
