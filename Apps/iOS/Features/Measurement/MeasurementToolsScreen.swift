import AtlasCore
import RealityKit
import SwiftUI
import UIKit

private enum MeasurementToolMode: String, CaseIterable, Identifiable {
    case ruler = "Рулетка", level = "Уровень", compass = "Компас", journal = "Журнал"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .ruler: "ruler"; case .level: "level"; case .compass: "location.north.circle"; case .journal: "list.bullet.rectangle" }
    }
    var testID: String {
        switch self { case .ruler: "ruler"; case .level: "level"; case .compass: "compass"; case .journal: "journal" }
    }
}
private struct MeasurementEditorRoute: Identifiable {
    let id = UUID()
    let record: MeasurementRecord?
    var context: MeasurementContext? = nil
    var referenceMeters: Double? = nil
    var referenceSource: MeasurementCorrectionSource = .manualReference
}

@MainActor
struct MeasurementToolsScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    let initialContext: MeasurementContext?
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var ruler = MeasurementCoordinator()
    @StateObject private var level = LevelService()
    @StateObject private var compass = CompassService()
    @State private var mode = MeasurementToolMode.ruler
    @State private var kind = MeasurementKind.distance
    @State private var role = MeasurementRole.distance
    @State private var target = MeasurementTarget.unspecified
    @State private var definition = MeasurementDefinition.unspecified
    @State private var samplePosition = MeasurementSamplePosition.unspecified
    @State private var positionNote = ""
    @State private var profileID = UUID()
    @State private var targetID = UUID()
    @State private var records: [MeasurementRecord] = []
    @State private var editor: MeasurementEditorRoute?
    @State private var issue: String?
    @State private var saving = false
    @State private var referenceText = ""
    @State private var referenceSource = MeasurementCorrectionSource.manualReference
    @State private var isVisible = false
    @State private var activation: Task<Void, Never>?

    init(model: AtlasAppModel, project: AtlasProject, initialContext: MeasurementContext? = nil) {
        self.model = model; self.project = project; self.initialContext = initialContext
        _role = State(initialValue: initialContext?.role ?? .distance)
        _target = State(initialValue: initialContext?.target ?? .unspecified)
        _definition = State(initialValue: initialContext?.effectiveDefinition ?? .unspecified)
        _samplePosition = State(initialValue: initialContext?.position ?? .unspecified)
        _positionNote = State(initialValue: initialContext?.positionNote ?? "")
        _targetID = State(initialValue: initialContext?.targetID ?? UUID())
        _profileID = State(initialValue: initialContext?.profileID ?? UUID())
        _kind = State(initialValue: initialContext?.role == .height ? .verticalDistance : .distance)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 4) {
                    ForEach(MeasurementToolMode.allCases) { value in
                        Button { mode = value } label: {
                            VStack(spacing: 6) {
                                Image(systemName: value.symbol).font(.headline)
                                Text(value.rawValue).font(.caption.weight(.semibold))
                            }.frame(maxWidth: .infinity).padding(.vertical, 12)
                                .foregroundStyle(mode == value ? Color.atlasAccentInk : Color.atlasMuted)
                                .background(mode == value ? Color.atlasAccent : .clear, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("measurement.mode.\(value.testID)")
                            .accessibilityAddTraits(mode == value ? .isSelected : [])
                    }
                }.padding(4).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 16))
                switch mode {
                case .ruler: rulerContent
                case .level: levelContent
                case .compass: compassContent
                case .journal: journalContent
                }
            }.padding(20)
        }
        .background(Color.atlasCanvas)
        .background(MeasurementSensorWindowReporter { orientation in
            level.setInterfaceOrientation(orientation)
            compass.setInterfaceOrientation(orientation)
        }.allowsHitTesting(false))
        .navigationTitle("Инструменты обмера")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.atlasAccent)
        .foregroundStyle(Color.atlasInk)
        .preferredColorScheme(.dark)
        .task {
            isVisible = true
            records = await model.measurements(in: project)
            if initialContext == nil, let contextRecord = records.filter({ $0.context?.profileID != nil }).max(by: { $0.createdAt < $1.createdAt }) {
                reuseProfile(from: contextRecord)
            }
            ruler.dimensionKind = kind; ruler.dimensionRole = role
            activateSelectedTool()
        }
        .onChange(of: mode) { _, _ in activateSelectedTool() }
        .onChange(of: kind) { _, value in
            if role == .height && value != .verticalDistance { role = .distance }
            if role == .surfaceHeight && value != .distance { role = .distance }
            if value == .verticalDistance && role == .distance { role = .height }
            ruler.dimensionKind = value
        }
        .onChange(of: role) { _, value in
            if value == .height { kind = .verticalDistance }
            if value == .surfaceHeight { kind = .distance }
            ruler.dimensionRole = value
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Keep the authorised request/session that survived the camera
                // permission sheet instead of launching a second startup.
                if mode != .ruler || (ruler.state != .preparing && ruler.state != .running) { activateSelectedTool() }
            }
            else { stopTools(preserveCameraRequest: phase == .inactive) }
        }
        .onDisappear { isVisible = false; stopTools() }
        .sheet(item: $editor) { route in
            MeasurementRecordEditor(projectID: project.id, initial: route.record, context: route.context, referenceMeters: route.referenceMeters, referenceSource: route.referenceSource) { record in
                guard !saving else { throw MeasurementUIError.saving }
                saving = true
                defer { saving = false }
                guard let saved = await model.saveMeasurement(record) else {
                    throw MeasurementUIError.persistence(model.issue ?? "Не удалось сохранить обмер.")
                }
                if let index = records.firstIndex(where: { $0.id == saved.id }) { records[index] = saved }
                else { records.insert(saved, at: 0) }
                // Editing another historical card must not change a caller's
                // explicit physical target. A new observation may deliberately
                // choose another category/object in its own editor.
                if initialContext == nil || route.record == nil || route.record?.revision == 0 || saved.context?.targetID == targetID {
                    reuseProfile(from: saved)
                }
                if route.record?.revision == 0 { ruler.clearPoints() }
            }
        }
        .alert("Обмер", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("Понятно") { issue = nil }
        } message: { Text(issue ?? "") }
    }

    private var rulerContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Две точки — один обмер").font(.title2.bold()).foregroundStyle(Color.atlasInk)
            Text(MeasurementCoordinator.usesLiDAR
                 ? "Камера и LiDAR помогают найти поверхности. Выберите две точки и проверьте размер."
                 : "Камера помогает найти поверхности. Выберите две точки; LiDAR для рулетки не обязателен.")
                .font(.subheadline).foregroundStyle(Color.atlasMuted)
            measurementContextPicker
            if MeasurementCoordinator.isSupported {
                rulerCamera
                measurementProjectionPicker
                measurementValues
                rulerButtons
                if let first = ruler.first {
                    Text("Точка 1: \(first.surfaceTitle)" + (ruler.second.map { "\nТочка 2: \($0.surfaceTitle)" } ?? ""))
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
                referenceComparison
            } else {
                ContentUnavailableView("AR недоступна", systemImage: "ruler", description: Text("Сохраните размер с обычной рулетки или лазерного дальномера вручную."))
                    .accessibilityIdentifier("measurement.cameraUnavailable")
            }
            Button("Ввести размер вручную", systemImage: "keyboard") { editor = MeasurementEditorRoute(record: nil, context: currentContext) }
                .buttonStyle(AtlasSecondaryButtonStyle()).frame(maxWidth: .infinity)
                .accessibilityIdentifier("measurement.manual")
            Text("AR-обмер — оценка по двум выбранным поверхностям. Погрешность не определена. Для ответственных работ сверяйте с контрольным размером. Обмер не совмещает план или 3D-модель с картой автоматически.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }
    }

    private var rulerCamera: some View {
        ZStack {
            MeasurementARView(coordinator: ruler)
            if let overlay = ruler.dimensionOverlay { MeasurementDimensionDrawing(overlay: overlay) }
            if ruler.state == .running && ruler.isCameraReady {
                Image(systemName: "plus").font(.system(size: 30, weight: .light))
                    .foregroundStyle(ruler.canCapturePoint ? Color.atlasLime : .white)
                    .shadow(color: .black.opacity(0.8), radius: 3)
                    .accessibilityHidden(true)
            }
            if !ruler.isCameraReady {
                VStack(spacing: 14) {
                    if ruler.state == .preparing || ruler.state == .running {
                        ProgressView().tint(.atlasAccent).scaleEffect(1.3)
                        Text("Открываем камеру…").font(.headline)
                    } else {
                        Image(systemName: ruler.issue == nil ? "camera" : "exclamationmark.triangle")
                            .font(.system(size: 30, weight: .light)).foregroundStyle(Color.atlasAccent)
                        Text(ruler.issue == nil ? "Камера готовится к обмеру" : "Камера требует внимания")
                            .font(.headline)
                    }
                }.padding(20).background(Color.atlasCard.opacity(0.95), in: RoundedRectangle(cornerRadius: 18))
                    .padding(.bottom, 40)
            }
            VStack {
                HStack {
                    Label(ruler.trackingNormal ? "Можно ставить точки" : (ruler.isCameraReady ? "Ищем поверхности" : "Запуск камеры"),
                          systemImage: ruler.trackingNormal ? "checkmark.circle" : "viewfinder")
                        .font(.caption.weight(.semibold)).padding(10)
                        .background(.black.opacity(0.65), in: Capsule())
                    Spacer()
                }
                Spacer()
                Text(ruler.message).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            }.padding(12).foregroundStyle(.white)
        }
        .frame(height: 320).background(Color.atlasGraphite)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Камера AR. \(ruler.message)")
        .accessibilityIdentifier("measurement.cameraStatus")
    }

    private var measurementProjectionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Расчёт A–B", selection: $kind) {
                Text("Прямая в 3D").tag(MeasurementKind.distance)
                Text("Горизонт · XZ").tag(MeasurementKind.horizontalDistance)
                Text("Высота · |ΔY|").tag(MeasurementKind.verticalDistance)
            }.pickerStyle(.menu).accessibilityIdentifier("measurement.projection")
            Text(kind == .verticalDistance ? "H — разность уровней по силе тяжести. Пунктир показывает боковое смещение B, исключённое из высоты." : kind == .horizontalDistance ? "Размер спроецирован на горизонтальную плоскость. Исходные точки A/B сохраняются." : "Прямая A–B включает наклон. Для высоты выберите |ΔY|.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }
    }

    private var currentContext: MeasurementContext {
        .init(role: role, target: target, targetID: targetID, profileID: profileID, position: samplePosition, positionNote: positionNote, definition: definition)
    }

    private func reuseProfile(from record: MeasurementRecord) {
        guard let context = record.context, let savedProfile = context.profileID else { return }
        profileID = savedProfile; targetID = context.targetID ?? targetID; target = context.target; role = context.role
        definition = context.effectiveDefinition; samplePosition = context.position; positionNote = context.positionNote
        kind = record.kind; ruler.dimensionKind = record.kind; ruler.dimensionRole = context.role
    }

    private var measurementContextPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Обозначение", selection: $role) { ForEach(MeasurementRole.allCases, id: \.self) { Text($0.fieldMeasurementTitle).tag($0) } }
                .accessibilityIdentifier("measurement.role")
            Picker("Что измеряем", selection: Binding(get: { target }, set: { value in
                if target != value { target = value; targetID = UUID(); profileID = UUID() }
            })) { ForEach(MeasurementTarget.allCases, id: \.self) { Text($0.fieldMeasurementTitle).tag($0) } }
                .accessibilityIdentifier("measurement.target")
            Picker("Какие границы", selection: $definition) { ForEach(MeasurementDefinition.allCases, id: \.self) { Text($0.fieldMeasurementTitle).tag($0) } }
                .accessibilityIdentifier("measurement.definition")
            Picker("Место замера", selection: $samplePosition) { ForEach(MeasurementSamplePosition.allCases, id: \.self) { Text($0.fieldMeasurementTitle).tag($0) } }
                .accessibilityIdentifier("measurement.position")
            TextField("Участок / пояснение к месту", text: $positionNote)
                .accessibilityIdentifier("measurement.positionNote")
            Button("Другой объект / новый профиль", systemImage: "plus.rectangle.on.rectangle") { targetID = UUID(); profileID = UUID(); positionNote = ""; samplePosition = .unspecified }
                .accessibilityIdentifier("measurement.newProfile")
            Text("Профиль \(profileID.uuidString.prefix(8)). Категорию и место выбирает специалист. Для проёма измеряйте его границы; для дверцы — само полотно. Каждый замер сохраняет собственные точки и время.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }.padding(16).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 16))
    }

    private var measurementValues: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(role.symbol + " " + (ruler.meters(kind: kind).map { measurementNumber($0) + " м" } ?? "—"))
                    .font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                Spacer()
                Text(ruler.second == nil ? "Предпросмотр" : "Две точки")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
            }
            HStack {
                projectionValue("3D", kind: .distance)
                Spacer()
                projectionValue("Горизонт", kind: .horizontalDistance)
                Spacer()
                projectionValue("Высота", kind: .verticalDistance)
            }.font(.caption)
        }.padding(16).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 16))
    }

    private func projectionValue(_ label: String, kind: MeasurementKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(Color.atlasMuted)
            Text(ruler.meters(kind: kind).map { measurementNumber($0) + " м" } ?? "—").monospacedDigit()
        }
    }

    private var rulerButtons: some View {
        VStack(spacing: 12) {
            if ruler.second != nil {
                AtlasPrimaryButton(title: "Сохранить обмер", systemImage: "checkmark") {
                    do {
                        let reference = parseMeasurement(referenceText).flatMap { $0 > 0 ? $0 : nil }
                        editor = MeasurementEditorRoute(record: try ruler.record(projectID: project.id, label: role.symbol + " · " + target.fieldMeasurementTitle + " · " + samplePosition.fieldMeasurementTitle, kind: kind, context: currentContext), referenceMeters: reference, referenceSource: referenceSource)
                    }
                    catch { issue = error.localizedDescription }
                }
                .accessibilityIdentifier("measurement.save")
            } else if ruler.state == .running {
                AtlasPrimaryButton(title: ruler.first == nil ? "Поставить первую точку" : "Поставить вторую точку", systemImage: "plus.viewfinder") { ruler.capturePoint() }
                    .disabled(!ruler.canCapturePoint)
                    .accessibilityIdentifier("measurement.point")
            } else {
                AtlasPrimaryButton(title: ruler.state == .preparing ? "Подготовка камеры…" : (ruler.issue == nil ? "Начать новый обмер" : "Перезапустить камеру"), systemImage: "camera") { activateSelectedTool() }
                    .disabled(ruler.state == .preparing)
                    .accessibilityIdentifier("measurement.retry")
            }
            if let issue = ruler.issue {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(Color.atlasInk)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("measurement.cameraIssue")
            }
            HStack {
                Button("Сбросить точки", systemImage: "arrow.counterclockwise") { ruler.clearPoints() }
                    .disabled(ruler.first == nil)
                Spacer()
                if ruler.issue != nil {
                    Button("Настройки камеры") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }.font(.subheadline)
        }
    }

    private var referenceComparison: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Контрольный размер", systemImage: "ruler").font(.headline)
            Picker("Контрольный прибор", selection: $referenceSource) {
                Text("Обычная рулетка").tag(MeasurementCorrectionSource.manualReference)
                Text("Лазерный дальномер").tag(MeasurementCorrectionSource.laserReference)
            }.pickerStyle(.menu)
            HStack {
                TextField("Рулетка или лазер, м", text: $referenceText).keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Text("м").foregroundStyle(Color.atlasMuted)
            }
            if let measured = ruler.meters(kind: kind, includeLiveTarget: false),
               let reference = parseMeasurement(referenceText),
               let comparison = try? MeasurementComparison.compare(measuredMeters: measured, referenceMeters: reference) {
                Text("Разница с контролем: \(signedMeasurementNumber(comparison.deltaMeters)) м · \(comparison.relativeDifferencePercent.formatted(.number.precision(.fractionLength(1))))%")
                    .font(.subheadline).monospacedDigit()
            }
            Text("Введите показание своего прибора. Автоматическое подключение к Bluetooth-дальномеру здесь не выполняется. Корректировку можно сохранить в карточке обмера с причиной.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }.padding(16).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 16))
    }

    private var levelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Уровень поверхности").font(.title2.bold()).foregroundStyle(Color.atlasInk)
            Text("Акселерометр и гироскоп определяют направление силы тяжести. Положите телефон на поверхность и дождитесь спокойного показания.")
                .font(.subheadline).foregroundStyle(Color.atlasMuted)
            if level.isSupported {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let fresh = level.reading.flatMap { (-0.1...1).contains(context.date.timeIntervalSince($0.observedAt)) ? $0 : nil }
                    VStack(spacing: 16) {
                        LevelInstrument(reading: fresh).frame(height: 250)
                        Text(fresh.map { $0.inclinationDegrees.formatted(.number.precision(.fractionLength(1))) + "°" } ?? "—")
                            .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(level.calibrated ? "Отклонение от нуля оператора" : "Наклон плоскости телефона к горизонту")
                            .font(.subheadline).foregroundStyle(Color.atlasMuted)
                        HStack {
                            angleValue("Продольный", value: fresh?.pitchDegrees)
                            Spacer()
                            angleValue("Поперечный", value: fresh?.rollDegrees)
                        }
                    }.padding(20).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 20))
                }
                HStack {
                    Button("Принять за ноль", systemImage: "scope") { level.calibrateZero() }
                        .disabled(level.reading == nil)
                    Spacer()
                    Button("Горизонт") { level.restoreHorizontal() }.disabled(!level.calibrated)
                }.buttonStyle(AtlasSecondaryButtonStyle())
                if level.calibrated {
                    Text("Ноль установлен вручную для текущего инструмента. Это относительный уклон, а не подтверждение горизонтальности поверхности.")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
            } else {
                ContentUnavailableView("Датчики недоступны", systemImage: "level", description: Text("На этом устройстве нет поддерживаемого Core Motion."))
            }
            if let issue = level.issue { Text(issue).font(.subheadline).foregroundStyle(.red) }
            Text("Чехол, выступ камеры, вибрации и движение влияют на показание. Для контрольной приёмки используйте проверенный физический уровень.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }
    }

    private func angleValue(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(Color.atlasMuted)
            Text(value.map { $0.formatted(.number.precision(.fractionLength(1))) + "°" } ?? "—")
                .font(.title3.weight(.semibold)).monospacedDigit()
        }
    }

    private var compassContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Направление на объекте").font(.title2.bold()).foregroundStyle(Color.atlasInk)
            Text("Магнитометр определяет азимут верхнего края экрана. При доступной свежей геопозиции показывается истинный север; иначе — магнитный.")
                .font(.subheadline).foregroundStyle(Color.atlasMuted)
            if compass.isSupported {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let fresh = compass.reading.flatMap { (-5...5).contains(context.date.timeIntervalSince($0.observedAt)) ? $0 : nil }
                    VStack(spacing: 14) {
                        CompassInstrument(degrees: fresh?.degrees).frame(height: 250)
                        Text(fresh.map { $0.degrees.formatted(.number.precision(.fractionLength(0))) + "°" } ?? "—")
                            .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(fresh.map { $0.isTrueNorth ? "Истинный север" : "Магнитный север" } ?? "Ожидание достоверного азимута")
                            .font(.headline)
                        if let fresh {
                            Text("Оценка датчика: ±\(fresh.accuracyDegrees.formatted(.number.precision(.fractionLength(1))))°")
                                .font(.caption).foregroundStyle(Color.atlasMuted)
                        }
                    }.padding(20).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 20))
                }
            } else {
                ContentUnavailableView("Компас недоступен", systemImage: "location.north.circle", description: Text("На этом устройстве нет доступного магнитометра."))
            }
            if let issue = compass.issue { Text(issue).font(.subheadline).foregroundStyle(Color.atlasMuted) }
            Text("Металл, арматура, магнитные держатели и чехлы искажают компас. Азимут не переносится в AR-систему координат и не геопривязывает скан автоматически.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }
    }

    private var journalContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Обмеры проекта").font(.title2.bold()).foregroundStyle(Color.atlasInk)
                Spacer()
                Button("Добавить", systemImage: "plus") { editor = MeasurementEditorRoute(record: nil, context: currentContext) }.labelStyle(.iconOnly)
                    .accessibilityIdentifier("measurement.journal.add")
            }
            if records.isEmpty {
                ContentUnavailableView("Пока нет обмеров", systemImage: "ruler", description: Text("Поставьте две AR-точки или сохраните контрольный размер вручную."))
            }
            ForEach(records) { record in
                Button { editor = MeasurementEditorRoute(record: record) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(record.label).font(.headline)
                            Spacer()
                            Text(measurementNumber(record.effectiveMeters) + " м").font(.headline).monospacedDigit()
                        }
                        Text("\(record.notation) · \(record.kind.measurementTitle) · \(record.source.measurementTitle)")
                            .font(.caption).foregroundStyle(Color.atlasMuted)
                        if let context = record.context {
                            Text(context.target.fieldMeasurementTitle + " · " + context.position.fieldMeasurementTitle + (context.positionNote.isEmpty ? "" : " · " + context.positionNote)).font(.caption)
                        }
                        if let frame = record.frameID { Text("AR · метры · Y по силе тяжести · \(frame.uuidString.prefix(8))").font(.caption2).foregroundStyle(Color.atlasMuted) }
                        if record.hasManualCorrection { Label("Есть ручная корректировка", systemImage: "pencil.circle").font(.caption).foregroundStyle(Color.atlasBlue) }
                        if record.surfaceEvidence.contains(.estimatedPlane) {
                            Text("Одна или обе точки — предполагаемая плоскость").font(.caption).foregroundStyle(Color.atlasMuted)
                        }
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Color.atlasMuted)
                    }.foregroundStyle(Color.atlasInk).padding(16).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain).accessibilityIdentifier("measurement.record." + record.id.uuidString)
                NavigationLink {
                    ApplyMeasurementScreen(model: model, project: project, initialMeasurementID: record.id)
                } label: {
                    Label("Применить к плану", systemImage: "square.split.2x2")
                }.font(.subheadline).padding(.horizontal, 16)
            }
            Text("Исходное значение сохраняется отдельно. Каждое ручное изменение добавляется в историю; точки разных AR-сессий не объединяются.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
            ForEach(Array(profileSummaries.enumerated()), id: \.offset) { _, summary in
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.context.role.symbol + " · " + summary.context.target.fieldMeasurementTitle + " · \(summary.count) замеров").font(.headline)
                    Text("Мин. \(measurementNumber(summary.minimumMeters)) м · макс. \(measurementNumber(summary.maximumMeters)) м · разброс \(measurementNumber(summary.spreadMeters)) м")
                        .font(.caption).monospacedDigit()
                    Text(summary.coordinateComparisonAvailable ? "Точки в одной AR-системе. Отдельные показания сохранены выше." : "Показания одного выбранного объекта; позиции разных AR-систем не совмещены.")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }.padding(16).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("measurement.profile." + (summary.context.profileID?.uuidString ?? "unidentified") + "." + summary.kind.rawValue + "." + summary.context.role.rawValue + "." + summary.context.effectiveDefinition.rawValue)
            }
        }
    }

    private var profileSummaries: [MeasurementProfileSummary] {
        let grouped = Dictionary(grouping: records.filter { $0.context?.profileID != nil }) { record in
            (record.context?.profileID?.uuidString ?? "") + "|" + (record.context?.targetID?.uuidString ?? "")
                + "|" + (record.context?.target.rawValue ?? "") + "|" + record.notation + "|" + record.kind.rawValue
                + "|" + (record.context?.effectiveDefinition.rawValue ?? "")
        }
        return grouped.values.compactMap { try? MeasurementProfile.summarize($0) }.sorted { $0.context.role.symbol < $1.context.role.symbol }
    }

    private func activateSelectedTool() {
        stopTools()
        guard isVisible, scenePhase == .active else { return }
        switch mode {
        case .ruler: activation = Task { await ruler.start() }
        case .level: level.start()
        case .compass: compass.start()
        case .journal: break
        }
    }
    private func stopTools(preserveCameraRequest: Bool = false) {
        if !(preserveCameraRequest && ruler.state == .preparing && mode == .ruler) {
            activation?.cancel(); activation = nil; ruler.stop()
        }
        level.stop(); compass.stop()
    }
}

private struct MeasurementARView: UIViewRepresentable {
    let coordinator: MeasurementCoordinator
    func makeUIView(context: Context) -> ARView { coordinator.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

private struct MeasurementSensorWindowReporter: UIViewRepresentable {
    let report: @MainActor (UIInterfaceOrientation) -> Void
    func makeUIView(context: Context) -> SensorWindowView {
        let view = SensorWindowView(); view.onOrientation = report; return view
    }
    func updateUIView(_ uiView: SensorWindowView, context: Context) {
        uiView.onOrientation = report; uiView.reportOrientation()
    }
}

private final class SensorWindowView: UIView {
    var onOrientation: (@MainActor (UIInterfaceOrientation) -> Void)?
    private var lastOrientation: UIInterfaceOrientation?
    override func didMoveToWindow() { super.didMoveToWindow(); lastOrientation = nil; reportOrientation() }
    override func layoutSubviews() { super.layoutSubviews(); reportOrientation() }
    func reportOrientation() {
        guard let scene = window?.windowScene else { return }
        let orientation = scene.interfaceOrientation
        guard
              orientation != .unknown, orientation != lastOrientation else { return }
        lastOrientation = orientation
        // UIKit may call this during a SwiftUI view update. Publish on the next
        // main actor turn, only if this same window/scene still owns the view.
        Task { @MainActor [weak self, weak scene] in
            guard let self, let scene, self.window?.windowScene === scene,
                  scene.interfaceOrientation == orientation else { return }
            self.onOrientation?(orientation)
        }
    }
}

private struct LevelInstrument: View {
    let reading: LevelService.Reading?
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) * 0.4
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: circle), with: .color(.atlasMuted.opacity(0.35)), lineWidth: 2)
            var axes = Path()
            axes.move(to: CGPoint(x: center.x - radius, y: center.y)); axes.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            axes.move(to: CGPoint(x: center.x, y: center.y - radius)); axes.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            context.stroke(axes, with: .color(.atlasMuted.opacity(0.3)), lineWidth: 1)
            context.stroke(Path(ellipseIn: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)), with: .color(.atlasBlue), lineWidth: 2)
            if let reading {
                var x = reading.rollDegrees / 45
                var y = reading.pitchDegrees / 45
                let norm = hypot(x, y)
                if norm > 1 { x /= norm; y /= norm }
                let position = CGPoint(x: center.x + x * radius * 0.82, y: center.y - y * radius * 0.82)
                context.fill(Path(ellipseIn: CGRect(x: position.x - 12, y: position.y - 12, width: 24, height: 24)), with: .color(.atlasBlue))
            }
        }
        .accessibilityLabel(reading.map { "Наклон \($0.inclinationDegrees.formatted(.number.precision(.fractionLength(1)))) градуса" } ?? "Данные уровня недоступны")
    }
}

private struct CompassInstrument: View {
    let degrees: Double?
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) * 0.38
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(.atlasMuted.opacity(0.35)), lineWidth: 2)
            var ticks = Path()
            for index in 0..<36 {
                let angle = Double(index) * .pi / 18
                let length: CGFloat = index % 9 == 0 ? 12 : 6
                ticks.move(to: CGPoint(x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius))
                ticks.addLine(to: CGPoint(x: center.x + sin(angle) * (radius - length), y: center.y - cos(angle) * (radius - length)))
            }
            context.stroke(ticks, with: .color(.atlasMuted), lineWidth: 1)
            context.draw(Text("Верх экрана").font(.caption).foregroundStyle(Color.atlasMuted), at: CGPoint(x: center.x, y: center.y - radius - 18))
            if let degrees {
                let angle = -degrees * .pi / 180
                let tip = CGPoint(x: center.x + sin(angle) * radius * 0.7, y: center.y - cos(angle) * radius * 0.7)
                var arrow = Path(); arrow.move(to: center); arrow.addLine(to: tip)
                context.stroke(arrow, with: .color(.atlasBlue), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: tip.x - 5, y: tip.y - 5, width: 10, height: 10)), with: .color(.atlasBlue))
                context.draw(Text("С").font(.headline).foregroundStyle(Color.atlasBlue), at: CGPoint(x: center.x + sin(angle) * radius * 0.9, y: center.y - cos(angle) * radius * 0.9))
            }
        }.accessibilityLabel(degrees.map { "Азимут \($0.formatted(.number.precision(.fractionLength(0)))) градусов" } ?? "Азимут недоступен")
    }
}

private enum MeasurementUIError: LocalizedError {
    case invalidNumber, emptyLabel, correctionReason, saving, persistence(String)
    var errorDescription: String? {
        switch self {
        case .invalidNumber: "Введите конечный неотрицательный размер в метрах."
        case .emptyLabel: "Укажите название обмера."
        case .correctionReason: "Укажите причину корректировки, чтобы сохранить историю."
        case .saving: "Обмер уже сохраняется."
        case .persistence(let message): message
        }
    }
}

private func parseMeasurement(_ text: String) -> Double? {
    guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")),
          number.isFinite, number >= 0 else { return nil }
    return number
}
private func measurementNumber(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(3))) }
private func signedMeasurementNumber(_ value: Double) -> String { (value > 0 ? "+" : "") + measurementNumber(value) }

private extension MeasurementKind {
    var measurementTitle: String {
        switch self { case .distance: "Расстояние 3D"; case .horizontalDistance: "Горизонтальная проекция"; case .verticalDistance: "Разница высот" }
    }
}
private extension MeasurementSource {
    var measurementTitle: String {
        switch self { case .arRaycast: "AR-точки"; case .manualReference: "Ручной контроль"; case .laserReference: "Показание лазера вручную" }
    }
}
