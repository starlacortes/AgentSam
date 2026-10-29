import SwiftUI
import Observation
import Foundation
import AgentSamCore

@Observable
final class MissionLiveState {
    let missionID: UUID
    var mission: Mission?
    var events: [RunEvent] = []
    var deliverables: [String] = []
    var deliverableContents: [String: String] = [:]
    var selectedDeliverable: String?
    private var observeTask: Task<Void, Never>?

    init(missionID: UUID) {
        self.missionID = missionID
    }

    func start(store: MissionStore) {
        guard observeTask == nil else { return }
        observeTask = Task { [weak self] in
            guard let self else { return }
            self.mission = await store.mission(id: self.missionID)
            self.events = await store.events(missionID: self.missionID, afterSeq: 0)
            self.deliverables = await store.deliverables(missionID: self.missionID)
            if let first = self.deliverables.first { self.selectedDeliverable = first }

            let stream = await store.subscribe(missionID: self.missionID)
            for await event in stream {
                guard !Task.isCancelled else { break }
                if !self.events.contains(where: { $0.seq == event.seq }) {
                    self.events.append(event)
                    self.events.sort { $0.seq < $1.seq }
                }
                switch event.kind {
                case .phase, .taskStarted, .taskDone, .cost, .deliverable, .verifyVerdict, .missionEnd:
                    self.mission = await store.mission(id: self.missionID)
                default:
                    break
                }
                if event.kind == .deliverable || event.kind == .missionEnd {
                    self.deliverables = await store.deliverables(missionID: self.missionID)
                    if self.selectedDeliverable == nil {
                        self.selectedDeliverable = self.deliverables.first
                    }
                }
                if event.kind == .missionEnd {
                    self.deliverableContents = [:]
                }
            }
        }
    }

    func stopObserving() {
        observeTask?.cancel()
        observeTask = nil
    }

    func content(for deliverable: String, store: MissionStore) async -> String? {
        if let cached = deliverableContents[deliverable] { return cached }
        guard let text = await store.deliverable(missionID: missionID, name: deliverable) else { return nil }
        deliverableContents[deliverable] = text
        return text
    }
}

@MainActor
@Observable
final class AppModel {
    let store: MissionStore
    let engine: MissionEngine
    let keyRing: KeychainKeyRing
    let client = LLMClient()

    var teams: [Team] = []
    var providers: [ProviderConfig] = []
    var missions: [Mission] = []
    var liveState: MissionLiveState?
    var dataDirPath: String = ""
    var isBootstrapped = false

    var notice: String?

    init() {
        let raw = ProcessInfo.processInfo.environment["AGENTSAM_DATA"]
        let url: URL
        if let raw, !raw.isEmpty {
            url = URL(fileURLWithPath: raw)
        } else {
            url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentSam", isDirectory: true)
        }
        store = MissionStore(root: url)
        keyRing = KeychainKeyRing()
        engine = MissionEngine(store: store, keyRing: keyRing)
        dataDirPath = url.path
        Task { await bootstrap() }
    }

    func bootstrap() async {
        let url = URL(fileURLWithPath: dataDirPath)
        let providersURL = url.appendingPathComponent("providers.json")
        if !FileManager.default.fileExists(atPath: providersURL.path) {
            await store.saveProviders(ProviderConfig.builtin)
        }
        if await store.loadTeams().isEmpty {
            await store.saveTeam(Team.starterTeam())
        }
        await reload()
        isBootstrapped = true
    }

    func reload() async {
        teams = await store.loadTeams()
        providers = await store.loadProviders()
        missions = await store.listMissions(limit: 200)
    }

    func saveProviders(_ list: [ProviderConfig]) async {
        providers = list
        await store.saveProviders(list)
    }

    func saveTeam(_ team: Team) async {
        var team = team
        team.updatedAt = Date()
        await store.saveTeam(team)
        await reload()
    }

    func deleteTeam(_ team: Team) async {
        await store.deleteTeam(id: team.id)
        await reload()
    }

    func launchMission(team: Team, objective: String) async {
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let mission = await store.createMission(team: team, objective: objective)
        await engine.launch(missionID: mission.id, team: team)
        await reload()
        open(mission.id)
    }

    func open(_ missionID: UUID) {
        liveState?.stopObserving()
        let state = MissionLiveState(missionID: missionID)
        liveState = state
        state.start(store: store)
    }

    func stopMission(_ missionID: UUID) async {
        await engine.stop(missionID: missionID)
    }

    func isRunning(_ missionID: UUID) -> Bool {
        missions.first(where: { $0.id == missionID })?.status == .running
    }

    func deleteMission(_ missionID: UUID) async {
        await engine.stop(missionID: missionID)
        if liveState?.missionID == missionID {
            liveState?.stopObserving()
            liveState = nil
        }
        await store.deleteMission(id: missionID)
        await reload()
    }

    func apiKey(for provider: ProviderConfig) -> String {
        keyRing.get(provider.keyAccount) ?? ""
    }

    func setAPIKey(_ key: String, for provider: ProviderConfig) {
        try? keyRing.set(key, for: provider.keyAccount)
    }

    func removeAPIKey(for provider: ProviderConfig) {
        keyRing.remove(provider.keyAccount)
    }

    func testConnection(to provider: ProviderConfig) async -> String {
        let key = apiKey(for: provider)
        guard !key.isEmpty else { return "No API key saved for \(provider.name)." }
        let result = await client.testConnection(provider: provider, key: key)
        return result.message
    }
}
