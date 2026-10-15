import SwiftUI

@main
@MainActor
struct AVELIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(configuration: AppConfiguration())
        }
    }
}
