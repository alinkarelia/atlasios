import SwiftUI
import UIKit
import AtlasCore

/// One task selector and one explicit local-project association. The server
/// remains the authority; neither selector manufactures a role or assignment.
struct StaffAccountScreen: View {
    @ObservedObject var model: AtlasAppModel
    @ObservedObject var staff: StaffAccountSession
    @State private var taskID = ""
    @State private var localProjectID: UUID?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Text("Семейный архив: Живая память").font(.headline)
                if let user = staff.context?.user {
                    Text(user.name).font(.subheadline)
                    if user.isChief { Text("Главный · максимальный доступ").font(.caption).foregroundStyle(Color.atlasMuted) }
                } else {
                    Text("Войдите своей почтой через сайт. Код вводится на сайте.")
                        .font(.subheadline).foregroundStyle(Color.atlasMuted)
                }
                if !staff.authenticated {
                    Button { Task { await staff.signIn() } } label: {
                        if staff.busy { ProgressView("Вход…") }
                        else { Label("Войти через сайт", systemImage:"person.crop.circle") }
                    }.disabled(staff.busy).accessibilityIdentifier("staff.signIn")
                }
            }.listRowBackground(Color.atlasCard)
            if staff.authenticated {
                Section("Рабочее положение") {
                    Label(staff.location.message, systemImage:staff.location.canWork ? "location.fill" : "location.slash")
                        .font(.subheadline).accessibilityIdentifier("staff.location.status")
                    if staff.workingSessionActive {
                        Button("Приостановить работу") { staff.pauseWorkSession() }
                    } else { Button("Начать рабочую сессию") { staff.startWorkSession() }.accessibilityIdentifier("staff.work.start") }
                    if !staff.location.authorized {
                        Button("Разрешить геолокацию") { staff.location.requestPermission() }
                            .accessibilityIdentifier("staff.location.allow")
                        Button("Открыть настройки iOS") {
                            if let url = URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    Text("Положение передаётся руководителю каждые 30 секунд во время активной рабочей сессии на экране. В фоне и после паузы получение положения прекращается. Приблизительная точность показывается отдельно.")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }.listRowBackground(Color.atlasCard)
                Section("Задание") {
                    if let context = staff.context, context.tasks.isEmpty {
                        Text("Предоставленных заданий пока нет").font(.headline)
                        Text(context.user.isChief ? "Вход главного выполнен. Для съёмки выберите настоящее задание на сайте." : "Руководитель назначает задания и доступ на сайте.")
                            .font(.subheadline).foregroundStyle(Color.atlasMuted)
                    } else {
                        Picker("Задание",selection:$taskID) {
                            Text("Выберите").tag("")
                            ForEach(staff.context?.tasks ?? []) { task in Text(task.title).tag(task.id) }
                        }.accessibilityIdentifier("staff.task")
                        if taskID != staff.selectedTaskID {
                            Button("Открыть задание") { Task { await staff.selectTask(taskID) } }
                                .disabled(taskID.isEmpty || staff.busy || !staff.location.canWork)
                                .accessibilityIdentifier("staff.task.open")
                        }
                    }
                }.listRowBackground(Color.atlasCard)
                if staff.selectedTask != nil {
                    Section("Проект на этом iPhone") {
                        Picker("Проект",selection:$localProjectID) {
                            Text("Выберите").tag(Optional<UUID>.none)
                            ForEach(model.projects) { project in Text(project.name).tag(Optional(project.id)) }
                        }.accessibilityIdentifier("staff.localProject")
                        if let id = localProjectID {
                            Button(staff.projectIsBound(id) ? "Открыть проект" : "Связать с выбранным заданием") {
                                do { try staff.bindProject(id); model.selectedProjectID = id }
                                catch { self.error = error.localizedDescription }
                            }.disabled(staff.busy).accessibilityIdentifier("staff.project.bind")
                        }
                        Button("Создать проект для задания") {
                            Task {
                                if let project = await model.createProject(name:staff.selectedTask?.title ?? "Рабочий проект",kind:.building) {
                                    do { try staff.bindProject(project.id); model.selectedProjectID = project.id }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                        }.accessibilityIdentifier("staff.project.create")
                        Text("Исходники остаются в своём проекте. Проект другого задания не переназначается; для новой работы создайте отдельный.")
                            .font(.caption).foregroundStyle(Color.atlasMuted)
                    }.listRowBackground(Color.atlasCard)
                }
                if staff.workAllowed {
                    Section { NavigationLink("Материалы команды") { StaffRuntimeWorkspaceScreen(model:model) } }
                        .listRowBackground(Color.atlasCard)
                }

            } else if staff.context != nil {
                Section { Button("Повторить проверку доступа") { Task { await staff.refresh() } }.disabled(staff.busy) }
                    .listRowBackground(Color.atlasCard)
            }
            if staff.hasAccount {
                Section {
                    Button("Обновить доступ") { Task { await staff.refresh() } }.disabled(staff.busy)
                    Button("Выйти",role:.destructive) { staff.signOut() }.accessibilityIdentifier("staff.signOut")
                }.listRowBackground(Color.atlasCard)
            }
            Section {
                NavigationLink("Локальные записи и экспорт") { StaffLocalRecordsScreen(model:model) }
                    .accessibilityIdentifier("staff.localRecords")
                NavigationLink("Помощь и данные") { DataInformationScreen() }
            }.listRowBackground(Color.atlasCard)
            if let message = error ?? staff.issue { Section { Text(message).foregroundStyle(.orange) }.listRowBackground(Color.atlasCard) }
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
        .navigationTitle("Рабочий аккаунт").navigationBarTitleDisplayMode(.inline)
        .onAppear { taskID = staff.selectedTaskID ?? ""; localProjectID = model.selectedProject?.id }
        .onChange(of:staff.selectedTaskID) { _, id in taskID = id ?? "" }
    }
}

private struct StaffLocalRecordsScreen: View {
    @ObservedObject var model: AtlasAppModel
    @State private var archive: URL?
    @State private var busy = false
    var body: some View {
        List {
            Section { Text("Исходные записи сохранены. Для новой съёмки и отправки необходим рабочий доступ и геолокация.").font(.subheadline) }
            ForEach(model.projects) { project in
                Button {
                    busy = true
                    Task { archive = await model.exportArchive(project:project); busy = false }
                } label: { Label(project.name,systemImage:"archivebox") }.disabled(busy)
            }
            if busy { ProgressView("Собираем архив…") }
            if let archive { ShareLink(item:archive) { Label("Сохранить архив",systemImage:"square.and.arrow.up") } }
        }.scrollContentBackground(.hidden).background(Color.atlasCanvas).navigationTitle("Локальные записи")
    }
}
