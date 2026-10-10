import SwiftUI

@main
struct AtlasApp: App {
    @StateObject private var model = AtlasAppModel()
    var body: some Scene {
        WindowGroup {
            AtlasRootScreen(model: model)
                .tint(.atlasAccent)
                .task { await model.start() }
        }
    }
}

