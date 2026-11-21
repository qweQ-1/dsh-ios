import SwiftUI

@main
@MainActor
struct DshApp: App {
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            ChatScreen(settings: settings)
                .preferredColorScheme(.dark)
        }
    }
}
