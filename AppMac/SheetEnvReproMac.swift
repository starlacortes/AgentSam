import SwiftUI

// Temporary repro: mirrors AgentSamApp's structure to test whether
// sheet content inherits an Observable object injected via .environment(_:)
// on macOS.
struct SheetEnvReproMacChildView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("dataDir: \(model.dataDirPath)")
    }
}

struct SheetEnvReproMacRootView: View {
    @State private var model = AppModel()
    @State private var showSheet = true

    var body: some View {
        Group {
            Text("Root content")
        }
        .environment(model)
        .sheet(isPresented: $showSheet) {
            SheetEnvReproMacChildView()
        }
    }
}

#Preview("Mac sheet env inheritance") {
    SheetEnvReproMacRootView()
}
