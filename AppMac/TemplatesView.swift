import SwiftUI
import AgentSamCore

struct TemplatesView: View {
    @Environment(AppModel.self) private var model
    @State private var preview: TeamTemplate?
    @State private var editingTeam: Team?
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("CURATED TEAMS").agentSamKicker()
                    Text("Hire a team in one click.")
                        .font(AgentSamTheme.displayFont(31))
                        .foregroundStyle(AgentSamTheme.ink)
                    Text("Preview the roster, then make it yours. Every role, model, and prompt remains editable.")
                        .font(.callout)
                        .foregroundStyle(AgentSamTheme.muted)
                }
                .frame(maxWidth: 680)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 285), spacing: 18)], spacing: 18) {
                    ForEach(TeamTemplateCatalog.all) { template in
                        TeamTemplateCard(template: template, agents: template.agents(providers: model.providers)) {
                            preview = template
                        } onHire: {
                            hire(template)
                        }
                    }
                    BuildTeamCard {
                        editingTeam = Team(name: "New Team", emoji: "🛡️")
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1_180)
            .frame(maxWidth: .infinity)
        }
        .background(AgentSamBackground())
        .navigationTitle("Team Templates")
        .sheet(item: $preview) { template in
            TeamTemplatePreview(template: template, agents: template.agents(providers: model.providers)) {
                preview = nil
                hire(template)
            } onClose: {
                preview = nil
            }
            .frame(minWidth: 650, minHeight: 600)
        }
        .sheet(item: $editingTeam) { team in
            TeamEditSheet(team: team)
                .frame(minWidth: 680, minHeight: 560)
        }
        .overlay {
            if saving { ProgressView("Hiring team…").padding().agentSamPanel() }
        }
    }

    private func hire(_ template: TeamTemplate) {
        saving = true
        let team = template.makeTeam(providers: model.providers)
        Task {
            await model.saveTeam(team)
            saving = false
            editingTeam = team
        }
    }
}
