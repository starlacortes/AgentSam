import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Settings

/// Which providers turn speech into text and text into speech for the coordinator chat.
/// Every field is optional: anything left empty is picked automatically from the providers that have keys.
public struct VoiceSettings: Codable, Hashable, Sendable {
    public var sttProviderID: String?
    public var sttModel: String?
    /// "none" turns server speech off, so clients use their own built-in voice.
    public var ttsProviderID: String?
    public var ttsModel: String?
    public var ttsVoice: String?

    public init(sttProviderID: String? = nil, sttModel: String? = nil, ttsProviderID: String? = nil, ttsModel: String? = nil, ttsVoice: String? = nil) {
        self.sttProviderID = sttProviderID
        self.sttModel = sttModel
        self.ttsProviderID = ttsProviderID
        self.ttsModel = ttsModel
        self.ttsVoice = ttsVoice
    }
}

/// A resolved speech setup: what will actually be used, given the settings and which keys exist.
public struct VoiceSetup: Codable, Hashable, Sendable {
    public struct Engine: Codable, Hashable, Sendable {
        public var providerID: String
        public var providerName: String
        public var model: String
        public var voice: String?
    }

    /// Nil when no provider can transcribe: the mic is unavailable.
    public var stt: Engine?
    /// Nil when no provider can speak: clients fall back to their built-in voice.
    public var tts: Engine?
}

/// How a provider's speech-to-text API is shaped.
public enum TranscriptionDialect: String, Codable, Sendable {
    /// `POST /audio/transcriptions`, multipart upload, Bearer auth (OpenAI, Groq).
    case openAI
    /// `POST /listen`, raw audio body, Token auth, Deepgram-style JSON (GreenPT).
    case greenPT
}

public enum SpeechDefaults {
    /// Speech-to-text models for providers with an OpenAI-style `/audio/transcriptions` endpoint, best first.
    public static let sttModels: [String: String] = [
        "openai": "gpt-4o-mini-transcribe",
        "groq": "whisper-large-v3-turbo",
        "greenpt": "green-s",
    ]

    /// Which transcription API a provider speaks, or nil when it has none we know of.
    /// GreenPT is recognized by its host too, so a provider added by hand under another id still works.
    public static func transcriptionDialect(for provider: ProviderConfig) -> TranscriptionDialect? {
        let host = URL(string: provider.baseURL)?.host?.lowercased() ?? ""
        if provider.id == "greenpt" || host == "greenpt.ai" || host.hasSuffix(".greenpt.ai") { return .greenPT }
        if sttModels[provider.id] != nil || host == "api.openai.com" || host == "api.groq.com" { return .openAI }
        return nil
    }

    /// The default speech-to-text model for a provider that can transcribe.
    public static func sttModel(for provider: ProviderConfig) -> String? {
        if let model = sttModels[provider.id] { return model }
        switch transcriptionDialect(for: provider) {
        case .greenPT: return "green-s"
        case .openAI: return URL(string: provider.baseURL)?.host == "api.groq.com" ? "whisper-large-v3-turbo" : "gpt-4o-mini-transcribe"
        case nil: return nil
        }
    }
    /// Text-to-speech models for providers with an OpenAI-style `/audio/speech` endpoint.
    public static let ttsModels: [String: String] = [
        "openai": "gpt-4o-mini-tts",
    ]
    public static let ttsVoice = "alloy"
    public static let ttsVoices = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]

    /// Picks engines from the settings, falling back to the first provider that has a key.
    public static func resolve(settings: VoiceSettings, providers: [ProviderConfig], hasKey: (ProviderConfig) -> Bool) -> VoiceSetup {
        func usable(_ id: String?) -> ProviderConfig? {
            guard let id, let provider = providers.first(where: { $0.id == id }),
                  provider.kind == .openAICompatible, hasKey(provider) else { return nil }
            return provider
        }

        var setup = VoiceSetup()

        func canTranscribe(_ provider: ProviderConfig?) -> ProviderConfig? {
            guard let provider, transcriptionDialect(for: provider) != nil else { return nil }
            return provider
        }
        // An explicit pick wins; otherwise OpenAI, then Groq, then GreenPT (any id on its host).
        var greenPT: ProviderConfig?
        for candidate in providers where transcriptionDialect(for: candidate) == .greenPT {
            if let found = usable(candidate.id) { greenPT = found; break }
        }
        let sttProvider = canTranscribe(usable(settings.sttProviderID))
            ?? usable("openai") ?? usable("groq") ?? greenPT
        if let provider = sttProvider {
            let model = nonEmpty(settings.sttProviderID == provider.id ? settings.sttModel : nil)
                ?? sttModel(for: provider) ?? "whisper-1"
            setup.stt = .init(providerID: provider.id, providerName: provider.name, model: model)
        }

        if settings.ttsProviderID != "none" {
            let ttsProvider = usable(settings.ttsProviderID) ?? usable("openai")
            if let provider = ttsProvider {
                let explicit = settings.ttsProviderID == provider.id
                let model = nonEmpty(explicit ? settings.ttsModel : nil) ?? ttsModels[provider.id] ?? "tts-1"
                let voice = nonEmpty(settings.ttsVoice) ?? ttsVoice
                setup.tts = .init(providerID: provider.id, providerName: provider.name, model: model, voice: voice)
            }
        }
        return setup
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Client

public struct SpeechError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Calls OpenAI-style audio endpoints: `/audio/transcriptions` and `/audio/speech`.
/// OpenAI and Groq both serve these, so the same code covers either key.
public struct SpeechClient: Sendable {
    public static let maxAudioBytes = 10 * 1024 * 1024
    public static let maxSpeechCharacters = 4_000

    let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: config)
        }
    }

    /// Turns recorded audio into text.
    public func transcribe(audio: Data, mimeType: String, provider: ProviderConfig, key: String, model: String, language: String? = nil) async throws -> String {
        guard !audio.isEmpty else { throw SpeechError("The recording was empty.") }
        guard audio.count <= Self.maxAudioBytes else { throw SpeechError("The recording is too long.") }
        if SpeechDefaults.transcriptionDialect(for: provider) == .greenPT {
            return try await transcribeGreenPT(audio: audio, mimeType: mimeType, provider: provider, key: key, model: model, language: language)
        }

        let boundary = "agentsam-\(UUID().uuidString)"
        var fields: [(String, String)] = [("model", model), ("response_format", "json")]
        if let language, !language.isEmpty { fields.append(("language", language)) }
        let body = Self.multipartBody(
            boundary: boundary,
            fields: fields,
            fileField: "file",
            fileName: "speech.\(Self.fileExtension(for: mimeType))",
            fileType: Self.baseType(mimeType),
            fileData: audio
        )

        var request = URLRequest(url: try Self.endpoint(provider, "audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await send(request)
        try Self.check(response, data)
        struct Transcription: Decodable { var text: String? }
        guard let text = try? JSONDecoder().decode(Transcription.self, from: data).text else {
            throw SpeechError("The speech provider sent back something unexpected.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// GreenPT's Deepgram-style API: raw audio in the body, options in the query, `Token` auth.
    private func transcribeGreenPT(audio: Data, mimeType: String, provider: ProviderConfig, key: String, model: String, language: String?) async throws -> String {
        var request = URLRequest(url: try Self.greenPTListenURL(provider, model: model, language: language))
        request.httpMethod = "POST"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.baseType(mimeType), forHTTPHeaderField: "Content-Type")
        request.httpBody = audio

        let (data, response) = try await send(request)
        try Self.check(response, data)
        return try Self.greenPTTranscript(data)
    }

    public static func greenPTListenURL(_ provider: ProviderConfig, model: String, language: String?) throws -> URL {
        guard var components = URLComponents(url: try endpoint(provider, "listen"), resolvingAgainstBaseURL: false) else {
            throw SpeechError("The provider's base URL is invalid.")
        }
        var query = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]
        if let language, !language.isEmpty { query.append(URLQueryItem(name: "language", value: language)) }
        components.queryItems = query
        guard let url = components.url else { throw SpeechError("The provider's base URL is invalid.") }
        return url
    }

    /// Reads `results.channels[0].alternatives[0].transcript`.
    public static func greenPTTranscript(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Results: Decodable {
                struct Channel: Decodable {
                    struct Alternative: Decodable { var transcript: String? }
                    var alternatives: [Alternative]?
                }
                var channels: [Channel]?
            }
            var results: Results?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw SpeechError("The speech provider sent back something unexpected.")
        }
        let text = decoded.results?.channels?.first?.alternatives?.first?.transcript ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns text into MP3 audio.
    public func speak(text: String, provider: ProviderConfig, key: String, model: String, voice: String, instructions: String? = nil) async throws -> Data {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxSpeechCharacters))
        guard !trimmed.isEmpty else { throw SpeechError("There is nothing to say.") }

        struct SpeechRequest: Encodable {
            var model: String
            var input: String
            var voice: String
            var response_format: String
            var instructions: String?
        }
        // Only the gpt-4o family takes steering instructions; older TTS models reject the field.
        let steer = model.hasPrefix("gpt-") ? instructions : nil
        var request = URLRequest(url: try Self.endpoint(provider, "audio/speech"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SpeechRequest(model: model, input: trimmed, voice: voice, response_format: "mp3", instructions: steer))

        let (data, response) = try await send(request)
        try Self.check(response, data)
        guard !data.isEmpty else { throw SpeechError("The speech provider sent back no audio.") }
        return data
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw SpeechError("Couldn't reach the speech provider: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    static func endpoint(_ provider: ProviderConfig, _ path: String) throws -> URL {
        let base = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(path)") else { throw SpeechError("The provider's base URL is invalid.") }
        return url
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SpeechError("Speech provider error (HTTP \(status)): " + LLMClient.snippet(of: data))
        }
    }

    /// "audio/webm;codecs=opus" → "audio/webm".
    static func baseType(_ mimeType: String) -> String {
        let base = mimeType.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return base.isEmpty ? "application/octet-stream" : base
    }

    /// File extension the provider uses to detect the audio format.
    public static func fileExtension(for mimeType: String) -> String {
        switch baseType(mimeType) {
        case "audio/webm", "video/webm": "webm"
        case "audio/mp4", "video/mp4", "audio/x-m4a", "audio/m4a", "audio/aac": "mp4"
        case "audio/ogg", "application/ogg": "ogg"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/flac": "flac"
        default: "webm"
        }
    }

    public static func multipartBody(boundary: String, fields: [(String, String)], fileField: String, fileName: String, fileType: String, fileData: Data) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        for (name, value) in fields {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(name)\"")
            line("")
            line(value)
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"")
        line("Content-Type: \(fileType)")
        line("")
        body.append(fileData)
        line("")
        line("--\(boundary)--")
        return body
    }
}
