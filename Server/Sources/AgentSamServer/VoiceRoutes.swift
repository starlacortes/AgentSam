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

/// Voice for the coordinator chat: `/api/voice`, `/api/chats/:id/transcribe`, and spoken replies.
func voiceRoutes(
    _ api: RoutesBuilder,
    admin adminAPI: RoutesBuilder,
    ctx: ServerContext,
    chats: ChatStore,
    ownedChat: @escaping @Sendable (Request) async throws -> CoordinatorChat
) {
    let speech = SpeechClient()

    @Sendable func currentSetup() async -> (VoiceSetup, VoiceSettings, [ProviderConfig]) {
        let providers = await ctx.store.loadProviders()
        let settings = await chats.loadSettings().voice ?? VoiceSettings()
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
        try req.json(await info())
    }

    adminAPI.put("voice") { req async throws -> Response in
        var body = try req.decodeJSON(VoiceSettings.self)
        let ids = Set(await ctx.store.loadProviders().map(\.id))
        for id in [body.sttProviderID, body.ttsProviderID].compactMap({ $0 }) where !id.isEmpty && id != "none" {
            guard ids.contains(id) else { throw Abort(.badRequest, reason: SrvL10n.t("srv.voiceUnknownProvider", lang: SrvL10n.lang(for: req))) }
        }
        if let voice = body.ttsVoice, voice.count > 40 { body.ttsVoice = String(voice.prefix(40)) }
        var settings = await chats.loadSettings()
        settings.voice = body
        await chats.saveSettings(settings)
        return try req.json(await info())
    }

    // The browser posts the raw recording; Content-Type says its format.
    api.on(.POST, "chats", ":id", "transcribe", body: .collect(maxSize: ByteCount(value: SpeechClient.maxAudioBytes))) { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        let chat = try await ownedChat(req)
        let (setup, _, providers) = await currentSetup()
        guard let stt = setup.stt else {
            throw Abort(.conflict, reason: SrvL10n.t("srv.voiceNoSTT", lang: lang))
        }
        guard let buffer = req.body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.voiceEmpty", lang: lang))
        }
        let audio = Data(buffer.readableBytesView)
        let mimeType = req.headers.contentType.map { "\($0.type)/\($0.subType)" } ?? "audio/webm"
        let (provider, key) = try engine(stt, providers, lang: lang)
        do {
            let text = try await speech.transcribe(audio: audio, mimeType: mimeType, provider: provider, key: key, model: stt.model, language: chat.language)
            return try req.json(TranscriptResponse(text: text))
        } catch let error as SpeechError {
            throw Abort(.badGateway, reason: error.message)
        }
    }

    // A coordinator line as MP3. A GET, so an <audio> element can play it with the session cookie.
    api.get("chats", ":id", "lines", ":lineID", "speech") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        let chat = try await ownedChat(req)
        guard let lineID = req.parameters.get("lineID").flatMap(UUID.init(uuidString:)),
              let line = chat.lines.first(where: { $0.id == lineID }), line.kind == .coordinator else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.voiceNoLine", lang: lang))
        }
        let (setup, _, providers) = await currentSetup()
        guard let tts = setup.tts else {
            throw Abort(.conflict, reason: SrvL10n.t("srv.voiceNoTTS", lang: lang))
        }
        let (provider, key) = try engine(tts, providers, lang: lang)
        let teams = await ctx.store.loadTeams()
        let name = teams.first(where: { $0.id == chat.teamID })?.coordinator?.name ?? "the coordinator"
        do {
            let audio = try await speech.speak(
                text: line.text,
                provider: provider,
                key: key,
                model: tts.model,
                voice: tts.voice ?? SpeechDefaults.defaultVoice(for: provider, language: chat.language),
                instructions: "You are \(name), a calm, friendly team coordinator giving a quick spoken update. Natural pace, warm and clear."
            )
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "audio/mpeg")
            headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=3600")
            return Response(status: .ok, headers: headers, body: .init(data: audio))
        } catch let error as SpeechError {
            throw Abort(.badGateway, reason: error.message)
        }
    }
}
