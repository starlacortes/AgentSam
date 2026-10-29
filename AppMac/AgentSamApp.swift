import SwiftUI
import AgentSamCore

@main
struct AgentSamApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("AgentSam") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(AgentSamTheme.emerald)
                .frame(minWidth: 1_040, minHeight: 660)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}
