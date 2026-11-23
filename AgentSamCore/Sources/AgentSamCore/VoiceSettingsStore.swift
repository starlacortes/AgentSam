import Foundation

/// Keeps the admin's voice choices in `chat-settings.json`.
///
/// The file name and its `voice` key come from the retired coordinator chat, so settings saved
/// before it was removed still load. Other keys in old files (such as `defaultTeamID`) are ignored.
public actor VoiceSettingsStore {
    public nonisolated let root: URL

    private struct File: Codable {
        var voice: VoiceSettings?
    }

    public init(root: URL) {
        self.root = root
    }

    private nonisolated var url: URL { root.appendingPathComponent("chat-settings.json") }

    /// The saved settings, or automatic choices when nothing was saved.
    public func load() -> VoiceSettings {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return VoiceSettings() }
        return file.voice ?? VoiceSettings()
    }

    public func save(_ settings: VoiceSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(File(voice: settings)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
