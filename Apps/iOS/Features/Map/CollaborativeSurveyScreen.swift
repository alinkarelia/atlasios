import Foundation
import SwiftUI
import MapKit
import UIKit
import UniformTypeIdentifiers
import AtlasCore

@MainActor
struct CollaborativeSurveyScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var guidanceService = CollaborativeGuidanceService()
    @State private var document: CollaborativeSurveyStoredPlan?
    @State private var index: CollaborativeSurveyMapIndex?
    @State private var boundaries: [AtlasFeature] = []
    @State private var busy = false
    @State private var ready = false
    @State private var issue: String?
    @State private var message: String?
    @State private var creating = false
    @State private var draft: CollaborativeSurveyDraft?
    @State private var pendingDraft: CollaborativeSurveyDraft?
    @State private var workerID: UUID?
    @State private var cell: CollaborativeSurveyCell?
    @State private var showImporter = false
    @State private var importPreview: CollaborativeSurveyImportRequest?
    @State private var share: CollaborativeSurveyShareRequest?
    @State private var currentPoint: MetricPoint2D?
    @State private var guidance: CollaborativeSurveyGuidance?
    @State private var showHistory = false
    @State private var showCellList = false
    @State private var pendingCell: CollaborativeSurveyCell?
    private let store: CollaborativeSurveyStore

    init(model: AtlasAppModel, project: AtlasProject) {
        self.model = model; self.project = project
        store = CollaborativeSurveyStore(projectID: project.id, reference: project.coordinateReference,
            directory: model.captureDirectory(for: project).appendingPathComponent("Collaboration", isDirectory: true))
    }
    private var sourceMatches: Bool {
        guard let document else { return true }
        return boundaries.contains { $0.id == document.sourceFeatureID && $0.geometry == document.plan.sourceBoundary }
    }
    var body: some View {
        Group {
            List {
                Section { introduction }.listRowBackground(Color.atlasCanvas)
                if !ready { Section { ProgressView("Открываем план совместной съёмки") }.listRowBackground(Color.atlasCanvas) }
                if let document, let index {
                    Section { mapSection(document, index: index) }.listRowBackground(Color.atlasCanvas)
                    Section("Мой участок") { workerSection(document) }.listRowBackground(Color.atlasCanvas)
                    Section("Направление к работе") { guidanceSection(document) }.listRowBackground(Color.atlasCanvas)
                    Section("Команда · \(document.plan.workers.count)") { workerRows(document, index: index) }.listRowBackground(Color.atlasCanvas)
                    Section("Обмен планом") { exchangeSection(document) }.listRowBackground(Color.atlasCanvas)
                    Section { limitations(document) }.listRowBackground(Color.atlasCanvas)
                } else if ready {
                    Section {
                        Text(boundaries.isEmpty ? "Сначала создайте границу участка на карте. Нужен полигон; внутренние исключённые контуры сохранятся." : "Разделите выбранный полигон по площади между сотрудниками. Распределение нужно проверить перед началом работы.")
                            .font(.subheadline)
                        Button("Распределить участки", systemImage: "person.3.fill") { creating = true }
                            .disabled(boundaries.isEmpty || busy).accessibilityIdentifier("collaboration.create")
                        Button("Открыть план коллеги JSON", systemImage: "square.and.arrow.down") { showImporter = true }
                            .disabled(busy).accessibilityIdentifier("collaboration.import")
                    }.listRowBackground(Color.atlasCanvas)
                }
                if let issue { Section { Text(issue).foregroundStyle(.orange).accessibilityIdentifier("collaboration.issue") }.listRowBackground(Color.atlasCanvas) }
                if let message { Section { Text(message).font(.footnote).foregroundStyle(Color.atlasMuted).accessibilityIdentifier("collaboration.message") }.listRowBackground(Color.atlasCanvas) }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
            .background(CollaborativeSurveyOrientationReporter { guidanceService.compass.setInterfaceOrientation($0) }.allowsHitTesting(false))
            .navigationTitle("Совместная съёмка").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.accessibilityIdentifier("collaboration.close") } }
            .task { await restore() }
            .onChange(of: workerID) { _, value in saveWorkerSelection(value); updateGuidance() }
            .onReceive(guidanceService.$now) { _ in updateGuidance() }
            .onChange(of: phase) { _, value in if value != .active { guidanceService.stop(); updateGuidance() } }
            .onDisappear { guidanceService.stop() }
            .sheet(isPresented: $creating, onDismiss: { draft = pendingDraft; pendingDraft = nil }) {
                CollaborativeSurveyCreationScreen(project: project, boundaries: boundaries) { value in
                    pendingDraft = .init(document: value); creating = false
                }
            }
            .sheet(item: $draft) { request in draftPreview(request.document) }
            .sheet(item: $cell) { selected in
                if let document { cellReview(selected, document: document) }
            }
            .sheet(item: $importPreview) { request in importReview(request.preview) }
            .sheet(item: $share) { request in CollaborativeSurveyShareSheet(url: request.url) }
            .sheet(isPresented: $showHistory) { if let document { history(document) } }
            .sheet(isPresented: $showCellList, onDismiss: { cell = pendingCell; pendingCell = nil }) {
                if let document, let index {
                    CollaborativeSurveyCellListScreen(plan: document.plan, index: index, selectedWorkerID: workerID) {
                        pendingCell = $0; showCellList = false
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                switch result {
                case let .success(urls): if let url = urls.first { Task { await prepareImport(url) } }
                case let .failure(error): issue = error.localizedDescription
                }
            }
        }.preferredColorScheme(.dark)
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.name).font(.caption).foregroundStyle(Color.atlasMuted)
            Text("Один полигон. Свои участки.").font(.title3.bold())
            Text("Цвет показывает назначение, знак — состояние материалов. Сотрудники могут пересекать границы; приложение предупреждает, сохраняя свободу перехода.")
                .font(.subheadline)
            Label("Локальный план · обмен JSON", systemImage: "iphone.gen3.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }
    }
    private func mapSection(_ document: CollaborativeSurveyStoredPlan, index: CollaborativeSurveyMapIndex) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CollaborativeSurveyPlanCanvas(plan: document.plan, index: index, point: currentPoint,
                accuracyMeters: guidanceService.usableFix?.accuracyMeters, selectedWorkerID: workerID) { cell = $0 }
                .frame(height: 330).clipShape(RoundedRectangle(cornerRadius: 14))
            CollaborativeSurveyLegend()
            Button("Открыть список ячеек", systemImage: "list.bullet") { showCellList = true }
                .accessibilityIdentifier("collaboration.cells")
            Text("≈ \(document.plan.estimatedWorkAreaSquareMeters.formatted(.number.precision(.fractionLength(0)))) м² · ячейка \(document.plan.cellSizeMeters.formatted(.number.precision(.fractionLength(0)))) м · \(document.plan.partialCellCount) краевых для проверки")
                .font(.caption).foregroundStyle(Color.atlasMuted).accessibilityIdentifier("collaboration.summary")
            if !sourceMatches {
                Text("Граница проекта изменилась. Этот план сохраняет исходную границу; направление отключено до согласования нового этапа.")
                    .font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("collaboration.boundaryChanged")
            }
        }
    }
    private func workerSection(_ document: CollaborativeSurveyStoredPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Я работаю как", selection: $workerID) {
                Text("Выберите себя").tag(UUID?.none)
                ForEach(document.plan.workers) { Text($0.name).tag(Optional($0.id)) }
            }.accessibilityIdentifier("collaboration.worker")
            Text("Выбор относится только к этому iPhone. Импорт плана не меняет вашу роль; сообщения не являются живым положением коллег.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
            if let workerID, document.plan.workersWithoutAssignments.contains(workerID) {
                Text("У сотрудника пока нет ячеек. Руководитель может переназначить их в карточке ячейки.").font(.footnote).foregroundStyle(.orange)
            }
        }
    }
    private func guidanceSection(_ document: CollaborativeSurveyStoredPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if document.plan.coordinateReference != .wgs84 {
                Text("Локальный план в метрах: GPS не переносится в эту систему. Выберите свою ячейку на схеме; географическая стрелка недоступна.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            } else {
                Button(guidanceService.running ? "Остановить направление" : "Включить GPS и компас", systemImage: "location.north.line") {
                    if guidanceService.running { guidanceService.stop() } else { guidanceService.start() }
                    updateGuidance()
                }.disabled(workerID == nil || !sourceMatches).accessibilityIdentifier("collaboration.guidance.start")
                if let guidance {
                    let nearTarget = guidance.distanceMeters.map { $0 <= (guidanceService.usableFix?.accuracyMeters ?? 0) } ?? false
                    HStack(spacing: 16) {
                        if let turn = guidance.turnDegrees, !nearTarget {
                            Image(systemName: "location.north.fill").font(.system(size: 44)).foregroundStyle(Color.atlasAccent)
                                .rotationEffect(.degrees(turn)).accessibilityLabel("Поверните на \(turn.formatted(.number.precision(.fractionLength(0)))) градусов")
                        } else { Image(systemName: "location.slash").font(.title).foregroundStyle(Color.atlasMuted) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(nearTarget && [.ready, .headingUnavailable].contains(guidance.status) ? "Примерно у рабочей точки" : guidanceTitle(guidance.status)).font(.headline)
                            if let target = guidance.targetCellID { Text("К ячейке \(target)").font(.caption) }
                            if let distance = guidance.distanceMeters { Text("≈ \(distance.formatted(.number.precision(.fractionLength(0)))) м по прямой").font(.subheadline) }
                        }
                    }.accessibilityIdentifier("collaboration.guidance.result")
                    if nearTarget {
                        Text("Стрелка скрыта в пределах заявленной погрешности GPS. Осмотрите рабочую ячейку; близость к точке не подтверждает съёмку.")
                            .font(.footnote).foregroundStyle(Color.atlasMuted)
                    }
                    if guidance.status == .otherWorkersSector {
                        Text("Вы в участке коллеги. Переход разрешён; вернитесь к своему заданию, когда это удобно и безопасно.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if guidance.status == .boundaryUncertain {
                        Text("Круг погрешности пересекает границу. Принадлежность участка и стрелка скрыты, чтобы не выдавать неточную позицию за факт.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                if let fix = guidanceService.fix {
                    Text("GPS сообщает ±\(fix.accuracyMeters.formatted(.number.precision(.fractionLength(1)))) м · для направления нужно ≤\(min(10, max(1, document.plan.cellSizeMeters / 2)).formatted(.number.precision(.fractionLength(1)))) м")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
                if let issue = guidanceService.issue { Text(issue).font(.footnote).foregroundStyle(.orange) }
                if guidanceService.running, guidanceService.usableHeading == nil {
                    Text("Для стрелки нужен свежий компас с истинным севером и погрешностью ≤20°. Уберите телефон от металлической ограды.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                }
            }
            Text("Направление по прямой не учитывает проходы, заборы и препятствия. Пройденное место не считается отснятым.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
        }
    }
    private func workerRows(_ document: CollaborativeSurveyStoredPlan, index: CollaborativeSurveyMapIndex) -> some View {
        ForEach(Array(document.plan.workers.enumerated()), id: \.element.id) { offset, worker in
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(CollaborativeSurveyPalette.worker(offset)).frame(width: 12, height: 12).padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(offset + 1). \(worker.name)").font(.subheadline.bold())
                    let summary = index.workers[worker.id] ?? .init()
                    Text("≈ \(summary.area.formatted(.number.precision(.fractionLength(0)))) м² · \(summary.total) ячеек · проверено \(summary.verified)")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                    Text("Без материалов \(summary.unobserved) · наблюдались \(summary.observed) · переснять \(summary.needsRescan)")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
            }.accessibilityIdentifier("collaboration.worker." + worker.id.uuidString)
        }
    }
    private func exchangeSection(_ document: CollaborativeSurveyStoredPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Версия \(document.plan.revision) · последние изменения \(document.plan.updatedAt.formatted(date: .numeric, time: .shortened))")
                .font(.caption).foregroundStyle(Color.atlasMuted)
            Button("Поделиться планом JSON", systemImage: "square.and.arrow.up") { Task { await exportPlan() } }
                .disabled(busy).accessibilityIdentifier("collaboration.share")
            Button("Проверить файл коллеги", systemImage: "square.and.arrow.down") { showImporter = true }
                .disabled(busy).accessibilityIdentifier("collaboration.import")
            Button("История назначений и материалов", systemImage: "clock.arrow.circlepath") { showHistory = true }
                .accessibilityIdentifier("collaboration.history")
            Text("Общий JSON сохраняет UUID проекта, сотрудников, границу, назначения и журнал. Совместимые материалы объединяются по идентификаторам; расходящиеся назначения требуют согласования. Фото, видео и модели передаются полным ZIP проекта отдельно.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
            Text("Местоположение и изменения коллег не поступают в реальном времени. Для этого нужен сервер следующего этапа.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
        }
    }
    private func limitations(_ document: CollaborativeSurveyStoredPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(document.plan.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(Color.atlasMuted) }
            if document.plan.componentCount > 1 {
                Text("Связных частей: \(document.plan.componentCount). Между частями безопасный проход не установлен.")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }
    private func draftPreview(_ document: CollaborativeSurveyStoredPlan) -> some View {
        NavigationStack {
            List {
                Section { Text("Проверьте назначения перед сохранением. Баланс рассчитан по площади; густота объектов, доступность и трудоёмкость могут различаться.") }
                Section {
                    CollaborativeSurveyPlanCanvas(plan: document.plan, index: .init(plan: document.plan), point: nil,
                        accuracyMeters: nil, selectedWorkerID: nil) { _ in }.frame(height: 330)
                    workerRows(document, index: .init(plan: document.plan))
                }
                Section { limitations(document) }
                Section {
                    Button("Сохранить распределение", systemImage: "checkmark") { Task { await saveDraft(document) } }
                        .disabled(busy).accessibilityIdentifier("collaboration.confirmPlan")
                    if let issue { Text(issue).foregroundStyle(.orange) }
                }
            }.scrollContentBackground(.hidden).background(Color.atlasCanvas)
                .navigationTitle("Проверка участков").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { draft = nil } } }
        }.preferredColorScheme(.dark)
    }
    private func cellReview(_ cell: CollaborativeSurveyCell, document: CollaborativeSurveyStoredPlan) -> some View {
        CollaborativeSurveyCellScreen(cell: cell, document: document, selectedWorkerID: workerID,
            currentGPSCellID: currentGPSCellID(document.plan), fix: guidanceService.usableFix,
            coverageStatus: index?.coverage[cell.id] ?? .unobserved,
            model: model, project: project) { newPlan in
                await persist(newPlan)
            }
    }
    private func importReview(_ preview: CollaborativeSurveyImportPreview) -> some View {
        NavigationStack {
            List {
                Section {
                    Text(importTitle(preview.disposition)).font(.headline)
                    Text("Добавляется записей о материалах: \(preview.additionalEvidenceCount). Версия на iPhone после принятия: \(preview.document.plan.revision).")
                    Text("Оригинальные события сохраняются; дубликаты не создаются. Импорт JSON не переносит фото или 3D-файлы и не выполняет их совмещение.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                }
                Section { Button("Принять проверенный план", systemImage: "checkmark") { Task { await acceptImport(preview) } }
                    .disabled(busy).accessibilityIdentifier("collaboration.import.confirm") }
                if let issue { Section { Text(issue).foregroundStyle(.orange) } }
            }.scrollContentBackground(.hidden).background(Color.atlasCanvas)
                .navigationTitle("Проверка обмена").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { importPreview = nil } } }
        }.preferredColorScheme(.dark)
    }
    private func history(_ document: CollaborativeSurveyStoredPlan) -> some View {
        NavigationStack {
            List {
                Section("Назначения · \(document.plan.assignmentHistory.count)") {
                    ForEach(document.plan.assignmentHistory.reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Версия \(event.revision) · \(document.plan.workers.first { $0.id == event.workerID }?.name ?? "Сотрудник")")
                            Text("Ячеек: \(event.cellIDs.count) · \(event.timestamp.formatted(date: .numeric, time: .shortened))").font(.caption)
                        }
                    }
                }
                Section("Материалы и проверки · \(document.plan.evidence.count)") {
                    ForEach(document.plan.evidence.reversed()) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(evidenceTitle(item.kind)).font(.headline)
                            Text("\(document.plan.workers.first { $0.id == item.workerID }?.name ?? "Сотрудник") · \(item.timestamp.formatted(date: .numeric, time: .shortened))").font(.caption)
                            Text("Ячейки: \(item.cellIDs.joined(separator: ", "))").font(.caption)
                            if !item.note.isEmpty { Text(item.note).font(.footnote) }
                            if let captureID = item.captureID { Text("Материал \(captureID.uuidString)").font(.caption).foregroundStyle(Color.atlasMuted) }
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background(Color.atlasCanvas).navigationTitle("История плана")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { showHistory = false } } }
        }.preferredColorScheme(.dark)
    }
    private func restore() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        boundaries = await model.features(in: project).filter { feature in
            guard feature.geometry.coordinateReference == project.coordinateReference else { return false }
            switch feature.geometry { case .metricPolygon, .geographicPolygon: return true; default: return false }
        }
        do { try await display(store.load()); ready = true; issue = nil }
        catch { issue = error.localizedDescription; ready = false }
    }
    private func display(_ next: CollaborativeSurveyStoredPlan?) async throws {
        document = next
        if let next {
            index = await Task.detached(priority: .utility) { CollaborativeSurveyMapIndex(plan: next.plan) }.value
            let saved = UserDefaults.standard.string(forKey: workerPreferenceKey(next.plan.id)).flatMap(UUID.init(uuidString:))
            workerID = saved.flatMap { id in next.plan.workers.contains { $0.id == id } ? id : nil }
        } else { index = nil; workerID = nil }
        updateGuidance()
    }
    private func saveDraft(_ next: CollaborativeSurveyStoredPlan) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let latest = await model.features(in: project)
            guard latest.contains(where: { $0.id == next.sourceFeatureID && $0.revision == next.sourceFeatureRevision && $0.geometry == next.plan.sourceBoundary }) else {
                throw CollaborativeSurveyStoreError.revisionConflict
            }
            let saved = try await store.save(next, expectedSHA256: nil)
            try await display(saved); draft = nil; issue = nil; model.fieldMaterialsDidChange(projectID: project.id)
        } catch { issue = error.localizedDescription }
    }
    private func persist(_ next: CollaborativeSurveyPlan) async -> Bool {
        guard !busy, let current = document else { return false }; busy = true; defer { busy = false }
        do {
            let expected = current.currentSHA256
            let changed = try await Task.detached(priority: .utility) { var value = current; try value.append(next); return value }.value
            let saved = try await store.save(changed, expectedSHA256: expected)
            try await display(saved); issue = nil; model.fieldMaterialsDidChange(projectID: project.id); return true
        } catch { issue = error.localizedDescription; return false }
    }
    private func prepareImport(_ url: URL) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await Task.detached(priority: .utility) { try CollaborativeSurveyStore.readBounded(url) }.value
            let preview = try await store.previewExchange(data, expectedSHA256: document?.currentSHA256)
            importPreview = .init(preview: preview); issue = nil
        } catch { issue = error.localizedDescription }
    }
    private func acceptImport(_ preview: CollaborativeSurveyImportPreview) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let saved = try await store.acceptImport(preview, expectedSHA256: document?.currentSHA256)
            try await display(saved); importPreview = nil; issue = nil; ready = true
            message = "План сохранён на iPhone. Материалы коллег нужно открыть из полного ZIP отдельно."
            model.fieldMaterialsDidChange(projectID: project.id)
        } catch { issue = error.localizedDescription }
    }
    private func exportPlan() async {
        guard !busy, let document else { return }; busy = true; defer { busy = false }
        do {
            let data = try await store.exchangeData(document)
            let directory = model.directory.appendingPathComponent("Exports", isDirectory: true)
            let projectID = project.id
            let url = try await Task.detached(priority: .utility) {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = "TerraView_team_\(formatter.string(from: Date()))_\(projectID.uuidString)_r\(document.plan.revision)_\(UUID().uuidString.prefix(8)).terraview-team.json"
                let url = directory.appendingPathComponent(name); try data.write(to: url, options: .atomic); return url
            }.value
            share = .init(url: url); issue = nil
        } catch { issue = error.localizedDescription }
    }
    private func updateGuidance() {
        guard sourceMatches, let plan = document?.plan, let workerID, let fix = guidanceService.usableFix,
              let point = try? plan.project(fix.coordinate) else { currentPoint = nil; guidance = nil; return }
        currentPoint = point
        guard !plan.workersWithoutAssignments.contains(workerID) else { guidance = nil; return }
        let heading = plan.projection.flatMap { guidanceService.headingInGrid($0) }
        guidance = plan.guidance(workerID: workerID, position: point, frameID: plan.gridFrameID,
            horizontalAccuracyMeters: fix.accuracyMeters, headingInGridDegrees: heading,
            maximumAccuracyMeters: min(10, max(1, plan.cellSizeMeters / 2)))
    }
    private func currentGPSCellID(_ plan: CollaborativeSurveyPlan) -> String? {
        guard let point = currentPoint, let guidance,
              ![.poorAccuracy, .unknownAccuracy, .boundaryUncertain, .frameMismatch, .outsideBoundary].contains(guidance.status),
              CollaborativeSurveyPlanner.contains(point, in: plan.boundary) else { return nil }
        return plan.cells.first { cell in
            guard let a = cell.boundsVertices.first, cell.boundsVertices.count == 4 else { return false }
            let b = cell.boundsVertices[2]; return point.x >= a.x && point.x <= b.x && point.y >= a.y && point.y <= b.y
        }?.id
    }
    private func workerPreferenceKey(_ planID: UUID) -> String { "TerraView.Collaboration.Worker.\(project.id.uuidString).\(planID.uuidString)" }
    private func saveWorkerSelection(_ id: UUID?) {
        guard let planID = document?.plan.id else { return }
        if let id { UserDefaults.standard.set(id.uuidString, forKey: workerPreferenceKey(planID)) }
        else { UserDefaults.standard.removeObject(forKey: workerPreferenceKey(planID)) }
    }
}

private struct CollaborativeSurveyDraft: Identifiable { var id: UUID { document.plan.id }; let document: CollaborativeSurveyStoredPlan }
private struct CollaborativeSurveyImportRequest: Identifiable { let id = UUID(); let preview: CollaborativeSurveyImportPreview }
private struct CollaborativeSurveyShareRequest: Identifiable { let id = UUID(); let url: URL }

private func importTitle(_ value: CollaborativeSurveyImportPreview.Disposition) -> String {
    switch value { case .newPlan: "Новый общий план"; case .fastForward: "Продолжение общей версии"; case .mergeEvidence: "Объединение журналов сотрудников"; case .unchanged: "Все записи уже есть на iPhone" }
}
private func evidenceTitle(_ value: CollaborativeSurveyEvidenceKind) -> String {
    switch value { case .gpsWalk: "Место посещено · GPS"; case .captureObserved: "Есть материал"; case .operatorVerified: "Проверка сотрудником" }
}
private func scanSourceTitle(_ value: ScanSource) -> String {
    switch value { case .liDAR: "LiDAR"; case .roomPlan: "План помещения"; case .photogrammetry: "Фотограмметрия"; case .imported: "Импорт" }
}
private func guidanceTitle(_ value: CollaborativeSurveyGuidanceStatus) -> String {
    switch value {
    case .ready: "Направление к вашей ячейке"; case .complete: "Ваши ячейки проверены"
    case .unknownAccuracy: "Точность GPS неизвестна"; case .poorAccuracy: "Недостаточная точность GPS"
    case .frameMismatch: "Нет привязки к плану"; case .headingUnavailable: "Ожидаем истинный север"
    case .outsideBoundary: "Вы вне рабочей границы"; case .otherWorkersSector: "Участок коллеги"
    case .boundaryUncertain: "Положение у границы неопределённо"
    }
}

@MainActor
private struct CollaborativeSurveyCreationScreen: View {
    let project: AtlasProject
    let boundaries: [AtlasFeature]
    let onPrepared: (CollaborativeSurveyStoredPlan) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var boundaryID: UUID?
    @State private var workerCount = 5
    @State private var names = (1...64).map { "Сотрудник \($0)" }
    @State private var cellSize = "10"
    @State private var busy = false
    @State private var issue: String?
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Граница") {
                    Picker("Рабочий полигон", selection: $boundaryID) {
                        Text("Выберите границу").tag(UUID?.none)
                        ForEach(boundaries) { Text($0.label).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("collaboration.setup.boundary")
                    Text("Исходный контур и отверстия сохраняются. Независимые этажи и AR-сессии не объединяются этим распределением.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                }
                Section("Сотрудники") {
                    Stepper("Вышло сотрудников: \(workerCount)", value: $workerCount, in: 1...64)
                        .accessibilityIdentifier("collaboration.setup.count")
                    ForEach(0..<workerCount, id: \.self) { index in
                        TextField("Имя \(index + 1)", text: $names[index]).focused($editing)
                            .textInputAutocapitalization(.words).autocorrectionDisabled()
                            .accessibilityIdentifier("collaboration.setup.name.\(index)")
                    }
                }
                Section("Детальность распределения") {
                    TextField("Размер ячейки, м", text: $cellSize).keyboardType(.decimalPad).focused($editing)
                        .accessibilityIdentifier("collaboration.setup.cellSize")
                    Text("От 1 до 500 м. Маленькая ячейка не повышает точность GPS. Для больших участков начните с 10–25 м; краевые фрагменты выделяются для проверки.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                }
                Section {
                    Button("Предложить распределение", systemImage: "square.grid.3x3") { Task { await prepare() } }
                        .disabled(boundaryID == nil || busy).accessibilityIdentifier("collaboration.setup.preview")
                    if busy { ProgressView("Рассчитываем участки") }
                    if let issue { Text(issue).foregroundStyle(.orange) }
                }
            }.scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively)
                .background(Color.atlasCanvas).navigationTitle("Подготовка команды").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(busy) }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Готово") { editing = false }.accessibilityIdentifier("collaboration.setup.keyboardDone") }
                }
                .onAppear { if boundaries.count == 1 { boundaryID = boundaries.first?.id } }
        }.preferredColorScheme(.dark)
    }
    private func prepare() async {
        guard !busy, let selected = boundaries.first(where: { $0.id == boundaryID }) else { return }
        guard let size = Double(cellSize.replacingOccurrences(of: ",", with: ".")), size.isFinite else {
            issue = "Укажите размер ячейки числом в метрах."; return
        }
        editing = false; busy = true; defer { busy = false }
        let workers = Array(names.prefix(workerCount)).map { CollaborativeSurveyWorker(name: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let project = project
        do {
            let document = try await Task.detached(priority: .utility) {
                let plan = try CollaborativeSurveyPlanner.create(projectID: project.id, boundary: selected.geometry,
                    workers: workers, cellSizeMeters: size)
                return try CollaborativeSurveyStoredPlan(plan: plan, sourceFeatureID: selected.id,
                    sourceFeatureRevision: selected.revision, projectName: project.name, projectKind: project.kind)
            }.value
            issue = nil; onPrepared(document)
        } catch { issue = error.localizedDescription }
    }
}

private struct CollaborativeSurveyMapIndex: Sendable {
    struct WorkerSummary: Sendable {
        var total = 0; var area = 0.0; var verified = 0; var unobserved = 0; var observed = 0; var needsRescan = 0
    }
    let owners: [String: UUID]
    let coverage: [String: CollaborativeSurveyCoverage]
    let paletteIndex: [UUID: Int]
    let workers: [UUID: WorkerSummary]
    init(plan: CollaborativeSurveyPlan) {
        owners = Dictionary(uniqueKeysWithValues: plan.assignments.map { ($0.cellID, $0.workerID) })
        coverage = plan.coverageIndex()
        paletteIndex = Dictionary(uniqueKeysWithValues: plan.workers.enumerated().map { ($0.element.id, $0.offset) })
        var summaries = [UUID: WorkerSummary]()
        for cell in plan.cells {
            guard let owner = owners[cell.id] else { continue }
            var value = summaries[owner] ?? WorkerSummary(); value.total += 1; value.area += cell.estimatedWorkAreaSquareMeters
            switch coverage[cell.id] ?? .unobserved {
            case .unobserved, .walked: value.unobserved += 1
            case .observed: value.observed += 1
            case .verified: value.verified += 1
            case .needsRescan: value.needsRescan += 1
            }
            summaries[owner] = value
        }
        workers = summaries
    }
}

private enum CollaborativeSurveyPalette {
    static func worker(_ index: Int) -> Color {
        let colors: [Color] = [.atlasAccent, .cyan, .orange, .purple, .pink, .blue, .mint, .yellow]
        return colors[max(0, index) % colors.count]
    }
    static func status(_ value: CollaborativeSurveyCoverage) -> Color {
        switch value { case .unobserved: .atlasMuted; case .walked: .gray; case .observed: .cyan; case .verified: .atlasAccent; case .needsRescan: .orange }
    }
    static func symbol(_ value: CollaborativeSurveyCoverage) -> String {
        switch value { case .unobserved: "circle"; case .walked: "figure.walk"; case .observed: "camera.fill"; case .verified: "checkmark.circle.fill"; case .needsRescan: "exclamationmark.triangle.fill" }
    }
    static func title(_ value: CollaborativeSurveyCoverage) -> String {
        switch value { case .unobserved: "Без материалов"; case .walked: "Посещено, без съёмки"; case .observed: "Есть материал"; case .verified: "Проверено сотрудником"; case .needsRescan: "Нужно переснять" }
    }
}

private struct CollaborativeSurveyLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Нет материалов", systemImage: "circle")
                Spacer()
                Label("Есть материал", systemImage: "camera.fill").foregroundStyle(.cyan)
            }
            HStack {
                Label("Проверено", systemImage: "checkmark.circle.fill").foregroundStyle(Color.atlasAccent)
                Spacer()
                Label("Переснять", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text("Пунктир — краевой фрагмент. Цвет заливки обозначает сотрудника, не точность обмера.")
                .foregroundStyle(Color.atlasMuted)
            Text("Состояния взяты из журнала. При обмене JSON исходные фото и модели передаются отдельно.")
                .foregroundStyle(Color.atlasMuted)
        }.font(.caption).accessibilityIdentifier("collaboration.legend")
    }
}

/// Canvas clipping uses the ORIGINAL outer ring and holes. Grid rectangles
/// never paint outside the work area. Far views show sampled points explicitly.
private struct CollaborativeSurveyPlanCanvas: View {
    let plan: CollaborativeSurveyPlan
    let index: CollaborativeSurveyMapIndex
    let point: MetricPoint2D?
    let accuracyMeters: Double?
    let selectedWorkerID: UUID?
    let onSelect: (CollaborativeSurveyCell) -> Void
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @GestureState private var drag = CGSize.zero
    private let maximumVisibleCells = 600

    var body: some View {
        GeometryReader { geometry in
            let offset = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
            let transform = PlotTransform(points: plan.boundary.vertices, size: geometry.size, zoom: zoom, pan: offset)
            let visible = plan.cells.filter { transform.intersects([$0.boundsVertices[0], $0.boundsVertices[2]], width: Double(geometry.size.width)) }
            let detailed = visible.count <= maximumVisibleCells
            let strideSize = max(1, Int(ceil(Double(visible.count) / Double(maximumVisibleCells))))
            let rendered = detailed ? visible : stride(from: 0, to: visible.count, by: strideSize).map { visible[$0] }
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.atlasCanvas))
                var mask = path(plan.boundary.vertices, transform: transform)
                for hole in plan.boundary.holes { mask.addPath(path(hole, transform: transform)) }
                var clipped = context
                clipped.clip(to: mask, style: FillStyle(eoFill: true))
                for cell in rendered {
                    let owner = index.owners[cell.id]
                    let color = CollaborativeSurveyPalette.worker(owner.flatMap { index.paletteIndex[$0] } ?? 0)
                    let active = selectedWorkerID == nil || selectedWorkerID == owner
                    let center = transform.screen(cell.center)
                    if detailed {
                        let rectangle = path(cell.boundsVertices, transform: transform)
                        clipped.fill(rectangle, with: .color(color.opacity(active ? 0.24 : 0.09)))
                        clipped.stroke(rectangle, with: .color(color.opacity(active ? 0.9 : 0.3)),
                            style: StrokeStyle(lineWidth: 1, dash: cell.boundaryStatus == .partialRequiresReview ? [4, 3] : []))
                        let state = index.coverage[cell.id] ?? .unobserved
                        if state != .unobserved {
                            var symbol = clipped.resolve(Image(systemName: CollaborativeSurveyPalette.symbol(state)))
                            symbol.shading = .color(CollaborativeSurveyPalette.status(state))
                            clipped.draw(symbol, at: center)
                        }
                        if transform.scale * plan.cellSizeMeters > 40 {
                            clipped.draw(Text(cell.id).font(.system(size: 9)).foregroundStyle(Color.atlasInk),
                                at: CGPoint(x: center.x, y: center.y + 13))
                        }
                    } else {
                        clipped.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
                            with: .color(color.opacity(active ? 0.8 : 0.3)))
                    }
                }
                context.stroke(mask, with: .color(.atlasInk), lineWidth: 2)
                if let point {
                    let location = transform.screen(point)
                    if let accuracyMeters {
                        let radius = accuracyMeters * transform.scale
                        context.fill(Path(ellipseIn: CGRect(x: location.x - radius, y: location.y - radius, width: radius * 2, height: radius * 2)), with: .color(.blue.opacity(0.13)))
                    }
                    context.fill(Path(ellipseIn: CGRect(x: location.x - 5, y: location.y - 5, width: 10, height: 10)), with: .color(.blue))
                    context.stroke(Path(ellipseIn: CGRect(x: location.x - 5, y: location.y - 5, width: 10, height: 10)), with: .color(.white), lineWidth: 2)
                }
                let text = detailed ? "Коснитесь ячейки · ≈ \(Int(transform.visibleWidth.rounded())) м по ширине" : "Обзор: точки назначения · приблизьте для ячеек"
                context.draw(Text(text).font(.caption).foregroundStyle(Color.atlasInk),
                    at: CGPoint(x: size.width / 2, y: size.height - 17))
            }.contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    guard detailed else { return }
                    let point = transform.metric(location)
                    guard CollaborativeSurveyPlanner.contains(point, in: plan.boundary),
                          let selected = visible.first(where: {
                              point.x >= $0.boundsVertices[0].x && point.x <= $0.boundsVertices[2].x &&
                              point.y >= $0.boundsVertices[0].y && point.y <= $0.boundsVertices[2].y
                          }) else { return }
                    onSelect(selected)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 10).updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in pan.width += value.translation.width; pan.height += value.translation.height })
                .overlay(alignment: .topTrailing) { zoomControls }
                .accessibilityIdentifier("collaboration.canvas")
                .accessibilityLabel(plan.coordinateReference == .wgs84 ? "План участков в проекции WGS84. Север сверху; GPS показан с кругом погрешности." : "План участков в локальных метрах. GPS в этой системе недоступен.")
        }
    }
    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { zoom = max(1, zoom / 1.7) } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel("Уменьшить план").accessibilityIdentifier("collaboration.zoomOut")
            Button { zoom = min(32, zoom * 1.7) } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel("Приблизить план").accessibilityIdentifier("collaboration.zoomIn")
            Button { zoom = 1; pan = .zero } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .accessibilityLabel("Показать весь полигон")
        }.buttonStyle(.bordered).padding(8).background(Color.atlasCanvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
    }
    private func path(_ vertices: [MetricPoint2D], transform: PlotTransform) -> Path {
        Path { value in
            guard let first = vertices.first else { return }
            value.move(to: transform.screen(first)); for point in vertices.dropFirst() { value.addLine(to: transform.screen(point)) }; value.closeSubpath()
        }
    }
}

@MainActor
private struct CollaborativeSurveyCellScreen: View {
    let cell: CollaborativeSurveyCell
    let document: CollaborativeSurveyStoredPlan
    let selectedWorkerID: UUID?
    let currentGPSCellID: String?
    let fix: CollaborativeGuidanceService.Fix?
    let coverageStatus: CollaborativeSurveyCoverage
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    let onSave: (CollaborativeSurveyPlan) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var scans: [ScanRecord] = []
    @State private var captureID: UUID?
    @State private var assetID: UUID?
    @State private var quality = CollaborativeSurveyEvidenceQuality.unknown
    @State private var note = ""
    @State private var reviewNote = ""
    @State private var boundaryReviewed = false
    @State private var materialReviewed = false
    @State private var referencedIDs = Set<UUID>()
    @State private var newOwnerID: UUID?
    @State private var confirmingReassignment = false
    @State private var busy = false
    @State private var issue: String?
    @FocusState private var editing: Bool
    private var owner: CollaborativeSurveyWorker? {
        let id = document.plan.assignments.first { $0.cellID == cell.id }?.workerID
        return document.plan.workers.first { $0.id == id }
    }
    private var capture: ScanRecord? { scans.first { $0.id == captureID } }
    private var sourceAssets: [SourceAssetReference] {
        capture?.assets.filter { [.image, .video, .mesh, .roomPlanJSON].contains($0.kind) } ?? []
    }
    private var references: [CollaborativeSurveyEvidence] {
        document.plan.evidence.filter { $0.cellIDs.contains(cell.id) && $0.kind == .captureObserved && $0.quality != .unknown }
    }
    private var usableReferences: [CollaborativeSurveyEvidence] { references.filter { $0.quality == .usable } }
    private var rescanReferences: [CollaborativeSurveyEvidence] { references.filter { $0.quality == .needsRescan } }
    private var canVerify: Bool {
        selectedWorkerID != nil && materialReviewed && !reviewNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        usableReferences.contains { referencedIDs.contains($0.id) } &&
        (cell.boundaryStatus == .interior || boundaryReviewed)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Ячейка \(cell.id)") { overview }
                Section("Реальный материал") { materialSection }
                Section("Проверка полноты") { verificationSection }
                Section("Назначение") { assignmentSection }
                Section("Посещение") {
                    Button("Отметить посещение GPS", systemImage: "figure.walk") { Task { await recordWalk() } }
                        .disabled(busy || selectedWorkerID == nil || currentGPSCellID != cell.id || fix == nil)
                        .accessibilityIdentifier("collaboration.cell.walk")
                    Text("Только свежая точка в этой ячейке вне круга неопределённости. Посещение не подтверждает фото или LiDAR-покрытие.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                }
                if busy { Section { ProgressView("Проверяем источник и сохраняем журнал") } }
                if let issue { Section { Text(issue).foregroundStyle(.orange).accessibilityIdentifier("collaboration.cell.issue") } }
            }.scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively)
                .background(Color.atlasCanvas).navigationTitle(cell.id).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(busy) }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Готово") { editing = false }.accessibilityIdentifier("collaboration.cell.keyboardDone") }
                }
                .task { scans = await model.scans(in: project); newOwnerID = owner?.id }
                .onChange(of: captureID) { _, _ in assetID = nil }
                .confirmationDialog("Передать ячейку выбранному сотруднику? История назначения сохранится.", isPresented: $confirmingReassignment, titleVisibility: .visible) {
                    Button("Передать ячейку") { Task { await reassign() } }
                    Button("Отмена", role: .cancel) { }
                }
        }.preferredColorScheme(.dark)
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Назначено: \(owner?.name ?? "Не определено")").font(.headline).accessibilityIdentifier("collaboration.cell.owner")
            Label(CollaborativeSurveyPalette.title(coverageStatus),
                  systemImage: CollaborativeSurveyPalette.symbol(coverageStatus))
                .accessibilityIdentifier("collaboration.cell.coverage")
            Text("Рабочая площадь ≈ \(cell.estimatedWorkAreaSquareMeters.formatted(.number.precision(.fractionLength(1)))) м²")
                .font(.caption).foregroundStyle(Color.atlasMuted)
            if cell.boundaryStatus == .partialRequiresReview {
                Text("Краевой фрагмент: рабочая часть ограничена исходным полигоном и отверстиями. Прямоугольник сетки не является границей участка.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if selectedWorkerID == nil { Text("Сначала выберите себя в основном экране плана.").font(.footnote).foregroundStyle(.orange) }
        }
    }
    private var materialSection: some View {
        Group {
            Picker("Материал проекта", selection: $captureID) {
                Text("Выберите съёмку").tag(UUID?.none)
                ForEach(scans) { scan in Text("\(scan.createdAt.formatted(date: .numeric, time: .shortened)) · \(scanSourceTitle(scan.source)) · \(scan.id.uuidString.prefix(6))").tag(Optional(scan.id)) }
            }.accessibilityIdentifier("collaboration.cell.capture")
            if captureID != nil {
                Picker("Исходный файл", selection: $assetID) {
                    Text("Выберите файл").tag(UUID?.none)
                    ForEach(sourceAssets) { Text(URL(fileURLWithPath: $0.relativePath).lastPathComponent).tag(Optional($0.id)) }
                }.accessibilityIdentifier("collaboration.cell.asset")
            }
            Picker("Состояние материала", selection: $quality) {
                Text("Не оценено").tag(CollaborativeSurveyEvidenceQuality.unknown)
                Text("Пригоден после осмотра").tag(CollaborativeSurveyEvidenceQuality.usable)
                Text("Нужно переснять").tag(CollaborativeSurveyEvidenceQuality.needsRescan)
            }.accessibilityIdentifier("collaboration.cell.quality")
            TextField("Что видно в материале и чего не хватает", text: $note, axis: .vertical).lineLimit(2...5).focused($editing)
                .accessibilityIdentifier("collaboration.cell.note")
            Text("Вы вручную связываете материал с рабочей ячейкой. Это не совмещение 3D и не доказательство съёмки всей её площади. Исходный файл проверяется по SHA256; его AR-система сохраняется отдельно.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
            Button("Связать реальный файл с ячейкой", systemImage: "link") { Task { await recordMaterial() } }
                .disabled(busy || selectedWorkerID == nil || captureID == nil || assetID == nil)
                .accessibilityIdentifier("collaboration.cell.attach")
        }
    }
    private var verificationSection: some View {
        Group {
            if usableReferences.isEmpty {
                Text("Для проверки нужен хотя бы один реальный материал этой ячейки, оценённый как пригодный. GPS-посещение не подходит.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            } else {
                ForEach(usableReferences) { item in
                    Toggle("Материал \(item.captureID?.uuidString.prefix(6) ?? "—") · \(item.timestamp.formatted(date: .numeric, time: .shortened))", isOn: Binding(
                        get: { referencedIDs.contains(item.id) },
                        set: { if $0 { referencedIDs.insert(item.id) } else { referencedIDs.remove(item.id) } }))
                        .accessibilityIdentifier("collaboration.cell.reference." + item.id.uuidString)
                }
            }
            if !rescanReferences.isEmpty {
                Text("Отмеченных проблем: \(rescanReferences.count). Подтверждение включает их идентификаторы; опишите, как проверили или пересняли проблемные места.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            TextField("Результат осмотра и что проверено", text: $reviewNote, axis: .vertical).lineLimit(2...5).focused($editing)
                .accessibilityIdentifier("collaboration.cell.reviewNote")
            Toggle("Я проверил выбранные материалы и полноту ячейки", isOn: $materialReviewed)
                .accessibilityIdentifier("collaboration.cell.materialReviewed")
            if cell.boundaryStatus == .partialRequiresReview {
                Toggle("Проверил рабочий край и исключённые контуры", isOn: $boundaryReviewed)
                    .accessibilityIdentifier("collaboration.cell.boundaryReviewed")
            }
            Text("Проверка сотрудником означает осмотр полноты материалов. Она не подтверждает сантиметровую точность GPS или автоматическую регистрацию модели.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
            Button("Записать проверку", systemImage: "checkmark.circle") { Task { await verify() } }
                .disabled(busy || !canVerify).accessibilityIdentifier("collaboration.cell.verify")
        }
    }
    private var assignmentSection: some View {
        Group {
            Picker("Передать сотруднику", selection: $newOwnerID) {
                Text("Выберите сотрудника").tag(UUID?.none)
                ForEach(document.plan.workers) { Text($0.name).tag(Optional($0.id)) }
            }.accessibilityIdentifier("collaboration.cell.newOwner")
            Button("Проверить переназначение", systemImage: "arrow.left.arrow.right") {
                editing = false; confirmingReassignment = true
            }.disabled(busy || selectedWorkerID == nil || newOwnerID == nil || newOwnerID == owner?.id)
                .accessibilityIdentifier("collaboration.cell.reassign")
            Text("Это локальная правка общего плана. Передайте новую версию коллегам; расходящиеся назначения не объединяются автоматически.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
        }
    }
    private func recordMaterial() async {
        guard !busy, let worker = selectedWorkerID, let scan = capture,
              let asset = sourceAssets.first(where: { $0.id == assetID }) else { return }
        busy = true; editing = false; defer { busy = false }
        let root = model.directory; let sourcePlan = document.plan; let selectedCell = cell
        let selectedQuality = quality; let note = note
        do {
            let next = try await Task.detached(priority: .utility) {
                let proof = try CollaborativeSurveySourceProof.validate(asset: asset, scan: scan, projectID: sourcePlan.projectID, root: root)
                var plan = sourcePlan
                let item = CollaborativeSurveyEvidence(workerID: worker, kind: .captureObserved, timestamp: Date(),
                    cellIDs: [selectedCell.id], captureID: scan.id, sourceSHA256: proof,
                    footprintProvenance: .operatorMapped, sourceFrameID: scan.frameID,
                    footprint: MetricPolygon(frameID: plan.gridFrameID, vertices: selectedCell.boundsVertices),
                    quality: selectedQuality, note: note)
                try plan.recordEvidence(item, expectedRevision: plan.revision); return plan
            }.value
            if await onSave(next) { dismiss() } else { issue = "Не удалось сохранить. Прежний журнал сохранён; откройте ячейку заново." }
        } catch { issue = error.localizedDescription }
    }
    private func verify() async {
        guard !busy, canVerify, let worker = selectedWorkerID else { return }
        let selected = usableReferences.filter { referencedIDs.contains($0.id) }
        let ids = selected.map(\.id) + rescanReferences.map(\.id)
        guard ids.count <= 256 else { issue = "В проверке больше 256 источников. Разделите работу на следующий этап."; return }
        busy = true; editing = false; defer { busy = false }
        let root = model.directory; let sourcePlan = document.plan; let scans = scans
        let selectedCell = cell; let note = reviewNote; let boundaryReviewed = boundaryReviewed
        do {
            let next = try await Task.detached(priority: .utility) {
                for evidence in selected {
                    guard let scan = scans.first(where: { $0.id == evidence.captureID }),
                          let expected = evidence.sourceSHA256 else { throw CollaborativeSurveyStoreError.invalidDocument }
                    var found = false
                    for asset in scan.assets where [.image, .video, .mesh, .roomPlanJSON].contains(asset.kind) {
                        if let known = asset.sha256, known != expected { continue }
                        if let actual = try? CollaborativeSurveySourceProof.validate(asset: asset, scan: scan, projectID: sourcePlan.projectID, root: root), actual == expected { found = true; break }
                    }
                    guard found else { throw CollaborativeSurveyStoreError.invalidDocument }
                }
                var plan = sourcePlan
                let item = CollaborativeSurveyEvidence(workerID: worker, kind: .operatorVerified, timestamp: Date(),
                    cellIDs: [selectedCell.id], quality: .usable, referencedEvidenceIDs: ids,
                    boundaryReviewed: boundaryReviewed, note: note)
                try plan.recordEvidence(item, expectedRevision: plan.revision); return plan
            }.value
            if await onSave(next) { dismiss() } else { issue = "Проверка не записана. Откройте актуальную ячейку перед повтором." }
        } catch { issue = "Проверка не записана: \(error.localizedDescription). Выбранные исходные файлы должны находиться в этом проекте на iPhone." }
    }
    private func recordWalk() async {
        guard !busy, let worker = selectedWorkerID, currentGPSCellID == cell.id, let fix,
              (-2...8).contains(Date().timeIntervalSince(fix.capturedAt)) else { return }
        busy = true; defer { busy = false }
        let source = document.plan; let selectedCell = cell
        do {
            let next = try await Task.detached(priority: .utility) {
                var plan = source
                let note = "GPS-посещение, не съёмка: \(fix.coordinate.latitude), \(fix.coordinate.longitude). Погрешность сообщена телефоном; принадлежность проверена с её учётом."
                let item = CollaborativeSurveyEvidence(workerID: worker, kind: .gpsWalk, timestamp: fix.capturedAt,
                    cellIDs: [selectedCell.id], horizontalAccuracyMeters: fix.accuracyMeters, note: note)
                try plan.recordEvidence(item, expectedRevision: plan.revision); return plan
            }.value
            if await onSave(next) { dismiss() }
        } catch { issue = error.localizedDescription }
    }
    private func reassign() async {
        guard !busy, let owner = newOwnerID else { return }; busy = true; defer { busy = false }
        let source = document.plan; let selectedCell = cell
        do {
            let next = try await Task.detached(priority: .utility) {
                var plan = source; try plan.reassign(cellIDs: [selectedCell.id], to: owner, expectedRevision: plan.revision); return plan
            }.value
            if await onSave(next) { dismiss() }
        } catch { issue = error.localizedDescription }
    }
}

private enum CollaborativeSurveySourceProof {
    static func validate(asset: SourceAssetReference, scan: ScanRecord, projectID: UUID, root: URL) throws -> String {
        guard scan.projectID == projectID, scan.assets.contains(asset), asset.byteCount > 0 else {
            throw CollaborativeSurveyStoreError.invalidDocument
        }
        try FieldTransferPaths.validate(relativePath: asset.relativePath)
        let base = root.standardizedFileURL
        guard base.path == base.resolvingSymlinksInPath().path else { throw CollaborativeSurveyStoreError.invalidPath }
        var file = base
        let components = asset.relativePath.split(separator: "/")
        for (index, component) in components.enumerated() {
            file.appendPathComponent(String(component))
            let type = try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
            guard type == (index == components.count - 1 ? .typeRegular : .typeDirectory),
                  file.standardizedFileURL.path == file.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw CollaborativeSurveyStoreError.invalidPath
            }
        }
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (before[.size] as? NSNumber)?.int64Value == asset.byteCount else { throw CollaborativeSurveyStoreError.invalidDocument }
        let actual = try FieldTransferDigest.sha256(fileURL: file)
        if let declared = asset.sha256, declared != actual { throw CollaborativeSurveyStoreError.invalidDocument }
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (after[.size] as? NSNumber)?.int64Value == asset.byteCount,
              (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date),
              (before[.systemFileNumber] as? NSNumber) == (after[.systemFileNumber] as? NSNumber) else {
            throw CollaborativeSurveyStoreError.invalidDocument
        }
        return actual
    }
}

private struct CollaborativeSurveyShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

private struct CollaborativeSurveyOrientationReporter: UIViewRepresentable {
    let report: @MainActor (UIInterfaceOrientation) -> Void
    func makeUIView(context: Context) -> CollaborativeSurveyOrientationView {
        let view = CollaborativeSurveyOrientationView(); view.onOrientation = report; return view
    }
    func updateUIView(_ view: CollaborativeSurveyOrientationView, context: Context) {
        view.onOrientation = report; view.reportOrientation()
    }
}

private final class CollaborativeSurveyOrientationView: UIView {
    var onOrientation: (@MainActor (UIInterfaceOrientation) -> Void)?
    private var last: UIInterfaceOrientation?
    override func didMoveToWindow() { super.didMoveToWindow(); last = nil; reportOrientation() }
    override func layoutSubviews() { super.layoutSubviews(); reportOrientation() }
    func reportOrientation() {
        guard let scene = window?.windowScene else { return }
        let orientation = scene.interfaceOrientation
        guard orientation != .unknown, orientation != last else { return }
        last = orientation
        Task { @MainActor [weak self, weak scene] in
            guard let self, let scene, self.window?.windowScene === scene,
                  scene.interfaceOrientation == orientation else { return }
            self.onOrientation?(orientation)
        }
    }
}

@MainActor
private struct CollaborativeSurveyCellListScreen: View {
    let plan: CollaborativeSurveyPlan
    let index: CollaborativeSurveyMapIndex
    let selectedWorkerID: UUID?
    let onSelect: (CollaborativeSurveyCell) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var onlyMine = true
    @State private var search = ""
    private var cells: [CollaborativeSurveyCell] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return plan.cells.filter {
            (!onlyMine || selectedWorkerID == nil || index.owners[$0.id] == selectedWorkerID) &&
            (query.isEmpty || $0.id.lowercased().contains(query))
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section { Toggle("Только мои ячейки", isOn: $onlyMine).disabled(selectedWorkerID == nil) }
                Section {
                    ForEach(cells) { cell in
                        Button { onSelect(cell) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(cell.id).font(.headline)
                                    Text(plan.workers.first { $0.id == index.owners[cell.id] }?.name ?? "Сотрудник")
                                        .font(.caption).foregroundStyle(Color.atlasMuted)
                                    if cell.boundaryStatus == .partialRequiresReview { Text("Краевой фрагмент").font(.caption).foregroundStyle(.orange) }
                                }
                                Spacer()
                                let state = index.coverage[cell.id] ?? .unobserved
                                Image(systemName: CollaborativeSurveyPalette.symbol(state)).foregroundStyle(CollaborativeSurveyPalette.status(state))
                                    .accessibilityLabel(CollaborativeSurveyPalette.title(state))
                            }
                        }.accessibilityIdentifier("collaboration.cell." + cell.id)
                    }
                }
            }.searchable(text: $search, prompt: "Номер ячейки, например r2c3")
                .scrollContentBackground(.hidden).background(Color.atlasCanvas)
                .navigationTitle("Ячейки плана").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}
