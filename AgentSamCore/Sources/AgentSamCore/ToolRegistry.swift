import Foundation

/// Where a tool Ada can call comes from, which decides how a call to it runs.
public enum ToolFamily: Sendable, Equatable {
    /// The conversation's private workspace, programs and schedules (`ChatWorkspaceTools`).
    case chat
    /// Patch, move and delete, the shared project, the terminal and host folders (`ExtendedWorkspaceTools`).
    case extended
    /// Files of missions linked to this conversation (`ConversationMissionTools`).
    case mission
    /// Saving procedures as skills (`SkillTools`).
    case skill
    /// External services through `ConnectorHub`. Reads run at once; writes need an approval.
    case connector
}

/// The tools offered in one request, with the family each name belongs to.
///
/// This is the single place that decides which tools Ada is offered and how each one runs. Every
/// call is looked up here, so a name that was not offered in this request cannot run, and a tool
/// is dispatched by the list it was offered from rather than by name patterns.
public struct OfferedTools: Sendable {
    public let definitions: [APIToolDef]
    private let families: [String: ToolFamily]

    public init(_ groups: [(ToolFamily, [APIToolDef])]) {
        var definitions: [APIToolDef] = []
        var families: [String: ToolFamily] = [:]
        for (family, defs) in groups {
            for def in defs where families[def.function.name] == nil {
                families[def.function.name] = family
                definitions.append(def)
            }
        }
        self.definitions = definitions
        self.families = families
    }

    public var names: Set<String> { Set(families.keys) }

    /// The family of a tool offered in this request, or nil when the name was not offered.
    public func family(of name: String) -> ToolFamily? { families[name] }

    /// Ada's direct-reply tools. Extended tools need workspace access; mission tools need a linked mission.
    public static func direct(connectorTools: [APIToolDef], hasLinkedMissions: Bool, hasExtendedAccess: Bool) -> OfferedTools {
        OfferedTools([
            (.connector, connectorTools),
            (.chat, ChatWorkspaceTools.definitions),
            (.extended, hasExtendedAccess ? ExtendedWorkspaceTools.definitions : []),
            (.mission, hasLinkedMissions ? ConversationMissionTools.definitions : []),
            (.skill, SkillTools.definitions),
        ])
    }
}
