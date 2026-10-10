import SwiftUI
import ARKit
import RoomPlan
import AtlasCore

struct SettingsScreen: View {
    @ObservedObject var model: AtlasAppModel
    @State private var backupURL: URL?
    @State private var busy = false
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Color.atlasAccentInk).frame(width: 60, height: 60)
                        .background(Color.atlasAccent, in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Atlas").font(.title.bold())
                        Text("Съёмка · Планы · Территории").font(.subheadline).foregroundStyle(Color.atlasMuted)
                    }
                }.padding(.vertical, 10)
            }.listRowBackground(Color.atlasCard)
            Section("Рабочее пространство") {
                NavigationLink { TeamConnectionScreen(model: model) } label: { Label("Моя команда", systemImage: "person.2") }
                NavigationLink { SubscriptionScreen(purchases: model.purchases) } label: { Label("Тарифы и покупки", systemImage: "creditcard") }
            }.listRowBackground(Color.atlasCard)
            Section("Устройство") {
                LabeledContent("LiDAR", value: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) ? "Поддерживается" : "Недоступен")
                LabeledContent("RoomPlan", value: RoomCaptureSession.isSupported ? "Поддерживается" : "Недоступен")
                Text("Полигоны, ручные планы, карточки и фото доступны без LiDAR. Обмеры требуют проверки контрольными размерами.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            }.listRowBackground(Color.atlasCard)
            Section {
                if let project = model.selectedProject {
                    Button {
                        busy = true
                        Task { backupURL = await model.exportArchive(project: project); busy = false }
                    } label: {
                        if busy { ProgressView("Собираем архив…") }
                        else { Label("Выгрузить текущий проект", systemImage: "archivebox") }
                    }.disabled(busy).accessibilityIdentifier("settings.exportProject")
                }
                if let backupURL { ShareLink(item: backupURL) { Label("Сохранить архив", systemImage: "square.and.arrow.up") } }
                Button("Добавить демонстрационный проект") { Task { await model.loadDemo() } }
                    .accessibilityIdentifier("settings.demo")
                NavigationLink { DataInformationScreen() } label: { Label("Данные и конфиденциальность", systemImage: "lock.shield") }
            } header: { Text("Мои данные") } footer: {
                Text("Изменения сохраняются на устройстве. Для резервной копии сохраните архив за пределами приложения.")
            }.listRowBackground(Color.atlasCard)
            Section("О приложении") {
                LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")
                Text("При потере отслеживания фрагменты съёмки сохраняют отдельные координаты. Геопривязка и объединение фрагментов требуют контрольных точек.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            }.listRowBackground(Color.atlasCard)
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .foregroundStyle(Color.atlasInk)
        .navigationTitle("Профиль")
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

struct DataInformationScreen: View {
    var body: some View {
        List {
            Section("На устройстве") {
                Text("Проекты, исходники, фото и бизнес-записи сохраняются в приложении. Для полевой работы аккаунт не нужен. Исходники не отправляются автоматически.")
            }
            Section("Работа команды") {
                Text("После входа сервер хранит имя, почту, идентификатор аккаунта и членство в организации. Действие «Передать метаданные» отправляет карточки, заметки и геометрию выбранного проекта. Проверьте состав записей перед передачей.")
            }
            Section("Подписки") {
                Text("Покупки оформляет App Store. Для командного тарифа подписанное подтверждение покупки проверяется сервером. После завершения подписки свои локальные данные можно открыть и выгрузить.")
            }
            Section("Фото и надписи") {
                Text("Фотофиксация и распознавание текста выполняются на устройстве. Распознанный текст является черновиком; сведения о захоронении и границах подтверждает специалист по источникам.")
            }
            Section("Положение и датчики") {
                Text("Во время съёмки геометка получается автоматически при разрешённой геолокации. Сохраняются координаты, время и доступная точность. Метку можно исправить на карте; исходное измерение и история сохраняются. Исходное фото при этом не изменяется.")
                Text("Уровень использует датчики движения, компас — датчик направления. Получение положения и показаний останавливается при уходе с соответствующего экрана и в фоне. Геометки не загружаются на сервер автоматически.")
            }
            Section("Копия данных") {
                Text("Удаление приложения может удалить локальные проекты. Периодически сохраняйте ZIP-архивы в Файлы или хранилище организации. Архив содержит данные и исходники, но импорт архива в этой версии ещё не предусмотрен.")
            }
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .foregroundStyle(Color.atlasInk)
        .navigationTitle("Мои данные").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}
