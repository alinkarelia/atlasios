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

    init(model: AtlasAppModel) {
        self.model = model
        _service = ObservedObject(wrappedValue: model.team)
    }

    var body: some View {
        Form {
            if let user = service.user {
                Section("Рабочий аккаунт") {
                    Label(user.displayName, systemImage: "person.crop.circle")
                    Text(user.email).foregroundStyle(Color.atlasMuted)
                    Text(service.serverAddress).font(.caption).textSelection(.enabled)
                    Button("Выйти", role: .destructive) {
                        Task { await service.signOut(); await model.configureCommerceAccount() }
                    }.disabled(service.busy)
                }
                workspace
            } else {
                Section {
                    Picker("Аккаунт", selection: $registering) {
                        Text("Войти").tag(false)
                        Text("Регистрация").tag(true)
                    }.pickerStyle(.segmented)
                    TextField("Адрес сервера команды", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Электронная почта", text: $email)
                        .keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(registering ? "Пароль · от 12 символов" : "Пароль", text: $password)
                        .textContentType(registering ? .newPassword : .password)
                    if registering {
                        TextField("Ваше имя", text: $name).textContentType(.name)
                        TextField("Название организации", text: $organizationName)
                    }
                    Button(registering ? "Создать рабочее пространство" : "Подключиться") {
                        Task {
                            await service.authenticate(server: server, email: email, password: password,
                                displayName: registering ? name : nil, organizationName: registering ? organizationName : nil)
                            if service.connected { password = "" }
                            await model.configureCommerceAccount()
                            if let organization = service.selectedOrganization { await service.loadOrganization(organization) }
                        }
                    }.disabled(service.busy || !formReady)
                } header: { Text("Моя команда") } footer: {
                    Text("Адрес выдаёт администратор команды. Учётная запись нужна для совместной работы; проекты и съёмки доступны на устройстве без входа.")
                }
            }
            if service.busy { Section { ProgressView("Соединяемся с сервером…") } }
            if let issue = service.issue {
                Section { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(Color.orange) }
            }
            if let message = service.publicationMessage { Section { Text(message).font(.subheadline) } }
        }
        .navigationTitle("Моя команда").navigationBarTitleDisplayMode(.inline)
        .task {
            if service.connected {
                await service.refresh()
                if let organization = service.selectedOrganization { await service.loadOrganization(organization) }
            }
            projectID = model.selectedProject?.id
        }
        .onChange(of: service.selectedOrganizationID) { _, _ in
            Task {
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
            }
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
            }
            Section {
                Picker("Локальный проект", selection: $projectID) {
                    Text("Выберите проект").tag(Optional<UUID>.none)
                    ForEach(model.projects) { project in Text(project.name).tag(Optional(project.id)) }
                }
                Button("Передать метаданные") {
                    guard let project = model.projects.first(where: { $0.id == projectID }), let organization = service.selectedOrganization else { return }
                    Task { if let snapshot = await model.snapshot(of: project) { await service.publish(snapshot, to: organization) } }
                }.disabled(service.busy || projectID == nil)
            } header: { Text("Передача проекта") } footer: {
                Text("Передаются карточки и полигоны. Исходники и планы выгружаются архивом из проекта. При конфликте версии объект сохраняется локально и требует разбора.")
            }
            Section("Проекты на сервере") {
                if service.projects.isEmpty { Text("Переданных проектов пока нет.").foregroundStyle(Color.atlasMuted) }
                ForEach(service.projects) { project in
                    LabeledContent(project.name, value: "Версия \(project.revision)")
                }
            }
        } else if !service.busy {
            Section { Button("Загрузить рабочие пространства") { Task { await service.refresh() } } }
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
