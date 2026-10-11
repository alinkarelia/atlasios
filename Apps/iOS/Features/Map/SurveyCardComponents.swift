import Foundation
import SwiftUI
import AtlasCore

enum SurveyCardError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

@MainActor
struct SurveyBoundaryBasisPicker: View {
    @Binding var selection: String
    private let known = ["digitized", "document", "physicalFence", "gpsTrack", "walkedGPS", "estimated"]
    var body: some View {
        Picker("Источник границы / положения", selection: $selection) {
            Text("Разметка специалистом").tag("digitized")
            Text("Документ / реестр").tag("document")
            Text("Физическая ограда").tag("physicalFence")
            Text("Трек GPS телефона").tag("gpsTrack")
            Text("Обход с GPS телефона").tag("walkedGPS")
            Text("Предположение").tag("estimated")
            if !known.contains(selection) { Text(selection).tag(selection) }
        }
    }
}

@MainActor
struct SurveyReviewPicker: View {
    @Binding var selection: ReviewStatus
    var body: some View {
        Picker("Проверка карточки", selection: $selection) {
            Text("Черновик").tag(ReviewStatus.draft)
            Text("Нужна проверка").tag(ReviewStatus.needsReview)
            Text("Проверено специалистом").tag(ReviewStatus.reviewed)
        }
        Text("Проверка содержания карточки не подтверждает сантиметровую точность координат.")
            .font(.footnote).foregroundStyle(Color.atlasMuted)
    }
}

enum SurveyRecordAction { case reject, remove, restore
    func applying(to feature: AtlasFeature) -> AtlasFeature {
        switch self { case .reject: SurveyFeatureLifecycle.reject(feature); case .remove: SurveyFeatureLifecycle.remove(feature); case .restore: SurveyFeatureLifecycle.restore(feature) }
    }
}

@MainActor
struct SurveyRecordActions: View {
    let feature: AtlasFeature
    var disabled: Bool = false
    let onAction: (SurveyRecordAction) -> Void
    @State private var pending: SurveyRecordAction?
    @State private var confirmation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if SurveyFeatureLifecycle.isSoftRemoved(feature) || SurveyFeatureLifecycle.status(of: feature) == .rejected {
                Button("Восстановить карточку", systemImage: "arrow.uturn.backward") { request(.restore) }
            } else {
                Button("Отклонить предположение", systemImage: "xmark.circle", role: .destructive) { request(.reject) }
                Button("Убрать из активных", systemImage: "archivebox", role: .destructive) { request(.remove) }
            }
            Text("Карточка, история и исходные фотографии сохраняются. Действие можно отменить восстановлением.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
        }
        .disabled(disabled)
        .confirmationDialog("Сохранить изменения карточки и изменить её состояние?", isPresented: $confirmation, titleVisibility: .visible) {
            Button("Подтвердить") { if let pending { onAction(pending) } }
            Button("Отмена", role: .cancel) { pending = nil }
        }
    }
    private func request(_ action: SurveyRecordAction) { pending = action; confirmation = true }
}

extension BurialVisibleSign {
    var title: String {
        switch self {
        case .mound: "Насыпь / холм"
        case .cross: "Крест"
        case .monument: "Памятник"
        case .fence: "Ограда"
        case .slab: "Плита"
        case .noVisibleMarker: "Видимого обозначения нет"
        case .other: "Другие признаки"
        }
    }
}

extension BurialIdentityStatus {
    var title: String { switch self { case .unknown: "Личность неизвестна"; case .partial: "Известна частично"; case .identified: "Личность установлена" } }
}

extension SurveyFeatureStatus {
    var burialTitle: String { switch self { case .candidate: "Возможное захоронение · нужна проверка"; case .confirmed: "Захоронение подтверждено"; case .rejected: "Предположение отклонено" } }
}

@MainActor
struct SurveyFeatureHistoryScreen: View {
    @ObservedObject var model: AtlasAppModel
    let feature: AtlasFeature
    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [AtlasFeature] = []
    @State private var loading = true
    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView("Загружаем историю") }
                else if revisions.isEmpty { Text("Сохранённых изменений пока нет.").foregroundStyle(Color.atlasMuted) }
                ForEach(revisions, id: \.revision) { revision in
                    DisclosureGroup("Версия \(revision.revision) · \(revision.label)") {
                        Text(revision.category == .grave ? SurveyFeatureLifecycle.status(of: revision).burialTitle : genericStatus(revision))
                        if let metadata = try? BurialMetadata(attributes: revision.attributes), revision.category == .grave {
                            Text(metadata.identityStatus.title)
                            ForEach(metadata.people) { Text($0.fullName.isEmpty ? "Имя не указано" : $0.fullName) }
                            if !metadata.inscriptionDraft.isEmpty { Text(metadata.inscriptionDraft) }
                        }
                        Text(SurveyGeometrySummary.text(revision.geometry)).font(.caption)
                        if let time = revision.attributes["survey.savedAt"] ?? revision.attributes["survey.reviewedAt"] { Text(time).font(.caption) }
                        if !revision.notes.isEmpty { Text(revision.notes) }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
            .navigationTitle("История карточки")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task { revisions = await model.featureHistory(feature); loading = false }
        }
    }
    private func genericStatus(_ value: AtlasFeature) -> String {
        if SurveyFeatureLifecycle.isSoftRemoved(value) { return "Убрано из активных" }
        switch SurveyFeatureLifecycle.status(of: value) { case .candidate: return "Наблюдение · требует проверки"; case .confirmed: return "Проверено специалистом"; case .rejected: return "Отклонено" }
    }
}

extension BurialType {
    var title: String {
        switch self {
        case .unknown: "Не установлено"
        case .individual: "Индивидуальное"
        case .family: "Семейное / родовое"
        case .mass: "Братское / массовое"
        case .mausoleum: "Мавзолей"
        case .crypt: "Склеп"
        case .memorial: "Мемориальный объект"
        }
    }
}
