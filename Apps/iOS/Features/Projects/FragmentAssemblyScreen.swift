import SwiftUI
import UIKit
import AtlasCore

/// Original meshes and their local frames remain unchanged. Every placement is
/// reviewed and exported into a separate, explicitly labelled derivative.
struct FragmentAssemblyScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @State private var document: FragmentAssemblyDocument?
    @State private var readiness: FragmentAssemblyReadiness?
    @State private var scans: [ScanRecord] = []
    @State private var anchorID: UUID?
    @State private var busy = false
    @State private var loaded = false
    @State private var issue: String?
    @State private var showPairing = false
    @State private var review: FragmentRegistrationReviewRequest?
    @State private var result: FragmentAssemblyExportResult?
    @State private var sharing = false
    private var store: FragmentAssemblyStore { .init(projectID: project.id, assetDirectory: model.directory) }

    var body: some View {
        List {
            Section {
                Text("Общие ориентиры связывают независимые сканы в одну систему координат. Оригиналы сохраняются; GPS не используется как точная привязка.")
                    .foregroundStyle(Color.atlasMuted)
            }
            if !loaded { ProgressView("Открываем фрагменты…") }
            if let document {
                sources(document)
                Section("Привязки") {
                    Button("Связать два фрагмента", systemImage: "point.3.connected.trianglepath.dotted") { showPairing = true }
                        .disabled(busy || document.sourceBindings.count < 2)
                        .accessibilityIdentifier("assembly.addRegistration")
                    ForEach(document.registry.registrations) { record in
                        Button { review = .init(record: record, documentSHA256: document.currentSHA256) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(short(record.candidate.source.captureID)) → \(short(record.candidate.target.captureID))")
                                Text("\(stateTitle(record.state)) · проверка \(distance(record.candidate.maximumCheckResidualMeters))")
                                    .font(.caption).foregroundStyle(Color.atlasMuted)
                            }
                        }
                    }
                }.listRowBackground(Color.atlasCard)
                assemblyResult(document)
            } else if loaded {
                Section("Опорный фрагмент") {
                    if scans.isEmpty {
                        Text("Сначала сохраните LiDAR-съёмку в этом проекте. Каждый новый сеанс имеет собственную систему координат.")
                            .accessibilityIdentifier("assembly.emptyState")
                    } else {
                        Picker("Опора", selection: $anchorID) {
                            Text("Выберите фрагмент").tag(nil as UUID?)
                            ForEach(scans) { scan in Text(scanTitle(scan)).tag(scan.id as UUID?) }
                        }
                        Button("Создать журнал сборки") { Task { await bootstrap() } }
                            .disabled(anchorID == nil || busy).accessibilityIdentifier("assembly.bootstrap")
                    }
                }.listRowBackground(Color.atlasCard)
            }
            if busy { ProgressView("Проверяем оригиналы…") }
            if let issue { Section { Text(issue).foregroundStyle(.orange) }.listRowBackground(Color.atlasCard) }
            Section("Как связать надёжно") {
                Text("Выберите не менее трёх общих неподвижных точек, разнесённых по участку и не лежащих на одной прямой. Ещё одну отдельную точку используйте для проверки: она не участвует в вычислении.")
                    .accessibilityIdentifier("assembly.guide")
                Text("Углы капитального забора, марки и углы зданий подходят лучше веток, кустов и похожих друг на друга памятников. Продольные цепочки привязок требуют дополнительных контрольных точек и замыкания на прежние участки.")
                Text("Здесь выполняется совмещение сеток. Текстурирование, сшивка фотографий и построение ортофото требуют отдельной обработки.")
            }.font(.footnote).foregroundStyle(Color.atlasMuted).listRowBackground(Color.atlasCard)
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .navigationTitle("Сборка фрагментов").navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(isPresented: $showPairing) {
            if let document {
                FragmentPairingScreen(document: document, assetDirectory: model.directory) { source, target, controls, checks in
                    try await propose(source: source, target: target, controls: controls, checks: checks)
                }
            }
        }
        .sheet(item: $review) { request in
            FragmentRegistrationReviewScreen(record: request.record) { state, reason in
                try await decide(request.record.id, reviewedSHA256: request.documentSHA256, state: state, reason: reason)
            }
        }
        .sheet(isPresented: $sharing) { if let result { FragmentAssemblyShareSheet(urls: result.urls) } }
    }

    private func sources(_ document: FragmentAssemblyDocument) -> some View {
        Section("Оригиналы · \(document.sourceBindings.count)") {
            ForEach(document.sourceBindings, id: \.source.captureID) { binding in
                NavigationLink {
                    MeshPreviewScreen(url: model.directory.appendingPathComponent(binding.relativePath),
                        projectID: project.id, journalDirectory: model.directory.appendingPathComponent("Projects/\(project.id.uuidString)/ModelMeasurements"))
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(binding.source.captureID == document.registry.anchor.captureID ? "Опора · \(short(binding.source.captureID))" : "Фрагмент · \(short(binding.source.captureID))")
                        Text("\(binding.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(placementTitle(binding.source.frameID))")
                            .font(.caption).foregroundStyle(Color.atlasMuted)
                    }
                }
            }
            let added = Set(document.sourceBindings.map(\.source.captureID))
            ForEach(scans.filter { !added.contains($0.id) }) { scan in
                Button("Добавить · \(scanTitle(scan))") { Task { await add(scan) } }.disabled(busy)
            }
        }.listRowBackground(Color.atlasCard)
    }
    private func assemblyResult(_ document: FragmentAssemblyDocument) -> some View {
        Section("Общая модель") {
            if let readiness {
                Text(readiness.readyForAlignedDerivative ? "Подтверждённые привязки согласованы" : "Есть отдельные или противоречивые фрагменты")
                if !readiness.conflicts.isEmpty {
                    Text("Противоречий: \(readiness.conflicts.count). Проверьте ориентиры; автоматическая сборка остановлена.").foregroundStyle(.orange)
                }
                Button("Собрать отдельный OBJ и отчёт", systemImage: "cube.transparent") { Task { await export(document) } }
                    .disabled(busy || !readiness.readyForAlignedDerivative || document.sourceBindings.count < 2)
                    .accessibilityIdentifier("assembly.exportAligned")
            }
            if let result {
                NavigationLink("Открыть собранную модель") { MeshPreviewScreen(url: result.meshURL) }
                Button("Поделиться моделью и отчётом", systemImage: "square.and.arrow.up") { sharing = true }
            }
            Text("Файл в метрах, в системе опорного скана. Привязка к географической карте выполняется отдельно. Остаточная ошибка на ориентирах не задаёт точность всей территории.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
        }.listRowBackground(Color.atlasCard)
    }
    private func reload() async {
        do {
            scans = await model.scans(in: project).filter { $0.source == .liDAR && $0.status == .ready && $0.assets.contains { $0.relativePath.lowercased().hasSuffix(".obj") } }
            try await display(try await store.load())
        } catch { issue = error.localizedDescription }
        loaded = true
    }
    private func display(_ next: FragmentAssemblyDocument?) async throws {
        let state = try await Task.detached(priority: .utility) { try next?.registry.assemblyReadiness() }.value
        document = next; readiness = state
    }
    private func bootstrap() async {
        guard let anchorID else { return }; busy = true; issue = nil; defer { busy = false }
        do { try await display(try await store.bootstrap(scans: scans, anchorCaptureID: anchorID)); changed() }
        catch { issue = error.localizedDescription }
    }
    private func add(_ scan: ScanRecord) async {
        guard let document else { return }; busy = true; issue = nil; defer { busy = false }
        do { try await display(try await store.registerSource(scan: scan, expectedSHA256: document.currentSHA256)); changed() }
        catch { issue = error.localizedDescription }
    }
    private func propose(source: FragmentSourceReference, target: FragmentSourceReference,
                         controls: [FragmentControlPointPair], checks: [FragmentControlPointPair]) async throws {
        guard let document else { throw FragmentAssemblyError.missingDocument }
        let next = try await Task.detached(priority: .utility) {
            var registry = document.registry
            try registry.propose(source: source, target: target, controls: controls, checkPoints: checks,
                gravityConstraint: .iPhoneYUp, expectedRevision: registry.revision)
            return registry
        }.value
        try await display(try await store.saveRegistry(next, expectedSHA256: document.currentSHA256)); changed()
    }
    private func decide(_ id: UUID, reviewedSHA256: String, state: FragmentRegistrationState, reason: String) async throws {
        guard let document else { throw FragmentAssemblyError.missingDocument }
        guard document.currentSHA256 == reviewedSHA256 else { throw FragmentAssemblyError.revisionConflict }
        let operatorID: UUID
        let key = "TerraView.LocalRegistrationOperator"
        if let raw = UserDefaults.standard.string(forKey: key), let saved = UUID(uuidString: raw) { operatorID = saved }
        else { operatorID = UUID(); UserDefaults.standard.set(operatorID.uuidString, forKey: key) }
        var registry = document.registry
        try registry.decide(registrationID: id, state: state, operatorID: operatorID, reason: reason, expectedRevision: registry.revision)
        try await display(try await store.saveRegistry(registry, expectedSHA256: document.currentSHA256)); changed()
    }
    private func export(_ document: FragmentAssemblyDocument) async {
        busy = true; issue = nil; defer { busy = false }
        let root = model.directory
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("TerraView-assembly-\(UUID().uuidString)")
        do {
            result = try await Task.detached(priority: .utility) {
                try FragmentMeshAssemblyExporter.export(document: document, assetDirectory: root, outputDirectory: output)
            }.value
        } catch { issue = error.localizedDescription }
    }
    private func changed() { result = nil; model.fieldMaterialsDidChange(projectID: project.id) }
    private func placementTitle(_ frame: UUID) -> String {
        switch readiness?.placements.first(where: { $0.source.frameID == frame })?.status {
        case .registered: "привязан"
        case .ambiguous: "противоречие"
        default: "отдельная система"
        }
    }
    private func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }
    private func scanTitle(_ scan: ScanRecord) -> String { "\(scan.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(short(scan.id))" }
    private func stateTitle(_ state: FragmentRegistrationState) -> String {
        switch state { case .candidate: "Нужна проверка"; case .approved: "Подтверждено"; case .rejected: "Отклонено" }
    }
    private func distance(_ value: Double?) -> String { value.map { String(format: "%.3f м", $0) } ?? "нет контрольной точки" }
}

private struct FragmentPairDraft: Identifiable {
    let id = UUID()
    var source = ["", "", ""]
    var target = ["", "", ""]
    var isCheck = false
    func pair() throws -> FragmentControlPointPair {
        func point(_ values: [String]) throws -> MetricPoint3D {
            let parsed = values.compactMap { Double($0.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
            guard parsed.count == 3, parsed.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else {
                throw TeamError.rejected("Введите конечные X, Y и Z в метрах для каждой точки.")
            }
            return .init(x: parsed[0], y: parsed[1], z: parsed[2])
        }
        return try .init(id: id, source: point(source), target: point(target), evidence: .operatorMatchedPoint)
    }
}

private struct FragmentPairingScreen: View {
    let document: FragmentAssemblyDocument
    let assetDirectory: URL
    let save: (FragmentSourceReference, FragmentSourceReference, [FragmentControlPointPair], [FragmentControlPointPair]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: UUID?
    @State private var targetID: UUID?
    @State private var pairs = [FragmentPairDraft(), FragmentPairDraft(), FragmentPairDraft(), FragmentPairDraft(isCheck: true)]
    @State private var busy = false
    @State private var issue: String?
    @State private var endpointRequest: FragmentEndpointRequest?
    var body: some View {
        NavigationStack {
            Form {
                Section("Системы координат оригиналов") {
                    fragmentPicker("Перемещаемый", selection: $sourceID)
                    fragmentPicker("Опорный", selection: $targetID)
                    Text("Точки должны обозначать одни и те же неподвижные места. Можно взять координаты концов измерений, сохранённых в просмотре оригинала.").font(.footnote)
                }
                ForEach($pairs) { $pair in
                    Section(pair.isCheck ? "Независимая проверочная точка" : "Общий ориентир") {
                        Toggle("Только проверка, без подгонки", isOn: $pair.isCheck)
                        coordinateRow("Перемещаемый", values: $pair.source)
                        Button("Выбрать точку из его измерений") { endpointRequest = .init(pairID: pair.id, isSource: true, captureID: sourceID) }.disabled(sourceID == nil)
                        coordinateRow("Опорный", values: $pair.target)
                        Button("Выбрать точку из его измерений") { endpointRequest = .init(pairID: pair.id, isSource: false, captureID: targetID) }.disabled(targetID == nil)
                    }
                }
                Section {
                    Button("Добавить ориентир", systemImage: "plus") { pairs.append(.init()) }.disabled(pairs.count >= 16 || busy)
                    Text("Минимум три точки для расчёта и одна отдельная для проверки. После расчёта проверьте ошибки и подтвердите привязку в журнале.").font(.footnote)
                    if let issue { Text(issue).foregroundStyle(.orange) }
                }
            }.scrollContentBackground(.hidden).background(Color.atlasCanvas)
            .navigationTitle("Общие ориентиры").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Рассчитать") { Task { await calculate() } }.disabled(busy || sourceID == nil || targetID == nil || sourceID == targetID) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Готово") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
            }
            .sheet(item: $endpointRequest) { request in
                if let binding = document.sourceBindings.first(where: { $0.source.captureID == request.captureID }) {
                    FragmentEndpointPicker(binding: binding, projectID: document.projectID, assetDirectory: assetDirectory) { values in
                        if let index = pairs.firstIndex(where: { $0.id == request.pairID }) {
                            let strings = values.map { String(format: "%.8f", $0) }
                            if request.isSource { pairs[index].source = strings } else { pairs[index].target = strings }
                        }
                        endpointRequest = nil
                    }
                }
            }
        }
    }
    private func fragmentPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("Выберите фрагмент").tag(nil as UUID?)
            ForEach(document.sourceBindings, id: \.source.captureID) { binding in
                Text(String(binding.source.captureID.uuidString.prefix(8))).tag(binding.source.captureID as UUID?)
            }
        }.onChange(of: selection.wrappedValue) { _, _ in pairs = [.init(), .init(), .init(), .init(isCheck: true)] }
    }
    private func coordinateRow(_ title: String, values: Binding<[String]>) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(Color.atlasMuted)
            HStack {
                ForEach(0..<3, id: \.self) { axis in
                    TextField(["X, м", "Y, м", "Z, м"][axis], text: values[axis]).keyboardType(.numbersAndPunctuation)
                }
            }
        }
    }
    private func calculate() async {
        busy = true; issue = nil; defer { busy = false }
        do {
            guard let source = document.sourceBindings.first(where: { $0.source.captureID == sourceID })?.source,
                  let target = document.sourceBindings.first(where: { $0.source.captureID == targetID })?.source else { throw FragmentAssemblyError.invalidDocument }
            let controls = try pairs.filter { !$0.isCheck }.map { try $0.pair() }
            let checks = try pairs.filter(\.isCheck).map { try $0.pair() }
            guard controls.count >= 3, !checks.isEmpty else { throw TeamError.rejected("Нужны минимум три ориентира и одна независимая проверочная точка.") }
            try await save(source, target, controls, checks); dismiss()
        } catch { issue = error.localizedDescription }
    }
}

private struct FragmentEndpointRequest: Identifiable { let id = UUID(); let pairID: UUID; let isSource: Bool; let captureID: UUID? }
private struct FragmentEndpointPicker: View {
    let binding: FragmentAssemblySourceBinding
    let projectID: UUID
    let assetDirectory: URL
    let select: ([Double]) -> Void
    @State private var observations: [MeshDimensionObservation] = []
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            List {
                Text("Координаты относятся к неизменённому оригиналу. Выберите конец измерения, совпадающий с общим ориентиром.")
                ForEach(observations) { observation in
                    Section(observation.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                        Button("Начало · \(description(observation.start))") { select(observation.start) }
                        Button("Конец · \(description(observation.end))") { select(observation.end) }
                    }
                }
                if observations.isEmpty { Text(issue ?? "Сохранённых измерений нет. Откройте оригинал, измерьте ориентиры или введите их координаты вручную.") }
            }.navigationTitle("Точки оригинала").navigationBarTitleDisplayMode(.inline)
            .task {
                do {
                    let directory = assetDirectory.appendingPathComponent("Projects/\(projectID.uuidString)/ModelMeasurements")
                    let journal = MeshMeasurementJournal(directory: directory, projectID: projectID)
                    observations = try await journal.load(source: binding.source.sourceSHA256).filter { $0.frameID == binding.source.frameID && $0.unit == "m" && $0.start.count == 3 && $0.end.count == 3 }
                } catch { issue = error.localizedDescription }
            }
        }
    }
    private func description(_ point: [Double]) -> String { point.map { String(format: "%.3f", $0) }.joined(separator: "; ") + " м" }
}

private struct FragmentRegistrationReviewRequest: Identifiable {
    var id: UUID { record.id }
    let record: FragmentRegistrationRecord
    let documentSHA256: String
}
private struct FragmentRegistrationReviewScreen: View {
    let record: FragmentRegistrationRecord
    let save: (FragmentRegistrationState, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var busy = false
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Проверка расчёта") {
                    LabeledContent("Ошибка RMS на ориентирах", value: metres(record.candidate.rmsResidualMeters))
                    LabeledContent("Максимум на ориентирах", value: metres(record.candidate.maximumResidualMeters))
                    LabeledContent("Независимая проверка", value: metres(record.candidate.maximumCheckResidualMeters))
                    LabeledContent("Отклонение вертикали", value: record.candidate.gravityDeviationDegrees.map { String(format: "%.2f°", $0) } ?? "не проверена")
                    Text(record.candidate.quality == .meetsThresholds ? "Пороговые проверки пройдены. Убедитесь, что ориентиры обозначают одни и те же физические точки." : "Пороговые проверки не пройдены. Подтверждение недоступно; уточните ориентиры.")
                }
                Section("Ошибки по точкам") {
                    ForEach(record.candidate.residuals, id: \.controlID) { residual in
                        LabeledContent("Ориентир · \(String(residual.controlID.uuidString.prefix(8)))", value: metres(residual.distanceMeters))
                    }
                    ForEach(record.candidate.checkResiduals, id: \.controlID) { residual in
                        LabeledContent("Проверка · \(String(residual.controlID.uuidString.prefix(8)))", value: metres(residual.distanceMeters))
                    }
                }
                Section("Решение специалиста") {
                    TextField("Что проверено / причина решения", text: $reason, axis: .vertical)
                    Button("Подтвердить привязку", systemImage: "checkmark.circle") { Task { await decide(.approved) } }
                        .disabled(busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || record.candidate.quality != .meetsThresholds)
                    Button("Отклонить привязку", role: .destructive) { Task { await decide(.rejected) } }
                        .disabled(busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let issue { Text(issue).foregroundStyle(.orange) }
                }
                Section("История решений") {
                    ForEach(record.decisions, id: \.revision) { decision in
                        Text("\(decision.state == .approved ? "Подтверждена" : "Отклонена") · \(decision.reason)").font(.footnote)
                    }
                }
            }.scrollContentBackground(.hidden).background(Color.atlasCanvas)
            .navigationTitle("Проверка привязки").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(busy) } }
        }
    }
    private func metres(_ value: Double?) -> String { value.map { String(format: "%.3f м", $0) } ?? "нет данных" }
    private func decide(_ state: FragmentRegistrationState) async {
        busy = true; issue = nil; defer { busy = false }
        do { try await save(state, reason); dismiss() } catch { issue = error.localizedDescription }
    }
}

private struct FragmentAssemblyShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
