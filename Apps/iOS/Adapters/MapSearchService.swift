import Foundation
import Combine
@preconcurrency import MapKit
import AtlasCore

struct MapSearchSuggestion: Identifiable {
    let id = UUID()
    let completion: MKLocalSearchCompletion
    var title: String { completion.title }
    var subtitle: String { completion.subtitle }
}

struct MapSearchPlace: Sendable {
    let title: String
    let coordinate: GeographicCoordinate
}

/// Results come only from MapKit. Each query owns a separate completer so a
/// delayed delegate response cannot replace the current query's suggestions.
@MainActor
final class MapSearchService: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [MapSearchSuggestion] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isResolving = false
    @Published private(set) var issue: String?
    @Published private(set) var searchedQuery = ""

    private var completer: MKLocalSearchCompleter?
    private var activeSearch: MKLocalSearch?
    private var debounce: Task<Void, Never>?
    private var queryTicket = UUID()
    private var resolveTicket = UUID()

    func updateQuery(_ text: String, region: MKCoordinateRegion? = nil) {
        debounce?.cancel(); completer?.cancel(); completer = nil
        activeSearch?.cancel(); activeSearch = nil
        queryTicket = UUID(); resolveTicket = UUID()
        suggestions = []; issue = nil; searchedQuery = ""; isResolving = false
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { isSearching = false; return }
        isSearching = true
        let ticket = queryTicket
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, self.queryTicket == ticket, !Task.isCancelled else { return }
            let source = MKLocalSearchCompleter()
            source.delegate = self
            source.resultTypes = [.address, .pointOfInterest]
            if let region { source.region = region }
            self.completer = source
            self.searchedQuery = query
            source.queryFragment = query
        }
    }

    func resolve(_ suggestion: MapSearchSuggestion) async -> MapSearchPlace? {
        activeSearch?.cancel()
        let ticket = UUID(); resolveTicket = ticket
        isResolving = true; issue = nil
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion.completion))
        activeSearch = search
        do {
            let response = try await search.start()
            guard resolveTicket == ticket, !Task.isCancelled else { return nil }
            isResolving = false; activeSearch = nil
            guard let item = response.mapItems.first,
                  CLLocationCoordinate2DIsValid(item.placemark.coordinate) else {
                issue = "Не удалось определить координаты выбранного адреса. Попробуйте уточнить запрос."
                return nil
            }
            return MapSearchPlace(title: item.name ?? suggestion.title,
                coordinate: GeographicCoordinate(longitude: item.placemark.coordinate.longitude,
                                                  latitude: item.placemark.coordinate.latitude))
        } catch {
            guard resolveTicket == ticket, !Task.isCancelled else { return nil }
            isResolving = false; activeSearch = nil
            issue = "Адрес не найден или поиск временно недоступен. Проверьте интернет и повторите."
            return nil
        }
    }

    func cancel() {
        queryTicket = UUID(); resolveTicket = UUID()
        debounce?.cancel(); debounce = nil
        completer?.cancel(); completer = nil
        activeSearch?.cancel(); activeSearch = nil
        isSearching = false; isResolving = false
        suggestions = []; searchedQuery = ""; issue = nil
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard completer === self.completer else { return }
        suggestions = Array(completer.results.prefix(12)).map { MapSearchSuggestion(completion: $0) }
        isSearching = false; issue = nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard completer === self.completer else { return }
        isSearching = false; suggestions = []
        issue = "Поиск временно недоступен. Проверьте подключение к интернету или укажите координаты вручную."
    }
}
