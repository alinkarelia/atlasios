import SwiftUI
import UIKit

@MainActor
struct ContentView: View {
    @StateObject private var session: WebSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsOpen = false
    init(configuration: AppConfiguration) { _session = StateObject(wrappedValue: WebSession(configuration: configuration)) }
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                if session.workAllowed && session.issue == nil {
                    AVELIWebView(session: session)
                        .safeAreaInset(edge: .top, spacing: 0) {
                            HStack(spacing: 6) {
                                Image(systemName: "location.fill")
                                Text(session.location.reducedAccuracy ? "Работа · приблизительная геолокация" : "Работа · геолокация включена")
                                Spacer()
                            }.font(.caption).padding(.horizontal, 12).padding(.vertical, 6).background(.thinMaterial)
                        }
                    if session.isLoading { ProgressView().padding(12).background(.regularMaterial, in: Capsule()) }
                } else { connectionScreen }
            }
            .navigationTitle("AVELI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { settingsOpen = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Настройки") }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Link("Помощь", destination: session.configuration.helpURL)
                        if session.isSignedIn {
                            Button("Продолжить работу") { session.retry() }
                            Button("Завершить работу") { session.stopWork() }
                            Button("Выйти", role: .destructive) { session.logout() }
                        } else if session.busy { Button("Отменить вход") { session.logout() } }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Действия")
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { session.resume() } else { session.suspend() } }
        .sheet(isPresented: $settingsOpen) { settings }
        .alert("Открыть сайт?", isPresented: Binding(get: { session.externalURL != nil }, set: { if !$0 { session.externalURL = nil } })) {
            Button("Отмена", role: .cancel) { session.externalURL = nil }
            Button("Открыть в Safari") { if let url = session.externalURL { UIApplication.shared.open(url) }; session.externalURL = nil }
        } message: { Text(session.externalURL?.host ?? "Внешний сайт") }
        .sheet(item: $session.downloadedFile) { file in ShareSheet(url: file.url) }
    }
    private var connectionScreen: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("BrandMark").resizable().scaledToFit().frame(width: 88, height: 88).accessibilityHidden(true)
                Text("AVELI").font(.title2.bold())
                Text(AppConfiguration.projectName).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !session.accountName.isEmpty { Text(session.accountName).font(.headline) }
                if let issue = session.issue { Text(issue).font(.body).multilineTextAlignment(.center).accessibilityAddTraits(.updatesFrequently) }
                else if !session.isOnline { Label("Нет соединения. Работа приостановлена.", systemImage: "wifi.slash") }
                else if session.isSignedIn { Text(session.location.message).font(.body).multilineTextAlignment(.center) }
                else { Text("Войдите с почтой, которую используете на сайте.").foregroundStyle(.secondary).multilineTextAlignment(.center) }
                if session.busy { ProgressView("Открываем защищённый вход…") }
                Button(session.isSignedIn ? "Продолжить работу" : "Войти через сайт") {
                    if session.isSignedIn { session.retry() } else { session.signIn() }
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(session.busy || session.clearingWebData || !session.isOnline)
                if session.isSignedIn { Button("Настройки геолокации") { openSystemSettings() }.buttonStyle(.bordered) }
                Link("Помощь", destination: session.configuration.helpURL).font(.subheadline)
            }.padding(24).frame(maxWidth: 420).frame(maxWidth: .infinity)
        }
    }
    private var settings: some View {
        NavigationStack {
            Form {
                Section("Учётная запись") {
                    Text(session.accountName.isEmpty ? "Вход не выполнен" : session.accountName)
                    if session.isSignedIn { Button("Выйти", role: .destructive) { session.logout(); settingsOpen = false } }
                    else { Button("Войти через сайт") { settingsOpen = false; session.signIn() }.disabled(session.busy || session.clearingWebData || !session.isOnline) }
                }
                Section("Рабочая геолокация") {
                    Text("Координаты передаются только при открытом приложении во время работы. Их видят главный и уполномоченные руководители.")
                    Text(session.location.message).foregroundStyle(.secondary)
                    Button("Открыть настройки iOS") { openSystemSettings() }
                    if session.isSignedIn { Button("Завершить работу") { session.stopWork(); settingsOpen = false } }
                }
                Section("Приложение") {
                    Text("AVELI 1.0.3 (4)")
                    Text(AppConfiguration.projectName)
                    Link("Помощь", destination: session.configuration.helpURL)
                }
            }.navigationTitle("Настройки").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { settingsOpen = false } } }
        }
    }
    private func openSystemSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
}
