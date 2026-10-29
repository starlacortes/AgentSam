import SwiftUI
import AgentSamCore

struct GuidedSetupRail: View {
    let step: Int
    private let steps = [
        ("Connect models", "BRING YOUR OWN KEYS"),
        ("Pick a squad", "OR START FROM SCRATCH"),
        ("Meet the crew", "RENAME & RETUNE"),
        ("First mission", "WATCH IT RUN")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                let number = index + 1
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(number == step ? AgentSamTheme.emerald.opacity(0.1) : AgentSamTheme.deep)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(number <= step ? AgentSamTheme.emerald.opacity(0.5) : AgentSamTheme.strongLine))
                        if number < step {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(AgentSamTheme.emeraldLight)
                        } else {
                            Text("\(number)").font(.caption.monospaced().weight(.semibold)).foregroundStyle(number == step ? AgentSamTheme.emerald : AgentSamTheme.dim)
                        }
                    }
                    .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0).font(.callout.weight(.semibold)).foregroundStyle(number == step ? AgentSamTheme.ink : AgentSamTheme.muted)
                        Text(item.1).font(.system(size: 8, design: .monospaced)).tracking(0.7).foregroundStyle(AgentSamTheme.dim)
                    }
                    Spacer()
                }
                .padding(10)
                .background(number == step ? AgentSamTheme.emerald.opacity(0.055) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            Spacer()
            ProgressView(value: Double(step), total: 4)
                .tint(AgentSamTheme.emerald)
                .padding(.horizontal, 8)
                .padding(.top, 12)
            Text("Step \(step) of 4")
                .font(.caption2)
                .foregroundStyle(AgentSamTheme.dim)
                .padding(.horizontal, 8)
        }
        .padding(16)
        .frame(width: 232)
        .background(AgentSamTheme.deep)
    }
}

struct GuidedSetupHeading: View {
    let step: Int
    let kicker: String
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("STEP \(String(format: "%02d", step)) · \(kicker)").agentSamKicker()
            Text(title).font(AgentSamTheme.displayFont(29)).foregroundStyle(AgentSamTheme.ink)
            Text(description)
                .font(.callout)
                .foregroundStyle(AgentSamTheme.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProviderSelectionCard: View {
    let provider: ProviderConfig
    let selected: Bool
    let configured: Bool
    let action: () -> Void

    private var monogram: String { String(provider.name.first ?? "P").uppercased() }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(AgentSamTheme.emerald.opacity(0.1))
                    Text(monogram).font(AgentSamTheme.displayFont(18, weight: .bold)).foregroundStyle(AgentSamTheme.emeraldLight)
                }
                .frame(width: 42, height: 42)
                .overlay(Circle().strokeBorder(AgentSamTheme.emerald.opacity(0.35)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.callout.weight(.semibold)).foregroundStyle(AgentSamTheme.ink)
                    Text(provider.defaultModel ?? provider.baseURL)
                        .font(.caption2.monospaced())
                        .foregroundStyle(AgentSamTheme.muted)
                        .lineLimit(1)
                }
                Spacer()
                if configured {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(AgentSamTheme.emerald)
                }
                if provider.id == "ollama" { AgentSamChip("LOCAL", tint: AgentSamTheme.goldLight) }
            }
            .agentSamPanel(padding: 13, selected: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(selected ? "Selected" : "Select provider")
    }
}

struct SquadSelectionCard: View {
    let template: TeamTemplate
    let agents: [AgentProfile]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                AgentSamAvatarStack(agents: agents, size: 36)
                Text(template.name).font(.headline).foregroundStyle(AgentSamTheme.ink)
                Text("\(agents.count) agents · \(template.lowCost ? "lower cost" : "full capability")")
                    .font(.caption2.monospaced())
                    .foregroundStyle(AgentSamTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentSamPanel(padding: 15, selected: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PersonaCard: View {
    let agent: AgentProfile
    let providerName: String
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Spacer()
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(.plain)
                    .foregroundStyle(AgentSamTheme.dim)
                    .accessibilityLabel("Edit \(agent.name)")
            }
            AgentSamAvatar(name: agent.name, role: agent.role, size: 58)
            Text(agent.name).font(AgentSamTheme.displayFont(19)).foregroundStyle(AgentSamTheme.ink).lineLimit(1)
            Text(agent.title).agentSamKicker().foregroundStyle(AgentSamTheme.muted)
            AgentSamChip(agent.model.isEmpty ? "Choose model" : agent.model, tint: AgentSamTheme.emeraldLight, systemImage: "cpu")
            Text(providerName).font(.caption2).foregroundStyle(AgentSamTheme.dim).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .agentSamPanel(padding: 13, tint: AgentSamTheme.color(for: agent.role))
    }
}

#Preview("Setup rail") {
    GuidedSetupRail(step: 2)
        .frame(height: 520)
        .preferredColorScheme(.dark)
}

#Preview("Setup cards") {
    let template = TeamTemplateCatalog.all[0]
    VStack(alignment: .leading, spacing: 16) {
        GuidedSetupHeading(step: 1, kicker: "CONNECT MODELS", title: "Bring your own keys", description: "Add at least one provider so your agents have a model to think with.")
        ProviderSelectionCard(provider: ProviderConfig.builtin[0], selected: true, configured: true) {}
        ProviderSelectionCard(provider: ProviderConfig.builtin[5], selected: false, configured: false) {}
        SquadSelectionCard(template: template, agents: template.agents(providers: ProviderConfig.builtin), selected: true) {}
        PersonaCard(agent: AgentProfile.rosterTemplates[0], providerName: "Anthropic") {}
            .frame(width: 180)
    }
    .padding(24)
    .frame(width: 460)
    .background(AgentSamBackground())
    .preferredColorScheme(.dark)
}
