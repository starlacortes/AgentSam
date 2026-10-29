import SwiftUI
import AgentSamCore

@main
struct AgentSamiOSApp: App {
    @State private var session = ServerSession.shared
    @State private var showGuidedSetup = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !session.isConfigured {
                    ConnectView()
                } else {
                    TabView {
                        MissionsTab().tabItem { Label("Missions", systemImage: "flag.checkered.2.crossed") }
                        TeamsTab().tabItem { Label("Teams", systemImage: "person.3") }
                        TemplatesTab().tabItem { Label("Templates", systemImage: "square.grid.2x2") }
                        SettingsTab().tabItem { Label("Server", systemImage: "gearshape") }
                    }
                }
            }
            .environment(session)
            .preferredColorScheme(.dark)
            .tint(AgentSamTheme.emerald)
            .sheet(isPresented: $showGuidedSetup) { IOGuidedSetupView() }
            .task {
                if session.isConfigured {
                    await session.refreshAll()
                    presentSetupIfNeeded()
                }
            }
            .onChange(of: session.info) { _, info in
                if info != nil { presentSetupIfNeeded() }
            }
        }
    }

    private func presentSetupIfNeeded() {
        let key = "agentsam.onboarding.completed.\(session.baseURL)"
        if session.isConfigured && !UserDefaults.standard.bool(forKey: key) { showGuidedSetup = true }
    }
}

struct ConnectView: View {
    @Environment(ServerSession.self) private var session
    @State private var url = ""
    @State private var token = ""
    @State private var message: String?
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    AgentSamBrand()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 38)
                    VStack(spacing: 8) {
                        Text("Your teams, wherever you work.")
                            .font(AgentSamTheme.displayFont(25))
                            .foregroundStyle(AgentSamTheme.ink)
                            .multilineTextAlignment(.center)
                        Text("Connect to your secured AgentSam server to launch missions and watch agents work in real time.")
                            .font(.callout)
                            .foregroundStyle(AgentSamTheme.muted)
                            .multilineTextAlignment(.center)
                    }
                    VStack(alignment: .leading, spacing: 15) {
                        Text("SERVER CONNECTION").agentSamKicker()
                        TextField("Server URL (https://…)", text: $url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(AgentSamTheme.deep)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AgentSamTheme.strongLine))
                        SecureField("Access token", text: $token)
                            .textInputAutocapitalization(.never)
                            .padding(12)
                            .background(AgentSamTheme.deep)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AgentSamTheme.strongLine))
                        Text("Use the HTTPS address and long-lived token from your server deployment.")
                            .font(.caption)
                            .foregroundStyle(AgentSamTheme.dim)
                    }
                    .agentSamPanel(padding: 18)
                    if let message {
                        Label(message, systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(AgentSamTheme.danger)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        connecting = true
                        Task {
                            let ok = await session.connect(url: url, token: token)
                            connecting = false
                            if !ok { message = session.lastError ?? "Could not reach server." }
                        }
                    } label: {
                        HStack {
                            if connecting { ProgressView() }
                            Text("Connect to AgentSam")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AgentSamPrimaryButtonStyle())
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || token.isEmpty || connecting)
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(AgentSamBackground())
        }
    }
}
