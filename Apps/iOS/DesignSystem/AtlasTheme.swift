import SwiftUI

extension Color {
    static let atlasCanvas = Color(red: 0.063, green: 0.071, blue: 0.078)
    static let atlasCard = Color(red: 0.110, green: 0.125, blue: 0.141)
    static let atlasInk = Color(red: 0.957, green: 0.961, blue: 0.933)
    static let atlasMuted = Color(red: 0.643, green: 0.671, blue: 0.702)
    static let atlasAccent = Color(red: 0.851, green: 1.0, blue: 0.239)
    static let atlasAccentInk = atlasCanvas
    static let atlasLine = Color.white.opacity(0.13)
    static let atlasGraphite = atlasCanvas
    static let atlasLime = atlasAccent
    // Keep older screens on the same brand palette while their layouts evolve.
    static let atlasBlue = atlasAccent
}

struct AtlasPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(Color.atlasAccentInk)
            .background(Color.atlasAccent, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct AtlasSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 12)
            .foregroundStyle(Color.atlasInk)
            .background(Color.atlasCard, in: Capsule())
            .overlay(Capsule().stroke(Color.atlasLine, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct AtlasPrimaryButton: View {
    let title: String
    var systemImage: String = "arrow.right"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .accessibilityAddTraits(.isButton)
    }
}

struct AtlasEmptyState: View {
    let title: String
    let message: String
    let symbol: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .foregroundStyle(Color.atlasInk)
    }
}

struct AtlasSectionLabel: View {
    let title: String
    var body: some View { Text(title).font(.title3.bold()).foregroundStyle(Color.atlasInk) }
}

