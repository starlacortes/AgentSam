import SwiftUI
import AgentSamCore

struct TeamTemplateCard: View {
    let template: TeamTemplate
    let agents: [AgentProfile]
    let onPreview: () -> Void
    let onHire: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onPreview) {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(colors: template.coverColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String(template.name.prefix(1)))
                        .font(AgentSamTheme.displayFont(110, weight: .bold))
                        .foregroundStyle(AgentSamTheme.ink.opacity(0.045))
                        .offset(x: 8, y: -28)
                    VStack(alignment: .leading, spacing: 12) {
                        Spacer()
                        AgentSamAvatarStack(agents: agents, size: 38)
                        Text(template.name)
                            .font(AgentSamTheme.displayFont(21))
                            .foregroundStyle(AgentSamTheme.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    if template.lowCost {
                        AgentSamChip("LOW COST", tint: AgentSamTheme.goldLight)
                            .padding(10)
                    }
                }
                .frame(height: 132)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(template.name)")

            VStack(alignment: .leading, spacing: 12) {
                Text(template.summary)
                    .font(.callout)
                    .foregroundStyle(AgentSamTheme.muted)
                    .lineLimit(3)
                    .frame(minHeight: 52, alignment: .top)
                HStack(spacing: 6) {
                    ForEach(template.capabilities, id: \.self) { AgentSamChip($0) }
                }
                HStack {
                    Button("Meet the squad", action: onPreview)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AgentSamTheme.emeraldLight)
                    Spacer()
                    Button("Hire team", action: onHire)
                        .buttonStyle(AgentSamPrimaryButtonStyle())
                }
            }
            .padding(14)
        }
        .background(AgentSamTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(AgentSamTheme.line))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    }
}

struct BuildTeamCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(AgentSamTheme.displayFont(34))
                    .foregroundStyle(AgentSamTheme.gold)
                Text("Build from scratch")
                    .font(AgentSamTheme.displayFont(18))
                    .foregroundStyle(AgentSamTheme.ink)
                Text("Hand-pick agents from the full roster.")
                    .font(.callout)
                    .foregroundStyle(AgentSamTheme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 285)
            .padding(20)
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(AgentSamTheme.strongLine, style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
            )
        }
        .buttonStyle(.plain)
    }
}

struct TeamTemplatePreview: View {
    let template: TeamTemplate
    let agents: [AgentProfile]
    let onHire: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(template.name).font(AgentSamTheme.displayFont(26)).foregroundStyle(AgentSamTheme.ink)
                        Text(template.summary).font(.callout).foregroundStyle(AgentSamTheme.muted)
                    }
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(AgentSamGhostButtonStyle())
                        .accessibilityLabel("Close preview")
                }
                VStack(spacing: 9) {
                    ForEach(agents) { agent in
                        HStack(alignment: .top, spacing: 12) {
                            AgentSamAvatar(name: agent.name, role: agent.role, size: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 7) {
                                    Text(agent.name).font(.headline).foregroundStyle(AgentSamTheme.ink)
                                    AgentSamRoleBadge(role: agent.role)
                                }
                                Text(agent.systemPrompt)
                                    .font(.caption)
                                    .foregroundStyle(AgentSamTheme.muted)
                                    .lineLimit(3)
                            }
                            Spacer()
                            AgentSamChip(agent.model.isEmpty ? "Choose model" : agent.model, tint: AgentSamTheme.emeraldLight)
                        }
                        .agentSamPanel(padding: 11)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("TRY IT ON").agentSamKicker()
                    Text("“\(template.example)”")
                        .font(.callout.italic())
                        .foregroundStyle(AgentSamTheme.secondaryInk)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AgentSamTheme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                HStack {
                    Button("Keep browsing", action: onClose).buttonStyle(AgentSamGhostButtonStyle())
                    Spacer()
                    Button("Hire this team", action: onHire).buttonStyle(AgentSamPrimaryButtonStyle())
                }
            }
            .padding(22)
        }
        .background(AgentSamBackground())
    }
}

struct MissionObjectiveEditor: View {
    @Binding var objective: String
    var showsIdeas = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $objective)
                .font(.body)
                .foregroundStyle(AgentSamTheme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 118)
                .padding(10)
                .background(AgentSamTheme.deep)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AgentSamTheme.strongLine))
                .accessibilityLabel("Mission objective")
            if showsIdeas {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TeamTemplateCatalog.missionIdeas, id: \.self) { idea in
                            Button(idea) { objective = idea }
                                .buttonStyle(AgentSamGhostButtonStyle())
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }
}

#Preview("Template cards") {
    let template = TeamTemplateCatalog.all[0]
    VStack(spacing: 16) {
        TeamTemplateCard(template: template, agents: template.agents(providers: ProviderConfig.builtin), onPreview: {}, onHire: {})
        BuildTeamCard {}
    }
    .padding(24)
    .frame(width: 380)
    .background(AgentSamBackground())
    .preferredColorScheme(.dark)
}

#Preview("Template detail") {
    let template = TeamTemplateCatalog.all[0]
    TeamTemplatePreview(template: template, agents: template.agents(providers: ProviderConfig.builtin), onHire: {}, onClose: {})
        .frame(width: 520, height: 640)
        .preferredColorScheme(.dark)
}

#Preview("Objective editor") {
    @Previewable @State var objective = ""
    MissionObjectiveEditor(objective: $objective)
        .padding(24)
        .frame(width: 460)
        .background(AgentSamBackground())
        .preferredColorScheme(.dark)
}
