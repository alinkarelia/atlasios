import Foundation
import SwiftUI
import PhotosUI
import AtlasCore

/// A grave observation, burial confirmation and personal identity are three
/// different facts. Only the operator explicitly changes the latter two.
@MainActor
struct BurialCardScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    let feature: AtlasFeature
    let cemetery: AtlasFeature?
    let initialGeoTag: GeoTag?
    let isNew: Bool
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var photos = BurialPhotoService()
    @State private var metadata: BurialMetadata
    @State private var metadataIssue: String?
    @State private var label: String
    @State private var geometry: FeatureGeometry
    @State private var notes: String
    @State private var sector: String
    @State private var status: SurveyFeatureStatus
    @State private var confirmationBasis: String
    @State private var availableCemeteries: [AtlasFeature] = []
    @State private var complexes: [BurialComplexChoice] = []
    @State private var surveyedFences: [AtlasFeature] = []
    @State private var loading = true
    @State private var saving = false
    @State private var importing = false
    @State private var issue: String?
    @State private var showCamera = false
    @State private var showProjectPhotos = false
    @State private var selectedPhoto: PhotoEvidence?
    @State private var photoItem: PhotosPickerItem?
    @State private var showHistory = false
    @State private var askCancel = false
    @State private var pendingOCR: String?
    @State private var pendingOCRPhotoID: UUID?
    @State private var askOCR = false
    @State private var inscriptionPhotoID: UUID?

    init(model: AtlasAppModel, project: AtlasProject, feature: AtlasFeature, cemetery: AtlasFeature? = nil,
         initialGeoTag: GeoTag? = nil, isNew: Bool = false, onSaved: @escaping () -> Void) {
        self.model = model; self.project = project; self.feature = feature; self.cemetery = cemetery
        self.initialGeoTag = initialGeoTag; self.isNew = isNew; self.onSaved = onSaved
        var draft = BurialMetadata()
        var decodeIssue: String?
        do { draft = try BurialMetadata(attributes: feature.attributes) }
        catch { decodeIssue = error.localizedDescription }
        if let cemetery, draft.cemeteryID == nil { draft.cemeteryID = cemetery.id }
        // Legacy transcription remains an observation; it never fills people.
        if draft.inscriptionDraft.isEmpty, let legacy = feature.attributes["inscriptionDraft"] { draft.inscriptionDraft = legacy }
        _metadata = State(initialValue: draft); _metadataIssue = State(initialValue: decodeIssue)
        _label = State(initialValue: feature.label); _geometry = State(initialValue: feature.geometry)
        _notes = State(initialValue: feature.notes); _sector = State(initialValue: feature.attributes["sector"] ?? "")
        _status = State(initialValue: SurveyFeatureLifecycle.status(of: feature))
        _confirmationBasis = State(initialValue: feature.attributes["grave.confirmationBasis"] ?? "")
        _inscriptionPhotoID = State(initialValue: feature.attributes["grave.inscriptionSourcePhotoID"].flatMap(UUID.init(uuidString:)))
    }

    private var directory: URL { model.captureDirectory(for: project) }
    private var busy: Bool { saving || importing || photos.isProcessing }
    private var attachedPhotos: [PhotoEvidence] { metadata.photoIDs.compactMap { id in photos.photos.first { $0.id == id } } }
    private var canSave: Bool { !busy && metadataIssue == nil && !loading }

    var body: some View {
        NavigationStack {
            Form {
                if let metadataIssue {
                    Section("Исходные данные требуют проверки") {
                        Text(metadataIssue).foregroundStyle(.red)
                        Text("Сохранение заблокировано, чтобы не заменить повреждённые поля пустыми данными. Фотографии и исходная карточка сохраняются.")
                            .font(.footnote)
                    }
                }
                contextSection
                statusSection
                typeSection
                peopleSection
                signsSection
                photoSection
                inscriptionSection
                conditionSection
                positionSection
                if !isNew {
                    Section("История и состояние записи") {
                        Button("История изменений", systemImage: "clock.arrow.circlepath") { showHistory = true }
                            .accessibilityIdentifier("burial.history")
                        SurveyRecordActions(feature: feature, disabled: !canSave) { action in Task { await save(action: action) } }
                    }
                }
            }
            .disabled(metadataIssue != nil)
            .scrollContentBackground(.hidden).background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
            .navigationTitle(isNew ? "Новое захоронение" : "Карточка захоронения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { if changed { askCancel = true } else { dismiss() } }.disabled(busy)
                        .accessibilityIdentifier("burial.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await save() } }.disabled(!canSave)
                        .accessibilityIdentifier("burial.save")
                }
            }
            .interactiveDismissDisabled(changed || busy)
            .task {
                let features = await model.features(in: project)
                availableCemeteries = features.filter { $0.category == .cemetery }
                surveyedFences = features.filter { $0.category == .fence && SurveyFeatureLifecycle.isActive($0) }
                var groups: [UUID: String] = [:]
                for value in features where value.category == .grave {
                    if let data = try? BurialMetadata(attributes: value.attributes), let id = data.complexID, groups[id] == nil { groups[id] = value.label }
                }
                complexes = groups.map { BurialComplexChoice(id: $0.key, name: $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                await photos.load(projectID: project.id, captureDirectory: directory)
                loading = false
            }
            .onChange(of: photoItem) { _, item in if let item { Task { await importPhoto(item) } } }
            .sheet(isPresented: $showCamera) {
                BurialPhotoCameraScreen { data, fix, time in
                    let photo = try await photos.captureOriginal(data: data, projectID: project.id,
                        captureDirectory: directory, operatorFix: fix, capturedAt: time)
                    attach(photo); model.fieldMaterialsDidChange(projectID: project.id)
                }
            }
            .sheet(isPresented: $showProjectPhotos) {
                BurialProjectPhotoPicker(service: photos, directory: directory, attachedIDs: metadata.photoIDs, onSelect: attach)
            }
            .sheet(item: $selectedPhoto) { photo in
                BurialPhotoDetailScreen(service: photos, photo: photo, directory: directory, onUseOCR: receiveOCR)
            }
            .sheet(isPresented: $showHistory) { SurveyFeatureHistoryScreen(model: model, feature: feature) }
            .alert("Проверьте данные", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("Понятно", role: .cancel) { issue = nil }
            } message: { Text(issue ?? "") }
            .confirmationDialog("Не сохранять изменения карточки?", isPresented: $askCancel, titleVisibility: .visible) {
                Button("Закрыть без сохранения", role: .destructive) { dismiss() }
                Button("Продолжить заполнение", role: .cancel) { }
            } message: { Text("Снятые и добавленные оригиналы останутся в фотографиях проекта. Существующая карточка не изменится.") }
            .confirmationDialog("В карточке уже есть черновик надписи", isPresented: $askOCR, titleVisibility: .visible) {
                Button("Добавить распознанный текст") { applyOCR(replacing: false) }
                Button("Заменить черновик", role: .destructive) { applyOCR(replacing: true) }
                Button("Отмена", role: .cancel) { pendingOCR = nil; pendingOCRPhotoID = nil }
            }
        }
    }

    private var contextSection: some View {
        Section("Место обследования") {
            TextField("Номер / обозначение участка", text: $label).accessibilityIdentifier("burial.label")
            if let cemetery { LabeledContent("Кладбище", value: cemetery.label) }
            else {
                Picker("Кладбище", selection: $metadata.cemeteryID) {
                    Text("Связь не задана").tag(Optional<UUID>.none)
                    ForEach(availableCemeteries) { Text($0.label).tag(Optional($0.id)) }
                    if let id = metadata.cemeteryID, !availableCemeteries.contains(where: { $0.id == id }) {
                        Text("Связанное кладбище недоступно").tag(Optional(id))
                    }
                }
            }
            TextField("Сектор / ряд", text: $sector)
        }
    }

    private var statusSection: some View {
        Section {
            Text(status.burialTitle).font(.headline).accessibilityIdentifier("burial.status.summary")
            Picker("Наличие захоронения", selection: $status) {
                Text("Возможное · нужна проверка").tag(SurveyFeatureStatus.candidate)
                Text("Подтверждено специалистом").tag(SurveyFeatureStatus.confirmed)
                Text("Предположение отклонено").tag(SurveyFeatureStatus.rejected)
            }.accessibilityIdentifier("burial.status")
            if status == .confirmed {
                TextField("Основание подтверждения: обследование, реестр…", text: $confirmationBasis, axis: .vertical).lineLimit(2...5)
                    .accessibilityIdentifier("burial.confirmationBasis")
            }
            Picker("Личность", selection: $metadata.identityStatus) {
                ForEach(BurialIdentityStatus.allCases, id: \.self) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("burial.identity")
            Text(metadata.identityStatus.title).font(.subheadline).accessibilityIdentifier("burial.identity.summary")
            if status == .confirmed && metadata.identityStatus == .unknown {
                Text("Захоронение подтверждено; имя может оставаться неизвестным. Карточку можно дополнить позже.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            }
        } header: { Text("Что установлено") } footer: {
            Text("Насыпь или аномалия — наблюдаемый признак. Он не подтверждает погребение или личность автоматически.")
        }
    }

    private var typeSection: some View {
        Section {
            Picker("Тип захоронения / сооружения", selection: $metadata.burialType) {
                ForEach(BurialType.allCases, id: \.self) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("burial.type")
            Picker("Крыша / навес", selection: $metadata.hasRoof) {
                Text("Не обследовано").tag(Optional<Bool>.none)
                Text("Есть").tag(Optional(true))
                Text("Нет").tag(Optional(false))
            }
            TextField("Военный / исторический контекст — если установлен", text: $metadata.warContext, axis: .vertical).lineLimit(2...5)
            TextField("Источник сведений: надпись, документ, реестр…", text: $metadata.warContextSource, axis: .vertical).lineLimit(2...5)
            Picker("Комплекс связанных карточек", selection: $metadata.complexID) {
                Text("Отдельная карточка").tag(Optional<UUID>.none)
                ForEach(complexes) { Text($0.name).tag(Optional($0.id)) }
                if let id = metadata.complexID, !complexes.contains(where: { $0.id == id }) { Text("Текущий комплекс").tag(Optional(id)) }
            }
            Button("Создать общий комплекс для нескольких карточек", systemImage: "square.stack.3d.up") {
                let id = UUID(); metadata.complexID = id
                complexes.append(BurialComplexChoice(id: id, name: label.isEmpty ? "Новый комплекс" : label))
            }.disabled(metadata.complexID != nil)
        } header: { Text("Тип и общий комплекс") } footer: {
            Text("Для большого семейного или братского захоронения связывайте несколько карточек одним комплексом. Военная принадлежность и охранный статус не определяются по внешнему виду автоматически.")
        }
    }

    private var peopleSection: some View {
        Section {
            if metadata.people.isEmpty { Text("Сведения о людях пока не добавлены.").foregroundStyle(Color.atlasMuted) }
            ForEach($metadata.people) { $person in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Фамилия, имя, отчество — если известны", text: $person.fullName)
                    HStack {
                        TextField("Рождение: текст / дата", text: $person.birthText)
                        TextField("Смерть: текст / дата", text: $person.deathText)
                    }
                    TextField("Что удалось установить / сомнения", text: $person.notes, axis: .vertical).lineLimit(2...4)
                    Button("Убрать человека из карточки", role: .destructive) { let id = person.id; metadata.people.removeAll { $0.id == id } }
                }.padding(.vertical, 4)
            }
            Button("Добавить человека", systemImage: "person.badge.plus") { metadata.people.append(BurialPerson(fullName: "")) }
                .disabled(metadata.people.count >= 8).accessibilityIdentifier("burial.person.add")
        } header: { Text("Люди · необязательные сведения") } footer: {
            Text("Один участок может содержать несколько захоронений. Сохраняйте неизвестные даты пустыми, частичные записи — как «19??». Заполнение имени не меняет статус личности.")
        }
    }

    private var signsSection: some View {
        Section("Наблюдаемые признаки") {
            ForEach(BurialVisibleSign.allCases, id: \.self) { sign in
                Toggle(sign.title, isOn: Binding(get: { metadata.visibleSigns.contains(sign) }, set: { selected in
                    metadata.visibleSigns.removeAll { $0 == sign }; if selected { metadata.visibleSigns.append(sign) }
                }))
            }
        }
    }

    private var photoSection: some View {
        Section {
            if loading { ProgressView("Читаем фотографии проекта") }
            if !attachedPhotos.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(attachedPhotos) { photo in
                            VStack(spacing: 8) {
                                Button { selectedPhoto = photo } label: { BurialPhotoThumbnail(service: photos, photo: photo, directory: directory) }
                                    .buttonStyle(.plain)
                                Button("Отвязать", role: .destructive) { metadata.photoIDs.removeAll { $0 == photo.id } }
                                    .font(.caption).disabled(busy)
                            }
                        }
                    }
                }
            }
            let missing = metadata.photoIDs.count - attachedPhotos.count
            if !loading && missing > 0 { Text("Не найдены \(missing) связанные фотографии. Ссылки сохранены; исходные материалы не удаляются.").font(.footnote).foregroundStyle(.orange) }
            Button("Снять оригинал", systemImage: "camera") { showCamera = true }
                .disabled(busy || loading || metadata.photoIDs.count >= 48).accessibilityIdentifier("burial.photo.camera")
            PhotosPicker(selection: $photoItem, matching: .images, preferredItemEncoding: .current) {
                Label("Добавить из Фото", systemImage: "photo.on.rectangle")
            }.disabled(busy || loading || metadata.photoIDs.count >= 48)
            Button("Выбрать из проекта", systemImage: "folder") { showProjectPhotos = true }
                .disabled(busy || loading || metadata.photoIDs.count >= 48)
            if importing || photos.isProcessing { ProgressView("Сохраняем оригинал и распознаём текст") }
            if let message = photos.errorMessage { Text(message).font(.footnote).foregroundStyle(.red) }
        } header: { Text("Фотографии и доказательства") } footer: {
            Text("Оригинальные файлы, EXIF и хеш сохраняются в проекте. GPS файла и положение оператора показываются отдельно. Отвязка фотографии не удаляет оригинал.")
        }
    }

    private var inscriptionSection: some View {
        Section {
            TextField("Текст с памятника / плиты", text: $metadata.inscriptionDraft, axis: .vertical)
                .lineLimit(4...12).accessibilityIdentifier("burial.inscription")
        } header: { Text("Надпись · черновик для сверки") } footer: {
            Text("Откройте фотографию, чтобы взять текст настоящего OCR. Исправьте ошибки вручную. Надпись не является подтверждённой записью реестра.")
        }
    }

    private var conditionSection: some View {
        Section("Состояние и замечания специалиста") {
            TextField("Состояние: ухожено, заросло, повреждено…", text: $metadata.condition, axis: .vertical).lineLimit(2...5)
            TextField("Комментарии по этому участку", text: $notes, axis: .vertical).lineLimit(3...10)
                .accessibilityIdentifier("burial.notes")
        }
    }

    private var positionSection: some View {
        Section("Положение участка") {
            SurveyPositionSummary(feature: feature, initialGeoTag: initialGeoTag)
            DisclosureGroup("Исправить координаты вручную") { SurveyGeometryForm(geometry: $geometry) }
            if !fenceDistances.isEmpty {
                ForEach(fenceDistances, id: \.id) { item in
                    LabeledContent(item.name, value: "≈ " + item.meters.formatted(.number.precision(.fractionLength(1))) + " м")
                }
                Text("Кратчайшее расстояние до отмеченной линии ограды. Точность зависит от исходных координат; геометка телефона не является геодезическим обмером.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            }
        }
    }

    private var fenceDistances: [BurialFenceDistance] {
        surveyedFences.compactMap { fence in
            let parent = (fence.attributes[CemeteryAttribute.cemeteryID] ?? fence.attributes["parentCemeteryID"]).flatMap(UUID.init(uuidString:))
            guard parent == metadata.cemeteryID,
                  let distance = try? GeographicMetricGeometry.nearestDistance(point: geometry, toFence: fence.geometry),
                  distance.isFinite else { return nil }
            return BurialFenceDistance(id: fence.id, name: fence.label.isEmpty ? "Ограда" : fence.label, meters: distance)
        }.sorted { $0.meters < $1.meters }.prefix(5).map { $0 }
    }

    private var changed: Bool {
        label != feature.label || geometry != feature.geometry || notes != feature.notes || sector != (feature.attributes["sector"] ?? "") ||
        status != SurveyFeatureLifecycle.status(of: feature) || confirmationBasis != (feature.attributes["grave.confirmationBasis"] ?? "") ||
        metadata != (try? BurialMetadata(attributes: feature.attributes))
    }

    private func attach(_ photo: PhotoEvidence) {
        guard photo.projectID == project.id, !metadata.photoIDs.contains(photo.id) else { return }
        guard metadata.photoIDs.count < 48 else { issue = "В карточке можно прикрепить до 48 фотографий. Оригинал уже сохранён в проекте."; return }
        metadata.photoIDs.append(photo.id)
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard !busy else { return }
        importing = true; defer { importing = false; photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw SurveyCardError.message("Не удалось получить оригинальный файл из Фото.") }
            let photo = try await photos.importOriginal(data: data, projectID: project.id, captureDirectory: directory)
            attach(photo); model.fieldMaterialsDidChange(projectID: project.id)
        } catch { issue = error.localizedDescription }
    }

    private func receiveOCR(_ text: String, _ photoID: UUID) {
        pendingOCR = text; pendingOCRPhotoID = photoID
        if metadata.inscriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { applyOCR(replacing: true) }
        else { askOCR = true }
    }
    private func applyOCR(replacing: Bool) {
        guard let text = pendingOCR else { return }
        metadata.inscriptionDraft = replacing ? text : metadata.inscriptionDraft + "\n" + text
        inscriptionPhotoID = pendingOCRPhotoID
        pendingOCR = nil; pendingOCRPhotoID = nil
    }

    private func save(action: SurveyRecordAction? = nil) async {
        guard canSave else { return }
        saving = true; defer { saving = false }
        do {
            var value = feature
            let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
            value.label = clean.isEmpty ? "Захоронение \(feature.id.uuidString.prefix(6))" : clean
            value.geometry = geometry; value.notes = notes
            value.attributes = try SurveyCardMetadata.retainingPosition(in: feature, changedGeometry: geometry, initialGeoTag: initialGeoTag)
            value.attributes["sector"] = sector
            value = try metadata.applying(to: value)
            if status != SurveyFeatureLifecycle.status(of: feature) || isNew {
                switch status {
                case .candidate: value.attributes[CemeteryAttribute.status] = status.rawValue; value.reviewStatus = .needsReview
                case .confirmed: value = SurveyFeatureLifecycle.confirm(value, basis: confirmationBasis, operatorID: model.team.user?.id)
                case .rejected: value = SurveyFeatureLifecycle.reject(value)
                }
            } else if status == .confirmed { value.attributes["grave.confirmationBasis"] = confirmationBasis }
            if let inscriptionPhotoID { value.attributes["grave.inscriptionSourcePhotoID"] = inscriptionPhotoID.uuidString }
            value.attributes["survey.savedAt"] = ISO8601DateFormatter().string(from: Date())
            if let action { value = action.applying(to: value) }
            if await model.saveFeature(value) != nil { onSaved(); dismiss() }
            else { issue = model.issue ?? "Не удалось сохранить карточку. Ваш черновик остаётся на экране."; model.issue = nil }
        } catch { issue = error.localizedDescription }
    }
}

private struct BurialComplexChoice: Identifiable { let id: UUID; let name: String }
private struct BurialFenceDistance: Identifiable { let id: UUID; let name: String; let meters: Double }
