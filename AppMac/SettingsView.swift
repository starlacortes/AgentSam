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
                connectorsCard
                aboutCard
            }
            .padding(24)
        }
        .background(AgentSamBackground())
        .navigationTitle(String(localized: "Settings"))
        // Sheet content doesn't inherit the environment on macOS 27, so re-inject the model.
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
            .environment(model)
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
        settingsSection(String(localized: "Data location"), systemImage: "externaldrive") {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Workspace")).agentSamKicker()
                Text(model.dataDirPath)
                    .font(.callout.monospaced())
                    .foregroundStyle(AgentSamTheme.secondaryInk)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(String(localized: "Teams, missions, transcripts, deliverables, and the event ledger live here. Point AGENTSAM_DATA at a synced folder to share work between devices."))
                    .font(.caption)
                    .foregroundStyle(AgentSamTheme.muted)
                HStack {
                    Button(String(localized: "Reveal in Finder")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: model.dataDirPath))
                    }
                    Button(String(localized: "Run guided setup"), action: onRunSetup)
                    Button(String(localized: "Import starter team")) {
                        Task { await model.saveTeam(Team.starterTeam()) }
                    }
                }
                .buttonStyle(AgentSamGhostButtonStyle())
            }
        }
    }

    private var providersCard: some View {
        settingsSection(String(localized: "Providers — bring your own keys"), systemImage: "key.horizontal") {
            VStack(spacing: 0) {
                ForEach(model.providers) { provider in
                    ProviderRow(provider: provider, onEdit: { editingProvider = provider })
                    if provider.id != model.providers.last?.id {
                        Rectangle().fill(AgentSamTheme.line).frame(height: 1)
                    }
                }
                if model.providers.isEmpty {
                    Text(String(localized: "No providers configured."))
                        .font(.caption)
                        .foregroundStyle(AgentSamTheme.muted)
                        .padding(.vertical, 12)
                }
                HStack {
                    Button {
                        editingProvider = ProviderConfig(
                            id: "custom-\(UUID().uuidString.prefix(6).lowercased())",
                            name: String(localized: "OpenAI-compatible endpoint"),
                            kind: .openAICompatible,
                            baseURL: "https://",
                            models: [],
                            defaultModel: nil
                        )
                    } label: {
                        Label(String(localized: "Add provider"), systemImage: "plus")
                    }
                    .buttonStyle(AgentSamGhostButtonStyle())
                    Spacer()
                }
                .padding(.top, 10)
            }
        }
    }

    private var connectorsCard: some View {
        settingsSection(String(localized: "Connectors — optional external services"), systemImage: "link") {
            VStack(spacing: 0) {
                ForEach(model.connectorStatuses) { status in
                    ConnectorRow(status: status)
                    if status.id != model.connectorStatuses.last?.id {
                        Rectangle().fill(AgentSamTheme.line).frame(height: 1)
                    }
                }
                if model.connectorStatuses.isEmpty {
                    Text(String(localized: "No connectors available."))
                        .font(.caption)
                        .foregroundStyle(AgentSamTheme.muted)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private var aboutCard: some View {
        settingsSection(String(localized: "How it works"), systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 12) {
                aboutRow(String(localized: "Engine"), String(localized: "Coordinator plans → workers run in parallel → mechanical + independent verification → final report"))
                aboutRow(String(localized: "Server"), String(localized: "Run AgentSamServer on a secured host (see README) and control missions from the iPhone app."))
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

struct ConnectorRow: View {
    @Environment(AppModel.self) private var model
    let status: ConnectorStatus

    @State private var cloudflareToken = ""
    @State private var adsDeveloperToken = ""
    @State private var adsCustomerId = ""
    @State private var testResult: String?
    @State private var notice: String?
    @State private var testing = false
    @State private var working = false

    private var isGoogle: Bool { status.id == .gmail || status.id == .googleads }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: status.id == .gmail ? "envelope" : (status.id == .cloudflare ? "cloud" : "megaphone"))
                    .foregroundStyle(AgentSamTheme.emerald)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(status.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(AgentSamTheme.ink)
                        AgentSamChip(status.configured ? String(localized: "CONNECTED") : String(localized: "NOT CONNECTED"), tint: status.configured ? AgentSamTheme.emerald : AgentSamTheme.goldLight)
                    }
                    Text(status.detail)
                        .font(.caption)
                        .foregroundStyle(AgentSamTheme.muted)
                }
                Spacer()
            }

            Toggle(String(localized: "Enabled in missions"), isOn: enabledBinding)
                .disabled(!status.configured)
                .font(.callout)
                .foregroundStyle(status.configured ? AgentSamTheme.ink : AgentSamTheme.dim)

            permissionToggles

            credentialControls

            HStack(spacing: 8) {
                if isGoogle {
                    if !status.oauthAvailable {
                        Text(String(localized: "Google OAuth client not configured — set AGENTSAM_GOOGLE_CLIENT_ID and restart AgentSam."))
                            .font(.caption)
                            .foregroundStyle(AgentSamTheme.goldLight)
                    } else {
                        Button(status.configured ? String(localized: "Reconnect with Google") : String(localized: "Connect with Google"), action: connectGoogle)
                            .buttonStyle(AgentSamPrimaryButtonStyle())
                            .disabled(working)
                    }
                }
                if status.configured {
                    Button(String(localized: "Test")) { runTest() }
                        .buttonStyle(AgentSamGhostButtonStyle())
                        .disabled(testing || working)
                    Button(String(localized: "Disconnect")) { disconnect() }
                        .buttonStyle(AgentSamGhostButtonStyle())
                        .disabled(working)
                }
            }
            if let testResult {
                Text(testResult)
                    .font(.caption.monospaced())
                    .foregroundStyle(AgentSamTheme.muted)
                    .textSelection(.enabled)
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(AgentSamTheme.goldLight)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var permissionToggles: some View {
        switch status.id {
        case .gmail:
            Toggle(String(localized: "Allow agents to create drafts"), isOn: permissionBinding(\.createDraft))
                .font(.callout)
            Toggle(String(localized: "Allow agents to send email"), isOn: permissionBinding(\.sendEmail))
                .font(.callout)
        case .cloudflare:
            Toggle(String(localized: "Allow DNS writes and cache purge"), isOn: permissionBinding(\.dnsWrite))
                .font(.callout)
        case .googleads:
            EmptyView()
        }
    }

    @ViewBuilder
    private var credentialControls: some View {
        switch status.id {
        case .cloudflare:
            if !status.configured {
                HStack(spacing: 8) {
                    SecureField(String(localized: "Cloudflare API token"), text: $cloudflareToken)
                        .textFieldStyle(.plain)
                        .font(.callout.monospaced())
                        .padding(.horizontal, 11)
                        .frame(minHeight: 36)
                        .background(AgentSamTheme.deep.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AgentSamTheme.strongLine))
                        .onSubmit(saveCloudflareToken)
                    Button(String(localized: "Save & verify"), action: saveCloudflareToken)
                        .buttonStyle(AgentSamPrimaryButtonStyle())
                        .disabled(cloudflareToken.isEmpty || working)
                }
            }
        case .googleads:
            VStack(alignment: .leading, spacing: 8) {
                TextField(String(localized: "Google Ads developer token"), text: $adsDeveloperToken)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 11)
                    .frame(minHeight: 36)
                    .background(AgentSamTheme.deep.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AgentSamTheme.strongLine))
                TextField(String(localized: "Login customer ID (optional)"), text: $adsCustomerId)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 11)
                    .frame(minHeight: 36)
                    .background(AgentSamTheme.deep.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AgentSamTheme.strongLine))
                Button(String(localized: "Save credentials"), action: saveAdsCredentials)
                    .buttonStyle(AgentSamGhostButtonStyle())
                    .disabled(adsDeveloperToken.isEmpty && adsCustomerId.isEmpty)
            }
        case .gmail:
            EmptyView()
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { status.enabled },
            set: { newValue in
                Task { await model.setConnectorEnabled(status.id, enabled: newValue) }
            }
        )
    }

    private func permissionBinding(_ keyPath: WritableKeyPath<ConnectorPermissions, Bool>) -> Binding<Bool> {
        Binding(
            get: { status.permissions[keyPath: keyPath] },
            set: { newValue in
                var permissions = status.permissions
                permissions[keyPath: keyPath] = newValue
                Task { await model.setConnectorPermissions(status.id, permissions: permissions) }
            }
        )
    }

    private func connectGoogle() {
        working = true
        notice = nil
        Task {
            if let error = await model.startGoogleOAuth(status.id) {
                notice = error
            } else {
                notice = String(localized: "Connected with Google.")
            }
            working = false
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            testResult = await model.testConnector(status.id)
            testing = false
        }
    }

    private func disconnect() {
        Task {
            await model.disconnectConnector(status.id)
            testResult = nil
            notice = nil
        }
    }

    private func saveCloudflareToken() {
        working = true
        notice = nil
        Task {
            let result = await model.setCloudflareToken(cloudflareToken)
            if result.ok {
                cloudflareToken = ""
            } else {
                notice = result.message
            }
            working = false
        }
    }

    private func saveAdsCredentials() {
        Task {
            await model.setGoogleAdsCredentials(developerToken: adsDeveloperToken, customerId: adsCustomerId)
            adsDeveloperToken = ""
            adsCustomerId = ""
            notice = String(localized: "Google Ads credentials saved.")
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
                        AgentSamChip(provider.kind == .anthropic ? String(localized: "Anthropic API") : String(localized: "OpenAI-compatible"), tint: AgentSamTheme.teal)
                    }
                    Text(String(format: String(localized: "%@ · %lld models"), provider.defaultModel ?? "—", provider.models.count))
                        .font(.caption.monospaced())
                        .foregroundStyle(AgentSamTheme.dim)
                }
                Spacer()
                Button(String(localized: "Configure"), action: onEdit)
                    .buttonStyle(AgentSamGhostButtonStyle())
            }
            HStack(spacing: 8) {
                if hasKey {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AgentSamTheme.emerald)
                        .help(String(localized: "Key saved in Keychain"))
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(AgentSamTheme.goldLight)
                }
                SecureField(hasKey ? String(localized: "API key saved — paste to replace") : String(localized: "Paste API key"), text: $keyText)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .foregroundStyle(AgentSamTheme.ink)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 36)
                    .background(AgentSamTheme.deep.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AgentSamTheme.strongLine))
                    .onSubmit(saveKey)
                Button(hasKey ? String(localized: "Replace") : String(localized: "Save key"), action: saveKey)
                    .buttonStyle(AgentSamPrimaryButtonStyle())
                    .disabled(keyText.isEmpty)
                if hasKey {
                    Button(String(localized: "Remove")) {
                        model.removeAPIKey(for: provider)
                        keyText = ""
                    }
                    .buttonStyle(AgentSamGhostButtonStyle())
                }
                Button(String(localized: "Test")) {
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
                Text(String(format: String(localized: "Configure %@"), name.isEmpty ? String(localized: "provider") : name))
                    .font(AgentSamTheme.displayFont(23))
                    .foregroundStyle(AgentSamTheme.ink)
                Spacer()
                Button(String(localized: "Save")) { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(AgentSamPrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: baseURL)?.host == nil)
            }
            .padding()
            Divider()
            Form {
                TextField(String(localized: "Display name"), text: $name)
                Picker(String(localized: "Kind"), selection: $kind) {
                    Text(String(localized: "OpenAI-compatible")).tag(ProviderConfig.Kind.openAICompatible)
                    Text(String(localized: "Anthropic")).tag(ProviderConfig.Kind.anthropic)
                }
                .pickerStyle(.radioGroup)
                TextField(String(localized: "Base URL"), text: $baseURL)
                    .font(.callout.monospaced())
                    .help(kind == .anthropic ? String(localized: "e.g. https://api.anthropic.com") : String(localized: "e.g. https://api.openai.com/v1"))
                LabeledContent(String(localized: "Models")) {
                    TextField(String(localized: "Comma-separated model ids"), text: $modelsText)
                        .font(.callout.monospaced())
                }
                LabeledContent(String(localized: "Default model")) {
                    TextField(String(localized: "Default model id"), text: $defaultModel)
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
