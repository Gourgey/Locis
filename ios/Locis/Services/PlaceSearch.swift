import CoreLocation
import MapKit

/// A search suggestion as the user types.
struct PlaceSuggestion: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
}

/// A suggestion resolved to a position on the map.
struct ResolvedPlace: Equatable, Sendable {
    let name: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: ResolvedPlace, rhs: ResolvedPlace) -> Bool {
        lhs.name == rhs.name && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

enum PlaceSearchError: Error, Equatable {
    case notFound
    case failed
}

/// Address and place search. Queries go to Apple's MapKit service only and are
/// not stored by the app.
@MainActor
protocol PlaceSearching: AnyObject {
    /// Called on the main actor whenever suggestions for the latest query arrive.
    var onSuggestions: (([PlaceSuggestion]) -> Void)? { get set }
    func updateQuery(_ query: String)
    func resolve(_ suggestion: PlaceSuggestion) async throws -> ResolvedPlace
    /// Resolve free text the user submitted without picking a suggestion.
    func resolve(query: String) async throws -> ResolvedPlace
}

/// MapKit-backed search, biased towards Great Britain.
@MainActor
final class MapKitPlaceSearch: NSObject, PlaceSearching, @preconcurrency MKLocalSearchCompleterDelegate {
    var onSuggestions: (([PlaceSuggestion]) -> Void)?

    private let completer = MKLocalSearchCompleter()
    private var completions: [String: MKLocalSearchCompletion] = [:]

    static let greatBritain = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 54.5, longitude: -3.0),
        span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 11))

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = Self.greatBritain
    }

    func updateQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            completer.cancel()
            completions = [:]
            onSuggestions?([])
        } else {
            completer.queryFragment = trimmed
        }
    }

    func resolve(_ suggestion: PlaceSuggestion) async throws -> ResolvedPlace {
        guard let completion = completions[suggestion.id] else { throw PlaceSearchError.notFound }
        return try await run(MKLocalSearch.Request(completion: completion), fallbackName: suggestion.title)
    }

    func resolve(query: String) async throws -> ResolvedPlace {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = Self.greatBritain
        return try await run(request, fallbackName: query)
    }

    private func run(_ request: MKLocalSearch.Request, fallbackName: String) async throws -> ResolvedPlace {
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else { throw PlaceSearchError.notFound }
            return ResolvedPlace(name: item.name ?? fallbackName, coordinate: item.placemark.coordinate)
        } catch let error as PlaceSearchError {
            throw error
        } catch let error as MKError where error.code == .placemarkNotFound {
            throw PlaceSearchError.notFound
        } catch {
            throw PlaceSearchError.failed
        }
    }

    // MARK: MKLocalSearchCompleterDelegate (delivered on the main thread)

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        var mapped: [String: MKLocalSearchCompletion] = [:]
        var suggestions: [PlaceSuggestion] = []
        for (index, result) in completer.results.prefix(8).enumerated() {
            let id = "\(index)|\(result.title)|\(result.subtitle)"
            mapped[id] = result
            suggestions.append(PlaceSuggestion(id: id, title: result.title, subtitle: result.subtitle))
        }
        completions = mapped
        onSuggestions?(suggestions)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        completions = [:]
        onSuggestions?([])
    }
}
