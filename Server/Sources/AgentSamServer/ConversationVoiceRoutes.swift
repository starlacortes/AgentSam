import Vapor
import Foundation
import AgentSamCore

func conversationVoiceRoutes(_ api: RoutesBuilder, ctx: ServerContext) {
    let speech = SpeechClient()
    let chats = ChatStore(root: ctx.dataDir)

    @Sendable func currentSetup() async -> (VoiceSetup, [ProviderConfig]) {
        let providers = await ctx.store.loadProviders()
        let settings = await chats.loadSettings().voice ?? VoiceSettings()
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
        do {
            let audio = try await speech.speak(
                text: message.text,
                provider: provider,
                key: key,
                model: tts.model,
                voice: tts.voice ?? SpeechDefaults.defaultVoice(for: provider, language: lang),
                instructions: "You are Ada, a calm, friendly team coordinator giving a quick spoken update. Natural pace, warm and clear."
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
