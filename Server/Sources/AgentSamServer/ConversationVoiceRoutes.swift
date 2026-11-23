import Vapor
import Foundation
import AgentSamCore

func conversationVoiceRoutes(_ api: RoutesBuilder, ctx: ServerContext) {
    let speech = SpeechClient.shared
    let voiceSettings = VoiceSettingsStore(root: ctx.dataDir)

    @Sendable func currentSetup() async -> (VoiceSetup, [ProviderConfig]) {
        let providers = await ctx.store.loadProviders()
        let settings = await voiceSettings.load()
        let setup = SpeechDefaults.resolve(settings: settings, providers: providers) { provider in
            !(ctx.keyRing.get(provider.keyAccount) ?? "").isEmpty
        }
        return (setup, providers)
    }

    @Sendable func engine(_ engine: VoiceSetup.Engine, _ providers: [ProviderConfig], lang: String) throws -> (ProviderConfig, String) {
        guard let provider = providers.first(where: { $0.id == engine.providerID }),
              let key = ctx.keyRing.get(provider.keyAccount), !key.isEmpty else {
            throw Abort(.conflict, reason: SrvL10n.t("srv.voiceNoKey", lang: lang))
        }
        return (provider, key)
    }

    /// `spoken` is the language the words are in, which can differ from the app's language `lang`:
    /// numbers and amounts are read in it.
    @Sendable func synthesize(_ req: Request, text: String, tts: VoiceSetup.Engine, provider: ProviderConfig, key: String, lang: String, spoken: String, chunkCount: Int?) async throws -> Response {
        let started = Date()
        do {
            let audio = try await speech.speakAudio(
                text: text,
                provider: provider,
                key: key,
                model: tts.model,
                voice: tts.voice ?? SpeechDefaults.defaultVoice(for: provider, language: lang),
                instructions: "You are Ada, a calm, friendly team coordinator giving a quick spoken update. Natural pace, warm and clear.",
                language: spoken
            )
            req.logger.info("speech: \(text.count) chars in \(Int(Date().timeIntervalSince(started) * 1000)) ms (\(audio.data.count) bytes, \(audio.mimeType))")
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: audio.mimeType)
            headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=3600")
            if let chunkCount { headers.replaceOrAdd(name: "X-Speech-Chunks", value: String(chunkCount)) }
            return Response(status: .ok, headers: headers, body: .init(data: audio.data))
        } catch let error as SpeechError {
            throw Abort(.badGateway, reason: error.message)
        }
    }

    api.on(.POST, "conversations", ":id", "transcribe", body: .collect(maxSize: ByteCount(value: SpeechClient.maxAudioBytes))) { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        let owner = try req.requirePrincipal().conversationOwnerID
        guard try await ctx.conversations.get(id: req.conversationID, ownerID: owner) != nil else { throw ConversationError.notFound }
        let (setup, providers) = await currentSetup()
        guard let stt = setup.stt else { throw Abort(.conflict, reason: SrvL10n.t("srv.voiceNoSTT", lang: lang)) }
        guard let buffer = req.body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.voiceEmpty", lang: lang))
        }
        let audio = Data(buffer.readableBytesView)
        let mimeType = req.headers.contentType.map { "\($0.type)/\($0.subType)" } ?? "audio/webm"
        let (provider, key) = try engine(stt, providers, lang: lang)
        do {
            let text = try await speech.transcribe(audio: audio, mimeType: mimeType, provider: provider, key: key, model: stt.model, language: lang)
            return try req.json(TranscriptResponse(text: text))
        } catch let error as SpeechError {
            throw Abort(.badGateway, reason: error.message)
        }
    }

    api.get("conversations", ":id", "messages", ":messageID", "speech") { req async throws -> Response in
        let lang = req.query[String.self, at: "lang"] ?? SrvL10n.lang(for: req)
        let owner = try req.requirePrincipal().conversationOwnerID
        guard let conversation = try await ctx.conversations.get(id: req.conversationID, ownerID: owner),
              let messageID = req.parameters.get("messageID").flatMap(UUID.init(uuidString:)),
              let message = conversation.messages.first(where: { $0.id == messageID }),
              message.role == .assistant, message.status == .complete else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.voiceNoLine", lang: lang))
        }
        let (setup, providers) = await currentSetup()
        guard let tts = setup.tts else { throw Abort(.conflict, reason: SrvL10n.t("srv.voiceNoTTS", lang: lang)) }
        let (provider, key) = try engine(tts, providers, lang: lang)
        // `chunk=i` speaks one short piece, so the first words play while the rest is still being made.
        // Without it the whole message is spoken in one go.
        // A voice reply may carry on-screen detail; only its spoken part is read, and long replies stop early.
        let tail = lang.hasPrefix("es") ? "El resto está en pantalla." : "The rest is on screen."
        let source = message.speech ?? message.text
        let spoken = SpokenNumbers.language(of: source, fallback: lang)
        var text = SpeechClient.cappedSpeech(SpeechClient.spokenText(source, language: spoken), tail: tail)
        var chunkCount: Int?
        if let index = req.query[Int.self, at: "chunk"] {
            let pieces = SpeechClient.spokenChunks(text)
            chunkCount = pieces.count
            guard index >= 0, index < pieces.count else { return Response(status: .noContent) }
            text = pieces[index]
        }
        return try await synthesize(req, text: text, tts: tts, provider: provider, key: key, lang: lang, spoken: spoken, chunkCount: chunkCount)
    }

    /// Speaks one piece of text the browser already has, so a reply can start playing
    /// sentence by sentence while it is still being written.
    api.on(.POST, "conversations", ":id", "speech", body: .collect(maxSize: ByteCount(value: 32 * 1024))) { req async throws -> Response in
        struct SpeechText: Decodable { var text: String }
        let lang = req.query[String.self, at: "lang"] ?? SrvL10n.lang(for: req)
        let owner = try req.requirePrincipal().conversationOwnerID
        guard let conversation = try await ctx.conversations.get(id: req.conversationID, ownerID: owner) else { throw ConversationError.notFound }
        let body = try req.content.decode(SpeechText.self)
        // One sentence may not say which language it is in; the person's last message usually does.
        let lastAsked = conversation.messages.last(where: { $0.role == .user })?.text ?? ""
        let spoken = SpokenNumbers.language(of: body.text, fallback: SpokenNumbers.language(of: lastAsked, fallback: lang))
        let (setup, providers) = await currentSetup()
        guard let tts = setup.tts else { throw Abort(.conflict, reason: SrvL10n.t("srv.voiceNoTTS", lang: lang)) }
        let (provider, key) = try engine(tts, providers, lang: lang)
        return try await synthesize(req, text: body.text, tts: tts, provider: provider, key: key, lang: lang, spoken: spoken, chunkCount: nil)
    }
}
