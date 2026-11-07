@testable import AgentSamServer
import XCTVapor
import Foundation
import AgentSamCore

final class VoiceTests: XCTestCase {
    // MARK: Picking providers

    private let providers = ProviderConfig.builtin

    private func resolve(_ settings: VoiceSettings = VoiceSettings(), keys: Set<String>) -> VoiceSetup {
        SpeechDefaults.resolve(settings: settings, providers: providers) { keys.contains($0.id) }
    }

    func testOpenAIKeyGivesBothDirections() {
        let setup = resolve(keys: ["anthropic", "openai"])
        XCTAssertEqual(setup.stt?.providerID, "openai")
        XCTAssertEqual(setup.stt?.model, "gpt-4o-mini-transcribe")
        XCTAssertEqual(setup.tts?.providerID, "openai")
        XCTAssertEqual(setup.tts?.voice, SpeechDefaults.ttsVoice)
    }

    func testGroqOnlyTranscribesAndLeavesSpeechToTheBrowser() {
        let setup = resolve(keys: ["anthropic", "groq"])
        XCTAssertEqual(setup.stt?.providerID, "groq")
        XCTAssertEqual(setup.stt?.model, "whisper-large-v3-turbo")
        XCTAssertNil(setup.tts)
    }

    func testAnthropicOnlyHasNoServerSpeech() {
        let setup = resolve(keys: ["anthropic"])
        XCTAssertNil(setup.stt)
        XCTAssertNil(setup.tts)
    }

    func testSettingsOverrideAndCanTurnServerSpeechOff() {
        let settings = VoiceSettings(sttProviderID: "groq", sttModel: "whisper-large-v3", ttsProviderID: "none")
        let setup = resolve(settings, keys: ["openai", "groq"])
        XCTAssertEqual(setup.stt?.providerID, "groq")
        XCTAssertEqual(setup.stt?.model, "whisper-large-v3")
        XCTAssertNil(setup.tts)
    }

    func testChosenProviderWithoutKeyFallsBack() {
        let setup = resolve(VoiceSettings(sttProviderID: "groq"), keys: ["openai"])
        XCTAssertEqual(setup.stt?.providerID, "openai")
    }

    // MARK: GreenPT

    func testGreenPTKeyTranscribesWithGreenS() {
        let setup = resolve(keys: ["anthropic", "greenpt"])
        XCTAssertEqual(setup.stt?.providerID, "greenpt")
        XCTAssertEqual(setup.stt?.model, "green-s")
        XCTAssertNil(setup.tts, "GreenPT has no text-to-speech")
    }

    func testGreenPTAddedByHandIsRecognizedByHost() {
        let custom = ProviderConfig(id: "my-green", name: "Green", kind: .openAICompatible, baseURL: "https://api.eu.greenpt.ai/v1", models: ["glm-5.3"])
        XCTAssertEqual(SpeechDefaults.transcriptionDialect(for: custom), .greenPT)
        XCTAssertEqual(SpeechDefaults.sttModel(for: custom), "green-s")
        let setup = SpeechDefaults.resolve(settings: VoiceSettings(), providers: providers + [custom]) { $0.id == "my-green" }
        XCTAssertEqual(setup.stt?.providerID, "my-green")
    }

    func testProvidersWithoutSpeechAreNotOffered() {
        let deepseek = providers.first { $0.id == "deepseek" }!
        XCTAssertNil(SpeechDefaults.transcriptionDialect(for: deepseek))
    }

    func testGreenPTRequestAndResponseShape() throws {
        let provider = providers.first { $0.id == "greenpt" }!
        let url = try SpeechClient.greenPTListenURL(provider, model: "green-s", language: "es")
        XCTAssertEqual(url.host, "api.greenpt.ai")
        XCTAssertEqual(url.path, "/v1/listen")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "model", value: "green-s")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "language", value: "es")))

        let body = #"{"metadata":{},"results":{"channels":[{"alternatives":[{"transcript":" Hola equipo. ","words":[]}]}]}}"#
        XCTAssertEqual(try SpeechClient.greenPTTranscript(Data(body.utf8)), "Hola equipo.")
        XCTAssertThrowsError(try SpeechClient.greenPTTranscript(Data("not json".utf8)))
    }

    // MARK: Upload format

    func testMultipartBodyCarriesFieldsAndFile() throws {
        let body = SpeechClient.multipartBody(
            boundary: "XYZ",
            fields: [("model", "whisper-1")],
            fileField: "file",
            fileName: "speech.webm",
            fileType: "audio/webm",
            fileData: Data("AUDIO".utf8)
        )
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("--XYZ\r\n"))
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(text.contains("filename=\"speech.webm\"\r\nContent-Type: audio/webm\r\n\r\nAUDIO\r\n"))
        XCTAssertTrue(text.hasSuffix("--XYZ--\r\n"))
    }

    func testFileExtensionFollowsBrowserFormats() {
        XCTAssertEqual(SpeechClient.fileExtension(for: "audio/webm;codecs=opus"), "webm")
        XCTAssertEqual(SpeechClient.fileExtension(for: "audio/mp4"), "mp4")
        XCTAssertEqual(SpeechClient.fileExtension(for: "audio/ogg; codecs=opus"), "ogg")
    }

    // MARK: Routes

    private let serverToken = "test-server-token-0123456789"
    private var dataDir: URL!
    private var app: Application!

    private func startApp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-voice-\(UUID().uuidString)")
        setenv("AGENTSAM_DATA", dataDir.path, 1)
        setenv("AGENTSAM_TOKEN", serverToken, 1)
        setenv("AGENTSAM_WEB_DIR", dataDir.appendingPathComponent("no-web").path, 1)
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        if let app { try await app.asyncShutdown() }
        app = nil
        if let dataDir { try? FileManager.default.removeItem(at: dataDir) }
    }

    func testTranscribeWithoutASpeechKeyExplainsWhatIsMissing() async throws {
        unsetenv("AGENTSAM_KEY_PROVIDER_OPENAI")
        unsetenv("AGENTSAM_KEY_PROVIDER_GROQ")
        try await startApp()
        struct Chat: Decodable { var id: UUID }
        struct Info: Decodable { struct Setup: Decodable { var stt: String? }; var voices: [String] }

        try await app.test(.GET, "api/voice", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: self.serverToken)
        }) { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertFalse(try res.content.decode(Info.self).voices.isEmpty)
            XCTAssertFalse(res.body.string.contains("\"stt\":{"), "No key means no transcription engine")
        }

        var chatID = UUID()
        try await app.test(.POST, "api/chats", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: self.serverToken)
        }) { res async throws in
            chatID = try res.content.decode(Chat.self).id
        }

        try await app.test(.POST, "api/chats/\(chatID)/transcribe", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: self.serverToken)
            req.headers.contentType = HTTPMediaType(type: "audio", subType: "webm")
            req.body = ByteBuffer(bytes: [1, 2, 3])
        }) { res async in
            XCTAssertEqual(res.status, .conflict)
            XCTAssertTrue(res.body.string.contains("OpenAI or Groq"))
        }
    }
}
