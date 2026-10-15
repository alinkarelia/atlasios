import SwiftUI
import AtlasCore

struct StaffRuntimeWorkspaceScreen: View {
    @ObservedObject var model: AtlasAppModel
    @ObservedObject private var service: TeamService
    @State private var projectID: UUID?
    @State private var openedProject: AtlasProject?
    @State private var openingProjectID: UUID?
    init(model: AtlasAppModel) {
        self.model = model; _service = ObservedObject(wrappedValue:model.team)
    }
    var body: some View {
        List {
            workspace
            if let issue = service.issue { Section { Text(issue).foregroundStyle(.orange) }.listRowBackground(Color.atlasCard) }
        }
            .scrollContentBackground(.hidden).background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
            .navigationTitle("Материалы команды").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item:$openedProject) { project in ProjectDetailScreen(model:model,project:project) }
            .task {
                projectID = model.selectedProject?.id
                if let organization = service.selectedOrganization { await service.loadOrganization(organization) }
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
                Link("Состав команды и роли — на сайте", destination:StaffIdentityPolicy.origin)
                    .font(.footnote)
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
        do { try model.staff.bindProject(remote.id) }
        catch { service.issue = error.localizedDescription; return }
        if let local = model.projects.first(where: { $0.id == remote.id }) {
            model.selectedProjectID = local.id
            openedProject = local
            return
        }
        openingProjectID = remote.id
        Task {
            let local = await model.openSharedProject(remote)
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
