import SwiftUI
import AtlasCore

struct TeamConnectionScreen: View {
    @ObservedObject var model: AtlasAppModel
    var body: some View { StaffAccountScreen(model:model,staff:model.staff) }
}
