import SwiftUI

/// User-supplied workspace destinations are opened by iOS. The screen does not
/// imply an API connection, automatic attachment delivery or a new login flow.
struct TeamCommunicationScreen: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("atlas.communication.archiveURL.v1") private var archiveAddress = ""
    @AppStorage("atlas.communication.chatURL.v1") private var chatAddress = ""
    @AppStorage("atlas.communication.meetingURL.v1") private var meetingAddress = ""

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.title2).foregroundStyle(Color.atlasAccent)
                        .frame(width: 48, height: 48)
                        .background(Color.atlasCanvas, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Обсуждение рядом с материалами").font(.headline)
                        Text("Добавьте ссылки вашей команды. Они сохраняются на этом iPhone и открываются обычным способом.")
                            .font(.subheadline).foregroundStyle(Color.atlasMuted)
                    }
                }.padding(.vertical, 5)
            }.listRowBackground(Color.atlasCard)
            destinationSection(title: "Семейный архив: Живая память", hint: "HTTPS-ссылка на платформу «Семейный архив: Живая память» или рабочее пространство",
                symbol: "books.vertical", address: $archiveAddress, identifier: "communication.archive",
                openTitle: "Открыть архив")
            destinationSection(title: "Рабочий чат", hint: "HTTPS-ссылка на чат, где команда обсуждает проект",
                symbol: "bubble.left.and.bubble.right", address: $chatAddress, identifier: "communication.chat",
                openTitle: "Открыть рабочий чат")
            destinationSection(title: "Встреча", hint: "HTTPS-ссылка на встречу, например в Яндекс Телемосте",
                symbol: "video", address: $meetingAddress, identifier: "communication.meeting",
                openTitle: "Открыть встречу")
            Section("Как передать материалы") {
                Label("В проекте откройте «Материалы и отправка» и подготовьте комплект ZIP.", systemImage: "1.circle")
                Label("Нажмите «Поделиться комплектом» и выберите получателя или сохраните файл.", systemImage: "2.circle")
                Label("Откройте ваш архив или чат и приложите сохранённый комплект, если сервис поддерживает ZIP.", systemImage: "3.circle")
            }.font(.subheadline).listRowBackground(Color.atlasCard)
            Section {
                Text("Эти ссылки открывают сторонние сервисы. \(AppBrand.displayName) не загружает туда файлы автоматически и не подтверждает получение вложений. Авторизация и доступ к архиву остаются в выбранном сервисе.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            }.listRowBackground(Color.atlasCard)
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .foregroundStyle(Color.atlasInk).tint(.atlasAccent)
        .navigationTitle("Архив и общение").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func destinationSection(title: String, hint: String, symbol: String,
                                    address: Binding<String>, identifier: String, openTitle: String) -> some View {
        Section {
            TextField("https://…", text: address)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityLabel("Ссылка: \(title)")
                .accessibilityIdentifier(identifier + ".address")
            Button {
                if let url = validatedDestination(address.wrappedValue) { openURL(url) }
            } label: {
                Label(openTitle, systemImage: symbol)
            }.disabled(validatedDestination(address.wrappedValue) == nil)
                .accessibilityIdentifier(identifier + ".open")
            if !address.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               validatedDestination(address.wrappedValue) == nil {
                Text("Укажите полную HTTPS-ссылку без логина и пароля в адресе.")
                    .font(.footnote).foregroundStyle(Color.orange)
            }
        } header: { Text(title) } footer: { Text(hint) }
            .listRowBackground(Color.atlasCard)
    }

    private func validatedDestination(_ address: String) -> URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }
}
