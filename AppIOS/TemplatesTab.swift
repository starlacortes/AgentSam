import SwiftUI
import AgentSamCore

struct TemplatesTab: View {
    @Environment(ServerSession.self) private var session
    @State private var preview: TeamTemplate?
    @State private var editingTeam: Team?
    @State private var showNewTeam = false
    @State private var saving = false

    private var providers: [ProviderConfig] { session.providers.map(\.provider) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CURATED TEAMS").agentSamKicker()
                        Text("Hire a team in one click.").font(AgentSamTheme.displayFont(27)).foregroundStyle(AgentSamTheme.ink)
                        Text("Preview the roster, then make every role and model your own.").font(.callout).foregroundStyle(AgentSamTheme.muted)
                    }
                    .padding(.horizontal, 16)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(TeamTemplateCatalog.all) { template in
                            TeamTemplateCard(template: template, agents: template.agents(providers: providers)) {
                                preview = template
                            } onHire: {
                                hire(template)
                            }
                        }
                        BuildTeamCard { showNewTeam = true }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 18)
            }
            .background(AgentSamBackground())
            .navigationTitle("Templates")
            .sheet(item: $preview) { template in
                NavigationStack {
                    TeamTemplatePreview(template: template, agents: template.agents(providers: providers)) {
                        preview = nil
                        hire(template)
                    } onClose: {
                        preview = nil
                    }
                }
            }
            .sheet(item: $editingTeam) { team in IOTeamEditView(team: team) }
            .sheet(isPresented: $showNewTeam) { IOTeamEditView(team: nil) }
            .overlay { if saving { ProgressView("Hiring team…").padding().agentSamPanel() } }
        }
    }

    private func hire(_ template: TeamTemplate) {
        saving = true
        let team = template.makeTeam(providers: providers)
        Task {
            if let saved = await session.saveTeam(team) { editingTeam = saved }
            saving = false
        }
    }
}
