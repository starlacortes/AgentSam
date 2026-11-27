import Foundation

public actor ConversationEngine {
    public typealias Completion = @Sendable (ProviderConfig, String, AgentProfile, String, [APIMessage], [APIToolDef]?) async throws -> LLMReply

    private let store: MissionStore
    private let conversations: ConversationStore
    private let memory: WorkspaceMemoryStore
    private let knowledge: WorkspaceKnowledgeStore?
    private let workspace: ChatWorkspaceStore
    private let photos: ConversationPhotoStore
    private let keyRing: KeyRing
    private let client: LLMClient
    private let connectors: ConnectorHub?
    private let promptStore: PromptStore
    private let access: ConversationAccess?
    private let skills: SkillStore
    private let helpers: HelperStore
    /// Whether a routing call decides DIRECT, SOLO, USE_SKILL or CLARIFY before Ada answers. Off: Ada
    /// answers in one loop and hands work on with `delegate` and `start_task` when it needs more.
    private let routing: Bool
    /// Output cap for spoken replies written without tools (team summaries, the last answer after the tool
    /// budget). A backstop only: voice replies are shown and read in full, however long, so this is
    /// high enough for a long answer the user asked for (a story, a full report read out).
    /// Turns that offer tools are not capped, because a capped tool call (a file write) would be cut off.
    static let voiceMaxTokens = 8_000
    private let completionOverride: Completion?
    private var running: [UUID: Task<Void, Never>] = [:]
    private var memoryJobs: [UUID: Task<Void, Never>] = [:]
    /// Running helper tasks: mission ID to the reply they run in, so a task can be stopped from its page.
    private var taskReplies: [UUID: (conversationID: UUID, ownerID: String)] = [:]

    public init(store: MissionStore, conversations: ConversationStore, memory: WorkspaceMemoryStore, workspace: ChatWorkspaceStore? = nil, keyRing: KeyRing, client: LLMClient = LLMClient(), connectors: ConnectorHub? = nil, promptStore: PromptStore? = nil, access: ConversationAccess? = nil, knowledge: WorkspaceKnowledgeStore? = nil, photos: ConversationPhotoStore? = nil, skills: SkillStore? = nil, helpers: HelperStore? = nil, routing: Bool = true) {
        self.store = store
        self.conversations = conversations
        self.memory = memory
        self.knowledge = knowledge
        self.workspace = workspace ?? ChatWorkspaceStore(root: store.root)
        self.photos = photos ?? ConversationPhotoStore(root: store.root)
        self.keyRing = keyRing
        self.client = client
        self.connectors = connectors
        self.promptStore = promptStore ?? PromptStore(builtins: PromptStore.builtins)
        self.access = access
        self.skills = skills ?? SkillStore(root: store.root)
        self.helpers = helpers ?? HelperStore(root: store.root)
        self.routing = routing
        self.completionOverride = nil
    }

    init(store: MissionStore, conversations: ConversationStore, memory: WorkspaceMemoryStore, workspace: ChatWorkspaceStore? = nil, keyRing: KeyRing, connectors: ConnectorHub? = nil, promptStore: PromptStore? = nil, access: ConversationAccess? = nil, knowledge: WorkspaceKnowledgeStore? = nil, photos: ConversationPhotoStore? = nil, skills: SkillStore? = nil, helpers: HelperStore? = nil, routing: Bool = true, completion: @escaping Completion) {
        self.store = store
        self.conversations = conversations
        self.memory = memory
        self.knowledge = knowledge
        self.workspace = workspace ?? ChatWorkspaceStore(root: store.root)
        self.photos = photos ?? ConversationPhotoStore(root: store.root)
        self.keyRing = keyRing
        self.client = LLMClient()
        self.connectors = connectors
        self.promptStore = promptStore ?? PromptStore(builtins: PromptStore.builtins)
        self.access = access
        self.skills = skills ?? SkillStore(root: store.root)
        self.helpers = helpers ?? HelperStore(root: store.root)
        self.routing = routing
        self.completionOverride = completion
    }

    @discardableResult
    /// `choice` answers a choice card Ada asked: its answers become the message text, and the card
    /// shows them. Any other message the person sends closes a waiting card, showing what they
    /// picked when their words clearly name its options.
    public func send(conversationID: UUID, ownerID: String, text rawText: String, launchedBy: String, language: String, scheduled: Bool = false, photos: [PhotoAttachment] = [], spoken: Bool = false, timeZone: String? = nil, trigger: TriggerEvent? = nil, choice: ChoiceReply? = nil) async throws -> Conversation {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let photos = Array(photos.prefix(ConversationPhotoStore.maxPerMessage))
        guard !text.isEmpty || !photos.isEmpty || choice != nil else { throw ConversationError.emptyMessage }
        guard text.count <= 20_000 else { throw ConversationError.messageTooLong }
        guard running[conversationID] == nil else { throw ConversationError.alreadyRunning }
        guard let conversation = try await conversations.get(id: conversationID, ownerID: ownerID) else { throw ConversationError.notFound }
        guard !conversation.messages.contains(where: { $0.status == .running }) else { throw ConversationError.alreadyRunning }
        let lang = language.lowercased().hasPrefix("es") ? "es" : "en"
        var choiceReply: ChoiceAnswer?
        if let choice {
            guard let card = conversation.messages.last(where: { $0.choice?.id == choice.cardID })?.choice else {
                throw ConversationError.choice(lang == "es" ? "Esta tarjeta ya no está en el chat." : "This card is no longer in the chat.")
            }
            guard card.state == .pending else {
                throw ConversationError.choice(lang == "es" ? "Esta tarjeta ya tiene respuesta. Escribe tu mensaje para cambiarla." : "This card was already answered. Write a message to change your answer.")
            }
            switch ChoiceCardTools.answer(card, reply: choice) {
            case .failure(let error): throw ConversationError.choice(error.message)
            case .success(let answer):
                choiceReply = answer
                text = answer.text(title: card.title, language: lang)
            }
        }
        if let timeZone { _ = try? await conversations.setTimeZone(id: conversationID, ownerID: ownerID, timeZone: timeZone) }
        // A waiting card takes one answer: this message, on the card or in words.
        if !scheduled && trigger == nil {
            let latestReply = conversation.messages.last(where: { $0.role == .assistant })?.id
            for message in conversation.messages where message.role == .assistant && message.choice?.state == .pending {
                guard let card = message.choice else { continue }
                let answer = card.id == choiceReply?.cardID ? choiceReply : (message.id == latestReply ? ChoiceCardTools.match(text, card: card) : nil)
                _ = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: message.id) { updated in
                    updated.choice?.state = answer == nil ? .closed : .answered
                    updated.choice?.answer = answer
                }
            }
        }
        let userMessage = ConversationMessage(role: .user, text: text, scheduled: scheduled || trigger != nil, photos: photos, spoken: spoken, trigger: trigger, choiceReply: choiceReply)
        let choosing = routing ? StepLabel.choosing(lang) : StepLabel.thinking(lang)
        let pending = ConversationMessage(role: .assistant, text: "", status: .running, activity: [AgentActivity(agentID: UUID(), agentName: "Ada", summary: choosing, state: "working")], steps: [MessageStep(label: choosing)])
        _ = try await conversations.append(id: conversationID, ownerID: ownerID, message: userMessage)
        let result = try await conversations.append(id: conversationID, ownerID: ownerID, message: pending)
        running[conversationID] = Task {
            // Every model call made for this reply adds its estimated cost to one meter.
            let meter = CostMeter()
            let trace = ReplyTrace(conversationID: conversationID)
            await CostMeter.$current.withValue(meter) {
                await ReplyTrace.$current.withValue(trace) {
                    await self.drive(conversationID: conversationID, ownerID: ownerID, userMessage: userMessage, responseID: pending.id, launchedBy: launchedBy, language: lang)
                }
            }
            EngineLog.write(.info, trace.summaryLine(costUSD: meter.total))
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

    /// The missions of the helper tasks running now.
    public var runningTaskIDs: [UUID] { Array(taskReplies.keys) }

    /// Whether a helper task is still running for this mission.
    public func isTaskRunning(missionID: UUID) -> Bool { taskReplies[missionID] != nil }

    /// Stops the reply a helper task runs in, which stops the task. False when no task is running.
    @discardableResult
    public func stopTask(missionID: UUID, language: String) async -> Bool {
        guard let reply = taskReplies[missionID] else { return false }
        await stop(conversationID: reply.conversationID, ownerID: reply.ownerID, language: language)
        return true
    }

    /// Starts a helper task outside a chat: the missions API and the Maloon workflows. The task gets
    /// a conversation of its own, so its approval cards, files and progress have a home, and runs
    /// exactly like `start_task` there (same tools, approvals, budgets and audit). `attachment` is
    /// saved as a file in that conversation for the helpers to read. Returns the running mission.
    public func launchTask(ownerID: String, launchedBy: String, objective rawObjective: String, attachment: (name: String, content: String)? = nil, skillID: String? = nil, language: String, sourceName: String = "Ada task", workflowID: String? = nil) async throws -> Mission {
        let lang = language.lowercased().hasPrefix("es") ? "es" : "en"
        let objective = rawObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { throw ConversationError.emptyMessage }
        guard objective.count <= 20_000 else { throw ConversationError.messageTooLong }
        if let notice = await dailyCapNotice(ownerID: ownerID, language: lang) { throw ConversationError.persistence(notice) }
        let skill: Skill?
        switch await enabledSkill(skillID, ownerID: ownerID) {
        case .failure(let error): throw ConversationError.persistence(error.message)
        case .success(let found): skill = found
        }
        let coordinator = try coordinator(providers: await store.loadProviders())
        var conversation = try await conversations.create(ownerID: ownerID)
        var text = objective
        if let attachment, let saved = await workspace.write(conversationID: conversation.id, name: attachment.name, content: attachment.content) {
            text += lang == "es" ? "\n\nEl contexto está en el archivo \(saved) de esta conversación." : "\n\nThe context is in the file \(saved) in this conversation."
        }
        let planning = lang == "es" ? "Planificando el trabajo" : "Planning the job"
        let userMessage = ConversationMessage(role: .user, text: text)
        let pending = ConversationMessage(role: .assistant, text: "", status: .running, activity: [AgentActivity(agentID: coordinator.id, agentName: "Ada", summary: planning, state: "working")], steps: [MessageStep(label: planning)])
        _ = try await conversations.append(id: conversation.id, ownerID: ownerID, message: userMessage)
        conversation = try await conversations.append(id: conversation.id, ownerID: ownerID, message: pending)
        let ref = ResponseRef(conversationID: conversation.id, ownerID: ownerID, responseID: pending.id, launchedBy: launchedBy, language: lang)
        let history = conversation.messages.filter { $0.status != .running }
        let context = await promptContext(conversation: conversation, history: history, memory: await memory.state(ownerID: ownerID).promptText, knowledge: "", scheduled: false, personName: launchedBy)
        let mission = await prepareTask(objective: text, skill: skill, context: context, language: lang, ref: ref, sourceName: sourceName, workflowID: workflowID, inputContext: attachment?.content)
        let conversationID = conversation.id
        running[conversationID] = Task {
            let meter = CostMeter()
            let trace = ReplyTrace(conversationID: conversationID)
            await CostMeter.$current.withValue(meter) {
                await ReplyTrace.$current.withValue(trace) {
                    await self.driveTask(mission, skill: skill, userMessage: userMessage, coordinator: coordinator, context: context, history: history, language: lang, ref: ref)
                }
            }
            EngineLog.write(.info, trace.summaryLine(costUSD: meter.total))
            await self.access?.spend.add(ownerID: ownerID, usd: meter.total)
        }
        return mission
    }

    /// Runs a launched task in its own reply, then writes Ada's answer from its report.
    private func driveTask(_ mission: Mission, skill: Skill?, userMessage: ConversationMessage, coordinator: AgentProfile, context: ConversationPromptContext, history: [ConversationMessage], language: String, ref: ResponseRef) async {
        defer { running[ref.conversationID] = nil }
        let es = language == "es"
        do {
            let tools = await directTools(ref: ref, context: context)
            let state = ToolRunState()
            let run = await performTask(mission, skill: skill, reason: nil, parent: tools.offered, state: state, coordinator: coordinator, context: context, language: language, ref: ref, conversationID: ref.conversationID, workstation: tools.workstation)
            try Task.checkCancellation()
            await beginStep(es ? "Redactando la respuesta" : "Writing the answer", in: ref)
            var answer = try await consolidate(userText: userMessage.text, missions: run.mission.map { [$0] } ?? [], coordinator: coordinator, context: context, history: history, language: language)
            let split = ConversationPrompts.extractSuggestions(answer)
            if !split.text.isEmpty { answer = split.text }
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let fileIDs = Array(NSOrderedSet(array: state.writtenFiles).array.compactMap { $0 as? String }) as [String]
            let completed = try await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { message in
                message.text = trimmed.isEmpty ? (run.mission?.finalReport ?? run.outcome.resultText) : trimmed
                message.status = .complete
                message.activity = message.activity.map { line in
                    var line = line
                    if line.agentName == "Ada" { line.summary = es ? "Respuesta consolidada" : "Response consolidated" }
                    line.state = "done"
                    return line
                }
                message.fileIDs = fileIDs
                message.quickReplies = split.suggestions
                Self.settleSteps(&message.steps, as: "done")
                message.completedAt = Date()
            }
            if let assistant = completed.messages.first(where: { $0.id == ref.responseID }) {
                remember(conversationID: ref.conversationID, ownerID: ref.ownerID, user: userMessage, assistant: assistant, coordinator: coordinator)
            }
        } catch {
            let stopped = error is CancellationError
            _ = try? await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { message in
                guard message.status == .running else { return }
                message.status = .failed
                message.text = stopped ? (es ? "Trabajo detenido." : "Job stopped.") : (es ? "No pude terminar el trabajo. \(error.localizedDescription)" : "I couldn’t finish the job. \(error.localizedDescription)")
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
        /// The person's language ("en" or "es"), for the live step labels.
        var language: String = "en"
        /// The person's message answers a choice card, so another card would only stall the work.
        var answeredChoice: Bool = false
    }

    /// The labels of the steps between tool calls, where Ada is working something out or writing.
    enum StepLabel {
        static func thinking(_ language: String) -> String { language == "es" ? "Pensándolo" : "Thinking it through" }
        static func reviewing(_ language: String) -> String { language == "es" ? "Revisando lo que encontré" : "Reviewing what I found" }
        static func nextStep(_ language: String) -> String { language == "es" ? "Decidiendo el siguiente paso" : "Working out the next step" }
        static func writing(_ language: String) -> String { language == "es" ? "Redactando la respuesta" : "Writing the answer" }
        static func choosing(_ language: String) -> String { language == "es" ? "Eligiendo la mejor forma de ayudar" : "Choosing how to help" }

        /// The step after a round of tools: reading what came back, or deciding what to do after a change.
        static func afterTools(_ names: [String], language: String) -> String {
            names.allSatisfy { ToolCatalog.spec($0)?.access == .read } ? reviewing(language) : nextStep(language)
        }

        /// True while the model is still working out what to do, so the first streamed words can
        /// turn the step into "Writing the answer". A tool's step is never replaced this way.
        static func isWaiting(_ label: String) -> Bool {
            ["en", "es"].contains { label == thinking($0) || label == reviewing($0) || label == nextStep($0) || label == choosing($0) }
        }
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
            Self.advanceStep(&message, to: label)
        }
    }

    /// Finishes the working step and starts `label`; Ada's activity line mirrors it.
    static func advanceStep(_ message: inout ConversationMessage, to label: String) {
        if message.steps.last?.label == label && message.steps.last?.state == "working" { return }
        // Words written just before a tool call were a lead-in, not the answer: that step gives way.
        if let last = message.steps.last, last.state == "working", ["en", "es"].contains(where: { last.label == StepLabel.writing($0) }) {
            message.steps.removeLast()
        }
        settleSteps(&message.steps, as: "done")
        message.steps.append(MessageStep(label: label))
        if let index = message.activity.firstIndex(where: { $0.agentName == "Ada" }) {
            message.activity[index].summary = label
            message.activity[index].state = "working"
            message.activity[index].updatedAt = Date()
        }
    }

    /// How long workspace knowledge is reused between messages before the workspace is looked at again.
    static let knowledgeFreshSeconds: TimeInterval = 300

    private func drive(conversationID: UUID, ownerID: String, userMessage: ConversationMessage, responseID: UUID, launchedBy: String, language: String) async {
        defer { running[conversationID] = nil }
        let ref = ResponseRef(conversationID: conversationID, ownerID: ownerID, responseID: responseID, spoken: userMessage.spoken, launchedBy: launchedBy, language: language == "es" ? "es" : "en", answeredChoice: userMessage.choiceReply != nil)
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
            let skillList = await skills.enabled(for: ownerID)
            let providers = await store.loadProviders()
            let coordinator = try coordinator(providers: providers)
            // Voice: say a few words right away while the real answer is worked out. It runs beside
            // the reply and is dropped if the reply finishes first.
            let acknowledgement = userMessage.spoken && !userMessage.scheduled
                ? Task { await self.acknowledge(userMessage, previous: conversation.messages, coordinator: coordinator, providers: providers, language: language, ref: ref) }
                : nil
            defer { acknowledgement?.cancel() }
            let catalog = SkillTeams.catalog(skillList)
            let history = conversation.messages.filter { $0.status != .running && (!$0.text.isEmpty || !$0.photos.isEmpty) }
            let workspaceMemory = await memory.state(ownerID: ownerID)
            let memoryText = workspaceMemory.promptText
            // Knowledge written in the last few minutes is used as it is; looking again reads every chat.
            let currentKnowledge = await knowledge?.refresh(ownerID: ownerID, freshFor: Self.knowledgeFreshSeconds)
            let context = await promptContext(conversation: conversation, history: history, memory: memoryText, knowledge: currentKnowledge?.stablePromptSummary ?? "", activity: currentKnowledge?.activityPromptSummary ?? "", scheduled: userMessage.scheduled, spoken: userMessage.spoken, personName: userMessage.scheduled ? nil : launchedBy, event: userMessage.trigger)
            // Photos: only Ada's direct reply looks at them. Routing, missions, and consolidation get a
            // note that they exist, which is enough to pick DIRECT and keeps those calls cheap.
            // Photos go to the configured vision model when there is one; otherwise Ada's own model looks.
            let replyCoordinator = await visionCoordinator(for: coordinator, providers: providers, hasPhotos: !userMessage.photos.isEmpty)
            // A model chosen as the vision model is trusted to see, whatever its family name suggests.
            let canSee = replyCoordinator != coordinator || providers.first(where: { $0.id == replyCoordinator.providerID }).map { VisionSupport.accepts(provider: $0, model: replyCoordinator.model) } ?? true
            let userText = Self.textWithPhotoNote(userMessage)
            let photoInput = canSee ? photoInputs(conversationID: conversationID, current: userMessage, history: history) : PhotoInputs()
            let directText = Self.directText(for: userMessage, canSee: canSee, model: replyCoordinator.model, language: language)
            // Without routing, and on the voice fast path (a quick spoken question), Ada answers directly:
            // one loop, where she can still delegate to helpers or start a task.
            var decision: ConversationDecision?
            if !routing || Self.isQuickSpokenQuestion(userMessage, history: history) {
                decision = ConversationDecision(action: .direct)
            } else {
                decision = try await route(userText: userText, coordinator: coordinator, skills: catalog, context: context, history: history, language: language)
            }
            if decision == nil {
                let retrySystem = ConversationPrompts.routingSystem(coordinator: coordinator, skills: catalog, context: context, store: promptStore, language: language) + "\nYour previous response was not valid. Return exactly one JSON object matching the contract, with a valid action."
                let retry = try await complete(coordinator: coordinator, system: retrySystem, messages: Self.chatTurns(from: history.dropLast()) + [.user(context.userTurn(userText))], tools: nil, purpose: "route")
                decision = ConversationDecision.parse(retry.message.content ?? "")
            }

            var responseText: String
            var activity = [AgentActivity(agentID: coordinator.id, agentName: "Ada", summary: language == "es" ? "Respondiendo directamente" : "Answering directly", state: "working")]
            var quickReplies: [String] = []
            var writtenFiles: [String] = []
            var toolLog: [String] = []

            switch decision?.action {
            case .solo, .useSkill, .routeTeam:
                // The older routing call (AGENTSAM_ROUTING=1) still picks SOLO or a skill; both now run
                // as helper tasks, exactly like start_task: planned steps, a helper per step, judgeAda's check.
                let chosen: [Skill?] = decision?.action == .solo ? [nil] : routedSkills(for: decision, skills: skillList)
                if chosen.isEmpty {
                    await beginStep(StepLabel.thinking(language), in: ref)
                    responseText = try await directAnswer(userText: directText, photos: photoInput, coordinator: replyCoordinator, context: context, history: history, language: language, ref: ref, conversationID: conversationID, writtenFiles: &writtenFiles, toolLog: &toolLog)
                } else {
                    activity[0].summary = shortSummary(decision?.rationale ?? decision?.message, fallback: es ? "Trabajando con mis especialistas" : "Working with my specialists")
                    _ = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                        message.activity = activity
                    }
                    let tools = await directTools(ref: ref, context: context)
                    let state = ToolRunState()
                    var finished: [Mission] = []
                    for skill in chosen {
                        var arguments: [(String, JSONValue)] = [("objective", .string(String(userText.prefix(8_000))))]
                        if let skill { arguments.append(("skill", .string(skill.id))) }
                        let call = APIToolCall(id: UUID().uuidString, function: .init(name: TaskTools.startToolName, arguments: TaskTools.json(.object(arguments))))
                        let run = await runTask(call: call, parent: tools.offered, state: state, coordinator: coordinator, context: context, language: language, ref: ref, conversationID: conversationID, workstation: tools.workstation)
                        if let mission = run.mission { finished.append(mission) }
                        try Task.checkCancellation()
                    }
                    writtenFiles.append(contentsOf: state.writtenFiles)
                    await beginStep(chosen.count > 1 ? (es ? "Combinando los resultados" : "Combining the results") : writing, in: ref)
                    responseText = try await consolidate(userText: userText, missions: finished, coordinator: coordinator, context: context, history: history, language: language)
                    activity[0].summary = es ? "Respuesta consolidada" : "Response consolidated"
                }
            case .clarify:
                responseText = decision?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if responseText.isEmpty { responseText = language == "es" ? "¿Qué resultado te gustaría conseguir?" : "What outcome would you like to achieve?" }
                activity[0].summary = language == "es" ? "Una pregunta antes de continuar" : "One question before continuing"
                quickReplies = ConversationMessage.cleanQuickReplies(decision?.options ?? [])
            case .direct, .proposeTeam, nil:
                // Teams are no longer proposed to people; an older stored prompt that still asks to
                // propose one gets a direct answer instead.
                await beginStep(StepLabel.thinking(language), in: ref)
                responseText = try await directAnswer(userText: directText, photos: photoInput, coordinator: replyCoordinator, context: context, history: history, language: language, ref: ref, conversationID: conversationID, writtenFiles: &writtenFiles, toolLog: &toolLog)
            }

            if decision?.action != .clarify {
                // Split even in voice mode, so a stray block never reaches the speaker.
                let split = ConversationPrompts.extractSuggestions(responseText)
                if !split.text.isEmpty {
                    responseText = split.text
                    quickReplies = split.suggestions
                }
            }
            // A spoken reply is shown and read the same: what Ada says matches the chat word for word.
            var speech: String? = nil
            if userMessage.spoken { responseText = ConversationPrompts.extractDetails(responseText).screen }

            try Task.checkCancellation()
            var trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            // A reply that ends on a choice card: its text is the card's lead-in, or the first question
            // when Ada wrote none. It is read aloud with the questions and options, and the card
            // takes the place of suggested replies.
            if let asked = try await conversations.get(id: conversationID, ownerID: ownerID)?.messages.first(where: { $0.id == responseID })?.choice, let first = asked.questions.first {
                if trimmed.isEmpty { trimmed = first.question }
                quickReplies = []
                let card = ChoiceCardTools.spokenText(asked, language: SpokenNumbers.language(of: trimmed, fallback: language))
                speech = trimmed == first.question ? card : trimmed + "\n\n" + card
            }
            guard !trimmed.isEmpty else { throw ConversationError.persistence("Ada received an empty response from the model. Please try again.") }
            for index in activity.indices { activity[index].state = "done" }
            let fileIDs = Array(NSOrderedSet(array: writtenFiles).array.compactMap { $0 as? String }) as [String]
            let completed = try await conversations.updateMessage(id: conversationID, ownerID: ownerID, messageID: responseID) { message in
                message.text = trimmed
                message.speech = speech
                message.status = .complete
                // Helpers Ada delegated to stay on the reply, so the app can show who worked on it.
                let helpers = message.activity.filter { line in line.teamName == HelperTools.activityLabel && !activity.contains { $0.id == line.id } }.map { line -> AgentActivity in
                    var line = line
                    if line.state == "working" { line.state = "done" }
                    return line
                }
                message.activity = activity + helpers
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

    /// The skills to run for a USE_SKILL decision, at most three. Skills are matched by ID or name;
    /// an older ROUTE_TEAM decision is matched by the team each skill was migrated from.
    private func routedSkills(for decision: ConversationDecision?, skills: [Skill]) -> [Skill] {
        var chosen: [Skill] = []
        for id in decision?.skillIDs ?? [] {
            let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let skill = skills.first(where: { $0.id == key || $0.name.lowercased() == key }), !chosen.contains(skill) { chosen.append(skill) }
        }
        for id in decision?.teamIDs ?? [] {
            if let skill = skills.first(where: { $0.teamID == id }), !chosen.contains(skill) { chosen.append(skill) }
        }
        return Array(chosen.prefix(3))
    }

    /// Ada's profile for a reply that carries photos: the vision model chosen in settings, or the
    /// image processor provider when Ada's own model cannot see and that provider has a key.
    /// Without photos, or with no usable choice, Ada keeps her own model.
    private func visionCoordinator(for ada: AgentProfile, providers: [ProviderConfig], hasPhotos: Bool) async -> AgentProfile {
        guard hasPhotos else { return ada }
        var target: VisionModelSetting? = await store.loadVisionModel()
        if target == nil {
            let adaCanSee = providers.first(where: { $0.id == ada.providerID }).map { VisionSupport.accepts(provider: $0, model: ada.model) } ?? true
            if adaCanSee { return ada }
            if let fallback = providers.first(where: { $0.id == "image-processor" }) {
                target = VisionModelSetting(providerID: fallback.id, model: fallback.defaultModel ?? fallback.models.first ?? "")
            }
        }
        guard let target, let provider = providers.first(where: { $0.id == target.providerID }),
              keyRing.get(provider.keyAccount) != nil, !target.model.isEmpty else { return ada }
        var vision = ada
        vision.providerID = provider.id
        vision.model = target.model
        return vision
    }

    /// The model that looks at Ada's browser screenshots for her: the vision model chosen in
    /// settings, or her own model when it can see, or the image processor provider. A model an
    /// admin chose is trusted as chosen (if it refuses pictures, the error says so); Ada's own
    /// model is used only when it is known to see. Nil when there is none.
    private func screenshotViewer(for ada: AgentProfile) async -> BrowserTools.Viewer? {
        let providers = await store.loadProviders()
        let viewer = await visionCoordinator(for: ada, providers: providers, hasPhotos: true)
        guard let provider = providers.first(where: { $0.id == viewer.providerID }), keyRing.get(provider.keyAccount) != nil else { return nil }
        let chosen = viewer.providerID != ada.providerID || viewer.model != ada.model
        guard chosen || VisionSupport.accepts(provider: provider, model: viewer.model) else { return nil }
        return BrowserTools.Viewer(model: viewer.model) { [self] image, prompt in
            let reply = try await self.complete(coordinator: viewer, system: BrowserTools.visionSystem, messages: [.user(prompt, images: [image])], tools: nil, maxTokens: 1_500, purpose: "vision")
            return reply.message.content ?? ""
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

    /// The ID of the one-agent "Ada (solo)" team older releases saved for SOLO missions. Kept so a
    /// saved copy is never migrated into a skill.
    public static let soloTeamID = UUID(uuidString: "AE4DA0A1-5F1D-4C4B-9A5A-DACA0E1E0F1F")!

    /// Earlier turns as real chat messages, oldest first, ending on an assistant turn so the caller can
    /// append the user's latest message. Consecutive same-role turns are merged because providers
    /// expect alternating roles (a failed reply leaves two user messages in a row).
    static let maxToolLogEntries = 12

    /// "chat_read_file {"path":"notes.md"} → ok" or "… → failed: reason", short enough to carry in history.
    static func toolLogLine(call: APIToolCall, outcome: ToolOutcome) -> String {
        // A card's data is on screen and in the message; the log only needs to say which card it was.
        if call.function.name == InfoCardTools.toolName, outcome.succeeded, case .success(let card) = InfoCardTools.card(from: AgentTools.arguments(of: call)) {
            return card.logLine + " → ok"
        }
        // A choice card's questions and options, so a later turn knows what the person's answers are to.
        if call.function.name == ChoiceCardTools.toolName, outcome.succeeded, case .success(let card) = ChoiceCardTools.card(from: AgentTools.arguments(of: call)) {
            return card.logLine + " → shown; the person's next message answers it"
        }
        let arguments = call.function.arguments.replacingOccurrences(of: "\n", with: " ")
        let shortArguments = arguments.count > 120 ? String(arguments.prefix(120)) + "…" : arguments
        let firstLine = outcome.resultText.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let result = outcome.succeeded ? "ok" : "failed: " + String(firstLine.prefix(120))
        return "\(call.function.name) \(shortArguments) → \(result)"
    }

    static func chatTurns(from history: [ConversationMessage], limit: Int = 40, characters: Int = 6_000, images: [UUID: [APIImage]] = [:]) -> [APIMessage] {
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
        let reply = try await complete(coordinator: coordinator, system: system, messages: Self.chatTurns(from: history.dropLast()) + [.user(context.userTurn(userText))], tools: nil, purpose: "route")
        return ConversationDecision.parse(reply.message.content ?? "")
    }

    /// Model calls with tools in one direct reply before Ada must answer without them.
    static let maxToolRounds = 20

    /// The tools offered to Ada's direct reply, and to the helpers and tasks that run inside it.
    private func directTools(ref: ResponseRef?, context: ConversationPromptContext) async -> (offered: OfferedTools, connectorTools: [APIToolDef], workstation: Workstation?) {
        // The connectors and MCP servers hold the server's shared credentials: only owners an admin allowed get them.
        let sharedAllowed = await mayUseSharedAccounts(ownerID: ref?.ownerID)
        let connectorTools = sharedAllowed ? (await connectors?.toolDefs(readOnly: access == nil) ?? []) : []
        // Only tools offered in this request may run, and each runs by the family it was offered from.
        let workstation = await workstation(ownerID: ref?.ownerID)
        let mcpTools = sharedAllowed ? (await access?.mcp?.toolDefs() ?? []) : []
        // Handing work to a task needs a user-owned reply to show its progress in.
        let taskTools = ref == nil ? [] : TaskTools.definitions(catalog: SkillTeams.catalog(await skills.enabled(for: ref?.ownerID)))
        // Helpers run inside this reply, so they need a user-owned reply to show their work in too.
        // Proposing a saved helper role needs an approval card, so it is offered only with access.
        let hasBrowser = await browser(ownerID: ref?.ownerID) != nil
        let delegateTools = ref == nil ? [] : HelperTools.definitions(hasWorkstation: workstation != nil, hasMCP: !mcpTools.isEmpty, hasBrowser: hasBrowser, saved: await helpers.all(ownerID: ref?.ownerID), canSave: access != nil, skills: await skills.enabled(for: ref?.ownerID).map(\.id))
        let offered = OfferedTools.direct(connectorTools: connectorTools, hasLinkedMissions: !context.missionIDs.isEmpty, hasExtendedAccess: access != nil, hasWorkstation: workstation != nil, hasBrowser: hasBrowser, browserOpen: Self.browserInUse(history: context.history), mcpTools: mcpTools, taskTools: taskTools, delegateTools: delegateTools, cards: ref != nil, cardsOpen: Self.cardsInUse(history: context.history), choices: ref != nil)
        return (offered, connectorTools, workstation)
    }

    /// Replies back that count as "cards are in use", so show_card is sent from the start.
    static let cardHistoryWindow = 6

    /// Whether one of Ada's replies in this chat used her browser. Then a page is likely open and
    /// the person may come back to it at any point, so every browser tool is sent from the first
    /// call for the rest of the chat. Otherwise only `browser_open`, `browser_look` and
    /// `browser_tabs` are, and the rest follow once she uses one of them or the person asks her
    /// to act on a page.
    public static func browserInUse(history: [ConversationMessage]) -> Bool {
        history.contains { $0.role == .assistant && $0.usedBrowser }
    }

    /// Whether one of Ada's recent replies showed a card: then the person likely wants more of them,
    /// so show_card is sent from the first call. Otherwise it follows once she has used a tool.
    public static func cardsInUse(history: [ConversationMessage]) -> Bool {
        history.suffix(cardHistoryWindow).contains { $0.role == .assistant && !$0.cards.isEmpty }
    }

    private func directAnswer(userText: String, photos photoInput: PhotoInputs = PhotoInputs(), coordinator: AgentProfile, context: ConversationPromptContext, history: [ConversationMessage], language: String, ref: ResponseRef? = nil, conversationID: UUID, writtenFiles: inout [String], toolLog: inout [String]) async throws -> String {
        let direct = await directTools(ref: ref, context: context)
        let connectorTools = direct.connectorTools
        let workstation = direct.workstation
        // A message that asks for a card or a click gets those tools from the first call.
        var offeredTools = direct.offered.revealing(askedFor: userText)
        let system = ConversationPrompts.directResponseSystem(coordinator: coordinator, context: context, connectorTools: connectorTools, hasLinkedMissions: !context.missionIDs.isEmpty, hasExtendedTools: access != nil, store: promptStore, language: language)
        let text = context.userTurn(userText)
        // The context now rides in the user turn instead of the system prompt; budget for it on top
        // of the conversation, as before, so it doesn't crowd out earlier turns.
        let allowance = ConversationCompactor.estimateTokens(context.turnPreamble)
        var messages = Self.chatTurns(from: history.dropLast(), images: photoInput.history)
        messages.append(.user(text, images: photoInput.current))
        let state = ToolRunState()
        let summaries = ConversationCompactor.SummaryState()
        let replyCap = await replySpendCap(ownerID: ref?.ownerID)
        var overCap = false
        for round in 0..<Self.maxToolRounds {
            try Task.checkCancellation()
            let stream = streamer(for: ref)
            let reply = try await completeDirect(coordinator: coordinator, system: system, messages: messages, tools: offeredTools.definitions, contextAllowance: allowance, summaries: summaries, onDelta: stream?.handler)
            messages.append(reply.message)
            let calls = reply.message.tool_calls ?? []
            if calls.isEmpty { return reply.message.content ?? "" }
            // Text before a tool call is a preamble, not the answer; drop it so the next turn starts clean.
            // Closing the stream keeps a late flush from bringing the preamble back over a tool's step.
            stream?.close()
            if stream != nil { await publishPartial("", in: ref) }
            for asked in calls {
                // A file or terminal call for the project runs as its project tool.
                let call = offeredTools.resolved(asked)
                await beginStep(ToolCatalog.label(for: call, language: language), in: ref)
                let outcome = await executeTool(call: call, offeredTools: offeredTools, state: state, context: context, language: language, ref: ref, conversationID: conversationID, coordinator: coordinator, workstation: workstation)
                writtenFiles.append(contentsOf: state.writtenFiles)
                state.writtenFiles = []
                let shown = Self.workstationFallback(toolName: call.function.name, outcome: outcome, hasWorkstation: workstation != nil)
                messages.append(.tool(id: call.id, content: String(shown.resultText.prefix(32_000)), isError: !shown.succeeded))
                if toolLog.count < Self.maxToolLogEntries { toolLog.append(Self.toolLogLine(call: call, outcome: shown)) }
                // Once Ada uses her browser, the tools that act on a page are sent from the next call on.
                if offeredTools.family(of: call.function.name) == .browser, offeredTools.holds(.browser) {
                    offeredTools = offeredTools.revealing(.browser)
                }
            }
            // A choice card ends the reply: the person answers next. Its lead-in text, if any, is the reply.
            if state.choice != nil { return DSMLToolCalls.strip(reply.message.content ?? "") }
            // Once Ada has used a tool she may have data worth a card, so show_card is sent from the next call.
            if offeredTools.holds(.card) { offeredTools = offeredTools.revealing(.card) }
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
            await beginStep(StepLabel.afterTools(calls.map(\.function.name), language: language), in: ref)
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
        let final = try await completeDirect(coordinator: coordinator, system: system, messages: messages, tools: nil, maxTokens: context.spoken ? Self.voiceMaxTokens : nil, contextAllowance: allowance, summaries: summaries, onDelta: streamer(for: ref)?.handler)
        let answer = final.message.content ?? ""
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return language == "es"
                ? "Usé todos los pasos de herramientas de esta respuesta antes de terminar. Pídeme que continúe y seguiré desde aquí."
                : "I used all the tool steps for this reply before finishing. Ask me to continue and I will pick up from here."
        }
        return answer
    }

    /// Mutable counters for one tool loop: the run budget, how many tasks started, whether a
    /// self-review ran, and the files written so far. One per reply, or one per helper.
    final class ToolRunState {
        var runs = 0
        var tasks = 0
        var delegations = 0
        var helperSaves = 0
        var cards = 0
        /// The choice card asked in this reply; the reply ends once it is shown.
        var choice: ChoiceCard?
        /// Set once a self-review runs: memory and skill tools then only suggest.
        var reviewed = false
        var writtenFiles: [String] = []
    }

    /// Runs one tool call. The call must have been offered in this request: the family it was
    /// offered from decides how it runs, which is the same for Ada and for the helpers she delegates to.
    private func executeTool(call: APIToolCall, offeredTools: OfferedTools, state: ToolRunState, context: ConversationPromptContext, language: String, ref: ResponseRef?, conversationID: UUID, coordinator: AgentProfile, workstation: Workstation?) async -> ToolOutcome {
        let offered = offeredTools.names
        let outcome: ToolOutcome
        switch offeredTools.family(of: call.function.name) {
        case nil, .worker:
            outcome = .failure(Self.unknownToolMessage(call.function.name, offered: offered))
        case .chat:
            if call.function.name == "run_program" {
                state.runs += 1
                if state.runs > ChatWorkspaceTools.maxRunsPerTurn {
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
                state.writtenFiles.append(contentsOf: outcome.wroteFiles)
                if let ref { await access?.audit.record(ownerID: ref.ownerID, action: "conversation.write", detail: outcome.wroteFiles.joined(separator: ", ")) }
            }
        case .extended:
            guard let access else { outcome = .failure("Workspace access is not available here."); break }
            let isTerminal = call.function.name == "run_terminal" || call.function.name == "project_terminal"
            if isTerminal { state.runs += 1 }
            if isTerminal && state.runs > ChatWorkspaceTools.maxRunsPerTurn {
                outcome = .failure("Program and terminal run limit reached for this reply (\(ChatWorkspaceTools.maxRunsPerTurn)).")
            } else {
                let project = ProjectScope(ownerID: ref?.ownerID ?? "", projectName: context.projectName)
                outcome = await ExtendedWorkspaceTools.run(call: call, workspace: workspace, conversationID: conversationID, project: project, terminal: access.terminal, hosts: access.hosts, actions: access.actions, audit: access.audit)
            }
            if !outcome.wroteFiles.isEmpty { state.writtenFiles.append(contentsOf: outcome.wroteFiles) }
        case .skill:
            if state.reviewed { outcome = .failure(SelfReviewTools.applyLaterMessage) } else { outcome = await SkillTools.run(call: call, skills: skills, ownerID: ref?.ownerID) }
        case .task:
            state.tasks += 1
            if state.tasks > TaskTools.maxPerReply {
                outcome = .failure("Job limit reached for this reply (\(TaskTools.maxPerReply)). Finish with what you have.")
            } else if let ref {
                outcome = await startTask(call: call, parent: offeredTools, state: state, coordinator: coordinator, context: context, language: language, ref: ref, conversationID: conversationID, workstation: workstation)
            } else {
                outcome = .failure("Jobs need a user-owned conversation.")
            }
        case .delegate where call.function.name == HelperTools.saveToolName:
            state.helperSaves += 1
            if state.reviewed {
                outcome = .failure(SelfReviewTools.applyLaterMessage)
            } else if state.helperSaves > HelperTools.maxSavesPerReply {
                outcome = .failure("Specialist role proposal limit reached for this reply (\(HelperTools.maxSavesPerReply)).")
            } else if let ref, let access {
                outcome = await proposeHelper(call: call, access: access, ref: ref, conversationID: conversationID, language: language)
            } else {
                outcome = .failure("Saving a specialist role needs a user-owned conversation with approvals.")
            }
        case .delegate:
            state.delegations += 1
            if state.delegations > HelperTools.maxPerReply {
                outcome = .failure("Specialist limit reached for this reply (\(HelperTools.maxPerReply)). Finish with what you have.")
            } else if let ref {
                outcome = await runHelper(call: call, parent: offeredTools, state: state, context: context, language: language, ref: ref, conversationID: conversationID, coordinator: coordinator, workstation: workstation)
            } else {
                outcome = .failure("Specialists need a user-owned conversation.")
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
            if state.reviewed { outcome = .failure(SelfReviewTools.applyLaterMessage) } else { outcome = await MemoryTools.run(call: call, memory: memory, ownerID: ref?.ownerID) }
        case .card:
            state.cards += 1
            if state.cards > InfoCardTools.maxPerReply {
                outcome = .failure("Card limit reached for this reply (\(InfoCardTools.maxPerReply)). Say the rest in text.")
            } else if let ref {
                outcome = await showCard(call: call, in: ref, number: state.cards)
            } else {
                outcome = .failure("Cards need a chat reply to appear in.")
            }
        case .choice:
            if state.choice != nil {
                outcome = .failure("A choice card is already shown in this reply; put every question in that one card.")
            } else if ref?.answeredChoice == true {
                // The person just answered a card: a second card in a row stalls the work.
                outcome = .failure("The person just answered your choice card. Do the work now with their answers, and assume what you must; say what you assumed.")
            } else if context.scheduled {
                outcome = .failure("This run was started by a schedule or trigger, so nobody is here to tap a card. Decide yourself, or ask in your text.")
            } else if let ref {
                outcome = await askChoice(call: call, in: ref, state: state)
            } else {
                outcome = .failure("Choice cards need a chat reply to appear in.")
            }
        case .selfReview:
            // From here on this reply only suggests; memory and skill tools refuse until the user picks.
            state.reviewed = true
            outcome = await SelfReviewTools.run(call: call, ownerID: ref?.ownerID, conversations: conversations, missions: store, actions: access?.actions, spend: access?.spend)
        case .mission:
            outcome = await ConversationMissionTools.run(call: call, store: store, allowedMissionIDs: Set(context.missionIDs))
        case .workstation:
            guard let workstation, let access, let ref else { outcome = .failure("Workstation access is not available here."); break }
            guard WorkstationTools.approvalNames.contains(call.function.name) else {
                outcome = await WorkstationTools.run(call: call, workstation: workstation)
                break
            }
            state.runs += 1
            if state.runs > ChatWorkspaceTools.maxRunsPerTurn {
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
        case .browser:
            guard let access, let ref, let link = await browser(ownerID: ref.ownerID) else { outcome = .failure("Ada's browser is not available here."); break }
            await markUsedBrowser(in: ref)
            let workspace = self.workspace
            let see = call.function.name == "browser_screenshot" ? await screenshotViewer(for: coordinator) : nil
            let step = await BrowserTools.run(call: call, link: link, see: see, readFile: { name in
                await workspace.readData(conversationID: conversationID, name: name, limit: BrowserTools.maxFileBytes)
            }) { name, data in
                await workspace.writeData(conversationID: conversationID, name: name, data: data, limit: 4_000_000)
            }
            switch step {
            case .done(let result):
                outcome = result
                if !result.wroteFiles.isEmpty { state.writtenFiles.append(contentsOf: result.wroteFiles) }
                if !BrowserTools.readNames.contains(call.function.name) {
                    await access.audit.record(ownerID: ref.ownerID, action: "browser.action", detail: BrowserTools.auditLine(call: call) + (result.succeeded ? "" : " (did not run)"))
                }
            case .needsApproval(let title, let detail, let arguments, let risk):
                let lifetime = await access.permissions.approvalLifetime(ownerID: ref.ownerID)
                let action = AgentActionRequest(
                    ownerID: ref.ownerID, conversationID: conversationID, kind: .browser,
                    title: title, detail: detail,
                    toolName: call.function.name, arguments: .object([("raw", .string(arguments))]), lifetime: lifetime
                )
                let saved = await access.actions.request(action)
                await access.audit.record(ownerID: ref.ownerID, action: "browser.approval-requested", detail: "\(risk.rawValue): \(title.prefix(200))")
                outcome = ToolOutcome(resultText: "Approval requested (\(saved.id.uuidString)): this would \(risk.phrase), so the person approves it on a card; this is the routine flow. Do not retry it and do not ask whether to go ahead. Nothing has happened yet. Do other work that does not depend on it, or end your reply saying it is waiting for approval. Once approved it runs once, only on this same page, and the outcome appears under approval requests on a later turn; look at the page again then.")
            }
        case .mcp:
            guard let mcp = access?.mcp, await mayUseSharedAccounts(ownerID: ref?.ownerID) else { outcome = .failure("MCP servers are not available here."); break }
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
            guard let connectors, await mayUseSharedAccounts(ownerID: ref?.ownerID) else { outcome = .failure("No connector is available for this tool."); break }
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
                    outcome = ToolOutcome(resultText: "Approval requested (\(saved.id.uuidString)).\(why) The user sees the approval card with the exact action and approves or denies it there; this is the routine flow. Do not retry this write, do not explain approvals or point the user to the card, and do not ask whether to go ahead. Nothing has run yet; the outcome will appear under approval requests in your context on a later turn.")
                } else {
                    outcome = .failure("Connector approvals are not available. No external write was performed.")
                }
            } else {
                outcome = .failure("A user-owned conversation is required to approve connector writes.")
            }
        }
        return outcome
    }

    /// Puts Ada's proposed helper role on an approval card. It always asks: no standing permission
    /// covers it, and the approval route applies it (see AccessRoutes).
    private func proposeHelper(call: APIToolCall, access: ConversationAccess, ref: ResponseRef, conversationID: UUID, language: String) async -> ToolOutcome {
        let request: HelperTools.SaveRequest
        switch HelperTools.saveRequest(from: call) {
        case .failure(let error): return .failure(error.message)
        case .success(let valid): request = valid
        }
        let current = await helpers.helper(for: request.function, ownerID: ref.ownerID)
        if request.undo && current == nil { return .failure("There is no saved role for \(request.name) to undo.") }
        let card = HelperTools.card(for: request, current: current, language: language)
        let lifetime = await access.permissions.approvalLifetime(ownerID: ref.ownerID)
        let action = AgentActionRequest(
            ownerID: ref.ownerID, conversationID: conversationID, kind: .helperSave,
            title: card.title, detail: card.detail,
            toolName: call.function.name, arguments: .object([("raw", .string(call.function.arguments))]), lifetime: lifetime
        )
        let saved = await access.actions.request(action)
        await access.audit.record(ownerID: ref.ownerID, action: "helper.proposed", detail: "\(request.name)\(request.undo ? " undo" : ""): \(request.reason.prefix(200))")
        return ToolOutcome(resultText: "Approval requested (\(saved.id.uuidString)). The user sees the proposed role on an approval card and approves or denies it there; this is the routine flow. Do not retry this call. Nothing has changed yet; until it is approved, specialists keep their current role.")
    }

    /// Runs one `delegate` call to the end: the helper gets the tools Ada handed it (a subset of her
    /// own, dispatched exactly as hers are), works for a few rounds, and reports back. Approval cards,
    /// standing permissions, the run budget and the spending limit apply as they do for Ada.
    private func runHelper(call: APIToolCall, parent: OfferedTools, state: ToolRunState, context: ConversationPromptContext, language: String, ref: ResponseRef, conversationID: UUID, coordinator: AgentProfile, workstation: Workstation?, maxRounds: Int = HelperTools.maxRounds) async -> ToolOutcome {
        let request: HelperTools.Request
        switch HelperTools.request(from: call, saved: await helpers.all(ownerID: ref.ownerID)) {
        case .failure(let error): return .failure(error.message)
        case .success(var valid):
            if let id = valid.skillID {
                guard let skill = await skills.skill(id: id, for: ref.ownerID), skill.enabled else {
                    let known = await skills.enabled(for: ref.ownerID).map(\.id).joined(separator: ", ")
                    return .failure("No enabled skill \"\(id)\". Enabled skills: \(known.isEmpty ? "none" : known). Leave skill out, or put the steps in the brief.")
                }
                valid.procedure = String(SkillTeams.procedureBlock(skill).trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
            }
            request = valid
        }
        // A specialist has a narrow job and a short run, so it gets every tool its groups allow at once.
        let offeredTools = parent.restricted { name, family in HelperTools.allows(name: name, family: family, groups: request.groups) }.revealingAll()
        let es = language == "es"
        await beginStep(es ? "\(request.name) está trabajando" : "\(request.name) is working", in: ref)
        var line = AgentActivity(agentID: UUID(), agentName: request.name, summary: HelperTools.firstLine(request.task, limit: 160), state: "working", teamName: HelperTools.activityLabel)
        await showHelper(line, in: ref)
        await access?.audit.record(ownerID: ref.ownerID, action: "delegate", detail: "\(request.name) [\(request.groups.map(\.rawValue).sorted().joined(separator: ","))]: \(request.task.prefix(200))")
        let system = HelperTools.systemPrompt(request: request, language: language, tools: offeredTools.definitions.map(\.function.name).sorted())
        var messages: [APIMessage] = [.user(request.task)]
        let helperState = ToolRunState()
        var toolLog: [String] = []
        var rounds = 0
        var stopped = false
        let replyCap = await replySpendCap(ownerID: ref.ownerID)
        // Specialists run on the provider's fast model; judgeAda keeps Ada's own.
        var profile = Self.specialistProfile(for: coordinator, function: request.function, providers: await store.loadProviders())
        do {
            var report = ""
            var finished = false
            for _ in 0..<maxRounds {
                try Task.checkCancellation()
                let reply: LLMReply
                do {
                    reply = try await complete(coordinator: profile, system: system, messages: messages, tools: offeredTools.definitions.isEmpty ? nil : offeredTools.definitions, purpose: "helper")
                } catch let error as LLMError where rounds == 0 && profile.model != coordinator.model && Self.mayBeModelRejection(error) {
                    // The provider does not know the fast model (an older account, a proxy with other
                    // names). Do the work on Ada's own model rather than fail the specialist.
                    await access?.audit.record(ownerID: ref.ownerID, action: "delegate.model_fallback", detail: "\(request.name): \(profile.model) refused (\(error.message.prefix(160))); using \(coordinator.model)")
                    profile = coordinator
                    reply = try await complete(coordinator: profile, system: system, messages: messages, tools: offeredTools.definitions.isEmpty ? nil : offeredTools.definitions, purpose: "helper")
                }
                rounds += 1
                messages.append(reply.message)
                let calls = reply.message.tool_calls ?? []
                if calls.isEmpty {
                    report = reply.message.content ?? ""
                    finished = true
                    break
                }
                for askedInner in calls {
                    let inner = offeredTools.resolved(askedInner)
                    // The helper's own tool calls show as steps too: "researchAda: Searching the web for …".
                    await beginStep("\(request.name): \(ToolCatalog.label(for: inner, language: language))", in: ref)
                    let outcome = await executeTool(call: inner, offeredTools: offeredTools, state: helperState, context: context, language: language, ref: ref, conversationID: conversationID, coordinator: coordinator, workstation: workstation)
                    messages.append(.tool(id: inner.id, content: String(outcome.resultText.prefix(32_000)), isError: !outcome.succeeded))
                    if toolLog.count < Self.maxToolLogEntries { toolLog.append(Self.toolLogLine(call: inner, outcome: outcome)) }
                }
                if let replyCap, (CostMeter.current?.total ?? 0) >= replyCap { break }
            }
            if !finished {
                stopped = true
                messages.append(.user("No tool steps are left. Report now with what you have, without calling tools, and say what is missing."))
                report = try await complete(coordinator: profile, system: system, messages: messages, tools: nil, purpose: "helper").message.content ?? ""
                rounds += 1
            }
            line.state = report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "failed" : "done"
            line.summary = HelperTools.firstLine(report, limit: 160, fallback: line.summary)
            line.updatedAt = Date()
            await showHelper(line, in: ref)
            state.writtenFiles.append(contentsOf: helperState.writtenFiles)
            await beginStep(es ? "Revisando el informe de \(request.name)" : "Checking \(request.name)'s report", in: ref)
            return HelperTools.result(request: request, report: report, files: Array(NSOrderedSet(array: helperState.writtenFiles).array.compactMap { $0 as? String }), toolLog: toolLog, rounds: rounds, stoppedEarly: stopped)
        } catch is CancellationError {
            return .failure("\(request.name) was stopped.")
        } catch {
            line.state = "failed"
            line.updatedAt = Date()
            await showHelper(line, in: ref)
            return .failure("\(request.name) could not finish: \(error.localizedDescription)")
        }
    }

    /// Adds or updates a helper's line in the running reply's activity.
    private func showHelper(_ line: AgentActivity, in ref: ResponseRef) async {
        _ = try? await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { message in
            guard message.status == .running else { return }
            if let index = message.activity.firstIndex(where: { $0.id == line.id }) {
                message.activity[index] = line
            } else {
                message.activity.append(line)
            }
        }
    }

    /// Where the OS sandbox is missing (Railway cannot start bubblewrap), `run_program` and the terminals
    /// refuse to run. When Ada has a workstation, that refusal points her there instead of ending the task.
    static func workstationFallback(toolName: String, outcome: ToolOutcome, hasWorkstation: Bool) -> ToolOutcome {
        guard hasWorkstation, !outcome.succeeded, ["run_program", "run_terminal", "project_terminal"].contains(toolName),
              outcome.resultText.contains("OS sandbox") || outcome.resultText.contains("persistent terminal is unavailable") else { return outcome }
        let reason = outcome.resultText
            .replacingOccurrences(of: " Tell the user; do not try to work around it.", with: "")
            .replacingOccurrences(of: " No command was run.", with: "")
        return .failure(reason + " Your workstation is available, so do the work there instead of telling the user it cannot be done: write files and run programs with workstation_run (for example a heredoc into a file, then python3 or node on it), and use git there for commits and branches. It goes through the normal approval cards unless a standing permission allows the command. If a git push is refused for missing credentials, say exactly that.")
    }

    /// The workstation, when the server turned it on and this owner may use it.
    /// Ada's browser, when the server has one she can drive and this owner may use it (admins only).
    private func browser(ownerID: String?) async -> BrowserLink? {
        guard let ownerID, let access, let browser = await access.browserFor(ownerID), browser.drivable else { return nil }
        return browser
    }

    /// True when there is no owner to check (nothing user-owned runs) or the owner may use shared accounts.
    private func mayUseSharedAccounts(ownerID: String?) async -> Bool {
        guard let ownerID, let access else { return true }
        return await access.sharedAccountsOwner(ownerID)
    }

    private func workstation(ownerID: String?) async -> Workstation? {
        guard let ownerID, let access, let workstation = await access.workstationFor(ownerID), await workstation.enabled else { return nil }
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
            return ToolOutcome(resultText: "Approval requested (\(saved.id.uuidString)).\(why) The user sees the approval card with the exact action and approves or denies it there; this is the routine flow. Do not retry this call, do not explain approvals or point the user to the card, and do not ask whether to go ahead. Nothing has run yet; the outcome will appear under approval requests in your context on a later turn.")
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
    /// Flags the reply as using the browser, so the web app opens the live window beside the chat.
    /// Checks a `show_card` call and adds the card to the running reply, so it shows at once and stays in the chat.
    private func showCard(call: APIToolCall, in ref: ResponseRef, number: Int) async -> ToolOutcome {
        switch InfoCardTools.card(from: AgentTools.arguments(of: call)) {
        case .failure(let error):
            return .failure(error.message)
        case .success(let card):
            do {
                _ = try await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { message in
                    message.cards.append(card)
                }
                return ToolOutcome(resultText: InfoCardTools.shownMessage(card, number: number))
            } catch {
                return .failure("The card could not be saved, so it is not shown. Give the information in text.")
            }
        }
    }

    /// Checks an `ask_choice` call and puts the card on the running reply, which then ends.
    private func askChoice(call: APIToolCall, in ref: ResponseRef, state: ToolRunState) async -> ToolOutcome {
        switch ChoiceCardTools.card(from: AgentTools.arguments(of: call)) {
        case .failure(let error):
            return .failure(error.message)
        case .success(let card):
            do {
                _ = try await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { message in
                    message.choice = card
                }
                state.choice = card
                return ToolOutcome(resultText: ChoiceCardTools.shownMessage)
            } catch {
                return .failure("The choice card could not be saved, so it is not shown. Ask in text instead.")
            }
        }
    }

    private func markUsedBrowser(in ref: ResponseRef) async {
        _ = try? await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { message in
            guard message.status == .running, !message.usedBrowser else { return }
            message.usedBrowser = true
        }
    }

    private func publishPartial(_ text: String, in ref: ResponseRef?) async {
        guard let ref else { return }
        // The trailing suggestions block is metadata for quick replies, not part of what Ada says.
        var visible = text.range(of: "```suggestions", options: .caseInsensitive).map { String(text[..<$0.lowerBound]) } ?? text
        // A spoken reply is read in full, so it has no separate spoken part. A stray ```details line
        // from an older prompt is folded into the text, and read with the rest.
        if ref.spoken { visible = ConversationPrompts.extractDetails(visible).screen }
        _ = try? await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { message in
            guard message.status == .running else { return }
            message.text = visible
            message.speech = nil
            // "Writing the answer" starts when words actually arrive, not while Ada is still thinking.
            if !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let last = message.steps.last, last.state == "working", StepLabel.isWaiting(last.label) {
                Self.advanceStep(&message, to: StepLabel.writing(ref.language))
            }
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
        let reply = try await complete(coordinator: coordinator, system: system, messages: Self.chatTurns(from: history.dropLast()) + [.user(turn)], tools: nil, maxTokens: context.spoken ? Self.voiceMaxTokens : nil, purpose: "consolidate")
        if reply.message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return reply.message.content ?? "" }
        return missions.compactMap(\.finalReport).joined(separator: "\n\n")
    }

    private func startTask(call: APIToolCall, parent: OfferedTools, state: ToolRunState, coordinator: AgentProfile, context: ConversationPromptContext, language: String, ref: ResponseRef, conversationID: UUID, workstation: Workstation?) async -> ToolOutcome {
        await runTask(call: call, parent: parent, state: state, coordinator: coordinator, context: context, language: language, ref: ref, conversationID: conversationID, workstation: workstation).outcome
    }

    /// Runs one `start_task` call on helpers: Ada plans up to four steps, each runs as a helper with
    /// the tools it needs (under the same approvals, budgets and audit as her own tools), judgeAda
    /// checks the result, and the whole run is recorded as a mission for its history and files page.
    /// Returns the finished mission too, when one was recorded.
    private func runTask(call: APIToolCall, parent: OfferedTools, state: ToolRunState, coordinator: AgentProfile, context: ConversationPromptContext, language: String, ref: ResponseRef, conversationID: UUID, workstation: Workstation?) async -> (outcome: ToolOutcome, mission: Mission?) {
        let request: TaskTools.Request
        switch TaskTools.request(from: call) {
        case .failure(let error): return (.failure(error.message), nil)
        case .success(let valid): request = valid
        }
        let skill: Skill?
        switch await enabledSkill(request.skill, ownerID: ref.ownerID) {
        case .failure(let error): return (.failure(error.message), nil)
        case .success(let found): skill = found
        }
        let mission = await prepareTask(objective: request.objective, skill: skill, context: context, language: language, ref: ref, sourceName: "Ada conversation")
        return await performTask(mission, skill: skill, reason: request.reason, parent: parent, state: state, coordinator: coordinator, context: context, language: language, ref: ref, conversationID: conversationID, workstation: workstation)
    }

    /// The enabled skill with this ID, nil for none, or an error that lists the enabled skills.
    private func enabledSkill(_ id: String?, ownerID: String) async -> Result<Skill?, TriggerError> {
        guard let id else { return .success(nil) }
        guard let found = await skills.skill(id: id, for: ownerID), found.enabled else {
            let known = await skills.enabled(for: ownerID).map(\.id).joined(separator: ", ")
            return .failure(.invalid("No enabled skill \"\(id)\". Enabled skills: \(known.isEmpty ? "none" : known). Leave skill out to plan it yourself."))
        }
        return .success(found)
    }

    /// Records a new task as a running mission linked to the reply, so it shows up at once.
    private func prepareTask(objective: String, skill: Skill?, context: ConversationPromptContext, language: String, ref: ResponseRef, sourceName: String, workflowID: String? = nil, inputContext: String? = nil) async -> Mission {
        let es = language == "es"
        var mission = Mission(teamID: TaskTools.teamID, teamName: skill?.name ?? (es ? "Trabajo de Ada" : "Ada's job"), objective: objective, sourceName: sourceName, workflowID: workflowID, inputContext: inputContext ?? context.missionHandoff, status: .running, phase: .planning, outputLanguage: language)
        mission.launchedBy = ref.launchedBy
        mission.ownerID = ref.ownerID
        mission.skillID = skill?.id
        mission.startedAt = Date()
        await store.saveMission(mission)
        taskReplies[mission.id] = (ref.conversationID, ref.ownerID)
        await access?.actions.link(missionID: mission.id, conversationID: ref.conversationID, ownerID: ref.ownerID)
        await access?.audit.record(ownerID: ref.ownerID, action: "task.start", detail: "\(mission.id.uuidString)\(skill.map { " [\($0.id)]" } ?? ""): \(objective.prefix(200))")
        _ = try? await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { message in
            if !message.missionIDs.contains(mission.id) { message.missionIDs.append(mission.id) }
        }
        await store.appendEvent(mission.id, kind: .missionStart, text: mission.objective)
        await store.appendEvent(mission.id, kind: .phase, text: MissionPhase.planning.rawValue)
        return mission
    }

    /// Plans, works and checks a task recorded by `prepareTask`, and finishes its mission.
    private func performTask(_ prepared: Mission, skill: Skill?, reason: String?, parent: OfferedTools, state: ToolRunState, coordinator: AgentProfile, context: ConversationPromptContext, language: String, ref: ResponseRef, conversationID: UUID, workstation: Workstation?) async -> (outcome: ToolOutcome, mission: Mission?) {
        var mission = prepared
        let request = (objective: mission.objective, reason: reason)
        let es = language == "es"
        let procedure = skill.map { String(SkillTeams.procedureBlock($0).trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000)) }
        let started = CostMeter.current?.total ?? 0
        defer { taskReplies[prepared.id] = nil }
        await beginStep(request.reason ?? (es ? "Planificando el trabajo" : "Planning the job"), in: ref)

        func finish(_ status: MissionStatus, report: String, verdict: VerificationReport.Verdict?) async -> Mission {
            mission.status = status
            mission.phase = .done
            mission.finishedAt = Date()
            mission.finalReport = report
            mission.totalCostUSD = max(0, (CostMeter.current?.total ?? 0) - started)
            await store.writeDeliverable(missionID: mission.id, name: "final-report.md", content: report)
            await store.appendEvent(mission.id, kind: .deliverable, text: "final-report.md", deliverableName: "final-report.md")
            await store.appendEvent(mission.id, kind: .report, text: String(report.prefix(20_000)))
            if mission.totalCostUSD > 0 { await store.appendEvent(mission.id, kind: .cost, costUSD: mission.totalCostUSD) }
            await store.appendEvent(mission.id, kind: .missionEnd, text: status == .completed ? "Job finished\(verdict.map { " (\($0.rawValue))" } ?? "")." : "Job \(status.rawValue).")
            await store.saveMission(mission)
            await access?.audit.record(ownerID: ref.ownerID, action: "task.finished", detail: "\(mission.id.uuidString): \(status.rawValue)\(verdict.map { ", \($0.rawValue)" } ?? "")")
            return mission
        }

        do {
            // Plan.
            let hasMCP = parent.definitions.contains { parent.family(of: $0.function.name) == .mcp }
            let hasBrowser = parent.definitions.contains { parent.family(of: $0.function.name) == .browser }
            let planTool = TaskTools.planDefinition(hasWorkstation: workstation != nil, hasMCP: hasMCP, hasBrowser: hasBrowser)
            var plan: [TaskTools.Step]?
            let planMessages: [APIMessage] = [.user("OBJECTIVE:\n\(request.objective)\(context.missionHandoff.isEmpty ? "" : "\n\nCONTEXT FROM THE CONVERSATION:\n\(context.missionHandoff.prefix(6_000))")")]
            if let reply = try? await complete(coordinator: coordinator, system: TaskTools.planSystemPrompt(language: language, procedure: procedure), messages: planMessages, tools: [planTool], purpose: "plan") {
                plan = reply.message.tool_calls?.lazy.compactMap { TaskTools.steps(from: $0) }.first
            }
            try Task.checkCancellation()
            if plan == nil { await store.appendEvent(mission.id, kind: .notice, text: "No usable plan came back, so one specialist does the whole objective.") }
            let steps = plan ?? TaskTools.fallbackPlan(objective: request.objective)
            await store.appendEvent(mission.id, kind: .plan, text: TaskTools.planSummary(steps))
            await store.appendEvent(mission.id, kind: .phase, text: MissionPhase.working.rawValue)

            // Work: each step is a helper.
            var reports: [(name: String, report: String)] = []
            var files: [String] = []
            var failures = 0
            for step in steps {
                try Task.checkCancellation()
                let task = TaskTools.stepTask(step, objective: request.objective, earlier: reports)
                await store.appendEvent(mission.id, kind: .taskStarted, agentName: step.name, text: HelperTools.firstLine(step.task, limit: 300))
                var arguments: [(String, JSONValue)] = [("function", .string(step.function)), ("task", .string(task)), ("tools", .array(step.groups.map(\.rawValue).sorted().map { .string($0) }))]
                if let id = skill?.id { arguments.append(("skill", .string(id))) }
                let stepCall = APIToolCall(id: UUID().uuidString, function: .init(name: "delegate", arguments: TaskTools.json(.object(arguments))))
                let stepState = ToolRunState()
                let outcome = await runHelper(call: stepCall, parent: parent, state: stepState, context: context, language: language, ref: ref, conversationID: conversationID, coordinator: coordinator, workstation: workstation, maxRounds: TaskTools.stepRounds)
                let report = TaskTools.reportBody(outcome)
                reports.append((step.name, report))
                state.writtenFiles.append(contentsOf: stepState.writtenFiles)
                for name in stepState.writtenFiles where !files.contains(name) {
                    files.append(name)
                    if let content = await workspace.read(conversationID: conversationID, name: name) {
                        await store.writeDeliverable(missionID: mission.id, name: name, content: content)
                        await store.appendEvent(mission.id, kind: .deliverable, agentName: step.name, text: name, deliverableName: name)
                    }
                }
                if outcome.succeeded {
                    await store.appendEvent(mission.id, kind: .taskDone, agentName: step.name, text: HelperTools.firstLine(report, limit: 300, fallback: "Done"))
                } else {
                    failures += 1
                    await store.appendEvent(mission.id, kind: .error, agentName: step.name, text: HelperTools.firstLine(outcome.resultText, limit: 300))
                }
            }

            // Check: judgeAda reads the files and reports, read-only. A job Ada planned as a single
            // step skips it: there is one report, and Ada reads it herself before she answers.
            try Task.checkCancellation()
            var verdict: VerificationReport.Verdict?
            var check = ""
            if TaskTools.needsJudge(planned: plan != nil, steps: steps.count) {
                await store.appendEvent(mission.id, kind: .phase, text: MissionPhase.verifying.rawValue)
                await beginStep(es ? "judgeAda está revisando el resultado" : "judgeAda is checking the result", in: ref)
                let judgeArguments = TaskTools.json(.object([
                    ("function", .string("judge")), ("task", .string(TaskTools.judgeTask(objective: request.objective, reports: reports, files: files))), ("tools", .array([])),
                ]))
                let judgeCall = APIToolCall(id: UUID().uuidString, function: .init(name: "delegate", arguments: judgeArguments))
                let judged = await runHelper(call: judgeCall, parent: parent, state: ToolRunState(), context: context, language: language, ref: ref, conversationID: conversationID, coordinator: coordinator, workstation: workstation)
                check = TaskTools.reportBody(judged)
                let found = judged.succeeded ? TaskTools.verdict(in: check) : .unverified
                verdict = found
                await store.appendEvent(mission.id, kind: .verifyVerdict, agentName: "judgeAda", text: found.rawValue.uppercased())
                await store.writeDeliverable(missionID: mission.id, name: "verification.md", content: "# Check by judgeAda: \(found.rawValue.uppercased())\n\n\(check)\n")
            } else {
                await store.appendEvent(mission.id, kind: .notice, text: "One-step job: judgeAda's check is skipped, and Ada reads the result herself.")
            }

            // Report.
            await store.appendEvent(mission.id, kind: .phase, text: MissionPhase.reporting.rawValue)
            let status: MissionStatus = failures == steps.count ? .failed : .completed
            let done = await finish(status, report: TaskTools.finalReport(objective: request.objective, reports: reports, verdict: verdict, check: check, files: files), verdict: verdict)
            await beginStep(es ? "Revisando el resultado" : "Checking the result", in: ref)
            return (TaskTools.result(mission: done, skillName: skill?.name ?? (es ? "especialistas de Ada" : "Ada's specialists"), files: files), done)
        } catch is CancellationError {
            let stopped = await finish(.stopped, report: "The job was stopped.", verdict: nil)
            return (.failure("The job was stopped."), stopped)
        } catch {
            let failed = await finish(.failed, report: "The job failed: \(error.localizedDescription)", verdict: nil)
            return (.failure("The job failed: \(error.localizedDescription)"), failed)
        }
    }

    private func promptContext(conversation: Conversation, history: [ConversationMessage], memory: String, knowledge: String, activity: String = "", scheduled: Bool, spoken: Bool = false, personName: String? = nil, event: TriggerEvent? = nil) async -> ConversationPromptContext {
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
            references.append("ID: \(id.uuidString)\nJob: \(mission.teamName); status: \(mission.status.rawValue); objective: \(String(mission.objective.replacingOccurrences(of: "\n", with: " ").prefix(240)))\nFiles: \(files.isEmpty ? "none" : files.joined(separator: ", "))")
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
            activity: activity,
            spoken: spoken,
            timeZoneID: conversation.timeZone,
            personName: personName,
            approvals: approvals,
            triggers: conversation.triggers,
            event: event
        )
    }

    /// Every model call the engine makes goes through here, so each one is costed and logged.
    /// `purpose` says in the log what the call was for.
    private func complete(coordinator: AgentProfile, system: String, messages: [APIMessage], tools: [APIToolDef]?, maxTokens: Int? = nil, purpose: String = "other", onDelta: TextDeltaHandler? = nil) async throws -> LLMReply {
        let registry = ProviderRegistry(providers: await store.loadProviders())
        guard let provider = registry.provider(id: coordinator.providerID) else { throw ConversationError.noProvider }
        let trace = ReplyTrace.current
        let call = trace?.beginCall(purpose: purpose) ?? 0
        let started = ModelCallLog.now()
        let firstWord = ModelCallLog.FirstWord(started: started)
        var timedDelta: TextDeltaHandler?
        if let onDelta {
            timedDelta = { text in
                firstWord.mark()
                onDelta(text)
            }
        }
        let reply: LLMReply
        do {
            if let completionOverride {
                reply = try await completionOverride(provider, keyRing.get(provider.keyAccount) ?? "", coordinator, system, messages, tools)
            } else {
                reply = try await client.complete(provider: provider, key: keyRing.get(provider.keyAccount) ?? "", model: coordinator.model, system: system, messages: messages, tools: tools, temperature: coordinator.temperature, maxTokens: maxTokens, onDelta: timedDelta)
            }
        } catch {
            EngineLog.write(.info, ModelCallLog.failureLine(conversation: trace?.conversation ?? "-", call: call, purpose: purpose, provider: provider.id, model: coordinator.model, error: error, totalMilliseconds: ModelCallLog.milliseconds(since: started)))
            throw error
        }
        let cost = Pricing.estimate(model: reply.model, inputTokens: reply.inputTokens, outputTokens: reply.outputTokens, cachedInputTokens: reply.cachedInputTokens, local: provider.isLocal)
        CostMeter.current?.add(cost)
        trace?.record(reply)
        EngineLog.write(.info, ModelCallLog.line(conversation: trace?.conversation ?? "-", call: call, purpose: purpose, provider: provider.id, reply: reply, messages: messages.count, tools: tools?.count ?? 0, firstWordMilliseconds: firstWord.milliseconds, totalMilliseconds: ModelCallLog.milliseconds(since: started), costUSD: cost))
        return reply
    }

    private func completeDirect(coordinator: AgentProfile, system: String, messages: [APIMessage], tools: [APIToolDef]?, maxTokens: Int? = nil, purpose: String = "reply", contextAllowance: Int = 0, summaries: ConversationCompactor.SummaryState = .init(), onDelta: TextDeltaHandler? = nil) async throws -> LLMReply {
        var budget = ModelLimits.conversationBudget(model: coordinator.model) + contextAllowance
        var overflowRetries = 0
        var messages = messages
        while true {
            let compacted = await ConversationCompactor.compact(messages: messages, budgetTokens: budget, summarizer: { previous, transcript in
                let request = ConversationCompactor.summaryRequest(previous: previous, transcript: transcript)
                let reply = try? await self.complete(coordinator: coordinator, system: ConversationCompactor.summarySystem, messages: [.user(request)], tools: nil, maxTokens: 900, purpose: "summary")
                return reply?.message.content
            }, state: summaries)
            do {
                return try await complete(coordinator: coordinator, system: system, messages: compacted.messages, tools: tools, maxTokens: maxTokens, purpose: purpose, onDelta: onDelta)
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

    // MARK: - Spoken acknowledgement

    /// How long the quick acknowledgement may take. After this, the app's own short line is used instead.
    static let acknowledgementTimeout: Duration = .seconds(4)

    /// Model names that are quick to answer: the small model of each family.
    static let fastModelHints = ["haiku", "-mini", "flash", "-lite", "nano", "instant", "deepseek-chat", "-8b"]

    /// The model for the acknowledgement: a small, fast one, on Ada's own provider if it has one,
    /// else on any provider with a key, else Ada's own model.
    static func acknowledgementProfile(for coordinator: AgentProfile, providers: [ProviderConfig], hasKey: (ProviderConfig) -> Bool) -> AgentProfile {
        func fast(_ model: String) -> Bool { fastModelHints.contains { model.lowercased().contains($0) } }
        var profile = coordinator
        if fast(coordinator.model) { return profile }
        if let own = providers.first(where: { $0.id == coordinator.providerID }), let model = own.models.first(where: fast) {
            profile.model = model
            return profile
        }
        for provider in providers where hasKey(provider) {
            if let model = provider.models.first(where: fast) {
                profile.providerID = provider.id
                profile.model = model
                return profile
            }
        }
        return profile
    }

    // MARK: - The specialists' model

    /// `AGENTSAM_SPECIALIST_MODEL` overrides the choice below: `main` keeps specialists on Ada's own
    /// model, and any other value is used as the model name on her provider.
    static let specialistModelOverride: String? = ProcessInfo.processInfo.environment["AGENTSAM_SPECIALIST_MODEL"].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }

    /// DeepSeek's fast model, as its API names it. Used when Ada talks to DeepSeek's own API and
    /// the provider's saved model list has no flash model yet.
    static let deepSeekFlashModel = "deepseek-flash"

    /// The model one of Ada's specialists runs on: the flash model of Ada's own provider, so reading,
    /// searching and drafting cost less and come back sooner. judgeAda keeps Ada's model, because a
    /// check is only worth having from the stronger one. Providers without a flash model are left
    /// as they are, and the same key is used either way.
    static func specialistProfile(for coordinator: AgentProfile, function: String, providers: [ProviderConfig], override: String? = specialistModelOverride) -> AgentProfile {
        guard HelperTools.key(for: function) != "judge" else { return coordinator }
        var profile = coordinator
        if let override {
            if override.lowercased() != "main" { profile.model = override }
            return profile
        }
        func flash(_ model: String) -> Bool { model.lowercased().contains("flash") }
        guard !flash(coordinator.model), let provider = providers.first(where: { $0.id == coordinator.providerID }) else { return coordinator }
        if let model = provider.models.first(where: flash) {
            profile.model = model
        } else if provider.kind == .openAICompatible, provider.baseURL.lowercased().contains("api.deepseek.com") {
            profile.model = deepSeekFlashModel
        }
        return profile
    }

    /// True when a provider's answer reads like "I don't know this model", not like a passing fault.
    static func mayBeModelRejection(_ error: LLMError) -> Bool {
        guard let status = error.statusCode, !error.isContextOverflow else { return false }
        return [400, 403, 404, 422].contains(status)
    }

    static func acknowledgementSystem(language: String, avoid: String?) -> String {
        let spanish = language == "es"
        var lines = [
            "You are Ada, a warm voice assistant. The person just asked you something out loud, and you are starting on it now.",
            "Reply with ONE short spoken acknowledgement of 2 to 7 words, in \(spanish ? "Spanish" : "English"), that tells them you're on it.",
            "Name the topic when it is natural, for example \(spanish ? "\"Déjame revisar tu calendario.\" or \"Un momento, busco esas cifras.\"" : "\"Let me check your calendar.\" or \"One sec, pulling up those numbers.\"").",
            "Never answer the question, never guess a result, never promise anything, never ask a question.",
            "Plain text only: no quotes, emoji, Markdown, or name.",
        ]
        if let avoid, !avoid.isEmpty { lines.append("Don't repeat your last one (\"\(avoid)\"); word it differently.") }
        return lines.joined(separator: "\n")
    }

    /// One short spoken line, or nil when the model's text isn't usable as one.
    static func cleanAcknowledgement(_ raw: String) -> String? {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var text = firstLine
            .replacingOccurrences(of: "[*_`#\"“”«»]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("Ada:") { text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        let words = text.split(separator: " ").count
        guard words >= 1, words <= 10, text.count <= 80, !text.contains("?") else { return nil }
        if let last = text.last, !".!…".contains(last) { text += "." }
        return text
    }

    /// Asks a small model for the acknowledgement and puts it on the reply, if the reply is still being written.
    private func acknowledge(_ message: ConversationMessage, previous: [ConversationMessage], coordinator: AgentProfile, providers: [ProviderConfig], language: String, ref: ResponseRef) async {
        let profile = Self.acknowledgementProfile(for: coordinator, providers: providers) { self.keyRing.get($0.keyAccount) != nil }
        let spoken = SpokenNumbers.language(of: message.text, fallback: language)
        let avoid = previous.last(where: { $0.role == .assistant && $0.acknowledgement != nil })?.acknowledgement
        let system = Self.acknowledgementSystem(language: spoken, avoid: avoid)
        let request = String(message.text.prefix(600))
        let line: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let reply = try? await self.complete(coordinator: profile, system: system, messages: [.user(request)], tools: nil, maxTokens: 40, purpose: ModelCallLog.acknowledgement)
                return reply?.message.content.flatMap(Self.cleanAcknowledgement)
            }
            group.addTask {
                try? await Task.sleep(for: Self.acknowledgementTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let line, !Task.isCancelled else { return }
        _ = try? await conversations.updateMessage(id: ref.conversationID, ownerID: ref.ownerID, messageID: ref.responseID) { reply in
            guard reply.status == .running, reply.acknowledgement == nil else { return }
            reply.acknowledgement = line
        }
    }

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
        let note = "[The user attached \(count == 1 ? "a photo" : "\(count) photos"). Only Ada's own reply can look at photos; her specialists and jobs cannot see them.]"
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
            // Memory upkeep runs on after the reply has been costed and summed up, so it keeps its
            // own meter and call count, and adds what it spent to the day itself.
            let meter = CostMeter()
            let trace = ReplyTrace(conversationID: conversationID)
            await CostMeter.$current.withValue(meter) {
                await ReplyTrace.$current.withValue(trace) {
                    await self.runMemoryUpkeep(conversationID: conversationID, ownerID: ownerID, user: user, assistant: assistant, coordinator: coordinator)
                }
            }
            await self.access?.spend.add(ownerID: ownerID, usd: meter.total)
        }
    }

    private func runMemoryUpkeep(conversationID: UUID, ownerID: String, user: ConversationMessage, assistant: ConversationMessage, coordinator: AgentProfile) async {
        do {
            var job = try await memory.record(conversationID: conversationID, ownerID: ownerID, userMessage: user, assistantMessage: assistant)
            var attempts = 0
            while let compaction = job, attempts < 3, !Task.isCancelled {
                attempts += 1
                do {
                    let reply = try await complete(coordinator: coordinator, system: ConversationPrompts.memorySystem(store: promptStore), messages: [.user(compaction.prompt)], tools: nil, purpose: "memory")
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
    private var closed = false

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
            guard !isClosed else { return }
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

    /// Stops any further text from reaching the sink.
    func close() {
        lock.withLock { closed = true }
    }

    private var isClosed: Bool { lock.withLock { closed } }

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
