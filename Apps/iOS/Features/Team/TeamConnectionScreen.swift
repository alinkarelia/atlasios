import SwiftUI
import AtlasCore

struct TeamConnectionScreen: View {
    @ObservedObject var model: AtlasAppModel
    @ObservedObject private var service: TeamService
    @State private var registering = false
    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var organizationName = ""
    @State private var memberEmail = ""
    @State private var memberRole = "surveyor"
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
                Text("Можно пользоваться вашим семейным архивом и чатом без сервера Atlas. Комплект ZIP с исходниками и метаданными создаётся из проекта.")
            }.listRowBackground(Color.atlasCard)
            if !service.connected, !model.projects.isEmpty {
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
                } header: { Text("Поделиться без входа") }
                    .listRowBackground(Color.atlasCard)
            }
            if let user = service.user {
                Section("Рабочий аккаунт") {
                    Label(user.displayName, systemImage: "person.crop.circle")
                    Text(user.email).foregroundStyle(Color.atlasMuted)
                    Text(service.serverAddress).font(.caption).textSelection(.enabled)
                    Button("Выйти", role: .destructive) {
                        Task {
                            await service.signOut()
                            await model.transfers.authenticationChanged()
                            await model.configureCommerceAccount()
                        }
                    }.disabled(service.busy)
                }.listRowBackground(Color.atlasCard)
                workspace
            } else {
                Section {
                    Picker("Аккаунт", selection: $registering) {
                        Text("Войти").tag(false)
                        Text("Регистрация").tag(true)
                    }.pickerStyle(.segmented)
                    TextField("Адрес сервера команды", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("team.server")
                    TextField("Электронная почта", text: $email)
                        .keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("team.email")
                    SecureField(registering ? "Пароль · от 12 символов" : "Пароль", text: $password)
                        .textContentType(registering ? .newPassword : .password)
                        .accessibilityIdentifier("team.password")
                    if registering {
                        TextField("Ваше имя", text: $name).textContentType(.name)
                        TextField("Название организации", text: $organizationName)
                    }
                    Button(registering ? "Создать рабочее пространство" : "Подключиться") {
                        Task {
                            await service.authenticate(server: server, email: email, password: password,
                                displayName: registering ? name : nil, organizationName: registering ? organizationName : nil)
                            if service.connected { password = "" }
                            await model.transfers.authenticationChanged()
                            await model.configureCommerceAccount()
                            if let organization = service.selectedOrganization { await service.loadOrganization(organization) }
                        }
                    }.disabled(service.busy || !formReady)
                        .accessibilityIdentifier("team.connect")
                } header: { Text("Сервер Atlas · дополнительно") } footer: {
                    Text("У Atlas пока нет общего сервера по умолчанию. Укажите HTTPS-адрес, который выдал администратор организации. Без входа можно снимать и сохранять проекты на iPhone.")
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
                await model.configureCommerceAccount()
                if let organization = service.selectedOrganization { await service.loadOrganization(organization) }
            }
        }
    }

    private var formReady: Bool {
        !server.isEmpty && email.contains("@") && !password.isEmpty &&
        (!registering || (password.count >= 12 && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
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
                if let organization = service.selectedOrganization, ["owner", "admin"].contains(organization.role ?? "") {
                    TextField("Почта нового участника", text: $memberEmail)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Роль участника", selection: $memberRole) {
                        ForEach(["surveyor", "reviewer", "manager", "viewer"], id: \.self) { role in
                            Text(roleTitle(role)).tag(role)
                        }
                    }
                    Button("Добавить участника") {
                        Task { await service.addMember(email: memberEmail, role: memberRole, organization: organization) }
                    }.disabled(service.busy || !memberEmail.contains("@"))
                    Text("Участник сначала регистрируется на этом сервере. Роль и доступ подтверждает сервер.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                }
            }.listRowBackground(Color.atlasCard)
            Section {
                Picker("Локальный проект", selection: $projectID) {
                    Text("Выберите проект").tag(Optional<UUID>.none)
                    ForEach(model.projects) { project in Text(project.name).tag(Optional(project.id)) }
                }
                if let project = model.projects.first(where: { $0.id == projectID }) {
                    NavigationLink {
                        TeamProjectTransferScreen(model: model, project: project)
                    } label: {
                        Label("Материалы и отправка", systemImage: "arrow.up.doc")
                    }.accessibilityIdentifier("team.projectTransfer")
                }
            } header: { Text("Отправить с этого iPhone") } footer: {
                Text("По умолчанию отправка ручная. В проекте можно включить автоматическую отправку после сохранения и ограничить её Wi-Fi.")
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
