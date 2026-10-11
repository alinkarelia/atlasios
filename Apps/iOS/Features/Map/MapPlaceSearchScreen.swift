import SwiftUI
import MapKit

@MainActor
struct MapPlaceSearchScreen: View {
    @ObservedObject var search: MapSearchService
    let region: MKCoordinateRegion?
    let onSelected: (MapSearchPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Населённый пункт, улица или адрес", text: $query)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                        .focused($focused).accessibilityIdentifier("map.search.query")
                }
                if search.isSearching || search.isResolving {
                    HStack { ProgressView(); Text(search.isResolving ? "Открываем место…" : "Ищем адрес…") }
                }
                if let issue = search.issue {
                    Text(issue).font(.subheadline).foregroundStyle(Color.orange)
                        .accessibilityIdentifier("map.search.issue")
                }
                if !search.suggestions.isEmpty {
                    Section("Результаты") {
                        ForEach(search.suggestions) { suggestion in
                            Button {
                                focused = false
                                Task { if let place = await search.resolve(suggestion) { onSelected(place) } }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(suggestion.title).foregroundStyle(Color.atlasInk)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle).font(.caption).foregroundStyle(Color.atlasMuted)
                                    }
                                }.padding(.vertical, 5)
                            }.disabled(search.isResolving)
                        }
                    }
                } else if !search.searchedQuery.isEmpty && !search.isSearching && search.issue == nil {
                    Text("Адрес не найден. Уточните название населённого пункта или улицы.")
                        .foregroundStyle(Color.atlasMuted).accessibilityIdentifier("map.search.noResults")
                } else if query.isEmpty {
                    Text("Введите название. Поиск Apple Maps требует подключения к интернету.")
                        .font(.subheadline).foregroundStyle(Color.atlasMuted)
                }
            }
            .scrollContentBackground(.hidden).background(Color.atlasCanvas)
            .navigationTitle("Поиск на карте").navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { search.cancel(); dismiss() } } }
            .onChange(of: query) { _, value in search.updateQuery(value, region: region) }
            .onAppear { focused = true }
            .onDisappear { search.cancel() }
        }.preferredColorScheme(.dark)
    }
}
