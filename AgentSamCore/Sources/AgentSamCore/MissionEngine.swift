import Foundation

public enum MissionEngineError: Error, LocalizedError {
    case noAgents
    case noCoordinator
    case missingKey(String)
    case unknownProvider(String)

    public var errorDescription: String? {
        switch self {
        case .noAgents: CoreL10n.t("engine.error.noAgents")
        case .noCoordinator: CoreL10n.t("engine.error.noCoordinator")
        case .missingKey(let name): CoreL10n.tf("engine.error.missingKey", name)
        case .unknownProvider(let id): CoreL10n.tf("engine.error.unknownProvider", id)
        }
    }
}

public actor MissionEngine {
    public struct Config: Sendable {
        public var maxParallel: Int
        public var maxSteps: Int
        public var verifyWithAgent: Bool

        public init(maxParallel: Int = 4, maxSteps: Int = 14, verifyWithAgent: Bool = true) {
            self.maxParallel = maxParallel
            self.maxSteps = maxSteps
            self.verifyWithAgent = verifyWithAgent
        }
    }

    struct WorkerResult: Sendable {
        var task: TaskPlanItem
        var agent: AgentProfile
        var handoff: String
        var deliverables: [String]
        var stats: MissionStats
        var error: String?
    }

    private let store: MissionStore
    private let keyRing: KeyRing
    private let client: LLMClient
    private let connectors: ConnectorHub?
    private let config: Config
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    public init(store: MissionStore, keyRing: KeyRing, client: LLMClient = LLMClient(), connectors: ConnectorHub? = nil, config: Config = Config()) {
        self.store = store
        self.keyRing = keyRing
        self.client = client
        self.connectors = connectors
        self.config = config
    }

    public func launch(missionID: UUID, team: Team) {
        guard runningTasks[missionID] == nil else { return }
        runningTasks[missionID] = Task {
            await self.drive(missionID: missionID, team: team)
        }
    }

    public func stop(missionID: UUID) {
        runningTasks[missionID]?.cancel()
    }

    public func isRunning(missionID: UUID) -> Bool {
        runningTasks[missionID] != nil
    }

    public var activeMissionIDs: [UUID] {
        Array(runningTasks.keys)
    }

    nonisolated private func l10n(_ key: String, mission: Mission) -> String {
        CoreL10n.t(key, lang: CoreL10n.language(for: mission))
    }

    nonisolated private func l10nf(_ key: String, _ args: CVarArg..., mission: Mission) -> String {
        let format = l10n(key, mission: mission)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: args)
    }

    nonisolated private func errorText(_ error: Error, mission: Mission) -> String {
        let lang = CoreL10n.language(for: mission)
        if let missionError = error as? MissionEngineError {
            switch missionError {
            case .noAgents: return CoreL10n.t("engine.error.noAgents", lang: lang)
            case .noCoordinator: return CoreL10n.t("engine.error.noCoordinator", lang: lang)
            case .missingKey(let name): return CoreL10n.tf("engine.error.missingKey", name, lang: lang)
            case .unknownProvider(let id): return CoreL10n.tf("engine.error.unknownProvider", id, lang: lang)
            }
        }
        return error.localizedDescription
    }

    private func drive(missionID: UUID, team: Team) async {
        defer { runningTasks[missionID] = nil }
        guard var mission = await store.mission(id: missionID) else { return }

        mission.status = .running
        mission.startedAt = Date()
        mission.phase = .planning
        await store.saveMission(mission)
        await store.appendEvent(missionID, kind: .missionStart, text: mission.objective)
        await store.appendEvent(missionID, kind: .phase, text: MissionPhase.planning.rawValue)

        do {
            guard !team.agents.isEmpty else { throw MissionEngineError.noAgents }
            try Task.checkCancellation()

            let registry = ProviderRegistry(providers: await store.loadProviders())
            let neededProviders = Set(team.agents.map(\.providerID))
            for providerID in neededProviders {
                guard let provider = registry.provider(id: providerID) else {
                    throw MissionEngineError.unknownProvider(providerID)
                }
                if keyRing.get(provider.keyAccount) == nil {
                    throw MissionEngineError.missingKey(provider.name)
                }
            }

            var stats = MissionStats()
            let workspace = store.deliverablesDirectory(missionID)
            let coordinator = team.coordinator ?? team.agents[0]

            let plan = try await makePlan(
                mission: mission, team: team, coordinator: coordinator,
                registry: registry, stats: &stats
            )

            mission.phase = .working
            mission.totalCostUSD = stats.costUSD
            mission.totalInputTokens = stats.inputTokens
            mission.totalOutputTokens = stats.outputTokens
            await store.saveMission(mission)
            await store.appendEvent(missionID, kind: .phase, text: MissionPhase.working.rawValue)

            let results = try await runWorkers(
                mission: mission, team: team, tasks: plan,
                registry: registry, workspace: workspace, stats: &stats
            )
            try Task.checkCancellation()

            mission.phase = .verifying
            await store.saveMission(mission)
            await store.appendEvent(missionID, kind: .phase, text: MissionPhase.verifying.rawValue)

            let report = try await verify(
                mission: mission, team: team, registry: registry,
                results: results, stats: &stats
            )
            try Task.checkCancellation()

            mission.phase = .reporting
            await store.saveMission(mission)
            await store.appendEvent(missionID, kind: .phase, text: MissionPhase.reporting.rawValue)

            let finalReport = try await writeFinalReport(
                mission: mission, team: team, coordinator: coordinator,
                registry: registry, results: results, verification: report,
                stats: &stats
            )

            mission.finalReport = finalReport
            mission.status = .completed
            mission.phase = .done
            mission.finishedAt = Date()
            mission.totalCostUSD = stats.costUSD
            mission.totalInputTokens = stats.inputTokens
            mission.totalOutputTokens = stats.outputTokens
            await store.saveMission(mission)
            await store.appendEvent(
                missionID,
                kind: .missionEnd,
                text: l10nf("engine.missionComplete", Int64(results.filter { $0.error == nil }.count), String(format: "%.4f", stats.costUSD), mission: mission)
            )
        } catch is CancellationError {
            mission.status = .stopped
            mission.phase = .done
            mission.finishedAt = Date()
            await store.saveMission(mission)
            await store.appendEvent(missionID, kind: .error, text: l10n("engine.missionStopped", mission: mission))
            await store.appendEvent(missionID, kind: .missionEnd, text: l10n("engine.missionStopped", mission: mission))
        } catch {
            mission.status = .failed
            mission.phase = .done
            mission.finishedAt = Date()
            await store.saveMission(mission)
            await store.appendEvent(missionID, kind: .error, text: errorText(error, mission: mission))
            await store.appendEvent(missionID, kind: .missionEnd, text: l10n("engine.missionFailed", mission: mission))
        }
    }

    private func makePlan(
        mission: Mission,
        team: Team,
        coordinator: AgentProfile,
        registry: ProviderRegistry,
        stats: inout MissionStats
    ) async throws -> [TaskPlanItem] {
        var messages: [APIMessage] = [.user(PromptBuilder.planPrompt(mission: mission, team: team))]
        let reply = try await call(
            agent: coordinator,
            registry: registry,
            missionID: mission.id,
            system: PromptBuilder.coordinatorSystem(team: team, mission: mission),
            messages: messages,
            tools: nil,
            stats: &stats
        )
        messages.append(reply.message)
        var plan = PlanParser.parse(reply.message.content ?? "")

        if plan.isEmpty {
            await store.appendEvent(mission.id, kind: .notice, text: l10n("engine.planNotParseable", mission: mission))
            messages.append(.user(PromptBuilder.replanPrompt(mission: mission, previous: reply.message.content ?? "")))
            let retry = try await call(
                agent: coordinator,
                registry: registry,
                missionID: mission.id,
                system: PromptBuilder.coordinatorSystem(team: team, mission: mission),
                messages: messages,
                tools: nil,
                stats: &stats
            )
            messages.append(retry.message)
            plan = PlanParser.parse(retry.message.content ?? "")
        }

        if plan.isEmpty {
            await store.appendEvent(mission.id, kind: .notice, text: l10n("engine.planFallback", mission: mission))
            plan = PlanParser.fallbackPlan(mission: mission, team: team)
        }

        var availableWorkers = team.workers
        let resolved = plan.prefix(max(1, availableWorkers.count)).map { item -> TaskPlanItem in
            var item = item
            let requested = team.worker(named: item.agentName)
            let agent = requested.flatMap({ candidate in
                availableWorkers.first(where: { $0.id == candidate.id })
            }) ?? availableWorkers.first ?? coordinator
            availableWorkers.removeAll(where: { $0.id == agent.id })
            item.agentName = agent.name
            return item
        }

        let summary = resolved.map { "Task \($0.id) — \($0.agentName): \($0.goal) → \($0.deliverable)" }.joined(separator: "\n")
        await store.appendEvent(mission.id, kind: .plan, text: summary)
        await store.saveConversation(missionID: mission.id, agentName: coordinator.name, messages: messages)
        return Array(resolved)
    }

    private func runWorkers(
        mission: Mission,
        team: Team,
        tasks: [TaskPlanItem],
        registry: ProviderRegistry,
        workspace: URL,
        stats: inout MissionStats
    ) async throws -> [WorkerResult] {
        var mission = mission
        var results: [WorkerResult] = []
        var index = 0

        while index < tasks.count {
            try Task.checkCancellation()
            let chunkEnd = min(index + max(1, config.maxParallel), tasks.count)
            let chunk = Array(tasks[index..<chunkEnd])
            index = chunkEnd

            let chunkResults: [WorkerResult] = await withTaskGroup(of: WorkerResult.self) { group in
                for task in chunk {
                    let agent = team.worker(named: task.agentName) ?? team.workers.first ?? team.agents[0]
                    group.addTask {
                        await self.runWorker(
                            task: task,
                            agent: agent,
                            team: team,
                            mission: mission,
                            registry: registry,
                            workspace: workspace
                        )
                    }
                }
                var collected: [WorkerResult] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }

            for result in chunkResults {
                stats.add(result.stats)
                if let error = result.error {
                    await store.appendEvent(mission.id, kind: .error, agent: result.agent, text: error)
                } else {
                    await store.appendEvent(
                        mission.id,
                        kind: .taskDone,
                        agent: result.agent,
                        text: result.handoff,
                        costUSD: result.stats.costUSD
                    )
                }
                results.append(result)
            }

            mission.totalCostUSD = stats.costUSD
            mission.totalInputTokens = stats.inputTokens
            mission.totalOutputTokens = stats.outputTokens
            await store.saveMission(mission)
        }
        return results
    }

    private nonisolated func runWorker(
        task: TaskPlanItem,
        agent: AgentProfile,
        team: Team,
        mission: Mission,
        registry: ProviderRegistry,
        workspace: URL
    ) async -> WorkerResult {
        var messages: [APIMessage] = [.user(PromptBuilder.workPrompt(task: task, mission: mission))]
        var workerStats = MissionStats(turns: 0)
        var handoff = l10n("engine.taskFinished", mission: mission)
        var deliverables: [String] = []
        await store.appendEvent(mission.id, kind: .taskStarted, agent: agent, text: task.goal)
        let connectorDefs = await connectors?.toolDefs() ?? []
        let externalToolNames = connectorDefs.map(\.function.name)
        let tools = AgentTools.workerTools + connectorDefs

        do {
            for _ in 0..<max(2, config.maxSteps) {
                try Task.checkCancellation()
                let reply = try await call(
                    agent: agent,
                    registry: registry,
                    missionID: mission.id,
                    system: PromptBuilder.workerSystem(agent: agent, team: team, mission: mission, externalTools: externalToolNames),
                    messages: messages,
                    tools: tools,
                    stats: &workerStats
                )
                messages.append(reply.message)

                let calls = reply.message.tool_calls ?? []
                if calls.isEmpty {
                    let text = reply.message.content ?? ""
                    if !text.isEmpty { handoff = text }
                    break
                }

                var finished = false
                for call in calls {
                    let outcome: ToolOutcome
                    if let connectors, connectors.owns(call.function.name) {
                        outcome = await connectors.run(call: call)
                    } else {
                        outcome = AgentTools.run(call: call, workspace: workspace)
                    }
                    if let name = outcome.wroteFiles.first {
                        deliverables = Array(Set(deliverables + outcome.wroteFiles)).sorted()
                        await store.appendEvent(mission.id, kind: .deliverable, agent: agent, text: task.deliverable, deliverableName: name)
                    }
                    await store.appendEvent(mission.id, kind: .toolCall, agent: agent, text: "\(call.function.name): \(outcome.resultText.prefix(400))")
                    messages.append(.tool(id: call.id, content: outcome.resultText))
                    if outcome.finished {
                        finished = true
                        if let summary = outcome.finishSummary { handoff = summary }
                    }
                }
                if finished { break }
            }
            await store.saveConversation(missionID: mission.id, agentName: agent.name, messages: messages)
            return WorkerResult(task: task, agent: agent, handoff: handoff, deliverables: deliverables, stats: workerStats, error: nil)
        } catch is CancellationError {
            await store.saveConversation(missionID: mission.id, agentName: agent.name, messages: messages)
            let partial = MissionStats(inputTokens: workerStats.inputTokens, outputTokens: workerStats.outputTokens, costUSD: workerStats.costUSD, turns: workerStats.turns)
            return WorkerResult(task: task, agent: agent, handoff: l10n("engine.taskStopped", mission: mission), deliverables: deliverables, stats: partial, error: "stopped")
        } catch {
            await store.saveConversation(missionID: mission.id, agentName: agent.name, messages: messages)
            let failed = MissionStats(inputTokens: workerStats.inputTokens, outputTokens: workerStats.outputTokens, costUSD: workerStats.costUSD, turns: workerStats.turns)
            return WorkerResult(task: task, agent: agent, handoff: l10n("engine.taskFailed", mission: mission), deliverables: deliverables, stats: failed, error: l10nf("engine.workerFailed", agent.name, task.deliverable, errorText(error, mission: mission), mission: mission))
        }
    }

    private func verify(
        mission: Mission,
        team: Team,
        registry: ProviderRegistry,
        results: [WorkerResult],
        stats: inout MissionStats
    ) async throws -> VerificationReport {
        let deliverableNames = await store.deliverables(missionID: mission.id)
        var findings: [VerificationReport.Finding] = []

        for result in results {
            let name = AgentTools.normalized(result.task.deliverable)
            let listed = deliverableNames.contains { $0 == name }
            if !listed {
                findings.append(VerificationReport.Finding(
                    level: result.error == nil ? .fail : .concern,
                    check: l10n("engine.checkMechanical", mission: mission),
                    detail: l10nf("engine.deliverableMissing", result.task.deliverable, mission: mission)
                ))
            } else if result.error == nil {
                findings.append(VerificationReport.Finding(
                    level: .pass,
                    check: l10n("engine.checkMechanical", mission: mission),
                    detail: l10nf("engine.deliverableWritten", result.task.deliverable, result.agent.name, mission: mission)
                ))
            }
        }

        var verdict: VerificationReport.Verdict
        if let verifier = team.verifier, config.verifyWithAgent, !deliverableNames.isEmpty {
            var messages: [APIMessage] = [.user(PromptBuilder.verifyPrompt(deliverables: deliverableNames, mission: mission))]
            var verifierFindings: [VerificationReport.Finding] = []
            do {
                for _ in 0..<6 {
                    try Task.checkCancellation()
                    let reply = try await call(
                        agent: verifier,
                        registry: registry,
                        missionID: mission.id,
                        system: PromptBuilder.verifierSystem(agent: verifier, mission: mission),
                        messages: messages,
                        tools: AgentTools.readTools,
                        stats: &stats
                    )
                    messages.append(reply.message)
                    let calls = reply.message.tool_calls ?? []
                    if calls.isEmpty { break }
                    for call in calls {
                        let outcome = AgentTools.run(call: call, workspace: store.deliverablesDirectory(mission.id), readOnly: true)
                        await store.appendEvent(mission.id, kind: .toolCall, agent: verifier, text: "\(call.function.name): \(outcome.resultText.prefix(400))")
                        messages.append(.tool(id: call.id, content: outcome.resultText))
                    }
                }
                let lastText = messages.last(where: { $0.role == "assistant" && $0.content != nil })?.content ?? ""
                let parsed = VerifierParser.parse(lastText)
                verifierFindings = parsed.findings
                verdict = parsed.verdict
                if parsed.findings.isEmpty {
                    verifierFindings.append(VerificationReport.Finding(
                        level: .concern,
                        check: l10n("engine.checkVerifier", mission: mission),
                        detail: l10n("engine.verifierUnparseable", mission: mission)
                    ))
                }
            } catch {
                verifierFindings.append(VerificationReport.Finding(
                    level: .concern,
                    check: l10n("engine.checkVerifier", mission: mission),
                    detail: l10nf("engine.verifierFailed", error.localizedDescription, mission: mission)
                ))
                verdict = .unverified
            }
            await store.saveConversation(missionID: mission.id, agentName: verifier.name, messages: messages)
            findings += verifierFindings
            if verifierFindings.contains(where: { $0.level == .fail }) {
                verdict = .failed
            } else if verifierFindings.contains(where: { $0.level == .concern }) {
                verdict = .concerns
            }
        } else {
            verdict = .unverified
        }

        let mechanicalWorst = findings
            .filter { $0.check == "mechanical" }
            .map(\.level)
            .max()

        if let worst = mechanicalWorst {
            let mechanicalVerdict: VerificationReport.Verdict = worst == .pass ? .clean : (worst == .concern ? .concerns : .failed)
            if mechanicalVerdict == .failed { verdict = .failed }
            else if mechanicalVerdict == .concerns && verdict == .clean { verdict = .concerns }
        }

        let report = VerificationReport(verdict: verdict, findings: findings)
        for finding in findings.sorted(by: { $0.level > $1.level }) {
            await store.appendEvent(
                mission.id,
                kind: .verifyFinding,
                text: "\(finding.level.rawValue.uppercased()) — \(finding.check): \(finding.detail)"
            )
        }
        await store.appendEvent(mission.id, kind: .verifyVerdict, text: verdict.rawValue.uppercased())
        await store.writeDeliverable(missionID: mission.id, name: "verification.md", content: report.markdown)
        return report
    }

    private func writeFinalReport(
        mission: Mission,
        team: Team,
        coordinator: AgentProfile,
        registry: ProviderRegistry,
        results: [WorkerResult],
        verification: VerificationReport,
        stats: inout MissionStats
    ) async throws -> String {
        let handoffs = results.map { result in
            "\(result.agent.name) — \(result.task.deliverable): \(result.handoff)"
        }
        var messages: [APIMessage] = [.user(PromptBuilder.reportPrompt(mission: mission, handoffs: handoffs, verification: verification))]
        let reply = try await call(
            agent: coordinator,
            registry: registry,
            missionID: mission.id,
            system: PromptBuilder.coordinatorSystem(team: team, mission: mission),
            messages: messages,
            tools: nil,
            stats: &stats
        )
        messages.append(reply.message)

        var report = stripFences(reply.message.content ?? "")
        if report.isEmpty {
            report = l10n("engine.fallbackReport", mission: mission) + "\n\n" + handoffs.joined(separator: "\n\n")
        }
        if verification.verdict != .clean {
            report += "\n\n" + verification.markdown(language: CoreL10n.language(for: mission))
        }
        await store.writeDeliverable(missionID: mission.id, name: "final-report.md", content: report)
        await store.saveConversation(missionID: mission.id, agentName: coordinator.name, messages: messages)
        await store.appendEvent(mission.id, kind: .deliverable, agent: coordinator, text: "final-report.md", deliverableName: "final-report.md")
        await store.appendEvent(mission.id, kind: .report, agent: coordinator, text: String(report.prefix(20_000)))
        return report
    }

    nonisolated private func call(
        agent: AgentProfile,
        registry: ProviderRegistry,
        missionID: UUID,
        system: String,
        messages: [APIMessage],
        tools: [APIToolDef]?,
        stats: inout MissionStats
    ) async throws -> LLMReply {
        guard let provider = registry.provider(id: agent.providerID) else {
            throw MissionEngineError.unknownProvider(agent.providerID)
        }
        let key = keyRing.get(provider.keyAccount) ?? ""
        let reply = try await client.complete(
            provider: provider,
            key: key,
            model: agent.model,
            system: system,
            messages: messages,
            tools: tools,
            temperature: agent.temperature
        )
        stats.turns += 1
        stats.inputTokens += reply.inputTokens
        stats.outputTokens += reply.outputTokens
        stats.costUSD += Pricing.estimate(model: reply.model, inputTokens: reply.inputTokens, outputTokens: reply.outputTokens)
        if let text = reply.message.content, !text.isEmpty {
            await store.appendEvent(missionID, kind: .agentMessage, agent: agent, text: String(text.prefix(4_000)))
        }
        return reply
    }

    private func stripFences(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            if let firstNewline = body.firstIndex(of: "\n") {
                body = String(body[body.index(after: firstNewline)...])
            }
            if body.hasSuffix("```") {
                body = String(body.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return body
    }
}
