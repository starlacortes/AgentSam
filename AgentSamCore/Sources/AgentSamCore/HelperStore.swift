import Foundation

/// A helper role Ada saved for herself, after the user approved it on a card.
///
/// A saved helper only holds prompt text and default tool groups. It never changes permissions,
/// keys, spending limits or connectors: tools still go through the same approvals as Ada's.
public struct SavedHelper: Codable, Hashable, Sendable, Identifiable {
    /// The function key, lowercased letters and digits: "pricecheck" for priceCheckAda.
    public var id: String
    /// What Ada called the function ("price check").
    public var function: String
    /// researchAda, priceCheckAda.
    public var name: String
    public var role: String
    public var groups: [HelperTools.Group]
    public var version: Int
    /// Why Ada made the latest change, as shown on the approval card.
    public var reason: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Earlier versions, newest first, so a change can be undone.
    public var history: [Version]

    public struct Version: Codable, Hashable, Sendable {
        public var version: Int
        public var role: String
        public var groups: [HelperTools.Group]
        public var reason: String
        public var savedAt: Date
    }
}

/// Saved helpers, one file per person. It reads the files on every call, so several instances
/// (the engine and the approval route) always agree.
///
/// `helpers.json` holds the roles saved before roles were private. They were shared already, so
/// they stay general: every person's helpers use them, read-only, unless the person saved their own
/// role for the same function. The server token keeps writing `helpers.json`, as it is the admin
/// account that existed when those roles were made.
public actor HelperStore {
    public nonisolated let root: URL
    public static let maxHelpers = 20
    public static let maxHistory = 5
    static let serverTokenOwner = "shared-server-token"

    private struct File: Codable { var helpers: [SavedHelper] = [] }

    public init(root: URL) { self.root = root }

    private nonisolated var generalURL: URL { root.appendingPathComponent("helpers.json") }

    /// The file a person's roles live in. Base64url of the owner ID, like the other owner-scoped stores.
    private nonisolated func fileURL(ownerID: String) -> URL {
        if ownerID == Self.serverTokenOwner { return generalURL }
        let key = Data(ownerID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return root.appendingPathComponent("helpers-\(key).json")
    }

    private func read(_ url: URL) -> File {
        guard let data = try? Data(contentsOf: url) else { return File() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(File.self, from: data)) ?? File()
    }

    private func write(_ file: File, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? encoder.encode(file) { try? data.write(to: url, options: .atomic) }
    }

    /// The roles one person's helpers use: their own, plus general ones they have not replaced.
    /// With no owner, only the general ones.
    public func all(ownerID: String?) -> [SavedHelper] {
        let general = read(generalURL).helpers
        guard let ownerID, fileURL(ownerID: ownerID) != generalURL else { return general.sorted { $0.name < $1.name } }
        let own = read(fileURL(ownerID: ownerID)).helpers
        let ownIDs = Set(own.map(\.id))
        return (own + general.filter { !ownIDs.contains($0.id) }).sorted { $0.name < $1.name }
    }

    public func helper(for function: String, ownerID: String?) -> SavedHelper? {
        let key = HelperTools.key(for: function)
        return all(ownerID: ownerID).first { $0.id == key }
    }

    /// Saves a new version of a helper, keeping the one it replaces in its history.
    @discardableResult
    /// A person's first change to a general role starts their own copy, so the general one stays as it is.
    public func save(function: String, role: String, groups: Set<HelperTools.Group>, reason: String, ownerID: String, now: Date = Date()) throws -> SavedHelper {
        guard let name = HelperTools.name(for: function) else { throw HelperStoreError.invalid("The function needs one to three short words.") }
        let key = HelperTools.key(for: function)
        let url = fileURL(ownerID: ownerID)
        var file = read(url)
        let sortedGroups = groups.union([.read]).sorted { $0.rawValue < $1.rawValue }
        if let index = file.helpers.firstIndex(where: { $0.id == key }) {
            var helper = file.helpers[index]
            helper.history.insert(.init(version: helper.version, role: helper.role, groups: helper.groups, reason: helper.reason, savedAt: helper.updatedAt), at: 0)
            helper.history = Array(helper.history.prefix(Self.maxHistory))
            helper.version += 1
            helper.role = role
            helper.groups = sortedGroups
            helper.reason = reason
            helper.updatedAt = now
            file.helpers[index] = helper
            write(file, to: url)
            return helper
        }
        guard file.helpers.count < Self.maxHelpers else {
            throw HelperStoreError.invalid("There are already \(Self.maxHelpers) saved helpers. Improve an existing one instead.")
        }
        let helper = SavedHelper(id: key, function: function, name: name, role: role, groups: sortedGroups, version: 1, reason: reason, createdAt: now, updatedAt: now, history: [])
        file.helpers.append(helper)
        write(file, to: url)
        return helper
    }

    /// Puts back the version before the current one. With no earlier version the saved helper is
    /// removed, so the general or built-in role (if any) applies again. Returns what is in effect afterwards.
    /// Only the person's own roles can be undone; a general role is left as it is. When the
    /// person's own role is removed, the general one (if any) applies to them again.
    public func undo(function: String, ownerID: String, now: Date = Date()) throws -> SavedHelper? {
        let key = HelperTools.key(for: function)
        let url = fileURL(ownerID: ownerID)
        var file = read(url)
        guard let index = file.helpers.firstIndex(where: { $0.id == key }) else {
            if read(generalURL).helpers.contains(where: { $0.id == key }) {
                throw HelperStoreError.invalid("The role for “\(function)” is shared with everyone and cannot be undone from here. Save a new role to use your own.")
            }
            throw HelperStoreError.invalid("There is no saved helper for “\(function)”.")
        }
        var helper = file.helpers[index]
        guard let previous = helper.history.first else {
            file.helpers.remove(at: index)
            write(file, to: url)
            return nil
        }
        helper.history.removeFirst()
        helper.version += 1
        helper.role = previous.role
        helper.groups = previous.groups
        helper.reason = "Undid version \(helper.version - 1), back to version \(previous.version)."
        helper.updatedAt = now
        file.helpers[index] = helper
        write(file, to: url)
        return helper
    }
}

public enum HelperStoreError: Error, Sendable {
    case invalid(String)
    public var message: String { if case .invalid(let text) = self { return text }; return "" }
}
