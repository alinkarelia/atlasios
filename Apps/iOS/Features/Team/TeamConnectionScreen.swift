import SwiftUI
import AtlasCore

struct TeamConnectionScreen: View {
    @ObservedObject var model: AtlasAppModel
    @ObservedObject private var service: TeamService
    @State private var projectID: UUID?
    @State private var openingProjectID: UUID?
    @State private var openedProject: AtlasProject?
    private let onOpenProject: ((RemoteProject) async -> AtlasProject?)?

    init(model: AtlasAppModel, onOpenProject: ((RemoteProject) async -> AtlasProject?)? = nil) {
        self.model = model
        self.onOpenProject = onOpenProject
        _service = ObservedObject(wrappedValue: model.team)
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "person.2.fill")
                        .font(.title2).foregroundStyle(Color.atlasAccent)
                        .frame(width: 48, height: 48)
                        .background(Color.atlasCanvas, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Одна команда. Общий проект.").font(.headline)
                        Text("Фото, модели, планы и паспорт съёмки — в нужный проект. Способ отправки выбираете вы.")
                            .font(.subheadline).foregroundStyle(Color.atlasMuted)
                    }
                }.padding(.vertical, 5)
            }.listRowBackground(Color.atlasCard)
            Section {
                NavigationLink {
                    TeamCommunicationScreen()
                } label: {
                    Label("Архив, рабочий чат и встреча", systemImage: "bubble.left.and.bubble.right")
                }.accessibilityIdentifier("team.communication")
            } header: { Text("Связь с командой") } footer: {
                Text("Все инструменты доступны без заданий. Комплект ZIP можно передать вручную; передача в задание команды использует существующий аккаунт сайта.")
            }.listRowBackground(Color.atlasCard)
            if !model.projects.isEmpty {
                Section {
                    Picker("Проект на iPhone", selection: $projectID) {
                        Text("Выберите проект").tag(Optional<UUID>.none)
                        ForEach(model.projects) { project in Text(project.name).tag(Optional(project.id)) }
                    }
                    if let project = model.projects.first(where: { $0.id == projectID }) {
                        NavigationLink {
                            TeamProjectTransferScreen(model: model, project: project)
                        } label: {
                            Label("Подготовить и передать материалы", systemImage: "archivebox")
                        }.accessibilityIdentifier("team.projectTransfer")
                    }
                } header: { Text("Материалы на iPhone") }
                    .listRowBackground(Color.atlasCard)
            }
            Section {
                Label("Личная выгрузка не подключена", systemImage: "icloud.slash")
                    .font(.subheadline.weight(.semibold))
                Text("Текущее подключение не поддерживает личную выгрузку на сервер без задания. Все инструменты, сохранение на iPhone и передача ZIP доступны полностью.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
                    .accessibilityIdentifier("team.personalUploadUnavailable")
            } header: { Text("Личные проекты") }
                .listRowBackground(Color.atlasCard)
            if let account = service.accountUser, service.accountSignedIn {
                Section("Семейный архив: Живая память") {
                    Label(account.displayName.isEmpty ? "Рабочий аккаунт сайта" : account.displayName,
                        systemImage: "person.crop.circle")
                        .accessibilityIdentifier("team.accountStatus")
                    if !account.email.isEmpty { Text(account.email).foregroundStyle(Color.atlasMuted) }
                    if let expiry = service.accountExpiresAt {
                        Text("Вход действует до \(expiry.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(Color.atlasMuted)
                    }
                    Button("Обновить доступные задания") {
                        Task { await service.refresh(); await model.transfers.authenticationChanged() }
                    }.disabled(service.busy)
                    Button("Выйти из рабочего аккаунта", role: .destructive) {
                        Task { await service.signOut(); await model.transfers.authenticationChanged() }
                    }.accessibilityIdentifier("team.archiveSignOut")
                }.listRowBackground(Color.atlasCard)
                Section {
                    if service.availableTasks.isEmpty {
                        Text("Доступных заданий пока нет").font(.headline)
                        Text("Вход выполнен. Все инструменты, съёмка, карточки и экспорт доступны полностью. Задания нужны только для организации совместной работы.")
                            .font(.subheadline).foregroundStyle(Color.atlasMuted)
                    } else {
                        ForEach(service.availableTasks) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title)
                                if let workspace = task.workspaceTitle {
                                    Text(workspace).font(.caption).foregroundStyle(Color.atlasMuted)
                                }
                            }
                        }
                        Text("Задание и доступ к оригиналам выбираются в разделе «Материалы и отправка» нужного проекта.")
                            .font(.footnote).foregroundStyle(Color.atlasMuted)
                    }
                    Link("Открыть рабочий кабинет сайта", destination: URL(string: "https://archiverf.ru/#staff/apps")!)
                } header: { Text("Доступные задания") }
                    .listRowBackground(Color.atlasCard)
                if service.runtimeReady { workspace }
            } else {
                Section {
                    Text("Используйте логин и пароль сайта «Семейный архив: Живая память». Защищённое окно сайта откроется после нажатия кнопки. Пароль вводится на сайте и не сохраняется в TerraView.")
                        .font(.subheadline).foregroundStyle(Color.atlasMuted)
                        .accessibilityIdentifier("team.archiveExplanation")
                    Button {
                        Task {
                            await service.signInToFamilyArchive()
                            await model.transfers.authenticationChanged()
                        }
                    } label: {
                        Label("Войти через Семейный архив", systemImage: "person.badge.key")
                    }.disabled(service.busy).accessibilityIdentifier("team.archiveSignIn")
                    if service.busy {
                        Button("Отменить вход", role: .cancel) {
                            Task { await service.signOut(); await model.transfers.authenticationChanged() }
                        }.accessibilityIdentifier("team.archiveCancelSignIn")
                    }
                } header: { Text("Один аккаунт с сайтом") } footer: {
                    Text("Съёмка, измерения и экспорт доступны бесплатно без входа и без заданий. Передача в задание команды подключается отдельно; новая учётная запись в приложении не создаётся.")
                }.listRowBackground(Color.atlasCard)
            }
            if service.busy { Section { ProgressView("Соединяемся с сервером…").tint(.atlasAccent) }.listRowBackground(Color.atlasCard) }
            if let issue = service.issue {
                Section { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(Color.orange) }
                    .listRowBackground(Color.atlasCard)
            }
            if let message = service.publicationMessage {
                Section { Text(message).font(.subheadline) }.listRowBackground(Color.atlasCard)
            }
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .foregroundStyle(Color.atlasInk).tint(.atlasAccent)
        .navigationTitle("Моя команда").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationDestination(item: $openedProject) { project in
            ProjectDetailScreen(model: model, project: project)
        }
        .task {
            if service.connected {
                await service.refresh()
                if let organization = service.selectedOrganization { await service.loadOrganization(organization) }
            }
            projectID = model.selectedProject?.id
        }
        .onChange(of: service.selectedOrganizationID) { _, _ in
            Task {
                await model.transfers.authenticationChanged()
                if let organization = service.selectedOrganization { await service.loadOrganization(organization) }
            }
        }
    }

    @ViewBuilder private var workspace: some View {
        if !service.organizations.isEmpty {
            Section("Рабочее пространство") {
                Picker("Организация", selection: $service.selectedOrganizationID) {
                    ForEach(service.organizations) { organization in
                        Text(organization.name).tag(Optional(organization.id))
                    }
                }.disabled(service.busy)
                if let organization = service.selectedOrganization {
                    LabeledContent("Моя роль", value: roleTitle(organization.role ?? "viewer"))
                    Button("Обновить") { Task { await service.loadOrganization(organization) } }.disabled(service.busy)
                }
            }.listRowBackground(Color.atlasCard)
            Section("Участники") {
                ForEach(service.members) { member in
                    LabeledContent(member.displayName, value: roleTitle(member.role))
                }
                Link("Управлять доступом на сайте", destination: URL(string: "https://archiverf.ru/#staff/apps")!)
            }.listRowBackground(Color.atlasCard)
            Section("Общие проекты") {
                if service.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Общих проектов пока нет").font(.headline)
                        Text("Выберите локальный проект выше и отправьте материалы. После подтверждения сервера проект станет доступен команде.")
                            .font(.subheadline).foregroundStyle(Color.atlasMuted)
                    }.padding(.vertical, 4)
                }
                ForEach(service.projects) { project in
                    Button { openSharedProject(project) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: ProjectKind(rawValue: project.kind)?.symbol ?? "folder")
                                .font(.title3).foregroundStyle(Color.atlasAccent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name).font(.headline).foregroundStyle(Color.atlasInk)
                                Text(model.projects.contains(where: { $0.id == project.id }) ? "Открыть на iPhone" : "Открыть общий проект")
                                    .font(.caption).foregroundStyle(Color.atlasMuted)
                            }
                            Spacer()
                            if openingProjectID == project.id { ProgressView().tint(.atlasAccent) }
                            else { Image(systemName: "chevron.right").foregroundStyle(Color.atlasMuted) }
                        }.padding(.vertical, 5)
                    }.buttonStyle(.plain)
                        .disabled(openingProjectID != nil || service.busy)
                        .accessibilityIdentifier("team.openSharedProject.\(project.id.uuidString)")
                }
            }.listRowBackground(Color.atlasCard)
        } else if !service.busy {
            Section { Button("Загрузить рабочие пространства") { Task { await service.refresh() } } }
                .listRowBackground(Color.atlasCard)
        }
    }

    private func openSharedProject(_ remote: RemoteProject) {
        guard openingProjectID == nil else { return }
        if let local = model.projects.first(where: { $0.id == remote.id }) {
            model.selectedProjectID = local.id
            openedProject = local
            return
        }
        openingProjectID = remote.id
        Task {
            let local: AtlasProject?
            if let onOpenProject { local = await onOpenProject(remote) }
            else { local = await model.openSharedProject(remote) }
            openingProjectID = nil
            if let local {
                model.selectedProjectID = local.id
                openedProject = local
            }
        }
    }

    private func roleTitle(_ role: String) -> String {
        switch role {
        case "owner": "Владелец"
        case "admin": "Администратор"
        case "manager": "Менеджер"
        case "surveyor": "Полевой специалист"
        case "reviewer": "Проверяющий"
        default: "Наблюдатель"
        }
    }
}
