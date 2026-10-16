import SwiftUI

@main
struct AtlasApp: App {
    @StateObject private var model = AtlasAppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            AtlasRootScreen(model: model)
                .tint(.atlasAccent)
                .task {
                    model.team.setCloudWorkForeground(scenePhase == .active)
                    await model.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    model.team.setCloudWorkForeground(phase == .active)
                    if phase == .active { model.transfers.sceneBecameActive() }
                    else if phase == .background { model.transfers.sceneBecameInactive() }
                }
        }
    }
}

