import SwiftUI
import AgentSamCore

extension Color {
    init(agentSamHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}

enum AgentSamTheme {
    static let background = Color(agentSamHex: 0x0A100D)
    static let deep = Color(agentSamHex: 0x0B120E)
    static let panel = Color(agentSamHex: 0x0E1712)
    static let raised = Color(agentSamHex: 0x101A14)
    static let ink = Color(agentSamHex: 0xF2F7F2)
    static let secondaryInk = Color(agentSamHex: 0xDCE6DD)
    static let muted = Color(agentSamHex: 0x93A89A)
    static let dim = Color(agentSamHex: 0x72877A)
    static let emerald = Color(agentSamHex: 0x4AD99E)
    static let emeraldLight = Color(agentSamHex: 0x7FE0B4)
    static let gold = Color(agentSamHex: 0xC9A96A)
    static let goldLight = Color(agentSamHex: 0xD4B878)
    static let teal = Color(agentSamHex: 0x5BC8BD)
    static let danger = Color(agentSamHex: 0xE69A8C)
    static let line = Color(agentSamHex: 0x94BE9C, opacity: 0.16)
    static let strongLine = Color(agentSamHex: 0x94BE9C, opacity: 0.28)

    static func color(for role: AgentProfile.Role) -> Color {
        switch role {
        case .coordinator: emerald
        case .worker: teal
        case .verifier: goldLight
        }
    }

    static func color(for status: MissionStatus) -> Color {
        switch status {
        case .queued: goldLight
        case .running: emerald
        case .completed: emeraldLight
        case .failed: danger
        case .stopped: muted
        }
    }

    static func displayFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("Avenir Next", size: size, relativeTo: .title).weight(weight)
    }

    static var panelGradient: LinearGradient {
        LinearGradient(
            colors: [raised, panel],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct AgentSamBackground: View {
    var body: some View {
        ZStack {
            AgentSamTheme.background
            RadialGradient(
                colors: [AgentSamTheme.emerald.opacity(0.07), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [AgentSamTheme.gold.opacity(0.045), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 430
            )
        }
        .ignoresSafeArea()
    }
}

struct AgentSamPanelModifier: ViewModifier {
    var padding: CGFloat = 16
    var tint: Color = AgentSamTheme.emerald
    var selected = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(AgentSamTheme.panelGradient)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.62) : AgentSamTheme.line, lineWidth: selected ? 1.4 : 1)
            )
            .shadow(color: .black.opacity(selected ? 0.28 : 0.16), radius: selected ? 18 : 8, y: 5)
    }
}

extension View {
    func agentSamPanel(padding: CGFloat = 16, tint: Color = AgentSamTheme.emerald, selected: Bool = false) -> some View {
        modifier(AgentSamPanelModifier(padding: padding, tint: tint, selected: selected))
    }

    func agentSamKicker() -> some View {
        font(.system(size: 10, weight: .semibold, design: .monospaced))
        .tracking(1.5)
        .textCase(.uppercase)
        .foregroundStyle(AgentSamTheme.emerald)
    }
}

struct AgentSamPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(isEnabled ? AgentSamTheme.ink : AgentSamTheme.muted)
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(
                LinearGradient(
                    colors: isEnabled ? [Color(agentSamHex: 0x1F8A5F), Color(agentSamHex: 0x177250)] : [AgentSamTheme.raised, AgentSamTheme.raised],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AgentSamTheme.emerald.opacity(isEnabled ? 0.45 : 0.15))
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct AgentSamGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? AgentSamTheme.secondaryInk : AgentSamTheme.dim)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(AgentSamTheme.deep.opacity(configuration.isPressed ? 0.9 : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(AgentSamTheme.strongLine)
            )
    }
}

struct AgentSamChip: View {
    let text: String
    var tint: Color = AgentSamTheme.muted
    var systemImage: String?

    init(_ text: String, tint: Color = AgentSamTheme.muted, systemImage: String? = nil) {
        self.text = text
        self.tint = tint
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.075))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22)))
        .clipShape(Capsule())
    }
}

struct AgentSamStatusChip: View {
    let status: MissionStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(AgentSamTheme.color(for: status)).frame(width: 6, height: 6)
            Text(status.rawValue.capitalized)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(AgentSamTheme.color(for: status))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AgentSamTheme.color(for: status).opacity(0.1))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct AgentSamRoleBadge: View {
    let role: AgentProfile.Role

    var body: some View {
        AgentSamChip(role.label, tint: AgentSamTheme.color(for: role))
    }
}

struct AgentSamAvatar: View {
    let name: String
    let role: AgentProfile.Role
    var size: CGFloat = 46
    var active = false
    var complete = false

    private var tint: Color { AgentSamTheme.color(for: role) }
    private var initial: String { String(name.first(where: { $0.isLetter || $0.isNumber }) ?? "A").uppercased() }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.2), AgentSamTheme.raised], center: .topLeading, startRadius: 0, endRadius: size))
                .overlay(Circle().strokeBorder(tint.opacity(active ? 0.85 : 0.42), lineWidth: active ? 2 : 1))
                .shadow(color: active ? tint.opacity(0.2) : .black.opacity(0.24), radius: active ? 13 : 6, y: 3)
                .overlay(Text(initial).font(AgentSamTheme.displayFont(size * 0.36, weight: .bold)).foregroundStyle(tint))
            if active || complete {
                Circle()
                    .fill(AgentSamTheme.background)
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(
                        Group {
                            if complete {
                                Image(systemName: "checkmark")
                                    .font(.system(size: size * 0.13, weight: .bold))
                                    .foregroundStyle(AgentSamTheme.goldLight)
                            } else {
                                Circle().fill(AgentSamTheme.emerald).frame(width: size * 0.12, height: size * 0.12)
                            }
                        }
                    )
                    .offset(x: size * 0.04, y: size * 0.04)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(name), \(role.label)\(active ? ", working" : complete ? ", done" : "")")
    }
}

struct AgentSamAvatarStack: View {
    let agents: [AgentProfile]
    var size: CGFloat = 34

    var body: some View {
        HStack(spacing: -size * 0.22) {
            ForEach(Array(agents.prefix(5).enumerated()), id: \.element.id) { index, agent in
                AgentSamAvatar(name: agent.name, role: agent.role, size: size)
                    .overlay(Circle().strokeBorder(AgentSamTheme.background, lineWidth: 2))
                    .zIndex(Double(agents.count - index))
            }
            if agents.count > 5 {
                Text("+\(agents.count - 5)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AgentSamTheme.muted)
                    .frame(width: size, height: size)
                    .background(Circle().fill(AgentSamTheme.raised))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agents.count) agents: \(agents.map(\.name).joined(separator: ", "))")
    }
}

struct AgentSamMoneyText: View {
    let amount: Double

    var body: some View {
        Text(amount < 0.01 && amount > 0 ? String(format: "$%.4f", amount) : String(format: "$%.2f", amount))
            .monospacedDigit()
    }
}

struct AgentSamPhasePipeline: View {
    let phase: MissionPhase
    let status: MissionStatus
    private let order: [MissionPhase] = [.planning, .working, .verifying, .reporting, .done]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(order.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 5) {
                    Image(systemName: symbol(for: item))
                        .font(.caption2)
                        .foregroundStyle(color(for: item))
                    Text(item.label)
                        .font(.caption.weight(item == phase ? .semibold : .regular))
                        .foregroundStyle(color(for: item))
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(item == phase && status == .running ? AgentSamTheme.emerald.opacity(0.09) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                if index < order.count - 1 {
                    Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(AgentSamTheme.dim)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func isDone(_ item: MissionPhase) -> Bool {
        guard let current = order.firstIndex(of: phase), let target = order.firstIndex(of: item) else { return false }
        return target < current || phase == .done
    }

    private func symbol(for item: MissionPhase) -> String {
        if isDone(item) { return "checkmark.circle.fill" }
        if item == phase && status == .running { return "dot.radiowaves.left.and.right" }
        return "circle"
    }

    private func color(for item: MissionPhase) -> Color {
        isDone(item) || item == phase ? AgentSamTheme.emerald : AgentSamTheme.dim
    }
}

struct AgentSamBrand: View {
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Text("A")
                .font(AgentSamTheme.displayFont(18, weight: .bold))
                .foregroundStyle(AgentSamTheme.goldLight)
                .frame(width: 34, height: 34)
                .background(LinearGradient(colors: [Color(agentSamHex: 0x14361F), Color(agentSamHex: 0x0B2418)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(AgentSamTheme.gold.opacity(0.48)))
            VStack(alignment: .leading, spacing: 1) {
                Text("AgentSam").font(AgentSamTheme.displayFont(19)).foregroundStyle(AgentSamTheme.ink)
                if !compact {
                    Text("AUTONOMOUS WORKGROUP")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(AgentSamTheme.dim)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Theme components") {
    VStack(alignment: .leading, spacing: 20) {
        AgentSamBrand()
        HStack {
            ForEach(MissionStatus.allCases, id: \.self) { AgentSamStatusChip(status: $0) }
        }
        HStack {
            AgentSamChip("fact-checked")
            AgentSamChip("gpt-5.2-mini", tint: AgentSamTheme.emeraldLight, systemImage: "cpu")
            ForEach(AgentProfile.Role.allCases, id: \.self) { AgentSamRoleBadge(role: $0) }
        }
        HStack(spacing: 16) {
            AgentSamAvatar(name: "Ada", role: .coordinator)
            AgentSamAvatar(name: "Scout", role: .worker, active: true)
            AgentSamAvatar(name: "Judge", role: .verifier, complete: true)
            AgentSamAvatarStack(agents: AgentProfile.rosterTemplates)
        }
        AgentSamMoneyText(amount: 0.0042)
            .foregroundStyle(AgentSamTheme.ink)
        AgentSamPhasePipeline(phase: .verifying, status: .running)
        Text("Panel").foregroundStyle(AgentSamTheme.ink).agentSamPanel()
        HStack {
            Button("Primary") {}.buttonStyle(AgentSamPrimaryButtonStyle())
            Button("Disabled") {}.buttonStyle(AgentSamPrimaryButtonStyle()).disabled(true)
            Button("Ghost") {}.buttonStyle(AgentSamGhostButtonStyle())
        }
    }
    .padding(24)
    .background(AgentSamBackground())
    .preferredColorScheme(.dark)
}
