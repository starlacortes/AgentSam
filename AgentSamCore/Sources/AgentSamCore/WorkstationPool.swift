import Foundation

/// The machines people's Ada works on.
///
/// Admins (and the shared server token) use the operator account the server was configured with
/// (`AGENTSAM_WORKSTATION_SSH`, usually `ada@host`). Everyone else an admin allowed gets an account of
/// their own on the same machine, `adau<12 hex>`, with its own SSH key, home folder, background jobs
/// and job list: nobody can read or stop another person's files or jobs through Ada. The account is
/// created on first use by `/usr/local/bin/ada-user-add` (see deploy/workstation), the only sudo rule
/// the operator account needs for it. Personal accounts get no sudo.
public actor WorkstationPool {
    public let operatorMachine: Workstation
    private let dataDir: URL
    private let provisionCommand: String
    private var personal: [String: Workstation] = [:]
    /// Accounts set up since the server started. Setting up is idempotent, so a restart just repeats it once.
    private var ready: Set<String> = []

    public static let defaultProvisionCommand = "sudo -n /usr/local/bin/ada-user-add"

    public init(operatorMachine: Workstation, dataDir: URL, provisionCommand: String = WorkstationPool.defaultProvisionCommand) {
        self.operatorMachine = operatorMachine
        self.dataDir = dataDir
        self.provisionCommand = provisionCommand
    }

    /// The Unix account for an owner: `adau` and the first 12 hex digits of their account ID.
    public static func unixName(ownerID: String) -> String? {
        guard let id = UUID(uuidString: ownerID) else { return nil }
        return "adau" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
    }

    public static func validUnixName(_ name: String) -> Bool {
        name.count == 16 && name.hasPrefix("adau") && name.dropFirst(4).allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }

    public static func validPublicKey(_ key: String) -> Bool {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, parts[0] == "ssh-ed25519", key.count <= 400 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=@._- "))
        return key.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A person's own machine, set up the first time it is needed. Nil with a reason when it cannot be.
    public func machine(ownerID: String) async -> Result<Workstation, WorkstationPoolError> {
        guard await operatorMachine.enabled, let ssh = operatorMachine.config.ssh else {
            return .failure(.init(message: "Personal workstations need an SSH workstation (AGENTSAM_WORKSTATION_SSH)."))
        }
        guard let name = Self.unixName(ownerID: ownerID) else { return .failure(.init(message: "This account cannot have a workstation.")) }
        let machine: Workstation
        if let existing = personal[name] {
            machine = existing
        } else {
            let target = SSHTarget(destination: "\(name)@\(ssh.host)", port: ssh.port, hostKey: ssh.hostKey, directory: nil, binary: ssh.binary)
            let config = WorkstationConfig(enabled: true, home: operatorMachine.config.home, ssh: target, privateUser: true)
            machine = Workstation(config: config, dataDir: dataDir.appendingPathComponent("workstation/people/\(name)", isDirectory: true))
            personal[name] = machine
        }
        if !ready.contains(name) {
            guard let key = await machine.publicKey() else { return .failure(.init(message: "Ada's SSH key for this person could not be created. Nothing ran.")) }
            let outcome = await operatorMachine.addPersonalAccount(user: name, publicKey: key, command: provisionCommand)
            guard outcome.succeeded else {
                return .failure(.init(message: "Your workstation account could not be set up: \(outcome.resultText.prefix(400))"))
            }
            ready.insert(name)
        }
        return .success(machine)
    }
}

public struct WorkstationPoolError: Error, Sendable {
    public var message: String
}
