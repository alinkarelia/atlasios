import SwiftUI
import AtlasCore

/// One entry point for a site survey, its cards and reviewable relief layers.
struct CemeteryFieldworkScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @State private var features: [AtlasFeature] = []
    @State private var loading = true

    private var cemeteries: [AtlasFeature] {
        features.filter { $0.category == .cemetery && $0.attributes["survey.status"] != "rejected" }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    GeometryEditorScreen(model: model, project: project)
                } label: { Label("Карта и обход границы", systemImage: "map") }
                    .accessibilityIdentifier("cemetery.map")
            } header: { Text("Начать обследование") } footer: {
                Text("Создайте границу кладбища на карте или обойдите её с GPS. Затем добавляйте захоронения, проходы и объекты в этом же проекте.")
            }.listRowBackground(Color.atlasCard)

            Section("Кладбища в проекте") {
                if loading { ProgressView("Открываем участки…") }
                else if cemeteries.isEmpty {
                    Text("Пока нет границы кладбища. Откройте карту и создайте объект «Кладбище».")
                        .foregroundStyle(Color.atlasMuted)
                }
                ForEach(cemeteries) { cemetery in
                    NavigationLink {
                        CemeterySiteScreen(model: model, project: project, cemetery: cemetery,
                                           onSaved: { Task { await reload() } })
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(cemetery.label).font(.headline)
                            let linked = features.filter { $0.attributes["cemeteryID"] == cemetery.id.uuidString }
                            Text("\(linked.filter { $0.category == .grave && $0.attributes["survey.status"] != "rejected" }.count) карточек · \(linked.filter { [.path, .road, .fence].contains($0.category) }.count) линий")
                                .font(.caption).foregroundStyle(Color.atlasMuted)
                        }
                    }
                    NavigationLink {
                        TerrainSurveyScreen(project: project, cemetery: cemetery,
                            directory: model.captureDirectory(for: project),
                            onConfirmedFeature: { feature in
                                // A successful map write may precede a failed
                                // sidecar write. Stable candidate IDs make retry
                                // idempotent while retaining later card edits.
                                if let existing = await model.features(in: project).first(where: { $0.id == feature.id }) {
                                    guard existing.attributes["survey.sourceCandidateID"] == feature.attributes["survey.sourceCandidateID"],
                                          existing.attributes["sourceFrameID"] == feature.attributes["sourceFrameID"] else {
                                        throw TeamError.rejected("Точка с этим идентификатором уже существует и имеет другое происхождение.")
                                    }
                                    return
                                }
                                guard await model.saveFeature(feature) != nil else {
                                    let message = model.issue ?? "Не удалось сохранить точку на карте. Повторите после проверки хранилища."
                                    model.issue = nil
                                    throw TeamError.rejected(message)
                                }
                                await reload()
                            }, onSurveySaved: {
                                model.fieldMaterialsDidChange(projectID: project.id)
                            }, onCaptureSaved: { manifest in
                                Task { await model.registerCapture(manifest: manifest, project: project) }
                            })
                    } label: {
                        Label("Рельеф и возможные захоронения · \(cemetery.label)", systemImage: "square.3.layers.3d")
                    }.accessibilityIdentifier("cemetery.terrain")
                }
            }.listRowBackground(Color.atlasCard)

            Section {
                Text("Возможное захоронение требует проверки. Подтверждённое захоронение может оставаться без ФИО и дат: личность учитывается отдельно.")
                Text("LiDAR видит открытые поверхности. Бугорок, просадка или камень могут стать подсказкой, но сами по себе не подтверждают захоронение. Точки можно отклонить и восстановить.")
                Text("Для наложения рельефа нужны контрольные точки. Показатель GPS — радиус неопределённости; точность местных размеров не означает такую же точность положения на карте.")
                Link("Как документировать кладбища · NPS", destination: URL(string: "https://www.nps.gov/articles/000/cemetery-preservation-course-documentation.htm")!)
            } header: { Text("Проверка результатов") }
                .font(.subheadline).foregroundStyle(Color.atlasMuted)
                .listRowBackground(Color.atlasCard)
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .foregroundStyle(Color.atlasInk)
        .navigationTitle("Обследование кладбища")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .onAppear { Task { await reload() } }
    }

    private func reload() async {
        let values = await model.features(in: project)
        guard !Task.isCancelled else { return }
        features = values; loading = false
    }
}
