import SwiftUI
import AgentSamCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editingProvider: ProviderConfig?
    var onRunSetup: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                workspaceCard
                providersCard
                aboutCard
            }
            .padding(24)
        }
        .background(AgentSamBackground())
        .navigationTitle("Settings")
        .sheet(item: $editingProvider) { provider in
            ProviderEditSheet(provider: provider) { saved in
                Task {
                    var list = model.providers
                    if let index = list.firstIndex(where: { $0.id == saved.id }) {
                        list[index] = saved
                    } else {
                        list.append(saved)
                    }
                    await model.saveProviders(list)
                }
            }
            .frame(minWidth: 520, minHeight: 480)
        }
    }

    private func settingsSection<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentSamSectionHeading(title, systemImage: systemImage)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .agentSamPanel()
        }
    }

    private var workspaceCard: some View {
        settingsSection("Data location", systemImage: "externaldrive") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Workspace").agentSamKicker()
                Text(model.dataDirPath)
                    .font(.callout.monospaced())
                    .foregroundStyle(AgentSamTheme.secondaryInk)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Teams, missions, transcripts, deliverables, and the event ledger live here. Point AGENTSAM_DATA at a synced folder to share work between devices.")
                    .font(.caption)
                    .foregroundStyle(AgentSamTheme.muted)
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: model.dataDirPath))
                    }
                    Button("Run guided setup", action: onRunSetup)
                    Button("Import starter team") {
                        Task { await model.saveTeam(Team.starterTeam()) }
                    }
                }
                .buttonStyle(AgentSamGhostButtonStyle())
            }
        }
    }

    private var providersCard: some View {
        settingsSection("Providers — bring your own keys", systemImage: "key.horizontal") {
            VStack(spacing: 0) {
                ForEach(model.providers) { provider in
                    ProviderRow(provider: provider, onEdit: { editingProvider = provider })
                    if provider.id != model.providers.last?.id {
                        Rectangle().fill(AgentSamTheme.line).frame(height: 1)
                    }
                }
                if model.providers.isEmpty {
                    Text("No providers configured.")
                        .font(.caption)
                        .foregroundStyle(AgentSamTheme.muted)
                        .padding(.vertical, 12)
                }
                HStack {
                    Button {
                        editingProvider = ProviderConfig(
                            id: "custom-\(UUID().uuidString.prefix(6).lowercased())",
                            name: "OpenAI-compatible endpoint",
                            kind: .openAICompatible,
                            baseURL: "https://",
                            models: [],
                            defaultModel: nil
                        )
                    } label: {
                        Label("Add provider", systemImage: "plus")
                    }
                    .buttonStyle(AgentSamGhostButtonStyle())
                    Spacer()
                }
                .padding(.top, 10)
            }
        }
    }

    private var aboutCard: some View {
        settingsSection("How it works", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 12) {
                aboutRow("Engine", "Coordinator plans → workers run in parallel → mechanical + independent verification → final report")
                aboutRow("Server", "Run AgentSamServer on a secured host (see README) and control missions from the iPhone app.")
            }
        }
    }

    private func aboutRow(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).agentSamKicker()
            Text(text)
                .font(.caption)
                .foregroundStyle(AgentSamTheme.muted)
                .frame(maxWidth: 480, alignment: .leading)
        }
    }
}

struct ProviderRow: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderConfig
    let onEdit: () -> Void

    @State private var keyText = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: provider.kind == .anthropic ? "globe.desk" : "globe")
                    .foregroundStyle(AgentSamTheme.emerald)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(provider.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(AgentSamTheme.ink)
                        AgentSamChip(provider.kind == .anthropic ? "Anthropic API" : "OpenAI-compatible", tint: AgentSamTheme.teal)
                    }
                    Text("\(provider.defaultModel ?? "—") · \(provider.models.count) models")
                        .font(.caption.monospaced())
                        .foregroundStyle(AgentSamTheme.dim)
                }
                Spacer()
                Button("Configure", action: onEdit)
                    .buttonStyle(AgentSamGhostButtonStyle())
            }
            HStack(spacing: 8) {
                if hasKey {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AgentSamTheme.emerald)
                        .help("Key saved in Keychain")
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(AgentSamTheme.goldLight)
                }
                SecureField(hasKey ? "API key saved — paste to replace" : "Paste API key", text: $keyText)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .foregroundStyle(AgentSamTheme.ink)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 36)
                    .background(AgentSamTheme.deep.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AgentSamTheme.strongLine))
                    .onSubmit(saveKey)
                Button(hasKey ? "Replace" : "Save key", action: saveKey)
                    .buttonStyle(AgentSamPrimaryButtonStyle())
                    .disabled(keyText.isEmpty)
                if hasKey {
                    Button("Remove") {
                        model.removeAPIKey(for: provider)
                        keyText = ""
                    }
                    .buttonStyle(AgentSamGhostButtonStyle())
                }
                Button("Test") {
                    testing = true
                    Task {
                        testResult = await model.testConnection(to: provider)
                        testing = false
                    }
                }
                .buttonStyle(AgentSamGhostButtonStyle())
                .disabled(testing)
            }
            if let testResult {
                Text(testResult)
                    .font(.caption.monospaced())
                    .foregroundStyle(AgentSamTheme.muted)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 10)
    }

    private var hasKey: Bool {
        !model.apiKey(for: provider).isEmpty
    }

    private func saveKey() {
        model.setAPIKey(keyText, for: provider)
        keyText = ""
    }
}

struct ProviderEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let provider: ProviderConfig
    let onSave: (ProviderConfig) -> Void

    @State private var name = ""
    @State private var kind: ProviderConfig.Kind = .openAICompatible
    @State private var baseURL = ""
    @State private var modelsText = ""
    @State private var defaultModel = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Configure \(name.isEmpty ? "provider" : name)")
                    .font(AgentSamTheme.displayFont(23))
                    .foregroundStyle(AgentSamTheme.ink)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(AgentSamPrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: baseURL)?.host == nil)
            }
            .padding()
            Divider()
            Form {
                TextField("Display name", text: $name)
                Picker("Kind", selection: $kind) {
                    Text("OpenAI-compatible").tag(ProviderConfig.Kind.openAICompatible)
                    Text("Anthropic").tag(ProviderConfig.Kind.anthropic)
                }
                .pickerStyle(.radioGroup)
                TextField("Base URL", text: $baseURL)
                    .font(.callout.monospaced())
                    .help(kind == .anthropic ? "e.g. https://api.anthropic.com" : "e.g. https://api.openai.com/v1")
                LabeledContent("Models") {
                    TextField("Comma-separated model ids", text: $modelsText)
                        .font(.callout.monospaced())
                }
                LabeledContent("Default model") {
                    TextField("Default model id", text: $defaultModel)
                        .font(.callout.monospaced())
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(AgentSamBackground())
        .onAppear {
            name = provider.name
            kind = provider.kind
            baseURL = provider.baseURL
            modelsText = provider.models.joined(separator: ", ")
            defaultModel = provider.defaultModel ?? ""
        }
    }

    private func save() {
        let models = modelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let resolvedDefault = defaultModel.trimmingCharacters(in: .whitespaces)
        onSave(ProviderConfig(
            id: provider.id,
            name: name,
            kind: kind,
            baseURL: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
            models: models,
            defaultModel: resolvedDefault.isEmpty ? models.first : resolvedDefault
        ))
        dismiss()
    }
}
