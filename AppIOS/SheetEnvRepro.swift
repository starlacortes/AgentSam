import SwiftUI

// Temporary repro file: tests whether sheet content inherits an Observable
// object injected via .environment(_:) — mirrors AgentSamiOSApp's structure.
struct SheetEnvReproChildView: View {
    @Environment(ServerSession.self) private var session

    var body: some View {
        NavigationStack {
            VStack {
                Text("baseURL: '\(session.baseURL)'")
            }
        }
    }
}

// A: reads session in the main hierarchy (no sheet) — control.
struct SheetEnvReproDirectView: View {
    @State private var session = ServerSession.shared

    var body: some View {
        Group {
            Text("baseURL: '\(session.baseURL)'")
        }
        .environment(session)
    }
}

// B: sheet content reads session, environment injected on parent (mirrors app).
struct SheetEnvReproRootView: View {
    @State private var session = ServerSession.shared
    @State private var showSheet = true

    var body: some View {
        Group {
            Text("Root content")
        }
        .environment(session)
        .sheet(isPresented: $showSheet) {
            SheetEnvReproChildView()
        }
    }
}

// C: sheet content reads nothing from the environment — control for the sheet itself.
struct SheetEnvReproNoReadView: View {
    @State private var showSheet = true

    var body: some View {
        Group {
            Text("Root content")
        }
        .sheet(isPresented: $showSheet) {
            NavigationStack { Text("Sheet without env read") }
        }
    }
}

// D: environment re-injected inside the sheet closure — candidate fix.
struct SheetEnvReproFixedView: View {
    @State private var session = ServerSession.shared
    @State private var showSheet = true

    var body: some View {
        Group {
            Text("Root content")
        }
        .sheet(isPresented: $showSheet) {
            SheetEnvReproChildView()
                .environment(session)
        }
    }
}

#Preview("A direct read no sheet") {
    SheetEnvReproDirectView()
}

#Preview("B sheet reads env") {
    SheetEnvReproRootView()
}

#Preview("C sheet no env read") {
    SheetEnvReproNoReadView()
}

#Preview("D sheet env reinjected") {
    SheetEnvReproFixedView()
}
