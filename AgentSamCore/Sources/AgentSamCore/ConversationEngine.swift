import Foundation

public actor ConversationEngine {
    public typealias Completion = @Sendable (ProviderConfig, String, AgentProfile, String, [APIMessage], [APIToolDef]?) async throws -> LLMReply
    public typealias MissionRunner = @Sendable (Team, String, String?, String?, String?) async throws -> Mission

    private let store: MissionStore
    private let conversations: ConversationStore
    private let memory: WorkspaceMemoryStore
    private let knowledge: WorkspaceKnowledgeStore?
    private let workspace: ChatWorkspaceStore
    private let keyRing: KeyRing
    private let client: LLMClient
    private let connectors: ConnectorHub?
    private let missions: MissionEngine
    private let promptStore: PromptStore
    private let access: ConversationAccess?
    private let directContextBudgetTokens = 20_000
    private let completionOverride: Completion?
    private let missionOverride: MissionRunner?
    private var running: [UUID: Task<Void, Never>] = [:]
    private var memoryJobs: [UUID: Task<Void, Never>] = [:]

    public init(store: MissionStore, conversations: ConversationStore, memory: WorkspaceMemoryStore, workspace: ChatWorkspaceStore? = nil, keyRing: KeyRing, client: LLMClient = LLMClient(), connectors: ConnectorHub? = nil, missions: MissionEngine, promptStore: PromptStore? = nil, access: ConversationAccess? = nil, knowledge: WorkspaceKnowledgeStore? = nil) {
        self.store = store
        self.conversations = conversations
        self.memory = memory
        self.knowledge = knowledge
        self.workspace = workspace ?? ChatWorkspaceStore(root: store.root)
        self.keyRing = keyRing
        self.client = client
        self.connectors = connectors
        self.missions = missions
        self.promptStore = promptStore ?? PromptStore(builtins: PromptStore.builtins)
        self.access = access
        self.completionOverride = nil
        self.missionOverride = nil
    }

    init(store: MissionStore, conversations: ConversationStore, memory: WorkspaceMemoryStore, workspace: ChatWorkspaceStore? = nil, keyRing: KeyRing, connectors: ConnectorHub? = nil, missions: MissionEngine, promptStore: PromptStore? = nil, access: ConversationAccess? = nil, knowledge: WorkspaceKnowledgeStore? = nil, completion: @escaping Completion, missionRunner: MissionRunner? = nil) {
        self.store = store
        self.conversations = conversations
        self.memory = memory
        self.knowledge = knowledge
        self.workspace = workspace ?? ChatWorkspaceStore(root: store.root)
        self.keyRing = keyRing
        self.client = LLMClient()
        self.connectors = connectors
        self.missions = missions
        self.promptStore = promptStore ?? PromptStore(builtins: PromptStore.builtins)
        self.access = access
        self.completionOverride = completion
        self.missionOverride = missionRunner
    }

    @discardableResult
    public func send(conversationID: UUID, ownerID: String, text rawText: String, launchedBy: String, language: String, scheduled: Bool = false) async throws -> Conversation {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConversationError.emptyMessage }
        guard text.count <= 20_000 else { throw ConversationError.messageTooLong }
        guard running[conversationID] == nil else { throw ConversationError.alreadyRunning }
        guard let conversation = try await conversations.get(id: conversationID, ownerID: ownerID) else { throw ConversationError.notFound }
        guard !conversation.messages.contains(where: { $0.status == .running }) else { throw ConversationError.alreadyRunning }
        let lang = language.lowercased().hasPrefix("es") ? "es" : "en"
        let userMessage = ConversationMessage(role: .user, text: text, scheduled: scheduled)
        let choosing = lang == "es" ? "Eligiendo la mejor forma de ayudar" : "Choosing how to help"
        let pending = ConversationMessage(role: .assistant, text: "", status: .running, activity: [AgentActivity(agentID: UUID(), agentName: "Ada", summary: choosing, state: "working")], steps: [MessageStep(label: choosing)])
        _ = try await conversations.append(id: conversationID, ownerID: ownerID, message: userMessage)
        let result = try await conversations.append(id: conversationID, ownerID: ownerID, message: pending)
        running[conversationID] = Task {
            await self.drive(conversationID: conversationID, ownerID: ownerID, userMessage: userMessage, responseID: pending.id, launchedBy: launchedBy, language: lang)
        }
        return result
    }

    public func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    public func stop(conversationID: UUID, ownerID: String, language: String) async {
        running[conversationID]?.cancel()
        guard let conversation = try? await conversations.get(id: conversationID, ownerID: ownerID) else { return }
        for message in conversation.messages where message.status == .running {
            _ = try? await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: message.id) { message in
                message.status = .failed
                message.text = language == "es" ? "Respuesta detenida." : "Response stopped."
                message.activity = []
                Self.settleSteps(&message.steps, as: "failed")
                message.completedAt = Date()
            }
        }
    }

    public func shutdown() async {
        for task in running.values { task.cancel() }
        for task in memoryJobs.values { task.cancel() }
    }

    /// Identifies the running response that live steps are written to.
    private struct ResponseRef: Sendable {
        var conversationID: UUID
        var ownerID: String
        var responseID: UUID
    }

    /// Marks every unfinished step as finished with the given state.
    static func settleSteps(_ steps: inout [MessageStep], as state: String, at date: Date = Date()) {
        for index in steps.indices where steps[index].state == "working" {
            steps[index].state = state
            steps[index].finishedAt = date
        }
    }

    /// Finishes the current step and starts a new one; Ada's activity line mirrors it.
    private func beginStep(_ label: String, in ref: ResponseRef?) async {
        guard let ref else { return }
        _ = try? await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { message in
            guard message.status == .running else { return }
            if message.steps.last?.label == label && message.steps.last?.state == "working" { return }
            Self.settleSteps(&message.steps, as: "done")
            message.steps.append(MessageStep(label: label))
            if let index = message.activity.firstIndex(where: { $0.agentName == "Ada" }) {
                message.activity[index].summary = label
                message.activity[index].state = "working"
                message.activity[index].updatedAt = Date()
            }
        }
    }

    private func drive(conversationID: UUID, ownerID: String, userMessage: ConversationMessage, responseID: UUID, launchedBy: String, language: String) async {
        defer { running[conversationID] = nil }
        let ref = ResponseRef(conversationID: conversationID, ownerID: ownerID, responseID: responseID)
        let es = language == "es"
        let writing = es ? "Redactando la respuesta" : "Writing the answer"
        do {
            guard let conversation = try await conversations.get(id: conversationID, ownerID: ownerID) else { return }
            let allTeams = await store.loadTeams()
            // The solo team is Ada's own permanent roster; it is never a routing target.
            let teams = allTeams.filter { $0.id != Self.soloTeamID }
            let providers = await store.loadProviders()
            let coordinator = try coordinator(providers: providers)
            let history = conversation.messages.filter { $0.status != .running && !$0.text.isEmpty }
            let workspaceMemory = await memory.state(ownerID: ownerID)
            let memoryText = workspaceMemory.enabled ? workspaceMemory.markdown : ""
            let currentKnowledge = await knowledge?.refresh(ownerID: ownerID)
            let context = await promptContext(conversation: conversation, history: history, memory: memoryText, knowledge: currentKnowledge?.promptSummary ?? "", scheduled: userMessage.scheduled)
            var decision = try await route(userText: userMessage.text, coordinator: coordinator, teams: teams, context: context, language: language)
            if decision == nil {
                let retrySystem = ConversationPrompts.routingSystem(coordinator: coordinator, teams: teams, context: context, store: promptStore, language: language) + "\nYour previous response was not valid. Return exactly one JSON object matching the contract, with a valid action."
                let retry = try await complete(coordinator: coordinator, system: retrySystem, messages: [.user(userMessage.text)], tools: nil)
                decision = ConversationDecision.parse(retry.message.content ?? "")
            }

            var responseText: String
            var proposal: TeamProposal?
            var missionIDs: [UUID] = []
            var teamIDs: [UUID] = []
            var activity = [AgentActivity(agentID: coordinator.id, agentName: "Ada", summary: language == "es" ? "Respondiendo directamente" : "Answering directly", state: "working")]
            var quickReplies: [String] = []
            var writtenFiles: [String] = []

            switch decision?.action {
            case .solo:
                var solo = Self.soloTeam(coordinator: coordinator, language: language)
                // Persist the singleton so its missions resolve in the mission pages. If a stale
                // copy exists (older provider config), adopt the current coordinator.
                if let existing = await store.team(id: Self.soloTeamID) {
                    solo.createdAt = existing.createdAt
                }
                await store.saveTeam(solo)
                let rationale = shortSummary(decision?.rationale ?? decision?.message, fallback: language == "es" ? "Trabajando en ello yo sola" : "Taking this on myself")
                activity[0].summary = rationale
                teamIDs = [solo.id]
                _ = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                    message.teamIDs = teamIDs
                    message.activity = activity
                    Self.settleSteps(&message.steps, as: "done")
                    message.steps.append(MessageStep(label: es ? "Trabajando en ello yo sola" : "Working on it myself"))
                }
                let mission = try await runMission(team: solo, objective: userMessage.text, context: context.missionHandoff, launchedBy: launchedBy, language: language, conversationID: conversationID, ownerID: ownerID, projectName: context.projectName)
                missionIDs = [mission.id]
                _ = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                    message.missionIDs = missionIDs
                }
                let finished = try await monitor(missions: [mission], teams: [solo], conversationID: conversationID, ownerID: ownerID, responseID: responseID, ada: activity[0])
                await beginStep(es ? "Redactando la respuesta" : "Writing the answer", in: ref)
                responseText = try await consolidate(userText: userMessage.text, missions: finished, coordinator: coordinator, context: context, language: language)
                activity = finished.flatMap { mission in
                    (solo.agents).map { AgentActivity(agentID: $0.id, agentName: $0.name, summary: mission.status == .completed ? (es ? "Trabajo completado" : "Work completed") : mission.status.rawValue, state: mission.status == .completed ? "done" : "failed", teamID: solo.id, teamName: solo.name) }
                }
                activity.insert(AgentActivity(agentID: coordinator.id, agentName: "Ada", summary: es ? "Respuesta consolidada" : "Response consolidated", state: "done"), at: 0)
            case .routeTeam:
                let selected = Array((decision?.teamIDs ?? []).compactMap { id in teams.first(where: { $0.id == id && !$0.workers.isEmpty }) }.prefix(3))
                if selected.isEmpty {
                    await beginStep(writing, in: ref)
                    responseText = try await directAnswer(userText: userMessage.text, coordinator: coordinator, context: context, language: language, ref: ref, conversationID: conversationID, writtenFiles: &writtenFiles)
                } else {
                    let rationale = shortSummary(decision?.rationale ?? decision?.message, fallback: language == "es" ? "Coordinando equipos especialistas" : "Coordinating specialist teams")
                    activity[0].summary = rationale
                    teamIDs = selected.map(\.id)
                    let teamList = selected.map(\.name).joined(separator: ", ")
                    _ = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                        message.teamIDs = teamIDs
                        message.activity = activity
                        Self.settleSteps(&message.steps, as: "done")
                        message.steps.append(MessageStep(label: es ? "Trabajando con \(teamList)" : "Working with \(teamList)"))
                    }
                    let routed = try await withThrowingTaskGroup(of: Mission.self, returning: [Mission].self) { group in
                        for team in selected {
                            group.addTask {
                                try await self.runMission(team: team, objective: userMessage.text, context: context.missionHandoff, launchedBy: launchedBy, language: language, conversationID: conversationID, ownerID: ownerID, projectName: context.projectName)
                            }
                        }
                        var launched: [Mission] = []
                        for try await mission in group {
                            launched.append(mission)
                            missionIDs.append(mission.id)
                            _ = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                                message.missionIDs = missionIDs
                            }
                        }
                        return selected.compactMap { team in launched.first(where: { $0.teamID == team.id }) }
                    }
                    let finished = try await monitor(missions: routed, teams: selected, conversationID: conversationID, ownerID: ownerID, responseID: responseID, ada: activity[0])
                    await beginStep(es ? "Combinando los resultados" : "Combining the results", in: ref)
                    responseText = try await consolidate(userText: userMessage.text, missions: finished, coordinator: coordinator, context: context, language: language)
                    activity = finished.flatMap { mission in
                        let team = selected.first(where: { $0.id == mission.teamID })
                        return (team?.agents ?? []).map { AgentActivity(agentID: $0.id, agentName: $0.name, summary: mission.status == .completed ? (language == "es" ? "Trabajo completado" : "Work completed") : mission.status.rawValue, state: mission.status == .completed ? "done" : "failed", teamID: team?.id, teamName: team?.name) }
                    }
                    activity.insert(AgentActivity(agentID: coordinator.id, agentName: "Ada", summary: language == "es" ? "Respuesta consolidada" : "Response consolidated", state: "done"), at: 0)
                }
            case .proposeTeam:
                if let draft = decision?.proposal, let made = try? TeamProposalValidation.make(draft: draft, teams: teams, providers: providers) {
                    await beginStep(es ? "Preparando la propuesta de equipo" : "Drafting a team proposal", in: ref)
                    proposal = made
                    responseText = try await directAnswer(userText: userMessage.text, coordinator: coordinator, context: context, language: language, proposal: made, ref: ref, conversationID: conversationID, writtenFiles: &writtenFiles)
                    activity[0].summary = language == "es" ? "Propuesta lista para revisar" : "Proposal ready for your review"
                } else {
                    responseText = language == "es"
                        ? "No pude preparar una propuesta válida. Dime qué especialistas necesitas y qué proveedor y modelo deben usar."
                        : "I couldn’t prepare a valid team draft. Tell me which specialists you need and which configured provider and model they should use."
                }
            case .clarify:
                responseText = decision?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if responseText.isEmpty { responseText = language == "es" ? "¿Qué resultado te gustaría conseguir?" : "What outcome would you like to achieve?" }
                activity[0].summary = language == "es" ? "Una pregunta antes de continuar" : "One question before continuing"
                quickReplies = ConversationMessage.cleanQuickReplies(decision?.options ?? [])
            case .direct, nil:
                await beginStep(writing, in: ref)
                responseText = try await directAnswer(userText: userMessage.text, coordinator: coordinator, context: context, language: language, ref: ref, conversationID: conversationID, writtenFiles: &writtenFiles)
            }

            if decision?.action != .clarify {
                let split = ConversationPrompts.extractSuggestions(responseText)
                if !split.text.isEmpty {
                    responseText = split.text
                    quickReplies = split.suggestions
                }
            }

            try Task.checkCancellation()
            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ConversationError.persistence("Ada received an empty response from the model. Please try again.") }
            for index in activity.indices { activity[index].state = "done" }
            let fileIDs = Array(NSOrderedSet(array: writtenFiles).array.compactMap { $0 as? String }) as [String]
            let completed = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                message.text = trimmed
                message.status = .complete
                message.proposal = proposal
                message.activity = activity
                message.quickReplies = quickReplies
                message.fileIDs = fileIDs
                Self.settleSteps(&message.steps, as: "done")
                message.completedAt = Date()
            }
            if let assistant = completed.messages.first(where: { $0.id == responseID }) {
                remember(conversationID: conversationID, ownerID: ownerID, user: userMessage, assistant: assistant, coordinator: coordinator)
            }
        } catch is CancellationError {
            _ = try? await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                message.status = .failed
                message.text = language == "es" ? "Respuesta detenida." : "Response stopped."
                message.activity = []
                Self.settleSteps(&message.steps, as: "failed")
                message.completedAt = Date()
            }
        } catch {
            _ = try? await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                message.status = .failed
                message.text = language == "es" ? "No pude completar la respuesta. \(error.localizedDescription)" : "I couldn’t complete the response. \(error.localizedDescription)"
                message.activity = []
                Self.settleSteps(&message.steps, as: "failed")
                message.completedAt = Date()
            }
        }
    }

    private func coordinator(providers: [ProviderConfig]) throws -> AgentProfile {
        guard !providers.isEmpty else { throw ConversationError.noProvider }
        var ada = AgentProfile.rosterTemplates[0]
        ada.systemPrompt = promptStore.render("ada_base")
        var provider = providers.first(where: { $0.id == ada.providerID })
        if provider == nil || keyRing.get(provider!.keyAccount) == nil {
            if let configured = providers.first(where: { keyRing.get($0.keyAccount) != nil }) {
                ada.providerID = configured.id
                ada.model = configured.defaultModel ?? configured.models[0]
                provider = configured
            }
        }
        guard let provider else { throw ConversationError.noProvider }
        guard keyRing.get(provider.keyAccount) != nil else { throw ConversationError.missingProviderKey(provider.name) }
        if !provider.models.contains(ada.model) { ada.model = provider.defaultModel ?? provider.models[0] }
        ada.name = "Ada"
        ada.role = .coordinator
        return ada
    }

    /// A one-agent team for SOLO missions: Ada is the coordinator *and* the only worker, so her
    /// self-directed work gets the full mission pipeline — plan, workspace, run steps, report —
    /// without a persisted specialist team. The team is a stable singleton so its missions
    /// resolve in the UI; it is hidden from the routing roster because SOLO is the way to use it.
    static let soloTeamID = UUID(uuidString: "AE4DA0A1-5F1D-4C4B-9A5A-DACA0E1E0F1F")!

    static func soloTeam(coordinator: AgentProfile, language: String) -> Team {
        var worker = coordinator
        worker.id = UUID()
        worker.role = .worker
        worker.title = language == "es" ? "Especialista" : "Solo specialist"
        worker.systemPrompt = "You are Ada working on your own mission. Plan carefully, produce real deliverables in your workspace, run programs to verify your work, and finish with a clear handoff summary for the coordinator."
        return Team(
            id: soloTeamID,
            name: language == "es" ? "Ada (sola)" : "Ada (solo)",
            emoji: "🧭",
            goal: language == "es" ? "Ada completa el trabajo ella sola." : "Ada completes the work on her own.",
            agents: [coordinator, worker],
            toolScope: ToolScope()
        )
    }

    private func route(userText: String, coordinator: AgentProfile, teams: [Team], context: ConversationPromptContext, language: String) async throws -> ConversationDecision? {
        let system = ConversationPrompts.routingSystem(coordinator: coordinator, teams: teams, context: context, store: promptStore, language: language)
        let reply = try await complete(coordinator: coordinator, system: system, messages: [.user(userText)], tools: nil)
        return ConversationDecision.parse(reply.message.content ?? "")
    }

    private func directAnswer(userText: String, coordinator: AgentProfile, context: ConversationPromptContext, language: String, proposal: TeamProposal? = nil, ref: ResponseRef? = nil, conversationID: UUID, writtenFiles: inout [String]) async throws -> String {
        let connectorTools = await connectors?.toolDefs(readOnly: access == nil) ?? []
        let missionTools = context.missionIDs.isEmpty ? [] : ConversationMissionTools.definitions
        let extendedTools = access == nil ? [] : ExtendedWorkspaceTools.definitions
        let tools = connectorTools + ChatWorkspaceTools.definitions + extendedTools + missionTools
        let system = ConversationPrompts.directResponseSystem(coordinator: coordinator, context: context, connectorTools: connectorTools, hasLinkedMissions: !context.missionIDs.isEmpty, hasExtendedTools: access != nil, store: promptStore, language: language)
        var text = userText
        if let proposal {
            text += "\n\nA team proposal has been prepared and is displayed separately for approval. Its name is \(proposal.team.name). Explain the proposal briefly, mention that no team has been created or changed yet, and ask the user to review it. Do not output JSON."
        }
        var messages: [APIMessage] = [.user(text)]
        var runs = 0
        for _ in 0..<8 {
            try Task.checkCancellation()
            let reply = try await completeDirect(coordinator: coordinator, system: system, messages: messages, tools: tools)
            messages.append(reply.message)
            let calls = reply.message.tool_calls ?? []
            if calls.isEmpty { return reply.message.content ?? "" }
            for call in calls {
                await beginStep(ConversationPrompts.toolStepLabel(call.function.name, language: language), in: ref)
                let outcome: ToolOutcome
                if ChatWorkspaceTools.owns(call.function.name) {
                    if call.function.name == "run_program" {
                        runs += 1
                        if runs > ChatWorkspaceTools.maxRunsPerTurn {
                            outcome = ToolOutcome(resultText: "Program and terminal run limit reached for this reply (4).")
                        } else {
                            outcome = await ChatWorkspaceTools.run(call: call, workspace: workspace, conversationID: conversationID)
                        }
                    } else if call.function.name == "chat_schedule_run" || call.function.name == "chat_schedule_cancel" {
                        let owner = ref?.ownerID
                        outcome = await ChatWorkspaceTools.run(call: call, workspace: workspace, conversationID: conversationID) { next in
                            guard let owner else { return nil }
                            let saved = try? await self.conversations.setSchedule(id: conversationID, ownerID: owner, schedule: next)
                            return saved?.schedule
                        }
                    } else {
                        outcome = await ChatWorkspaceTools.run(call: call, workspace: workspace, conversationID: conversationID)
                    }
                    if !outcome.wroteFiles.isEmpty {
                        writtenFiles.append(contentsOf: outcome.wroteFiles)
                        if let ref { await access?.audit.record(ownerID: ref.ownerID, action: "conversation.write", detail: outcome.wroteFiles.joined(separator: ", ")) }
                    }
                } else if ExtendedWorkspaceTools.owns(call.function.name), let access {
                    let isTerminal = call.function.name == "run_terminal" || call.function.name == "project_terminal"
                    if isTerminal { runs += 1 }
                    if isTerminal && runs > ChatWorkspaceTools.maxRunsPerTurn {
                        outcome = ToolOutcome(resultText: "Program and terminal run limit reached for this reply (4).")
                    } else {
                        let project = ProjectScope(ownerID: ref?.ownerID ?? "", projectName: context.projectName)
                        outcome = await ExtendedWorkspaceTools.run(call: call, workspace: workspace, conversationID: conversationID, project: project, terminal: access.terminal, hosts: access.hosts, actions: access.actions, audit: access.audit)
                    }
                    if !outcome.wroteFiles.isEmpty { writtenFiles.append(contentsOf: outcome.wroteFiles) }
                } else if ConversationMissionTools.owns(call.function.name) {
                    outcome = await ConversationMissionTools.run(call: call, store: store, allowedMissionIDs: Set(context.missionIDs))
                } else if let connectors {
                    if ConnectorHub.readOnlyToolNames.contains(call.function.name) {
                        outcome = await connectors.run(call: call, readOnly: true)
                    } else if let ref {
                        let action = AgentActionRequest(
                            ownerID: ref.ownerID, conversationID: conversationID, kind: .connectorWrite,
                            title: "Approve \(call.function.name)", detail: "Ada requested an external connector write. Review the exact arguments. Nothing has been sent or changed yet.",
                            toolName: call.function.name, arguments: .object([("raw", .string(call.function.arguments))])
                        )
                        if let saved = await access?.actions.request(action) {
                            outcome = ToolOutcome(resultText: "Approval requested (\(saved.id.uuidString)). Do not retry this write. Tell the user to review the approval card; the external action has not happened.")
                        } else {
                            outcome = ToolOutcome(resultText: "Connector approvals are not available. No external write was performed.")
                        }
                    } else {
                        outcome = ToolOutcome(resultText: "A user-owned conversation is required to approve connector writes.")
                    }
                } else {
                    outcome = ToolOutcome(resultText: "No connector is available for this tool.")
                }
                messages.append(.tool(id: call.id, content: String(outcome.resultText.prefix(32_000))))
            }
            await beginStep(language == "es" ? "Redactando la respuesta" : "Writing the answer", in: ref)
        }
        let final = try await completeDirect(coordinator: coordinator, system: system, messages: messages, tools: nil)
        return final.message.content ?? ""
    }

    private func consolidate(userText: String, missions: [Mission], coordinator: AgentProfile, context: ConversationPromptContext, language: String) async throws -> String {
        let system = ConversationPrompts.consolidationSystem(coordinator: coordinator, context: context, store: promptStore, language: language)
        let prompt = ConversationPrompts.consolidationPrompt(userText: userText, missions: missions, store: promptStore, language: language)
        let reply = try await complete(coordinator: coordinator, system: system, messages: [.user(prompt)], tools: nil)
        if reply.message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return reply.message.content ?? "" }
        return missions.compactMap(\.finalReport).joined(separator: "\n\n")
    }

    private func runMission(team: Team, objective: String, context: String?, launchedBy: String, language: String, conversationID: UUID, ownerID: String, projectName: String) async throws -> Mission {
        if let missionOverride { return try await missionOverride(team, objective, context, launchedBy, language) }
        var mission = await store.createMission(team: team, objective: objective, sourceName: "Ada conversation", inputContext: context, outputLanguage: language)
        mission.launchedBy = launchedBy
        let copied = await workspace.copyFiles(conversationID: conversationID, to: store.deliverablesDirectory(mission.id))
        let projectCopied = access == nil ? [] : await workspace.copyProject(ProjectScope(ownerID: ownerID, projectName: projectName), to: store.deliverablesDirectory(mission.id))
        await store.saveMission(mission)
        if !copied.isEmpty {
            await store.appendEvent(mission.id, kind: .notice, text: "Copied \(copied.count) conversation workspace file(s) into the mission: \(copied.joined(separator: ", "))")
        }
        if !projectCopied.isEmpty {
            await store.appendEvent(mission.id, kind: .notice, text: "Copied \(projectCopied.count) shared project file(s) into the mission under project/.")
        }
        await access?.actions.link(missionID: mission.id, conversationID: conversationID, ownerID: ownerID)
        await missions.launch(missionID: mission.id, team: team)
        return mission
    }

    private func promptContext(conversation: Conversation, history: [ConversationMessage], memory: String, knowledge: String, scheduled: Bool) async -> ConversationPromptContext {
        let prior = Array(history.dropLast())
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for message in prior.reversed() {
            for id in message.missionIDs.reversed() where !seen.contains(id) {
                seen.insert(id)
                ids.append(id)
                if ids.count == 8 { break }
            }
            if ids.count == 8 { break }
        }
        var references: [String] = []
        for id in ids {
            guard let mission = await store.mission(id: id) else { continue }
            let files = await store.deliverables(missionID: id)
            references.append("ID: \(id.uuidString)\nTeam: \(mission.teamName); status: \(mission.status.rawValue); objective: \(String(mission.objective.replacingOccurrences(of: "\n", with: " ").prefix(240)))\nFiles: \(files.isEmpty ? "none" : files.joined(separator: ", "))")
        }
        let manifest = await workspace.manifest(conversationID: conversation.id).joined(separator: "\n")
        let scope = ProjectScope(ownerID: conversation.ownerID, projectName: conversation.projectName)
        let projectManifest = access == nil ? "" : await workspace.projectManifest(scope)
        let hostGrants = await access?.hosts.summary(ownerID: conversation.ownerID) ?? ""
        return ConversationPromptContext(
            projectName: conversation.projectName,
            history: prior,
            memory: memory,
            workspaceManifest: manifest,
            missionReferences: references.joined(separator: "\n\n"),
            missionIDs: ids,
            schedule: conversation.schedule,
            scheduled: scheduled,
            projectManifest: projectManifest,
            hostGrants: hostGrants,
            knowledge: knowledge
        )
    }

    private func monitor(missions routed: [Mission], teams: [Team], conversationID: UUID, ownerID: String, responseID: UUID, ada: AgentActivity) async throws -> [Mission] {
        var latest = routed
        var sequences: [UUID: Int] = [:]
        var states: [String: AgentActivity] = [:]
        while true {
            try Task.checkCancellation()
            var complete = true
            var activity = [ada]
            for (index, routedMission) in latest.enumerated() {
                guard let mission = await store.mission(id: routedMission.id), let team = teams.first(where: { $0.id == routedMission.teamID }) else { continue }
                latest[index] = mission
                if mission.status == .queued || mission.status == .running { complete = false }
                let events = await store.events(missionID: mission.id, afterSeq: sequences[mission.id] ?? 0)
                sequences[mission.id] = events.last?.seq ?? sequences[mission.id]
                for agent in team.agents {
                    let key = "\(mission.id.uuidString):\(agent.id.uuidString)"
                    let matchesAgent: (RunEvent) -> Bool = { $0.agentID == agent.id || $0.agentName == agent.name }
                    let event = events.last(where: { matchesAgent($0) && ($0.kind == .taskStarted || $0.kind == .taskDone || $0.kind == .error) })
                    var current = states[key] ?? AgentActivity(agentID: agent.id, agentName: agent.name, summary: "Waiting for an assignment", state: "idle", teamID: team.id, teamName: team.name)
                    if let event {
                        current.summary = shortSummary(event.text, fallback: current.summary)
                        current.state = event.kind == .error ? "failed" : event.kind == .taskDone ? "done" : "working"
                        current.updatedAt = event.timestamp
                    }
                    if mission.status == .completed && current.state != "failed" {
                        current.state = "done"
                        if event == nil && states[key] == nil { current.summary = "Work completed" }
                    }
                    states[key] = current
                    activity.append(current)
                }
            }
            _ = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { $0.activity = activity }
            if complete {
                await syncMissionFiles(latest, conversationID: conversationID, ownerID: ownerID)
                return latest
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func syncMissionFiles(_ missions: [Mission], conversationID: UUID, ownerID: String) async {
        guard access != nil, let conversation = try? await conversations.get(id: conversationID, ownerID: ownerID) else { return }
        let project = ProjectScope(ownerID: ownerID, projectName: conversation.projectName)
        for mission in missions {
            let imported = await workspace.importMission(store, missionID: mission.id, to: project)
            if !imported.isEmpty {
                await access?.audit.record(ownerID: ownerID, action: "project.missionSync", detail: "\(mission.id.uuidString): \(imported.joined(separator: ", "))")
            }
        }
    }

    private func complete(coordinator: AgentProfile, system: String, messages: [APIMessage], tools: [APIToolDef]?) async throws -> LLMReply {
        let registry = ProviderRegistry(providers: await store.loadProviders())
        guard let provider = registry.provider(id: coordinator.providerID) else { throw ConversationError.noProvider }
        if let completionOverride {
            return try await completionOverride(provider, keyRing.get(provider.keyAccount) ?? "", coordinator, system, messages, tools)
        }
        return try await client.complete(provider: provider, key: keyRing.get(provider.keyAccount) ?? "", model: coordinator.model, system: system, messages: messages, tools: tools, temperature: coordinator.temperature)
    }

    private func completeDirect(coordinator: AgentProfile, system: String, messages: [APIMessage], tools: [APIToolDef]?) async throws -> LLMReply {
        var budget = directContextBudgetTokens
        var overflowRetries = 0
        while true {
            let compacted = ConversationCompactor.compact(messages: messages, budgetTokens: budget)
            do {
                return try await complete(coordinator: coordinator, system: system, messages: compacted.messages, tools: tools)
            } catch let error as LLMError where error.isContextOverflow {
                overflowRetries += 1
                guard overflowRetries <= 2 else { throw error }
                budget = max(ConversationCompactor.minimumBudgetTokens, budget / 2)
            }
        }
    }

    private func remember(conversationID: UUID, ownerID: String, user: ConversationMessage, assistant: ConversationMessage, coordinator: AgentProfile) {
        memoryJobs[assistant.id] = Task(priority: .utility) {
            defer { self.memoryJobs[assistant.id] = nil }
            do {
                var job = try await memory.record(conversationID: conversationID, ownerID: ownerID, userMessage: user, assistantMessage: assistant)
                var attempts = 0
                while let compaction = job, attempts < 3, !Task.isCancelled {
                    attempts += 1
                    do {
                        let reply = try await complete(coordinator: coordinator, system: ConversationPrompts.memorySystem(store: promptStore), messages: [.user(compaction.prompt)], tools: nil)
                        _ = try await memory.finishCompaction(compaction, markdown: reply.message.content ?? "")
                    } catch {
                        await memory.compactionFailed(ownerID: ownerID)
                        break
                    }
                    job = await memory.nextCompaction(ownerID: ownerID)
                }
            } catch {
                await memory.compactionFailed(ownerID: ownerID)
            }
        }
    }

    private func shortSummary(_ text: String?, fallback: String) -> String {
        let clean = (text ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return fallback }
        return String(clean.prefix(180))
    }
}
