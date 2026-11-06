import SwiftUI
import AgentSamCore

struct AgentEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agent: AgentProfile
    var isExisting: Bool = false
    let onHire: (AgentProfile) -> Void
    let onFire: (AgentProfile) -> Void

    @State private var name = ""
    @State private var emoji = "🤖"
    @State private var title = ""
    @State private var role: AgentProfile.Role = .worker
    @State private var systemPrompt = ""
    @State private var providerID = ""
    @State private var model_ = ""
    @State private var temperature: Double = 0.3

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isExisting ? String(format: String(localized: "Edit %@"), agent.name) : String(localized: "Hire agent"))
                    .font(AgentSamTheme.displayFont(23))
                    .foregroundStyle(AgentSamTheme.ink)
                Spacer()
                if isExisting {
                    Button(String(localized: "Fire agent"), role: .destructive) {
                        onFire(agent)
                        dismiss()
                    }
                    .buttonStyle(AgentSamGhostButtonStyle())
                }
                Button(String(localized: "Save")) { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(AgentSamPrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || providerID.isEmpty || model_.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            Divider()
            Form {
                Section(String(localized: "Identity")) {
                    HStack {
                        TextField(String(localized: "Emoji"), text: $emoji)
                            .frame(width: 50)
                        TextField(String(localized: "Name"), text: $name)
                        TextField(String(localized: "Title"), text: $title)
                    }
                    Picker(String(localized: "Role"), selection: $role) {
                        ForEach(AgentProfile.Role.allCases, id: \.self) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section(String(localized: "Engine")) {
                    Picker(String(localized: "Provider"), selection: $providerID) {
                        ForEach(model.providers) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    HStack {
                        TextField(String(localized: "Model"), text: $model_)
                        if let provider = selectedProvider, !provider.models.isEmpty {
                            Menu(String(localized: "Known models")) {
                                ForEach(provider.models, id: \.self) { known in
                                    Button(known) { model_ = known }
                                }
                            }
                        }
                    }
                    LabeledContent(String(localized: "Temperature")) {
                        Slider(value: $temperature, in: 0...1, step: 0.1) {
                            Text(String(localized: "Temperature"))
                        }
                        Text(String(format: "%.1f", temperature))
                            .font(.callout.monospacedDigit())
                            .frame(width: 36)
                    }
                }
                Section(String(localized: "System prompt")) {
                    TextEditor(text: $systemPrompt)
                        .font(.system(size: 12))
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                    Text(String(localized: "House rules (tool use, deliverables, finish tool) are appended automatically."))
                        .font(.caption2)
                        .foregroundStyle(AgentSamTheme.dim)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(AgentSamBackground())
        .onAppear {
            name = agent.name
            emoji = agent.emoji
            title = agent.title
            role = agent.role
            systemPrompt = agent.systemPrompt
            providerID = agent.providerID.isEmpty ? (model.providers.first?.id ?? "") : agent.providerID
            if !model.providers.contains(where: { $0.id == providerID }) {
                providerID = model.providers.first?.id ?? ""
            }
            model_ = agent.model
            if model_.isEmpty {
                model_ = selectedProvider?.defaultModel ?? selectedProvider?.models.first ?? ""
            }
            temperature = agent.temperature ?? 0.3
        }
        .onChange(of: providerID) { _, newValue in
            if let provider = model.providers.first(where: { $0.id == newValue }) {
                if !provider.models.contains(model_) || model_.isEmpty {
                    model_ = provider.defaultModel ?? provider.models.first ?? ""
                }
            }
        }
    }

    private var selectedProvider: ProviderConfig? {
        model.providers.first(where: { $0.id == providerID })
    }

    private func save() {
        let updated = AgentProfile(
            id: agent.id,
            name: name.trimmingCharacters(in: .whitespaces),
            emoji: emoji.isEmpty ? "🤖" : String(emoji.prefix(2)),
            title: title.isEmpty ? String(localized: "Specialist") : title,
            role: role,
            systemPrompt: systemPrompt,
            providerID: providerID,
            model: model_.trimmingCharacters(in: .whitespaces),
            temperature: temperature
        )
        onHire(updated)
        dismiss()
    }
}
