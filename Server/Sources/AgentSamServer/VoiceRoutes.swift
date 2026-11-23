import Vapor
import Foundation
import AgentSamCore

struct VoiceInfoResponse: Encodable {
    /// What is used right now, after automatic picks.
    var setup: VoiceSetup
    /// What an admin chose; empty fields mean automatic.
    var settings: VoiceSettings
    /// Providers that have a key and an OpenAI-style audio API, for the settings picker.
    var providers: [Option]
    var voices: [String]

    struct Option: Encodable {
        var id: String
        var name: String
        var canTranscribe: Bool
        var canSpeak: Bool
    }
}

struct TranscriptResponse: Encodable {
    var text: String
}

/// Voice setup: `GET /api/voice` and the admin's `PUT /api/voice`. Transcribing and speaking
/// for chats live in ConversationVoiceRoutes.
func voiceRoutes(_ api: RoutesBuilder, admin adminAPI: RoutesBuilder, ctx: ServerContext) {
    let voiceSettings = VoiceSettingsStore(root: ctx.dataDir)
    let speech = SpeechClient.shared

    @Sendable func currentSetup() async -> (VoiceSetup, VoiceSettings, [ProviderConfig]) {
        let providers = await ctx.store.loadProviders()
        let settings = await voiceSettings.load()
        let setup = SpeechDefaults.resolve(settings: settings, providers: providers) { provider in
            !(ctx.keyRing.get(provider.keyAccount) ?? "").isEmpty
        }
        return (setup, settings, providers)
    }

    @Sendable func info() async -> VoiceInfoResponse {
        let (setup, settings, providers) = await currentSetup()
        let options = providers
            .filter { $0.kind == .openAICompatible && !(ctx.keyRing.get($0.keyAccount) ?? "").isEmpty }
            .map { provider in
                VoiceInfoResponse.Option(
                    id: provider.id,
                    name: provider.name,
                    canTranscribe: SpeechDefaults.transcriptionDialect(for: provider) != nil,
                    // Built-in providers without speech are left out; a provider you added yourself
                    // (for example a self-hosted Kokoro server) can be picked for speech.
                    canSpeak: SpeechDefaults.ttsModels[provider.id] != nil || SpeechDefaults.isKokoro(provider)
                        || !ProviderConfig.builtin.contains(where: { $0.id == provider.id })
                )
            }
        let speaker = setup.tts.flatMap { tts in providers.first { $0.id == tts.providerID } }
        return VoiceInfoResponse(setup: setup, settings: settings, providers: options, voices: SpeechDefaults.voices(for: speaker))
    }

    @Sendable func engine(_ engine: VoiceSetup.Engine, _ providers: [ProviderConfig], lang: String) throws -> (ProviderConfig, String) {
        guard let provider = providers.first(where: { $0.id == engine.providerID }),
              let key = ctx.keyRing.get(provider.keyAccount), !key.isEmpty else {
            throw Abort(.conflict, reason: SrvL10n.t("srv.voiceNoKey", lang: lang))
        }
        return (provider, key)
    }

    api.get("voice") { req async throws -> Response in
        // Opening voice mode is the cue to wake the voice server, so the first reply doesn't pay for a cold start.
        let (setup, _, providers) = await currentSetup()
        if let tts = setup.tts, let provider = providers.first(where: { $0.id == tts.providerID }),
           let key = ctx.keyRing.get(provider.keyAccount), !key.isEmpty {
            let voice = tts.voice ?? SpeechDefaults.defaultVoice(for: provider, language: SrvL10n.lang(for: req))
            Task { await speech.warmUp(provider: provider, key: key, model: tts.model, voice: voice) }
        }
        return try req.json(await info())
    }

    adminAPI.put("voice") { req async throws -> Response in
        var body = try req.decodeJSON(VoiceSettings.self)
        let ids = Set(await ctx.store.loadProviders().map(\.id))
        for id in [body.sttProviderID, body.ttsProviderID].compactMap({ $0 }) where !id.isEmpty && id != "none" {
            guard ids.contains(id) else { throw Abort(.badRequest, reason: SrvL10n.t("srv.voiceUnknownProvider", lang: SrvL10n.lang(for: req))) }
        }
        if let voice = body.ttsVoice, voice.count > 40 { body.ttsVoice = String(voice.prefix(40)) }
        await voiceSettings.save(body)
        return try req.json(await info())
    }
}
