import SwiftUI
import AtlasCore

/// The displayed queue belongs to the authenticated server, user and organization.
/// A completed state is supplied by the coordinator only after a server receipt.
struct TeamProjectTransferScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @ObservedObject private var coordinator: FieldTransferCoordinator
    @ObservedObject private var team: TeamService
    @State private var settings = FieldTransferSettings()
    @State private var settingsLoaded = false
    @State private var changingSettings = false
    @State private var settingsRequestID = UUID()
    @State private var creatingArchive = false
    @State private var archiveURL: URL?
    @State private var archiveIssue: String?

    init(model: AtlasAppModel, project: AtlasProject) {
        self.model = model
        self.project = project
        _coordinator = ObservedObject(wrappedValue: model.transfers)
        _team = ObservedObject(wrappedValue: model.team)
    }

    private var records: [FieldTransferRecord] { coordinator.projectRecords(projectID: project.id) }
    private var unfinished: [FieldTransferRecord] { records.filter { $0.state != .completed } }
    private var completed: [FieldTransferRecord] { records.filter { $0.state == .completed } }
    private var preferenceContextID: String {
        team.serverAddress + "|" + (team.user?.id.uuidString ?? "local") + "|" +
        (team.selectedOrganizationID?.uuidString ?? "none")
    }
    private var deliveryExplanation: String {
        let behavior: String
        if settings.policy == .manual {
            behavior = "Снимайте и проверяйте материалы на устройстве. Отправка начнётся после нажатия «Отправить материалы». Ограничение Wi-Fi действует и при ручной отправке."
        } else if team.connected, team.selectedOrganization != nil {
            behavior = "Сохранённые материалы ставятся в очередь этого проекта. Без подходящей сети очередь сохраняется и продолжится при открытом приложении."
        } else {
            behavior = "Это настройка отправки на сервер Atlas. Для её работы войдите в рабочий аккаунт и выберите организацию. Автоматическая загрузка в семейный архив или чат этим переключателем не подключается; используйте комплект ZIP."
        }
        return behavior + " Настройка сохраняется отдельно для каждого рабочего аккаунта и организации."
    }
    private var canSend: Bool {
        team.connected && team.selectedOrganization != nil &&
        ["owner", "admin", "manager", "surveyor"].contains(team.selectedOrganization?.role ?? "") &&
        !team.busy && !coordinator.isPreparing && !coordinator.isSending && !changingSettings
    }

    var body: some View {
        List {
            projectHeader
            archiveSharingSection
            deliverySettings
            connectionSection
            sendSection
            queueSection
            receivedSection
            if let issue = coordinator.issue {
                Section {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.orange).font(.subheadline)
                }.listRowBackground(Color.atlasCard)
            }
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .foregroundStyle(Color.atlasInk).tint(.atlasAccent)
        .navigationTitle("Материалы и отправка").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: preferenceContextID) {
            settingsRequestID = UUID()
            changingSettings = false
            settingsLoaded = false
            await coordinator.refresh(projectID: project.id)
            let storedSettings = await coordinator.settings(projectID: project.id)
            guard !Task.isCancelled else { return }
            settings = storedSettings
            settingsLoaded = true
        }
        .refreshable { await coordinator.refresh(projectID: project.id) }
    }

    private var archiveSharingSection: some View {
        Section {
            Button {
                guard !creatingArchive else { return }
                creatingArchive = true; archiveIssue = nil; archiveURL = nil
                Task {
                    archiveURL = await model.exportArchive(project: project)
                    creatingArchive = false
                    if archiveURL == nil { archiveIssue = model.issue ?? "Не удалось собрать комплект. Исходники остаются на iPhone." }
                }
            } label: {
                if creatingArchive { ProgressView("Собираем исходники и паспорт…").tint(.atlasAccent) }
                else { Label("Подготовить комплект для передачи", systemImage: "archivebox") }
            }.disabled(creatingArchive).accessibilityIdentifier("transfer.createArchive")
            if let archiveURL {
                ShareLink(item: archiveURL) {
                    Label("Поделиться комплектом", systemImage: "square.and.arrow.up")
                }.accessibilityIdentifier("transfer.shareArchive")
            }
            NavigationLink {
                TeamCommunicationScreen()
            } label: { Label("Архив, рабочий чат и встреча", systemImage: "bubble.left.and.bubble.right") }
                .accessibilityIdentifier("transfer.communication")
            if let archiveIssue {
                Label(archiveIssue, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(Color.orange)
            }
        } header: { Text("Передать без сервера Atlas") } footer: {
            Text("ZIP содержит исходники и метаданные проекта. Его можно отправить в рабочий чат, сохранить в Файлы или загрузить в семейный архив. Выбор получателя и загрузка выполняются через меню iPhone.")
        }.listRowBackground(Color.atlasCard)
    }

    private var projectHeader: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: project.kind.symbol).font(.title2)
                    .foregroundStyle(Color.atlasAccent)
                    .frame(width: 48, height: 48)
                    .background(Color.atlasCanvas, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name).font(.headline)
                    Text("Исходники остаются на iPhone. Получение сервером подтверждается отдельно для каждого комплекта.")
                        .font(.subheadline).foregroundStyle(Color.atlasMuted)
                }
            }.padding(.vertical, 4)
        }.listRowBackground(Color.atlasCard)
    }

    private var deliverySettings: some View {
        Section {
            Picker("Способ отправки", selection: Binding(
                get: { settings.policy },
                set: { value in
                    var updated = settings
                    updated.policy = value
                    saveSettings(updated)
                }
            )) {
                Text("Вручную").tag(UploadPolicy.manual)
                Text("Автоматически").tag(UploadPolicy.automatic)
            }
            .pickerStyle(.segmented)
            .disabled(!settingsLoaded || changingSettings)
            .accessibilityIdentifier("transfer.mode")
            Toggle("Только Wi-Fi", isOn: Binding(
                get: { settings.wifiOnly },
                set: { value in
                    var updated = settings
                    updated.wifiOnly = value
                    saveSettings(updated)
                }
            ))
            .disabled(!settingsLoaded || changingSettings)
            .accessibilityIdentifier("transfer.wifiOnly")
        } header: { Text("Отправка на сервер Atlas") } footer: {
            Text(deliveryExplanation)
        }.listRowBackground(Color.atlasCard)
    }

    @ViewBuilder private var connectionSection: some View {
        Section {
            if let organization = team.selectedOrganization, team.connected {
                Label(organization.name, systemImage: "person.2")
                    .font(.subheadline.weight(.semibold))
                Text(team.serverAddress).font(.caption).foregroundStyle(Color.atlasMuted)
                    .textSelection(.enabled)
                Text("Время, геометки с точностью и история исправлений сохраняются в паспорте. Отправитель подтверждается рабочим аккаунтом.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
                    .accessibilityIdentifier("transfer.connectionHint")
            } else {
                Label("Команда ещё не подключена", systemImage: "externaldrive.badge.person.crop")
                    .font(.subheadline.weight(.semibold))
                Text("Для отправки через сервер Atlas войдите в рабочее пространство. Без подключения используйте комплект ZIP выше — материалы можно передать в ваш чат или архив.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
                    .accessibilityIdentifier("transfer.connectionHint")
                NavigationLink {
                    TeamConnectionScreen(model: model)
                } label: {
                    Label("Подключить команду", systemImage: "person.badge.key")
                }.accessibilityIdentifier("transfer.connectTeam")
            }
            if team.connected {
                Text(coordinator.connectionHint).font(.footnote).foregroundStyle(Color.atlasMuted)
                if let role = team.selectedOrganization?.role, !["owner", "admin", "manager", "surveyor"].contains(role) {
                    Text("Ваша роль позволяет просматривать материалы. Для отправки нужен доступ полевого специалиста или руководителя.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                }
            }
        }.listRowBackground(Color.atlasCard)
    }

    private var sendSection: some View {
        Section {
            Button {
                Task { await model.sendFieldMaterials(project: project) }
            } label: {
                HStack(spacing: 10) {
                    if coordinator.isPreparing { ProgressView().tint(.atlasAccentInk) }
                    else { Image(systemName: "arrow.up.doc") }
                    Text(coordinator.isPreparing ? "Проверяем и собираем файлы…" : "Отправить материалы")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            .disabled(!canSend)
            .accessibilityIdentifier("transfer.send")
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } footer: {
            Text("Передаются сохранённые фото, модели, планы, карточки и метаданные. При обрыве сети загрузка продолжится с подтверждённого сервером места. Для продолжения держите Atlas открытым.")
        }.listRowBackground(Color.atlasCard)
    }

    private var queueSection: some View {
        Section {
            if unfinished.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Нет ожидающих комплектов", systemImage: "tray")
                        .font(.subheadline.weight(.semibold))
                    Text("Сохраните новую съёмку или отправьте текущие материалы проекта. Пока отправка не запрошена, они остаются на устройстве.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                }.padding(.vertical, 4)
            } else {
                LabeledContent("Комплектов", value: "\(unfinished.count)")
                LabeledContent("Объём", value: byteLabel(unfinished.reduce(0) { $0 + $1.totalBytes }))
                ForEach(unfinished) { record in transferRow(record) }
            }
        } header: { Text("Очередь отправки") } footer: {
            Text((records.count >= 100 ? "Показаны последние 100 комплектов; числа и объём относятся к показанным записям. " : "") +
                 "Квитанция сервера подтверждает получение файлов. Проверка специалистом — отдельный этап.")
        }.listRowBackground(Color.atlasCard)
    }

    private var receivedSection: some View {
        Section {
            if !completed.isEmpty {
                LabeledContent("Получено полностью", value: "\(completed.count)")
                ForEach(completed) { record in transferRow(record) }
            }
            NavigationLink {
                TeamProjectMaterialsScreen(model: model, project: project)
            } label: {
                Label("Материалы команды на сервере", systemImage: "tray.full")
            }.disabled(!team.connected || team.selectedOrganization == nil)
                .accessibilityIdentifier("transfer.remoteMaterials")
        } header: { Text("В общем проекте") }
            .listRowBackground(Color.atlasCard)
    }

    private func transferRow(_ record: FieldTransferRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: stateSymbol(record.state)).foregroundStyle(stateColor(record.state))
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.manifest.title).font(.subheadline.weight(.semibold))
                    Text("\(record.manifest.materials.count) материалов · \(record.manifest.assets.count) файлов · \(byteLabel(record.totalBytes))")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
                Spacer(minLength: 4)
            }
            Text(stateTitle(record.state)).font(.caption.weight(.semibold))
                .foregroundStyle(stateColor(record.state))
            if record.state == .uploading {
                ProgressView(value: record.fractionCompleted).tint(.atlasAccent)
                Text("\(byteLabel(record.uploadedBytes)) из \(byteLabel(record.totalBytes)) подтверждено сервером")
                    .font(.caption.monospacedDigit()).foregroundStyle(Color.atlasMuted)
            }
            if let message = record.lastError, record.state != .completed {
                Text(message).font(.footnote).foregroundStyle(Color.atlasMuted)
                    .textSelection(.enabled)
            }
            if let date = record.completedAt, record.state == .completed {
                Text(date, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption).foregroundStyle(Color.atlasMuted)
            }
            if record.state == .uploading || record.state == .queued || record.state == .waiting {
                Button("Приостановить") { Task { await coordinator.pause(id: record.id) } }
                    .font(.subheadline).accessibilityIdentifier("transfer.pause.\(record.id.uuidString)")
            } else if record.state == .failed || record.state == .paused {
                Button("Повторить отправку") { Task { await coordinator.retry(id: record.id) } }
                    .font(.subheadline).accessibilityIdentifier("transfer.retry.\(record.id.uuidString)")
            }
        }.padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transfer.record.\(record.id.uuidString)")
    }

    private func saveSettings(_ updated: FieldTransferSettings) {
        guard settingsLoaded, !changingSettings else { return }
        let newlyAutomatic = settings.policy != updated.policy && updated.policy == .automatic
        let requestID = UUID()
        let contextID = preferenceContextID
        settingsRequestID = requestID
        changingSettings = true
        settings = updated
        Task {
            guard settingsRequestID == requestID, preferenceContextID == contextID else { return }
            await coordinator.setSettings(updated, projectID: project.id)
            let storedSettings = await coordinator.settings(projectID: project.id)
            guard settingsRequestID == requestID, preferenceContextID == contextID else { return }
            settings = storedSettings
            changingSettings = false
            guard newlyAutomatic, storedSettings.policy == .automatic, team.connected,
                  team.selectedOrganization != nil,
                  ["owner", "admin", "manager", "surveyor"].contains(team.selectedOrganization?.role ?? ""),
                  !Task.isCancelled else { return }
            _ = await model.prepareFieldTransfer(project: project)
        }
    }

    private func byteLabel(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func stateTitle(_ state: FieldTransferState) -> String {
        switch state {
        case .ready: "На устройстве"
        case .queued: "В очереди"
        case .uploading: "Загружается"
        case .waiting: "Ожидает соединение"
        case .failed: "Не отправлено"
        case .conflict: "Требует разбора"
        case .paused: "Приостановлено"
        case .completed: "Получено полностью"
        }
    }

    private func stateSymbol(_ state: FieldTransferState) -> String {
        switch state {
        case .ready: "externaldrive"
        case .queued: "clock"
        case .uploading: "arrow.up.circle"
        case .waiting: "wifi.slash"
        case .failed, .conflict: "exclamationmark.triangle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        }
    }

    private func stateColor(_ state: FieldTransferState) -> Color {
        switch state {
        case .failed, .conflict: .orange
        case .completed, .uploading: .atlasAccent
        default: .atlasMuted
        }
    }
}
