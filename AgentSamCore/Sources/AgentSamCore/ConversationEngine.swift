import Foundation

public actor ConversationEngine {
    public typealias Completion = @Sendable (ProviderConfig, String, AgentProfile, String, [APIMessage], [APIToolDef]?) async throws -> LLMReply
    public typealias MissionRunner = @Sendable (Team, String, String?, String?, String?) async throws -> Mission

    private let store: MissionStore
    private let conversations: ConversationStore
    private let memory: WorkspaceMemoryStore
    private let knowledge: WorkspaceKnowledgeStore?
    private let workspace: ChatWorkspaceStore
    private let photos: ConversationPhotoStore
    private let keyRing: KeyRing
    private let client: LLMClient
    private let connectors: ConnectorHub?
    private let missions: MissionEngine
    private let promptStore: PromptStore
    private let access: ConversationAccess?
    private let skills: SkillStore
    private let directContextBudgetTokens = 20_000
    /// Output cap for spoken replies written without tools (team summaries, the last answer after the tool
    /// budget). A backstop only: the voice style asks for about 60 spoken words plus optional on-screen detail.
    /// Turns that offer tools are not capped, because a capped tool call (a file write) would be cut off.
    static let voiceMaxTokens = 1_500
    private let completionOverride: Completion?
    private let missionOverride: MissionRunner?
    private var running: [UUID: Task<Void, Never>] = [:]
    private var memoryJobs: [UUID: Task<Void, Never>] = [:]

    public init(store: MissionStore, conversations: ConversationStore, memory: WorkspaceMemoryStore, workspace: ChatWorkspaceStore? = nil, keyRing: KeyRing, client: LLMClient = LLMClient(), connectors: ConnectorHub? = nil, missions: MissionEngine, promptStore: PromptStore? = nil, access: ConversationAccess? = nil, knowledge: WorkspaceKnowledgeStore? = nil, photos: ConversationPhotoStore? = nil, skills: SkillStore? = nil) {
        self.store = store
        self.conversations = conversations
        self.memory = memory
        self.knowledge = knowledge
        self.workspace = workspace ?? ChatWorkspaceStore(root: store.root)
        self.photos = photos ?? ConversationPhotoStore(root: store.root)
        self.keyRing = keyRing
        self.client = client
        self.connectors = connectors
        self.missions = missions
        self.promptStore = promptStore ?? PromptStore(builtins: PromptStore.builtins)
        self.access = access
        self.skills = skills ?? SkillStore(root: store.root)
        self.completionOverride = nil
        self.missionOverride = nil
    }

    init(store: MissionStore, conversations: ConversationStore, memory: WorkspaceMemoryStore, workspace: ChatWorkspaceStore? = nil, keyRing: KeyRing, connectors: ConnectorHub? = nil, missions: MissionEngine, promptStore: PromptStore? = nil, access: ConversationAccess? = nil, knowledge: WorkspaceKnowledgeStore? = nil, photos: ConversationPhotoStore? = nil, skills: SkillStore? = nil, completion: @escaping Completion, missionRunner: MissionRunner? = nil) {
        self.store = store
        self.conversations = conversations
        self.memory = memory
        self.knowledge = knowledge
        self.workspace = workspace ?? ChatWorkspaceStore(root: store.root)
        self.photos = photos ?? ConversationPhotoStore(root: store.root)
        self.keyRing = keyRing
        self.client = LLMClient()
        self.connectors = connectors
        self.missions = missions
        self.promptStore = promptStore ?? PromptStore(builtins: PromptStore.builtins)
        self.access = access
        self.skills = skills ?? SkillStore(root: store.root)
        self.completionOverride = completion
        self.missionOverride = missionRunner
    }

    @discardableResult
    public func send(conversationID: UUID, ownerID: String, text rawText: String, launchedBy: String, language: String, scheduled: Bool = false, photos: [PhotoAttachment] = [], spoken: Bool = false, timeZone: String? = nil, trigger: TriggerEvent? = nil) async throws -> Conversation {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let photos = Array(photos.prefix(ConversationPhotoStore.maxPerMessage))
        guard !text.isEmpty || !photos.isEmpty else { throw ConversationError.emptyMessage }
        guard text.count <= 20_000 else { throw ConversationError.messageTooLong }
        guard running[conversationID] == nil else { throw ConversationError.alreadyRunning }
        guard let conversation = try await conversations.get(id: conversationID, ownerID: ownerID) else { throw ConversationError.notFound }
        guard !conversation.messages.contains(where: { $0.status == .running }) else { throw ConversationError.alreadyRunning }
        if let timeZone { _ = try? await conversations.setTimeZone(id: conversationID, ownerID: ownerID, timeZone: timeZone) }
        let lang = language.lowercased().hasPrefix("es") ? "es" : "en"
        let userMessage = ConversationMessage(role: .user, text: text, scheduled: scheduled || trigger != nil, photos: photos, spoken: spoken, trigger: trigger)
        let choosing = lang == "es" ? "Eligiendo la mejor forma de ayudar" : "Choosing how to help"
        let pending = ConversationMessage(role: .assistant, text: "", status: .running, activity: [AgentActivity(agentID: UUID(), agentName: "Ada", summary: choosing, state: "working")], steps: [MessageStep(label: choosing)])
        _ = try await conversations.append(id: conversationID, ownerID: ownerID, message: userMessage)
        let result = try await conversations.append(id: conversationID, ownerID: ownerID, message: pending)
        running[conversationID] = Task {
            // Every model call made for this reply adds its estimated cost to one meter.
            let meter = CostMeter()
            await CostMeter.$current.withValue(meter) {
                await self.drive(conversationID: conversationID, ownerID: ownerID, userMessage: userMessage, responseID: pending.id, launchedBy: launchedBy, language: lang)
            }
            await self.access?.spend.add(ownerID: ownerID, usd: meter.total)
        }
        return result
    }

    public func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    /// Waits for the conversation's current reply to finish, then returns how that response ended.
    public func waitForReply(conversationID: UUID, ownerID: String, responseID: UUID) async -> ConversationMessageStatus? {
        if let task = running[conversationID] { await task.value }
        let conversation = try? await conversations.get(id: conversationID, ownerID: ownerID)
        return conversation?.messages.first { $0.id == responseID }?.status
    }

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
        /// The user spoke this message: a ```details part of the reply is shown but not spoken.
        var spoken: Bool = false
        /// Who the reply is for, recorded on missions Ada starts during it.
        var launchedBy: String = "Ada"
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
        let ref = ResponseRef(conversationID: conversationID, ownerID: ownerID, responseID: responseID, spoken: userMessage.spoken, launchedBy: launchedBy)
        let es = language == "es"
        let writing = es ? "Redactando la respuesta" : "Writing the answer"
        do {
            guard let conversation = try await conversations.get(id: conversationID, ownerID: ownerID) else { return }
            if let notice = await dailyCapNotice(ownerID: ownerID, language: language) {
                _ = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                    message.text = notice
                    message.status = .complete
                    message.activity = []
                    Self.settleSteps(&message.steps, as: "done")
                    message.completedAt = Date()
                }
                return
            }
            let allTeams = await store.loadTeams()
            // Any team saved on disk (for example through the API) becomes a skill the first time it
            // is seen. The solo team is Ada's own roster and is never a skill.
            await skills.migrate(teams: allTeams, skipping: [Self.soloTeamID])
            let skillList = await skills.enabled()
            let providers = await store.loadProviders()
            let coordinator = try coordinator(providers: providers)
            let catalog = SkillTeams.catalog(skillList)
            let history = conversation.messages.filter { $0.status != .running && (!$0.text.isEmpty || !$0.photos.isEmpty) }
            let workspaceMemory = await memory.state(ownerID: ownerID)
            let memoryText = workspaceMemory.promptText
            let currentKnowledge = await knowledge?.refresh(ownerID: ownerID)
            let context = await promptContext(conversation: conversation, history: history, memory: memoryText, knowledge: currentKnowledge?.promptSummary ?? "", scheduled: userMessage.scheduled, spoken: userMessage.spoken, personName: userMessage.scheduled ? nil : launchedBy, event: userMessage.trigger)
            // Photos: only Ada's direct reply looks at them. Routing, missions, and consolidation get a
            // note that they exist, which is enough to pick DIRECT and keeps those calls cheap.
            let canSee = providers.first(where: { $0.id == coordinator.providerID }).map { VisionSupport.accepts(provider: $0, model: coordinator.model) } ?? true
            let userText = Self.textWithPhotoNote(userMessage)
            let photoInput = canSee ? photoInputs(conversationID: conversationID, current: userMessage, history: history) : PhotoInputs()
            let directText = Self.directText(for: userMessage, canSee: canSee, model: coordinator.model, language: language)
            // Voice fast path: a quick spoken question goes straight to Ada's direct reply, skipping the
            // routing call that otherwise runs before she writes a word.
            var decision: ConversationDecision?
            if Self.isQuickSpokenQuestion(userMessage, history: history) {
                decision = ConversationDecision(action: .direct)
            } else {
                decision = try await route(userText: userText, coordinator: coordinator, skills: catalog, context: context, history: history, language: language)
            }
            if decision == nil {
                let retrySystem = ConversationPrompts.routingSystem(coordinator: coordinator, skills: catalog, context: context, store: promptStore, language: language) + "\nYour previous response was not valid. Return exactly one JSON object matching the contract, with a valid action."
                let retry = try await complete(coordinator: coordinator, system: retrySystem, messages: Self.chatTurns(from: history.dropLast()) + [.user(context.userTurn(userText))], tools: nil)
                decision = ConversationDecision.parse(retry.message.content ?? "")
            }

            var responseText: String
            var missionIDs: [UUID] = []
            var teamIDs: [UUID] = []
            var activity = [AgentActivity(agentID: coordinator.id, agentName: "Ada", summary: language == "es" ? "Respondiendo directamente" : "Answering directly", state: "working")]
            var quickReplies: [String] = []
            var writtenFiles: [String] = []
            var toolLog: [String] = []

            switch decision?.action {
            case .solo:
                var solo = Self.soloTeam(coordinator: coordinator, language: language, store: promptStore)
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
                let mission = try await runMission(team: solo, objective: userText, context: context.missionHandoff, launchedBy: launchedBy, language: language, conversationID: conversationID, ownerID: ownerID, projectName: context.projectName)
                missionIDs = [mission.id]
                _ = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                    message.missionIDs = missionIDs
                }
                let finished = try await monitor(missions: [mission], teams: [solo], conversationID: conversationID, ownerID: ownerID, responseID: responseID, ada: activity[0])
                for run in finished { CostMeter.current?.add(run.totalCostUSD) }
                await beginStep(es ? "Redactando la respuesta" : "Writing the answer", in: ref)
                responseText = try await consolidate(userText: userText, missions: finished, coordinator: coordinator, context: context, history: history, language: language)
                activity = finished.flatMap { mission in
                    (solo.agents).map { AgentActivity(agentID: $0.id, agentName: $0.name, summary: mission.status == .completed ? (es ? "Trabajo completado" : "Work completed") : mission.status.rawValue, state: mission.status == .completed ? "done" : "failed", teamID: solo.id, teamName: solo.name) }
                }
                activity.insert(AgentActivity(agentID: coordinator.id, agentName: "Ada", summary: es ? "Respuesta consolidada" : "Response consolidated", state: "done"), at: 0)
            case .useSkill, .routeTeam:
                let selected = await skillTeams(for: decision, skills: skillList, teams: allTeams, coordinator: coordinator, providers: providers)
                if selected.isEmpty {
                    await beginStep(writing, in: ref)
                    responseText = try await directAnswer(userText: directText, photos: photoInput, coordinator: coordinator, context: context, history: history, language: language, ref: ref, conversationID: conversationID, writtenFiles: &writtenFiles, toolLog: &toolLog)
                } else {
                    let rationale = shortSummary(decision?.rationale ?? decision?.message, fallback: language == "es" ? "Coordinando especialistas" : "Coordinating specialists")
                    activity[0].summary = rationale
                    teamIDs = selected.map(\.id)
                    let teamList = selected.map(\.name).joined(separator: ", ")
                    _ = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                        message.teamIDs = teamIDs
                        message.activity = activity
                        Self.settleSteps(&message.steps, as: "done")
                        message.steps.append(MessageStep(label: es ? "Trabajando con especialistas: \(teamList)" : "Working with specialists: \(teamList)"))
                    }
                    let routed = try await withThrowingTaskGroup(of: Mission.self, returning: [Mission].self) { group in
                        for team in selected {
                            group.addTask {
                                try await self.runMission(team: team, objective: userText, context: context.missionHandoff, launchedBy: launchedBy, language: language, conversationID: conversationID, ownerID: ownerID, projectName: context.projectName)
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
                    for run in finished { CostMeter.current?.add(run.totalCostUSD) }
                    await beginStep(es ? "Combinando los resultados" : "Combining the results", in: ref)
                    responseText = try await consolidate(userText: userText, missions: finished, coordinator: coordinator, context: context, history: history, language: language)
                    activity = finished.flatMap { mission in
                        let team = selected.first(where: { $0.id == mission.teamID })
                        return (team?.agents ?? []).map { AgentActivity(agentID: $0.id, agentName: $0.name, summary: mission.status == .completed ? (language == "es" ? "Trabajo completado" : "Work completed") : mission.status.rawValue, state: mission.status == .completed ? "done" : "failed", teamID: team?.id, teamName: team?.name) }
                    }
                    activity.insert(AgentActivity(agentID: coordinator.id, agentName: "Ada", summary: language == "es" ? "Respuesta consolidada" : "Response consolidated", state: "done"), at: 0)
                }
            case .clarify:
                responseText = decision?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if responseText.isEmpty { responseText = language == "es" ? "¿Qué resultado te gustaría conseguir?" : "What outcome would you like to achieve?" }
                activity[0].summary = language == "es" ? "Una pregunta antes de continuar" : "One question before continuing"
                quickReplies = ConversationMessage.cleanQuickReplies(decision?.options ?? [])
            case .direct, .proposeTeam, nil:
                // Teams are no longer proposed to people; an older stored prompt that still asks to
                // propose one gets a direct answer instead.
                await beginStep(writing, in: ref)
                responseText = try await directAnswer(userText: directText, photos: photoInput, coordinator: coordinator, context: context, history: history, language: language, ref: ref, conversationID: conversationID, writtenFiles: &writtenFiles, toolLog: &toolLog)
            }

            if decision?.action != .clarify {
                // Split even in voice mode, so a stray block never reaches the speaker.
                let split = ConversationPrompts.extractSuggestions(responseText)
                if !split.text.isEmpty {
                    responseText = split.text
                    quickReplies = split.suggestions
                }
            }
            var speech: String?
            if userMessage.spoken {
                let split = ConversationPrompts.extractDetails(responseText)
                responseText = split.screen
                speech = split.speech
            }

            try Task.checkCancellation()
            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ConversationError.persistence("Ada received an empty response from the model. Please try again.") }
            for index in activity.indices { activity[index].state = "done" }
            let fileIDs = Array(NSOrderedSet(array: writtenFiles).array.compactMap { $0 as? String }) as [String]
            let completed = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                message.text = trimmed
                message.speech = speech
                message.status = .complete
                message.activity = activity
                message.quickReplies = quickReplies
                message.fileIDs = fileIDs
                message.toolLog = toolLog
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

    /// The teams to run for a USE_SKILL decision, at most three. Skills are matched by ID or name;
    /// an older ROUTE_TEAM decision is matched by the team each skill runs as. Each built-in or
    /// Ada-saved skill's team is saved so mission history can show who worked on it.
    private func skillTeams(for decision: ConversationDecision?, skills: [Skill], teams: [Team], coordinator: AgentProfile, providers: [ProviderConfig]) async -> [Team] {
        var chosen: [Skill] = []
        for id in decision?.skillIDs ?? [] {
            let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let skill = skills.first(where: { $0.id == key || $0.name.lowercased() == key }), !chosen.contains(skill) { chosen.append(skill) }
        }
        for id in decision?.teamIDs ?? [] {
            if let skill = skills.first(where: { $0.teamID == id }), !chosen.contains(skill) { chosen.append(skill) }
        }
        var selected: [Team] = []
        for skill in chosen.prefix(3) {
            let saved = teams.first(where: { $0.id == skill.teamID })
            guard let team = SkillTeams.team(for: skill, coordinator: coordinator, providers: providers, hasKey: { self.keyRing.get($0.keyAccount) != nil }, saved: saved) else { continue }
            if !skill.specialists.isEmpty { await store.saveTeam(team) }
            selected.append(team)
        }
        return selected
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
    public static let soloTeamID = UUID(uuidString: "AE4DA0A1-5F1D-4C4B-9A5A-DACA0E1E0F1F")!

    static func soloTeam(coordinator: AgentProfile, language: String, store: PromptStore = PromptStore(builtins: PromptStore.builtins)) -> Team {
        var worker = coordinator
        worker.id = UUID()
        worker.role = .worker
        worker.title = language == "es" ? "Especialista" : "Solo specialist"
        worker.systemPrompt = store.render("ada_solo_worker")
        return Team(
            id: soloTeamID,
            name: language == "es" ? "Ada (sola)" : "Ada (solo)",
            emoji: "🧭",
            goal: language == "es" ? "Ada completa el trabajo ella sola." : "Ada completes the work on her own.",
            agents: [coordinator, worker],
            // Ada's own work follows the Connections toggles, exactly like her direct chat.
            toolScope: ToolScope(permissions: .all)
        )
    }

    /// Earlier turns as real chat messages, oldest first, ending on an assistant turn so the caller can
    /// append the user's latest message. Consecutive same-role turns are merged because providers
    /// expect alternating roles (a failed reply leaves two user messages in a row).
    static let maxToolLogEntries = 12

    /// "chat_read_file {"path":"notes.md"} → ok" or "… → failed: reason", short enough to carry in history.
    static func toolLogLine(call: APIToolCall, outcome: ToolOutcome) -> String {
        let arguments = call.function.arguments.replacingOccurrences(of: "\n", with: " ")
        let shortArguments = arguments.count > 120 ? String(arguments.prefix(120)) + "…" : arguments
        let firstLine = outcome.resultText.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let result = outcome.succeeded ? "ok" : "failed: " + String(firstLine.prefix(120))
        return "\(call.function.name) \(shortArguments) → \(result)"
    }

    static func chatTurns(from history: [ConversationMessage], limit: Int = 24, characters: Int = 6_000, images: [UUID: [APIImage]] = [:]) -> [APIMessage] {
        var turns: [APIMessage] = []
        for message in history.suffix(limit) {
            let role = message.role == .user ? "user" : "assistant"
            // Raw tool-call markup from an earlier reply teaches the model to write calls as text again.
            var body = String(DSMLToolCalls.strip(message.text).prefix(characters))
            if message.role != .user, !message.toolLog.isEmpty {
                // What Ada did with tools in that reply, so she doesn't redo or contradict it.
                body += "\n\n[Tools used in this reply: " + message.toolLog.joined(separator: "; ") + "]"
            }
            let attached = images[message.id] ?? []
            if !message.photos.isEmpty && attached.isEmpty {
                // The photo itself is no longer sent; say it was there so the turn still makes sense.
                let note = message.photos.count == 1 ? "[The user attached a photo here.]" : "[The user attached \(message.photos.count) photos here.]"
                body = body.isEmpty ? note : body + "\n" + note
            }
            if let last = turns.last, last.role == role {
                let merged = (last.images ?? []) + attached
                turns[turns.count - 1] = APIMessage(role: role, content: (last.content ?? "") + "\n\n" + body, images: merged.isEmpty ? nil : merged)
            } else {
                turns.append(APIMessage(role: role, content: body, images: attached.isEmpty ? nil : attached))
            }
        }
        while turns.first?.role == "assistant" { turns.removeFirst() }
        if turns.last?.role == "user" { turns.removeLast() }
        return turns
    }

    private func route(userText: String, coordinator: AgentProfile, skills catalog: String, context: ConversationPromptContext, history: [ConversationMessage], language: String) async throws -> ConversationDecision? {
        let system = ConversationPrompts.routingSystem(coordinator: coordinator, skills: catalog, context: context, store: promptStore, language: language)
        let reply = try await complete(coordinator: coordinator, system: system, messages: Self.chatTurns(from: history.dropLast()) + [.user(context.userTurn(userText))], tools: nil)
        return ConversationDecision.parse(reply.message.content ?? "")
    }

    /// Model calls with tools in one direct reply before Ada must answer without them.
    static let maxToolRounds = 20

    private func directAnswer(userText: String, photos photoInput: PhotoInputs = PhotoInputs(), coordinator: AgentProfile, context: ConversationPromptContext, history: [ConversationMessage], language: String, ref: ResponseRef? = nil, conversationID: UUID, writtenFiles: inout [String], toolLog: inout [String]) async throws -> String {
        let connectorTools = await connectors?.toolDefs(readOnly: access == nil) ?? []
        // Only tools offered in this request may run, and each runs by the family it was offered from.
        let workstation = await workstation(ownerID: ref?.ownerID)
        let mcpTools = await access?.mcp?.toolDefs() ?? []
        // Handing work to a task needs a user-owned reply to show its progress in.
        let taskTools = ref == nil ? [] : TaskTools.definitions(catalog: SkillTeams.catalog(await skills.enabled()))
        let offeredTools = OfferedTools.direct(connectorTools: connectorTools, hasLinkedMissions: !context.missionIDs.isEmpty, hasExtendedAccess: access != nil, hasWorkstation: workstation != nil, mcpTools: mcpTools, taskTools: taskTools)
        let tools = offeredTools.definitions
        let offered = offeredTools.names
        let system = ConversationPrompts.directResponseSystem(coordinator: coordinator, context: context, connectorTools: connectorTools, hasLinkedMissions: !context.missionIDs.isEmpty, hasExtendedTools: access != nil, store: promptStore, language: language)
        let text = context.userTurn(userText)
        // The context now rides in the user turn instead of the system prompt; budget for it on top
        // of the conversation, as before, so it doesn't crowd out earlier turns.
        let allowance = ConversationCompactor.estimateTokens(context.turnPreamble)
        var messages = Self.chatTurns(from: history.dropLast(), images: photoInput.history)
        messages.append(.user(text, images: photoInput.current))
        var runs = 0
        var tasks = 0
        let replyCap = await replySpendCap(ownerID: ref?.ownerID)
        var overCap = false
        for round in 0..<Self.maxToolRounds {
            try Task.checkCancellation()
            let stream = streamer(for: ref)
            let reply = try await completeDirect(coordinator: coordinator, system: system, messages: messages, tools: tools, contextAllowance: allowance, onDelta: stream?.handler)
            messages.append(reply.message)
            let calls = reply.message.tool_calls ?? []
            if calls.isEmpty { return reply.message.content ?? "" }
            // Text before a tool call is a preamble, not the answer; drop it so the next turn starts clean.
            if stream != nil { await publishPartial("", in: ref) }
            for call in calls {
                await beginStep(ConversationPrompts.toolStepLabel(call.function.name, language: language), in: ref)
                let outcome: ToolOutcome
                switch offeredTools.family(of: call.function.name) {
                case nil:
                    outcome = .failure(Self.unknownToolMessage(call.function.name, offered: offered))
                case .chat:
                    if call.function.name == "run_program" {
                        runs += 1
                        if runs > ChatWorkspaceTools.maxRunsPerTurn {
                            outcome = .failure("Program and terminal run limit reached for this reply (\(ChatWorkspaceTools.maxRunsPerTurn)).")
                        } else {
                            outcome = await ChatWorkspaceTools.run(call: call, workspace: workspace, conversationID: conversationID)
                        }
                    } else if call.function.name == "chat_schedule_run" || call.function.name == "chat_schedule_cancel" {
                        let owner = ref?.ownerID
                        outcome = await ChatWorkspaceTools.run(call: call, workspace: workspace, conversationID: conversationID, timeZone: context.timeZone) { next in
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
                case .extended:
                    guard let access else { outcome = .failure("Workspace access is not available here."); break }
                    let isTerminal = call.function.name == "run_terminal" || call.function.name == "project_terminal"
                    if isTerminal { runs += 1 }
                    if isTerminal && runs > ChatWorkspaceTools.maxRunsPerTurn {
                        outcome = .failure("Program and terminal run limit reached for this reply (\(ChatWorkspaceTools.maxRunsPerTurn)).")
                    } else {
                        let project = ProjectScope(ownerID: ref?.ownerID ?? "", projectName: context.projectName)
                        outcome = await ExtendedWorkspaceTools.run(call: call, workspace: workspace, conversationID: conversationID, project: project, terminal: access.terminal, hosts: access.hosts, actions: access.actions, audit: access.audit)
                    }
                    if !outcome.wroteFiles.isEmpty { writtenFiles.append(contentsOf: outcome.wroteFiles) }
                case .skill:
                    outcome = await SkillTools.run(call: call, skills: skills)
                case .task:
                    tasks += 1
                    if tasks > TaskTools.maxPerReply {
                        outcome = .failure("Task limit reached for this reply (\(TaskTools.maxPerReply)). Finish with what you have.")
                    } else if let ref {
                        outcome = await startTask(call: call, coordinator: coordinator, context: context, language: language, ref: ref)
                    } else {
                        outcome = .failure("Tasks need a user-owned conversation.")
                    }
                case .trigger:
                    let owner = ref?.ownerID
                    let conversations = self.conversations
                    let sink = owner.map { owner in
                        TriggerTools.Sink(
                            add: { trigger in
                                (try? await conversations.addTrigger(id: conversationID, ownerID: owner, trigger: trigger)) ?? .failure(.invalid("The trigger could not be saved."))
                            },
                            remove: { id in
                                (try? await conversations.removeTrigger(id: conversationID, ownerID: owner, triggerID: id)) ?? .failure(.notFound)
                            },
                            gmailConnected: offered.contains("gmail_search")
                        )
                    }
                    outcome = await TriggerTools.run(call: call, sink: sink, language: language)
                case .memory:
                    outcome = await MemoryTools.run(call: call, memory: memory, ownerID: ref?.ownerID)
                case .mission:
                    outcome = await ConversationMissionTools.run(call: call, store: store, allowedMissionIDs: Set(context.missionIDs))
                case .workstation:
                    guard let workstation, let access, let ref else { outcome = .failure("Workstation access is not available here."); break }
                    guard WorkstationTools.approvalNames.contains(call.function.name) else {
                        outcome = await WorkstationTools.run(call: call, workstation: workstation)
                        break
                    }
                    runs += 1
                    if runs > ChatWorkspaceTools.maxRunsPerTurn {
                        outcome = .failure("Program and terminal run limit reached for this reply (\(ChatWorkspaceTools.maxRunsPerTurn)).")
                        break
                    }
                    let command = (AgentTools.arguments(of: call)["command"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !command.isEmpty else { outcome = .failure("A command is required. Nothing ran."); break }
                    let shown = command.count > 80 ? String(command.prefix(77)) + "…" : command
                    outcome = await gatedWrite(
                        call: call, kind: .workstation, access: access, ownerID: ref.ownerID, conversationID: conversationID,
                        title: "Run on the workstation: \(shown)", ranTitle: "Ran on the workstation: \(shown)", detail: "Ada wants to run this on her Linux workstation, outside the sandbox. Nothing has run yet."
                    ) {
                        await WorkstationTools.execute(toolName: call.function.name, rawArguments: call.function.arguments, workstation: workstation)
                    }
                case .mcp:
                    guard let mcp = access?.mcp else { outcome = .failure("MCP servers are not available here."); break }
                    if await mcp.isReadOnly(call.function.name) {
                        outcome = await mcp.call(call.function.name, rawArguments: call.function.arguments)
                    } else if let access, let ref {
                        outcome = await gatedWrite(
                            call: call, kind: .mcpCall, access: access, ownerID: ref.ownerID, conversationID: conversationID,
                            title: "Approve \(call.function.name)", ranTitle: "Ran \(call.function.name) automatically", detail: "Ada wants to call a tool on a connected MCP server. Review the exact arguments. Nothing has been sent yet."
                        ) {
                            await mcp.call(call.function.name, rawArguments: call.function.arguments)
                        }
                    } else {
                        outcome = .failure("A user-owned conversation is required to approve MCP tool calls.")
                    }
                case .connector:
                    guard let connectors else { outcome = .failure("No connector is available for this tool."); break }
                    if ConnectorHub.readOnlyToolNames.contains(call.function.name) {
                        outcome = await connectors.run(call: call, readOnly: true)
                    } else if let ref {
                        let decision = await access?.permissions.decide(ownerID: ref.ownerID, toolName: call.function.name, arguments: AgentTools.arguments(of: call)) ?? .ask(nil)
                        if case .deny(let reason) = decision {
                            outcome = .failure(reason)
                            break
                        }
                        if case .allow = decision {
                            let result = await connectors.run(call: call, approved: true)
                            let record = AgentActionRequest(
                                ownerID: ref.ownerID, conversationID: conversationID, kind: .connectorWrite,
                                title: "Ran \(call.function.name) automatically", detail: "Your standing permission for this tool allowed it without an approval card.",
                                toolName: call.function.name, arguments: .object([("raw", .string(call.function.arguments))])
                            )
                            await access?.actions.recordAutomatic(record, result: result.resultText, succeeded: result.succeeded)
                            outcome = result.succeeded
                                ? ToolOutcome(resultText: "Ran without an approval card because the user's standing permission allows it.\n\n" + result.resultText)
                                : result
                            break
                        }
                        var reason: String?
                        if case .ask(let why) = decision { reason = why }
                        let lifetime = await access?.permissions.approvalLifetime(ownerID: ref.ownerID) ?? 15 * 60
                        let action = AgentActionRequest(
                            ownerID: ref.ownerID, conversationID: conversationID, kind: .connectorWrite,
                            title: "Approve \(call.function.name)", detail: "Ada requested an external connector write. Review the exact arguments. Nothing has been sent or changed yet." + (reason.map { " " + $0 } ?? ""),
                            toolName: call.function.name, arguments: .object([("raw", .string(call.function.arguments))]), lifetime: lifetime
                        )
                        if let saved = await access?.actions.request(action) {
                            let why = reason.map { " \($0)" } ?? ""
                            outcome = ToolOutcome(resultText: "Approval requested (\(saved.id.uuidString)).\(why) Do not retry this write. Tell the user to review the approval card; the external action has not happened. The outcome will appear under approval requests in your context on a later turn.")
                        } else {
                            outcome = .failure("Connector approvals are not available. No external write was performed.")
                        }
                    } else {
                        outcome = .failure("A user-owned conversation is required to approve connector writes.")
                    }
                }
                messages.append(.tool(id: call.id, content: String(outcome.resultText.prefix(32_000)), isError: !outcome.succeeded))
                if toolLog.count < Self.maxToolLogEntries { toolLog.append(Self.toolLogLine(call: call, outcome: outcome)) }
            }
            // The reply's spending limit stops further tool rounds; Ada answers with what she has.
            if let replyCap, (CostMeter.current?.total ?? 0) >= replyCap {
                overCap = true
                break
            }
            // Warn before the budget runs out, so Ada can wrap up instead of being cut off mid-task.
            let left = Self.maxToolRounds - round - 1
            if left > 0, left <= 2, let last = messages.indices.last, messages[last].role == "tool" {
                messages[last].content = (messages[last].content ?? "") + "\n\n[\(left) tool round\(left == 1 ? "" : "s") left in this reply; finish or say what is still missing.]"
            }
            await beginStep(language == "es" ? "Redactando la respuesta" : "Writing the answer", in: ref)
        }
        // The tool budget is spent. Say so, or some models keep "calling" tools by writing the calls as text.
        if overCap {
            messages.append(.user(language == "es"
                ? "Esta respuesta alcanzó el límite de gasto que fijó la persona. Responde ahora con lo que ya sabes, sin llamar a herramientas, y di qué falta y que puede pedirte que continúes."
                : "This reply reached the spending limit the person set. Answer now with what you already have, without calling any tools, and say what is still missing and that they can ask you to continue."))
        } else {
            messages.append(.user(language == "es"
                ? "Ya no quedan pasos de herramientas para esta respuesta. Responde ahora con lo que ya sabes, sin llamar a herramientas, y di qué falta si no pudiste terminar."
                : "No tool steps are left for this reply. Answer now with what you already have, without calling any tools, and say what is still missing if you could not finish."))
        }
        let final = try await completeDirect(coordinator: coordinator, system: system, messages: messages, tools: nil, maxTokens: context.spoken ? Self.voiceMaxTokens : nil, contextAllowance: allowance, onDelta: streamer(for: ref)?.handler)
        let answer = final.message.content ?? ""
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return language == "es"
                ? "Usé todos los pasos de herramientas de esta respuesta antes de terminar. Pídeme que continúe y seguiré desde aquí."
                : "I used all the tool steps for this reply before finishing. Ask me to continue and I will pick up from here."
        }
        return answer
    }

    /// The workstation, when the server turned it on and this owner may use it.
    private func workstation(ownerID: String?) async -> Workstation? {
        guard let ownerID, let access, let workstation = access.workstation, await workstation.enabled, await access.workstationOwner(ownerID) else { return nil }
        return workstation
    }

    /// A call that changes something outside the workspace: refused, run under a standing
    /// permission, or turned into an approval card that runs `execute` once approved.
    private func gatedWrite(call: APIToolCall, kind: AgentActionRequest.Kind, access: ConversationAccess, ownerID: String, conversationID: UUID, title: String, ranTitle: String, detail: String, execute: () async -> ToolOutcome) async -> ToolOutcome {
        let raw: JSONValue = .object([("raw", .string(call.function.arguments))])
        let decision = await access.permissions.decide(ownerID: ownerID, toolName: call.function.name, arguments: AgentTools.arguments(of: call))
        switch decision {
        case .deny(let reason):
            return .failure(reason)
        case .allow:
            let result = await execute()
            let record = AgentActionRequest(
                ownerID: ownerID, conversationID: conversationID, kind: kind,
                title: ranTitle,
                detail: "Your standing permission for this tool allowed it without an approval card.",
                toolName: call.function.name, arguments: raw
            )
            await access.actions.recordAutomatic(record, result: result.resultText, succeeded: result.succeeded)
            return result.succeeded ? ToolOutcome(resultText: "Ran without an approval card because the user's standing permission allows it.\n\n" + result.resultText) : result
        case .ask(let reason):
            let lifetime = await access.permissions.approvalLifetime(ownerID: ownerID)
            let action = AgentActionRequest(
                ownerID: ownerID, conversationID: conversationID, kind: kind,
                title: title, detail: detail + (reason.map { " " + $0 } ?? ""),
                toolName: call.function.name, arguments: raw, lifetime: lifetime
            )
            let saved = await access.actions.request(action)
            let why = reason.map { " \($0)" } ?? ""
            return ToolOutcome(resultText: "Approval requested (\(saved.id.uuidString)).\(why) Do not retry this call. Tell the user to review the approval card; nothing has run. The outcome will appear under approval requests in your context on a later turn.")
        }
    }

    /// The owner's per-reply spending limit, if one is set.
    private func replySpendCap(ownerID: String?) async -> Double? {
        guard let ownerID, let access else { return nil }
        return await access.permissions.policy(ownerID: ownerID).replySpendCapUSD
    }

    /// The reply to send instead of working when today's estimated spend has reached the owner's cap.
    private func dailyCapNotice(ownerID: String, language: String) async -> String? {
        guard let access, let cap = await access.permissions.policy(ownerID: ownerID).dailySpendCapUSD else { return nil }
        let spent = await access.spend.today(ownerID: ownerID)
        guard spent >= cap else { return nil }
        let amount = String(format: "%.2f", cap)
        return language == "es"
            ? "Hoy ya alcancé el límite de gasto diario de $\(amount), así que no empecé este trabajo. El límite se reinicia a medianoche (UTC), o un administrador puede subirlo en Ajustes, en Lo que Ada puede hacer sola."
            : "I've reached today's spending limit of $\(amount), so I didn't start on this. It resets at midnight UTC, or an admin can raise it in Settings under What Ada can do alone."
    }

    /// The result for a call to a tool that was not offered: names the closest real tools so the
    /// model can correct itself instead of guessing again.
    static func unknownToolMessage(_ name: String, offered: Set<String>) -> String {
        let words = Set(name.lowercased().split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init))
        let scored = offered.map { candidate -> (String, Int) in
            let parts = Set(candidate.split(separator: "_").map(String.init))
            return (candidate, parts.intersection(words).count)
        }
        let close = scored.filter { $0.1 > 0 }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(3).map(\.0)
        let suggestion = close.isEmpty ? "" : " Closest available: \(close.joined(separator: ", "))."
        return "Unknown tool: \(name). It is not available in this reply, so nothing ran and no approval was requested.\(suggestion) Use only the tools listed for this reply."
    }

    /// Streams text into the running response, throttled so storage is not rewritten per token.
    private func streamer(for ref: ResponseRef?) -> PartialTextStream? {
        guard let ref else { return nil }
        return PartialTextStream { [weak self] text in
            await self?.publishPartial(text, in: ref)
        }
    }

    /// Shows in-progress text on the running response. Never touches a response that has finished.
    private func publishPartial(_ text: String, in ref: ResponseRef?) async {
        guard let ref else { return }
        // The trailing suggestions block is metadata for quick replies, not part of what Ada says.
        var visible = text.range(of: "```suggestions", options: .caseInsensitive).map { String(text[..<$0.lowerBound]) } ?? text
        // For a spoken message the spoken part is fixed once the details line appears; the rest is on-screen only.
        var speech: String?
        if ref.spoken {
            let split = ConversationPrompts.extractDetails(visible)
            visible = split.screen
            speech = split.speech
        }
        _ = try? await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { message in
            guard message.status == .running else { return }
            message.text = visible
            message.speech = speech
        }
    }

    private func consolidate(userText: String, missions: [Mission], coordinator: AgentProfile, context: ConversationPromptContext, history: [ConversationMessage], language: String) async throws -> String {
        let system = ConversationPrompts.consolidationSystem(coordinator: coordinator, context: context, store: promptStore, language: language)
        let prompt = ConversationPrompts.consolidationPrompt(userText: userText, missions: missions, store: promptStore, language: language)
        var turn = context.turnPreamble + prompt
        if context.spoken {
            // The request above asks for evidence, files and caveats; for a spoken reply the voice rules win.
            turn += language == "es"
                ? "\n\nEsta respuesta se leerá en voz alta: sigue las reglas de VOICE REPLY del mensaje de sistema por encima del formato anterior."
                : "\n\nThis reply is read aloud: follow the VOICE REPLY rules in the system prompt over the format above."
        }
        let reply = try await complete(coordinator: coordinator, system: system, messages: Self.chatTurns(from: history.dropLast()) + [.user(turn)], tools: nil, maxTokens: context.spoken ? Self.voiceMaxTokens : nil)
        if reply.message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return reply.message.content ?? "" }
        return missions.compactMap(\.finalReport).joined(separator: "\n\n")
    }

    /// Runs one `start_task` call to the end: picks the skill's team (or Ada alone), launches the
    /// mission, shows its progress on the reply, and returns its report to Ada's loop.
    private func startTask(call: APIToolCall, coordinator: AgentProfile, context: ConversationPromptContext, language: String, ref: ResponseRef) async -> ToolOutcome {
        let request: TaskTools.Request
        switch TaskTools.request(from: call) {
        case .failure(let error): return .failure(error.message)
        case .success(let valid): request = valid
        }
        let es = language == "es"
        let team: Team
        let skillName: String
        if let skill = request.skill {
            let skillList = await skills.enabled()
            let selected = await skillTeams(for: ConversationDecision(action: .useSkill, skillIDs: [skill]), skills: skillList, teams: await store.loadTeams(), coordinator: coordinator, providers: await store.loadProviders())
            guard let first = selected.first else {
                let known = skillList.map(\.id).joined(separator: ", ")
                return .failure("No enabled skill \"\(skill)\" can run (unknown, or its specialists have no provider key). Enabled skills: \(known.isEmpty ? "none" : known). Leave skill out to work on it yourself.")
            }
            team = first
            skillName = skillList.first { $0.teamID == first.id }?.name ?? first.name
        } else {
            var solo = Self.soloTeam(coordinator: coordinator, language: language, store: promptStore)
            if let existing = await store.team(id: Self.soloTeamID) { solo.createdAt = existing.createdAt }
            await store.saveTeam(solo)
            team = solo
            skillName = es ? "Ada sola" : "Ada working alone"
        }
        let label = team.id == Self.soloTeamID
            ? (es ? "Trabajando en ello yo sola" : "Working on it myself")
            : (es ? "Trabajando con especialistas: \(team.name)" : "Working with specialists: \(team.name)")
        let ada = AgentActivity(agentID: coordinator.id, agentName: "Ada", summary: request.reason ?? label, state: "working")
        _ = try? await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { message in
            if !message.teamIDs.contains(team.id) { message.teamIDs.append(team.id) }
            message.activity = [ada]
        }
        await beginStep(label, in: ref)
        do {
            let mission = try await runMission(team: team, objective: request.objective, context: context.missionHandoff, launchedBy: ref.launchedBy, language: language, conversationID: ref.conversationID, ownerID: ref.ownerID, projectName: context.projectName)
            _ = try? await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { message in
                if !message.missionIDs.contains(mission.id) { message.missionIDs.append(mission.id) }
            }
            let finished = try await monitor(missions: [mission], teams: [team], conversationID: ref.conversationID, ownerID: ref.ownerID, responseID: ref.responseID, ada: ada)
            guard let done = finished.first else { return .failure("The task's mission disappeared before it finished.") }
            CostMeter.current?.add(done.totalCostUSD)
            await beginStep(es ? "Revisando el resultado" : "Checking the result", in: ref)
            return TaskTools.result(mission: done, skillName: skillName, files: await store.deliverables(missionID: done.id))
        } catch is CancellationError {
            return .failure("The task was stopped.")
        } catch {
            return .failure("The task could not start: \(error.localizedDescription)")
        }
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

    private func promptContext(conversation: Conversation, history: [ConversationMessage], memory: String, knowledge: String, scheduled: Bool, spoken: Bool = false, personName: String? = nil, event: TriggerEvent? = nil) async -> ConversationPromptContext {
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
        let approvals = await access?.actions.list(ownerID: conversation.ownerID, conversationID: conversation.id) ?? []
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
            knowledge: knowledge,
            spoken: spoken,
            timeZoneID: conversation.timeZone,
            personName: personName,
            approvals: approvals,
            triggers: conversation.triggers,
            event: event
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

    private func complete(coordinator: AgentProfile, system: String, messages: [APIMessage], tools: [APIToolDef]?, maxTokens: Int? = nil, onDelta: TextDeltaHandler? = nil) async throws -> LLMReply {
        let registry = ProviderRegistry(providers: await store.loadProviders())
        guard let provider = registry.provider(id: coordinator.providerID) else { throw ConversationError.noProvider }
        let reply: LLMReply
        if let completionOverride {
            reply = try await completionOverride(provider, keyRing.get(provider.keyAccount) ?? "", coordinator, system, messages, tools)
        } else {
            reply = try await client.complete(provider: provider, key: keyRing.get(provider.keyAccount) ?? "", model: coordinator.model, system: system, messages: messages, tools: tools, temperature: coordinator.temperature, maxTokens: maxTokens, onDelta: onDelta)
        }
        CostMeter.current?.add(reply)
        return reply
    }

    private func completeDirect(coordinator: AgentProfile, system: String, messages: [APIMessage], tools: [APIToolDef]?, maxTokens: Int? = nil, contextAllowance: Int = 0, onDelta: TextDeltaHandler? = nil) async throws -> LLMReply {
        var budget = directContextBudgetTokens + contextAllowance
        var overflowRetries = 0
        var messages = messages
        while true {
            let compacted = ConversationCompactor.compact(messages: messages, budgetTokens: budget)
            do {
                return try await complete(coordinator: coordinator, system: system, messages: compacted.messages, tools: tools, maxTokens: maxTokens, onDelta: onDelta)
            } catch let error as LLMError where error.isContextOverflow {
                overflowRetries += 1
                guard overflowRetries <= 2 else { throw error }
                budget = max(ConversationCompactor.minimumBudgetTokens, budget / 2)
            } catch let error as LLMError where Self.mayBeImageRejection(error) && messages.contains(where: { $0.images?.isEmpty == false }) {
                // The provider refused the photos (a text-only model we did not know about, or a
                // format it does not take). Answer without them and say so, rather than failing.
                messages = Self.withoutImages(messages, model: coordinator.model)
            }
        }
    }

    static func mayBeImageRejection(_ error: LLMError) -> Bool {
        guard let status = error.statusCode, !error.isContextOverflow else { return false }
        return [400, 404, 413, 415, 422].contains(status)
    }

    /// Drops every image and tells the model, in the turn that had them, why it cannot see them.
    static func withoutImages(_ messages: [APIMessage], model: String) -> [APIMessage] {
        messages.map { message in
            guard let images = message.images, !images.isEmpty else { return message }
            var copy = message
            copy.images = nil
            copy.content = (copy.content ?? "") + "\n\n(The user attached \(images.count == 1 ? "a photo" : "\(images.count) photos"), but the model \(model) rejected it. Say in one sentence that this model can't look at photos and that a vision model such as Claude or GPT can be chosen for Ada in Settings, then help with the rest of the message.)"
            return copy
        }
    }

    /// The images sent with a direct reply: the current message's photos, plus photos from the last
    /// few turns so follow-ups like "and the one on the left?" still work. Capped to keep cost sane.
    struct PhotoInputs: Sendable {
        var current: [APIImage] = []
        var history: [UUID: [APIImage]] = [:]
    }

    static let maxHistoryPhotos = 4
    static let photoHistoryWindow = 6

    private func photoInputs(conversationID: UUID, current: ConversationMessage, history: [ConversationMessage]) -> PhotoInputs {
        var inputs = PhotoInputs()
        inputs.current = current.photos.compactMap { photos.image(conversationID: conversationID, attachment: $0) }
        var budget = Self.maxHistoryPhotos
        for message in history.dropLast().suffix(Self.photoHistoryWindow).reversed() where message.role == .user && !message.photos.isEmpty {
            guard budget > 0 else { break }
            let loaded = message.photos.prefix(budget).compactMap { photos.image(conversationID: conversationID, attachment: $0) }
            if !loaded.isEmpty { inputs.history[message.id] = Array(loaded) }
            budget -= message.photos.count
        }
        return inputs
    }

    /// Words that suggest real work (a deliverable, a team, a schedule, an external action). A spoken
    /// message with one of these still goes through routing so it can become a SOLO or team run.
    static let workWords: [String] = [
        "build", "create", "make", "write", "draft", "design", "develop", "code", "fix", "deploy", "research",
        "analy", "report", "plan", "team", "mission", "agent", "website", "page", "app", "document", "spreadsheet",
        "schedule", "every ", "remind", "send", "email", "post", "publish", "change", "update", "delete", "pause",
        "launch", "set up", "setup", "compare", "summar", "list of", "file",
        "crea", "haz", "escrib", "diseñ", "investig", "informe", "equipo", "envía", "envia", "programa", "cada ", "cambia", "borra", "archivo",
    ]

    /// True for a short spoken message that is a question or a chat turn, not a request for work.
    /// It also stays false right after Ada asked something, because the answer may complete a
    /// clarification that routing needs to see.
    static func isQuickSpokenQuestion(_ message: ConversationMessage, history: [ConversationMessage]) -> Bool {
        guard message.spoken, message.photos.isEmpty, !message.scheduled else { return false }
        let text = message.text.lowercased()
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words > 0, words <= 25 else { return false }
        if workWords.contains(where: { text.contains($0) }) { return false }
        let previous = history.dropLast().last(where: { $0.role == .assistant })
        if let previous {
            if previous.proposal?.status == .pending { return false }
            if previous.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return false }
        }
        return true
    }

    /// The user's words plus a note about attached photos, for routing, missions, and consolidation,
    /// none of which look at the images themselves.
    static func textWithPhotoNote(_ message: ConversationMessage) -> String {
        guard !message.photos.isEmpty else { return message.text }
        let count = message.photos.count
        let note = "[The user attached \(count == 1 ? "a photo" : "\(count) photos"). Only Ada's DIRECT reply can look at photos; SOLO missions and specialist teams cannot see them.]"
        return message.text.isEmpty ? note : message.text + "\n\n" + note
    }

    /// The user's turn for Ada's direct reply, which carries the photos as images when the model can see them.
    static func directText(for message: ConversationMessage, canSee: Bool, model: String, language: String) -> String {
        guard !message.photos.isEmpty else { return message.text }
        let count = message.photos.count
        let photoWord = count == 1 ? "a photo" : "\(count) photos"
        if !canSee {
            let note = "(The user attached \(photoWord), but your current model, \(model), can't look at images. Say so in one short sentence, mention that a vision model such as Claude or GPT can be chosen for Ada in Settings, then help with the rest of the message if there is any.)"
            return message.text.isEmpty ? note : message.text + "\n\n" + note
        }
        return message.text.isEmpty ? "(The user sent \(photoWord) without a message. Say briefly what matters in it and what you can do with it.)" : message.text
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

/// Collects streamed text and hands the accumulated answer to `sink` at most every 150ms.
/// A flush is always scheduled for the latest text, so the tail of a burst is never lost.
final class PartialTextStream: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: @Sendable (String) async -> Void
    private let interval: TimeInterval
    private var text = ""
    private var lastFlush = Date.distantPast
    private var flushing = false

    init(interval: TimeInterval = 0.15, sink: @escaping @Sendable (String) async -> Void) {
        self.interval = interval
        self.sink = sink
    }

    var handler: TextDeltaHandler {
        { [self] delta in push(delta) }
    }

    private func push(_ delta: String) {
        guard let wait = reserveFlush(adding: delta) else { return }
        Task {
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            let snapshot = takeSnapshot()
            await sink(snapshot)
            if finishFlush(sent: snapshot) { push("") }
        }
    }

    /// Appends text; returns how long to wait before flushing, or nil when a flush is already pending.
    private func reserveFlush(adding delta: String) -> TimeInterval? {
        lock.withLock {
            text += delta
            guard !flushing else { return nil }
            flushing = true
            return max(0, interval - Date().timeIntervalSince(lastFlush))
        }
    }

    private func takeSnapshot() -> String {
        lock.withLock {
            lastFlush = Date()
            return text
        }
    }

    /// Ends a flush; returns true when more text arrived while it was in flight.
    private func finishFlush(sent: String) -> Bool {
        lock.withLock {
            flushing = false
            return text != sent
        }
    }
}
