import Foundation

/// A photo the user attached to a chat message. Only this small record is stored in the
/// conversation JSON; the image bytes live next to it on disk, because the web app polls the
/// conversation several times a second while Ada answers.
public struct PhotoAttachment: Codable, Hashable, Sendable {
    public var id: String
    public var mediaType: String
    public var bytes: Int

    public init(id: String, mediaType: String, bytes: Int) {
        self.id = id
        self.mediaType = mediaType
        self.bytes = bytes
    }
}

/// Photos attached to a conversation: `conversations/<uuid>/photos/<id>.<ext>`. This sits beside the
/// chat workspace (`files/`), not inside it, so photos never show up as workspace files Ada can
/// overwrite or that get copied into missions as text.
public struct ConversationPhotoStore: Sendable {
    /// The browser shrinks photos before upload; this only stops oversized raw uploads.
    public static let maxBytes = 5_000_000
    public static let maxPerMessage = 4

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func directory(_ conversationID: UUID) -> URL {
        root
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent(conversationID.uuidString, isDirectory: true)
            .appendingPathComponent("photos", isDirectory: true)
    }

    /// The image type from the file's first bytes. Only formats every vision provider accepts.
    public static func mediaType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }

    static func fileExtension(for mediaType: String) -> String {
        switch mediaType {
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "jpg"
        }
    }

    /// Photo ids are lowercase UUIDs, which also keeps them safe to use as file names.
    static func normalizedID(_ raw: String) -> String? {
        UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0.uuidString.lowercased() }
    }

    private func file(conversationID: UUID, id: String) -> (url: URL, mediaType: String)? {
        guard let id = Self.normalizedID(id) else { return nil }
        for type in ["image/jpeg", "image/png", "image/webp", "image/gif"] {
            let url = directory(conversationID).appendingPathComponent("\(id).\(Self.fileExtension(for: type))")
            if FileManager.default.fileExists(atPath: url.path) { return (url, type) }
        }
        return nil
    }

    /// Saves an uploaded photo. Returns nil when it is empty, too large, or not a supported image.
    public func save(conversationID: UUID, data: Data) -> PhotoAttachment? {
        guard !data.isEmpty, data.count <= Self.maxBytes, let type = Self.mediaType(of: data) else { return nil }
        let id = UUID().uuidString.lowercased()
        let folder = directory(conversationID)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("\(id).\(Self.fileExtension(for: type))"), options: .atomic)
        } catch {
            return nil
        }
        return PhotoAttachment(id: id, mediaType: type, bytes: data.count)
    }

    public func attachment(conversationID: UUID, id: String) -> PhotoAttachment? {
        guard let found = file(conversationID: conversationID, id: id),
              let size = try? found.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return PhotoAttachment(id: found.url.deletingPathExtension().lastPathComponent, mediaType: found.mediaType, bytes: size)
    }

    public func load(conversationID: UUID, id: String) -> (data: Data, mediaType: String)? {
        guard let found = file(conversationID: conversationID, id: id),
              let data = try? Data(contentsOf: found.url) else { return nil }
        return (data, found.mediaType)
    }

    /// The photo as a model input block, or nil when its file is gone.
    public func image(conversationID: UUID, attachment: PhotoAttachment) -> APIImage? {
        load(conversationID: conversationID, id: attachment.id).map { APIImage(mediaType: $0.mediaType, data: $0.data.base64EncodedString()) }
    }

    public func removeAll(conversationID: UUID) {
        try? FileManager.default.removeItem(at: directory(conversationID))
    }
}

/// Whether a model can look at images. Most current models can; this lists the families known to be
/// text-only, so Ada can say so plainly instead of sending photos the provider would reject. Unknown
/// models are tried, and a provider that rejects the images still gets a clear fallback.
public enum VisionSupport {
    public static func accepts(provider: ProviderConfig, model: String) -> Bool {
        let name = model.lowercased()
        // Explicit vision variants of otherwise text-only families.
        let visionMarkers = ["vision", "-vl", "vl-", "llava", "pixtral", "llama-4", "llama4", "gemma3", "gemma-3", "minicpm-v", "moondream"]
        if visionMarkers.contains(where: { name.contains($0) }) { return true }
        if name.range(of: "glm-[0-9.]+v", options: .regularExpression) != nil { return true }
        let textOnly = [
            "deepseek", "llama-3", "llama3", "mixtral", "mistral-7b", "gpt-oss", "qwen3", "qwen2.5", "qwq",
            "glm", "gpt-3.5", "o1-mini", "o3-mini", "claude-2", "claude-instant", "codestral",
        ]
        return !textOnly.contains(where: { name.contains($0) })
    }
}
