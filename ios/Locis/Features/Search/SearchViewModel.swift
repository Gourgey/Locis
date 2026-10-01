import Foundation
import Observation

/// State for the search field: suggestions as the user types, and resolving a
/// chosen suggestion to a place on the map.
@MainActor
@Observable
final class SearchViewModel {
    enum Status: Equatable {
        case idle
        case resolving
        case noResults
        case failed
    }

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            status = .idle
            service.updateQuery(query)
        }
    }
    private(set) var suggestions: [PlaceSuggestion] = []
    private(set) var status: Status = .idle
    /// The last place the user chose, shown as a destination marker.
    private(set) var destination: ResolvedPlace?

    private let service: PlaceSearching

    init(service: PlaceSearching) {
        self.service = service
        service.onSuggestions = { [weak self] suggestions in
            self?.suggestions = suggestions
        }
    }

    var message: String? {
        switch status {
        case .noResults: "No places found. Try a street name or postcode."
        case .failed: "Search isn't available right now. Check your connection."
        case .idle, .resolving: nil
        }
    }

    /// Resolve a suggestion. Returns the place on success.
    @discardableResult
    func choose(_ suggestion: PlaceSuggestion) async -> ResolvedPlace? {
        await resolve { try await self.service.resolve(suggestion) }
    }

    /// Resolve whatever is typed (the keyboard's Search key).
    @discardableResult
    func submit() async -> ResolvedPlace? {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return await resolve { try await self.service.resolve(query: text) }
    }

    private func resolve(_ work: () async throws -> ResolvedPlace) async -> ResolvedPlace? {
        status = .resolving
        do {
            let place = try await work()
            destination = place
            suggestions = []
            status = .idle
            return place
        } catch PlaceSearchError.notFound {
            status = .noResults
        } catch {
            status = .failed
        }
        return nil
    }

    func clear() {
        query = ""
        suggestions = []
        destination = nil
        status = .idle
    }
}
