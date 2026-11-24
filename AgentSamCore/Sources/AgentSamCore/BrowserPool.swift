import Foundation

/// People's own browsers.
///
/// Admins (and the server token) use the operator's browser, `ada-browser.service`, as before.
/// A person an admin gave a workstation gets a browser of their own: the template unit
/// `ada-browser@<account>.service` (see deploy/browser-agent) runs Chromium as their own workstation
/// account, with its profile, saved sign-ins, VNC password and control state under
/// `~/.ada-browser` in their home, which nobody else's account can read. Its display and ports come
/// from the account's numeric ID, so two people's browsers never share one.
///
/// The operator account starts and stops the unit (it may run systemctl); the picture and Ada's
/// requests are relayed as the person's own account. At most `maxPersonal` personal browsers run
/// at once, and each stops after the usual idle time.
public actor BrowserPool {
    public nonisolated let config: BrowserConfig
    private let operatorMachine: Workstation
    private let maxPersonal: Int
    private var links: [String: BrowserLink] = [:]

    public static let defaultMaxPersonal = 3
    static let passwordMarker = "__ADA_BROWSER_PASSWORD"
    static let uidMarker = "__ADA_BROWSER_UID"
    static let countMarker = "__ADA_BROWSERS_OPEN"
    static let selfMarker = "__ADA_BROWSER_SELF_ON"

    public init(config: BrowserConfig, operatorMachine: Workstation, maxPersonal: Int = BrowserPool.defaultMaxPersonal) {
        self.config = config
        self.operatorMachine = operatorMachine
        self.maxPersonal = max(1, maxPersonal)
    }

    /// The template unit instance for a person's account.
    public static func service(account: String) -> String { "ada-browser@\(account).service" }

    /// The display's VNC port and the agent's port for an account's numeric ID. run-browser.sh
    /// computes the same, so the server and the workstation always agree.
    public static func ports(uid: Int) -> (vnc: Int, agent: Int) {
        let slot = ((uid % 10_000) + 10_000) % 10_000
        return (30_000 + 2 * slot, 30_001 + 2 * slot)
    }

    /// Creates the person's browser folder and VNC password on first use, as the person, and prints
    /// the password and the account's numeric ID. Files are private: the account runs with umask 077.
    static let prepareScript = """
    d="$HOME/.ada-browser"
    mkdir -p "$d/profiles" && chmod 700 "$d" || exit 1
    if [ ! -s "$d/vnc-password.txt" ] || [ ! -s "$d/vnc.passwd" ]; then
      command -v vncpasswd >/dev/null 2>&1 || { echo "vncpasswd is missing on the workstation: run deploy/browser-agent/install.sh there." >&2; exit 1; }
      p="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8)"
      printf '%s\\n' "$p" > "$d/vnc-password.txt"
      printf '%s\\n' "$p" | vncpasswd -f > "$d/vnc.passwd"
    fi
    echo "\(passwordMarker) $(head -n 1 "$d/vnc-password.txt")"
    echo "\(uidMarker) $(id -u)"
    """

    /// Reads the password and numeric ID from the prepare script's output.
    static func parsePrepared(_ text: String) -> (password: String, uid: Int)? {
        var password: String?
        var uid: Int?
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == passwordMarker { password = parts[1].trimmingCharacters(in: .whitespaces) }
            if parts[0] == uidMarker { uid = Int(parts[1].trimmingCharacters(in: .whitespaces)) }
        }
        guard let password, (6...8).contains(password.count), password.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let uid, uid > 0 else { return nil }
        return (password, uid)
    }

    /// How many other personal browsers run, and whether this one does, from the check script's output.
    static func parseOpen(_ text: String) -> (others: Int, selfOn: Bool)? {
        var others: Int?
        var selfOn = false
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ").map(String.init)
            if parts.first == countMarker, parts.count == 2 { others = Int(parts[1]) }
            if parts.first == selfMarker { selfOn = true }
        }
        return others.map { ($0, selfOn) }
    }

    static func openScript(service: String) -> String {
        let unit = BrowserLink.quoted(service)
        return """
        n=$(systemctl list-units 'ada-browser@*.service' --state=active --plain --no-legend 2>/dev/null | awk '{print $1}' | grep -cvxF \(unit))
        echo "\(countMarker) ${n:-0}"
        systemctl is-active --quiet \(unit) && echo \(selfMarker)
        true
        """
    }

    /// A person's own browser on their own workstation account, set up the first time it is needed.
    public func link(account: String, machine: Workstation) async -> Result<BrowserLink, WorkstationPoolError> {
        guard config.enabled else { return .failure(.init(message: "Ada's browser is off on this server.")) }
        guard WorkstationPool.validUnixName(account) else { return .failure(.init(message: "This account cannot have a browser.")) }
        if let existing = links[account] { return .success(existing) }
        let prepared = await machine.run(command: Self.prepareScript, directory: nil, timeout: 30)
        guard prepared.succeeded, let found = Self.parsePrepared(prepared.resultText) else {
            return .failure(.init(message: "Your browser could not be set up on the workstation: \(prepared.resultText.prefix(300))"))
        }
        let ports = Self.ports(uid: found.uid)
        let service = Self.service(account: account)
        let linkConfig = BrowserConfig(enabled: true, vncPort: ports.vnc, agentPort: ports.agent, service: service, idleSeconds: config.idleSeconds)
        let operatorMachine = self.operatorMachine
        let limit = maxPersonal
        let link = BrowserLink(config: linkConfig, control: operatorMachine, viewer: machine, token: found.password, startCheck: {
            let outcome = await operatorMachine.run(command: BrowserPool.openScript(service: service), directory: nil, timeout: 20)
            guard let open = BrowserPool.parseOpen(outcome.resultText), !open.selfOn, open.others >= limit else { return nil }
            return "\(limit) people's browsers are already open on the workstation, which is the most it runs at once. Try again in a few minutes: each closes after \(Int(linkConfig.idleSeconds / 60)) minutes unused."
        })
        links[account] = link
        return .success(link)
    }
}
