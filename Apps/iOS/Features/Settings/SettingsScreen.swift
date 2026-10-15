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
                        Text(AppBrand.displayName).font(.title.bold())
                        Text("Съёмка · Планы · Территории").font(.subheadline).foregroundStyle(Color.atlasMuted)
                    }
                }.padding(.vertical, 10)
            }.listRowBackground(Color.atlasCard)
            Section("Рабочее пространство") {
                NavigationLink { TeamConnectionScreen(model: model) } label: { Label("Моя команда", systemImage: "person.2") }
                NavigationLink { TeamCommunicationScreen() } label: { Label("Архив, чат и встречи", systemImage: "bubble.left.and.bubble.right") }
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
                        busy = true; backupURL = nil
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
                Text("Работа выполняется с аккаунтом платформы «Семейный архив: Живая память» и текущим заданием. Исходные записи и экспорт сохраняются на устройстве.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
                Text("При потере отслеживания фрагменты съёмки сохраняют отдельные координаты. Геопривязка и объединение фрагментов требуют контрольных точек.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            }.listRowBackground(Color.atlasCard)
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .foregroundStyle(Color.atlasInk)
        .navigationTitle("Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

struct DataInformationScreen: View {
    var body: some View {
        List {
            Section("На устройстве") {
                Text("Проекты, исходники, фото и прежние записи остаются на устройстве, в том числе после выхода или потери доступа. Для новой съёмки и отправки нужны рабочий аккаунт, предоставленное задание и подтверждённая геолокация. Отправка по умолчанию ручная.")
            }
            Section("Работа команды") {
                Text("После входа сервер хранит имя, почту, идентификатор аккаунта и членство в организации. В разделе «Материалы и отправка» можно передать исходники, планы, карточки и паспорт выбранного проекта. Выберите ручную или автоматическую отправку и допустимую сеть. Получение всех файлов подтверждается сервером отдельно от проверки специалистом.")
                Text("Сохранённый ZIP можно выгрузить через меню «Поделиться». Вход в платформу «Семейный архив: Живая память» проходит на сайте по своей почте и коду; приложение не запрашивает отдельный пароль.")
            }
            Section("Бесплатные инструменты") {
                Text("Новый платный тариф этим обновлением не вводится. Рабочие полномочия назначает руководитель на сайте; они проверяются сервером.")
            }
            Section("Фото и надписи") {
                Text("Фотофиксация и распознавание текста выполняются на устройстве. Распознанный текст является черновиком; сведения о захоронении и границах подтверждает специалист по источникам.")
            }
            Section("Положение и датчики") {
                Text("Во время съёмки геометка получается автоматически при разрешённой геолокации. Сохраняются координаты, время и доступная точность. Метку можно исправить на карте; исходное измерение и история сохраняются. Исходное фото при этом не изменяется.")
                Text("Рабочая геолокация передаётся руководителю раз в30секунд только в активной рабочей сессии на экране. В фоне, после паузы или отзыва разрешения получение положения останавливается. Приблизительная точность показывается отдельно; вымышленная точка не подставляется.")
                Text("Уровень использует датчики движения, компас — датчик направления. Получение положения и показаний останавливается при уходе с соответствующего экрана и в фоне. Геометки входят в паспорт отправляемых материалов; исходное наблюдение и ручные исправления сохраняются отдельно.")
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
