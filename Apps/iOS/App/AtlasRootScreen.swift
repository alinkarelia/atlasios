import SwiftUI
import AtlasCore

struct AtlasRootScreen: View {
    @ObservedObject var model: AtlasAppModel
    var body: some View {
        Group {
            if !model.ready {
                VStack(spacing: 20) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 46, weight: .medium)).foregroundStyle(Color.atlasAccent)
                    ProgressView("Открываем проекты…").tint(.atlasAccent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.storeAvailable {
                AtlasEmptyState(title: "Данные недоступны", message: model.issue ?? "Проверьте свободное место на устройстве.", symbol: "externaldrive.badge.exclamationmark")
            } else {
                TabView {
                    NavigationStack { ProjectsScreen(model: model) }
                        .tabItem { Label("Проекты", systemImage: "folder.fill") }
                    NavigationStack {
                        if let project = model.selectedProject { GeometryEditorScreen(model: model, project: project).id(project.id) }
                        else { AtlasEmptyState(title: "Нет проекта", message: "Создайте проект, чтобы работать с полигонами.", symbol: "map") }
                    }.tabItem { Label("Карта", systemImage: "map") }
                    NavigationStack {
                        if let business = model.business { BusinessScreen(store: business) }
                        else { AtlasEmptyState(title: "Бизнес недоступен", message: "Не удалось открыть локальные данные.", symbol: "person.2") }
                    }.tabItem { Label("Бизнес", systemImage: "person.2") }
                    NavigationStack { SettingsScreen(model: model) }
                        .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
                }
                .toolbarBackground(Color.atlasCanvas, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            }
        }
        .foregroundStyle(Color.atlasInk)
        .background(Color.atlasCanvas.ignoresSafeArea())
        .tint(.atlasAccent)
        .preferredColorScheme(.dark)
        .alert("Atlas", isPresented: Binding(get: { model.issue != nil }, set: { if !$0 { model.issue = nil } })) {
            Button("Понятно", role: .cancel) { model.issue = nil }
        } message: { Text(model.issue ?? "") }
    }
}
