import AtlasCore
import SwiftUI
import UIKit

private enum MeasurementCorrectionInput: String, CaseIterable, Identifiable {
    case operatorEntered = "Ручная поправка", manualReference = "Рулетка", laserReference = "Лазерный дальномер"
    var id: String { rawValue }
    var source: MeasurementCorrectionSource {
        switch self { case .operatorEntered: .operatorEntered; case .manualReference: .manualReference; case .laserReference: .laserReference }
    }
}

@MainActor
struct MeasurementRecordEditor: View {
    let projectID: UUID
    let initial: MeasurementRecord?
    let initialContext: MeasurementContext?
    let referenceMeters: Double?
    let referenceSource: MeasurementCorrectionSource
    let save: @MainActor (MeasurementRecord) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var meters = ""
    @State private var kind = MeasurementKind.distance
    @State private var manualSource = MeasurementSource.manualReference
    @State private var role = MeasurementRole.distance
    @State private var target = MeasurementTarget.unspecified
    @State private var definition = MeasurementDefinition.unspecified
    @State private var position = MeasurementSamplePosition.unspecified
    @State private var positionNote = ""
    @State private var targetID: UUID?
    @State private var profileID: UUID?
    @State private var correctionSource = MeasurementCorrectionInput.operatorEntered
    @State private var reason = ""
    @State private var issue: String?
    @State private var saving = false

    init(projectID: UUID, initial: MeasurementRecord?, context: MeasurementContext? = nil, referenceMeters: Double? = nil, referenceSource: MeasurementCorrectionSource = .manualReference, save: @escaping @MainActor (MeasurementRecord) async throws -> Void) {
        self.projectID = projectID; self.initial = initial; self.referenceMeters = referenceMeters; self.referenceSource = referenceSource; self.save = save
        initialContext = initial?.context ?? context
        _label = State(initialValue: initial?.label ?? "Контрольный размер")
        _role = State(initialValue: initial?.context?.role ?? context?.role ?? .distance)
        _target = State(initialValue: initial?.context?.target ?? context?.target ?? .unspecified)
        _definition = State(initialValue: initial?.context?.effectiveDefinition ?? context?.effectiveDefinition ?? .unspecified)
        _position = State(initialValue: initial?.context?.position ?? context?.position ?? .unspecified)
        _positionNote = State(initialValue: initial?.context?.positionNote ?? context?.positionNote ?? "")
        _targetID = State(initialValue: initial?.context?.targetID ?? context?.targetID)
        _profileID = State(initialValue: initial?.context?.profileID ?? context?.profileID)
        _kind = State(initialValue: initial?.kind ?? (context?.role == .height ? .verticalDistance : .distance))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Обмер") {
                    TextField("Название", text: $label).accessibilityIdentifier("measurement.editor.label")
                    if let initial {
                        LabeledContent("Обозначение", value: initial.notation)
                        if let context = initial.context {
                            LabeledContent("Объект", value: context.target.fieldMeasurementTitle)
                            LabeledContent("Границы", value: context.effectiveDefinition.fieldMeasurementTitle)
                            LabeledContent("Место", value: context.position.fieldMeasurementTitle + (context.positionNote.isEmpty ? "" : " · " + context.positionNote))
                        }
                        LabeledContent("Исходный размер", value: number(initial.originalMeters) + " м")
                        LabeledContent("Текущее значение", value: number(initial.effectiveMeters) + " м")
                        if let frameID = initial.frameID {
                            Text("AR-система координат: \(frameID.uuidString.prefix(8))").font(.caption).foregroundStyle(.secondary)
                        }
                        if initial.surfaceEvidence.contains(.estimatedPlane) {
                            Text("Одна или обе точки получены по предполагаемой плоскости. Проверьте контрольным прибором.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Обозначение", selection: $role) { ForEach(MeasurementRole.allCases, id: \.self) { Text($0.fieldMeasurementTitle).tag($0) } }.accessibilityIdentifier("measurement.editor.role")
                        Picker("Объект", selection: $target) { ForEach(MeasurementTarget.allCases, id: \.self) { Text($0.fieldMeasurementTitle).tag($0) } }.accessibilityIdentifier("measurement.editor.target")
                        Picker("Границы", selection: $definition) { ForEach(MeasurementDefinition.allCases, id: \.self) { Text($0.fieldMeasurementTitle).tag($0) } }.accessibilityIdentifier("measurement.editor.definition")
                        Picker("Место", selection: $position) { ForEach(MeasurementSamplePosition.allCases, id: \.self) { Text($0.fieldMeasurementTitle).tag($0) } }.accessibilityIdentifier("measurement.editor.position")
                        TextField("Пояснение к месту замера", text: $positionNote).accessibilityIdentifier("measurement.editor.positionNote")
                        Picker("Тип размера", selection: $kind) {
                            Text("Расстояние").tag(MeasurementKind.distance)
                            Text("Горизонтальный размер").tag(MeasurementKind.horizontalDistance)
                            Text("Высота").tag(MeasurementKind.verticalDistance)
                        }
                        Text("H — вертикальный размер. Для каждого места сохраняется отдельная запись; среднее не заменяет исходные показания.").font(.caption).foregroundStyle(.secondary)
                        Picker("Источник", selection: $manualSource) {
                            Text("Обычная рулетка").tag(MeasurementSource.manualReference)
                            Text("Показание лазера").tag(MeasurementSource.laserReference)
                        }
                        TextField("Размер в метрах", text: $meters).keyboardType(.decimalPad).accessibilityIdentifier("measurement.editor.meters")
                        Text("Показание вводит оператор. Соединение с дальномером автоматически не устанавливается.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if initial != nil { correctionSection }
                if let initial, !initial.corrections.isEmpty {
                    Section("История изменений") {
                        ForEach(initial.corrections.reversed()) { correction in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(correction.meters.map { number($0) + " м" } ?? "Возврат к исходному размеру").font(.headline)
                                Text(correction.note).font(.subheadline)
                                Text(correction.changedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(initial == nil ? "Контрольный размер" : "Карточка обмера")
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .pickerStyle(.menu)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(saving).accessibilityIdentifier("measurement.editor.cancel") }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить") { persist(reset: false) }.disabled(saving).accessibilityIdentifier("measurement.editor.save") }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }.accessibilityIdentifier("measurement.editor.keyboardDone")
                }
            }
            .disabled(saving)
            .onChange(of: role) { _, value in
                if value == .height { kind = .verticalDistance }
                if value == .surfaceHeight { kind = .distance }
            }
            .onChange(of: kind) { _, value in
                if role == .height && value != .verticalDistance { role = .distance }
                if role == .surfaceHeight && value != .distance { role = .distance }
            }
            .onChange(of: target) { _, _ in
                guard initial == nil else { return }
                let next = UUID(); targetID = next; profileID = next
            }
            .alert("Обмер", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("Понятно") { issue = nil }
            } message: { Text(issue ?? "") }
        }
        .interactiveDismissDisabled(saving)
    }

    private var correctionSection: some View {
        Section {
            if let referenceMeters {
                LabeledContent("Контроль с прибора", value: number(referenceMeters) + " м")
                Button("Использовать контрольный размер") {
                    meters = String(referenceMeters)
                    correctionSource = referenceSource == .laserReference ? .laserReference : .manualReference
                }
            }
            TextField("Новый размер в метрах", text: $meters).keyboardType(.decimalPad).accessibilityIdentifier("measurement.editor.meters")
            Picker("Источник поправки", selection: $correctionSource) {
                ForEach(MeasurementCorrectionInput.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("Причина корректировки", text: $reason, axis: .vertical).lineLimit(2...5)
            if initial?.hasManualCorrection == true {
                Button("Вернуть исходный размер") { persist(reset: true) }
            }
        } header: { Text("Ручная корректировка") } footer: {
            Text("Оставьте новый размер пустым, чтобы сохранить карточку без поправки. Исходные точки и значение не изменятся; корректировка добавится в историю. Для возврата к исходному значению тоже укажите причину.")
        }
    }

    private func persist(reset: Bool) {
        guard !saving else { return }
        do {
            let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw MeasurementEditorError.emptyLabel }
            let value: MeasurementRecord
            if var existing = initial {
                existing.label = title
                if reset || !meters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let note = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !note.isEmpty else { throw MeasurementEditorError.correctionReason }
                    if reset {
                        existing.corrections.append(MeasurementCorrection(meters: nil, source: .operatorEntered, note: note))
                    } else {
                        guard let number = parseNumber(meters) else { throw MeasurementEditorError.invalidNumber }
                        existing.corrections.append(MeasurementCorrection(meters: number, source: correctionSource.source, note: note))
                    }
                }
                value = existing
            } else {
                guard let number = parseNumber(meters) else { throw MeasurementEditorError.invalidNumber }
                value = MeasurementRecord(projectID: projectID, label: title, kind: kind,
                    source: manualSource, originalMeters: number, context: MeasurementContext(role: role, target: target,
                        targetID: targetID, profileID: profileID,
                        position: position, positionNote: positionNote, definition: definition))
            }
            saving = true
            Task {
                do { try await save(value); dismiss() }
                catch { issue = error.localizedDescription }
                saving = false
            }
        } catch { issue = error.localizedDescription }
    }

    private func parseNumber(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value >= 0 else { return nil }
        return value
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(3))) }
}

private enum MeasurementEditorError: LocalizedError {
    case invalidNumber, emptyLabel, correctionReason
    var errorDescription: String? {
        switch self {
        case .invalidNumber: "Введите конечный неотрицательный размер в метрах."
        case .emptyLabel: "Укажите название обмера."
        case .correctionReason: "Укажите причину корректировки."
        }
    }
}
