import Foundation
import AgentSamCore
#if canImport(Glibc)
import Glibc
#endif

/// Settings for Google's official Google Ads MCP server (github.com/googleads/google-ads-mcp),
/// which Ada can run next to herself in this container and connect as one of her MCP servers.
/// The Docker image installs it under /opt/google-ads-mcp (see deploy/google-ads-mcp).
struct GoogleAdsMCPConfig: Sendable, Equatable {
    var enabled: Bool
    var python: String
    var launcher: String
    var toolsConfig: String
    var port: Int

    static let defaultPort = 8765
    static let serverName = "Google Ads MCP"

    /// AGENTSAM_GOOGLE_ADS_MCP=1 turns it on. AGENTSAM_GOOGLE_ADS_MCP_HOME and
    /// AGENTSAM_GOOGLE_ADS_MCP_PORT override where it is installed and the loopback port.
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> GoogleAdsMCPConfig {
        let flag = (env["AGENTSAM_GOOGLE_ADS_MCP"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let home = (env["AGENTSAM_GOOGLE_ADS_MCP_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "/opt/google-ads-mcp")
        let port = env["AGENTSAM_GOOGLE_ADS_MCP_PORT"].flatMap(Int.init).flatMap { (1_024...65_535).contains($0) ? $0 : nil } ?? defaultPort
        return GoogleAdsMCPConfig(
            enabled: ["1", "true", "yes", "on"].contains(flag),
            python: home + "/bin/python3",
            launcher: home + "/ada_launch.py",
            toolsConfig: home + "/tools_config.yaml",
            port: port
        )
    }

    var url: String { "http://127.0.0.1:\(port)/mcp" }
}

/// What the Google Ads MCP server signs in with: the same Google Ads connection Ada already has.
enum GoogleAdsMCPCredentials {
    /// An Application Default Credentials file for the server. Like Ada's own Google Ads tools, a
    /// service-account key wins over the signed-in Google account. Nil when Google Ads isn't connected.
    static func adcJSON(keyRing: KeyRing, clientID: String, clientSecret: String) -> Data? {
        let object: [String: String]
        if let account = GoogleTokenProvider.serviceAccount(for: .googleads, keyRing: keyRing) {
            object = [
                "type": "service_account",
                "client_email": account.clientEmail,
                "private_key": account.privateKey,
                "private_key_id": account.privateKeyID,
                "token_uri": account.tokenURI,
            ]
        } else if let refresh = keyRing.get(GoogleTokenProvider.refreshAccount(for: .googleads))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !refresh.isEmpty, !clientID.isEmpty, !clientSecret.isEmpty {
            object = [
                "type": "authorized_user",
                "client_id": clientID,
                "client_secret": clientSecret,
                "refresh_token": refresh,
            ]
        } else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// The server's whole environment. Nothing else of Ada's (provider keys, AGENTSAM_* secrets) is passed on.
    static func environment(config: GoogleAdsMCPConfig, home: URL, credentialsPath: String, token: String, keyRing: KeyRing) -> [String: String] {
        var env: [String: String] = [
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "HOME": home.path,
            "LANG": "C.UTF-8",
            "PYTHONUNBUFFERED": "1",
            "PORT": String(config.port),
            "ADA_MCP_TOKEN": token,
            "GOOGLE_APPLICATION_CREDENTIALS": credentialsPath,
            "GOOGLE_ADS_MCP_TOOLS_CONFIG": config.toolsConfig,
        ]
        if let developerToken = keyRing.get(GoogleAdsConnector.developerTokenAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !developerToken.isEmpty {
            env["GOOGLE_ADS_DEVELOPER_TOKEN"] = developerToken
        }
        let customer = (keyRing.get(GoogleAdsConnector.customerIdAccount) ?? "").filter(\.isNumber)
        if !customer.isEmpty { env["GOOGLE_ADS_LOGIN_CUSTOMER_ID"] = customer }
        return env
    }
}

/// Runs the Google Ads MCP server as a child process on 127.0.0.1 and keeps it connected in
/// Ada's MCP server list. It starts once Google Ads is connected, restarts when that connection
/// changes, and stops when it is disconnected. Each start has a fresh bearer token, because
/// programs Ada runs in this container can reach loopback too.
actor GoogleAdsMCPRunner {
    private let config: GoogleAdsMCPConfig
    private let keyRing: KeyRing
    private let oauth: GoogleOAuth
    private let registry: MCPRegistry

    private var process: Process?
    private var directory: URL?
    private var fingerprint: String?
    private var generation = 0
    private var failures = 0
    private var warnedMissing = false

    static let maxRestarts = 5

    init(config: GoogleAdsMCPConfig, keyRing: KeyRing, oauth: GoogleOAuth, registry: MCPRegistry) {
        self.config = config
        self.keyRing = keyRing
        self.oauth = oauth
        self.registry = registry
    }

    /// Starts the server, or restarts it when the Google Ads connection changed. Safe to call often.
    func sync() async {
        guard config.enabled else { return }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: config.python), fm.fileExists(atPath: config.launcher) else {
            if !warnedMissing {
                print("Google Ads MCP is on, but the server is not installed at \(config.launcher). Rebuild the image from deploy/Dockerfile.")
                warnedMissing = true
            }
            return
        }
        guard let credentials = GoogleAdsMCPCredentials.adcJSON(keyRing: keyRing, clientID: oauth.clientID, clientSecret: oauth.clientSecret) else {
            if process != nil { print("Google Ads was disconnected, so the Google Ads MCP server stopped.") }
            stopProcess()
            fingerprint = nil
            return
        }
        let developer = keyRing.get(GoogleAdsConnector.developerTokenAccount) ?? ""
        let customer = keyRing.get(GoogleAdsConnector.customerIdAccount) ?? ""
        let stamp = Secrets.sha256Hex(String(decoding: credentials, as: UTF8.self) + "\n" + developer + "\n" + customer)
        if stamp == fingerprint, process?.isRunning == true { return }
        fingerprint = stamp
        failures = 0
        await launch(credentials: credentials)
    }

    func stop() {
        generation += 1
        stopProcess()
    }

    private func launch(credentials: Data) async {
        stopProcess()
        generation += 1
        let current = generation
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ada-google-ads-mcp-\(UUID().uuidString.lowercased())")
        let credentialsURL = dir.appendingPathComponent("adc.json")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: credentialsURL.path, contents: credentials, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            print("The Google Ads MCP server could not start: its credentials file could not be written (\(error.localizedDescription)).")
            try? fm.removeItem(at: dir)
            return
        }
        let token = Secrets.randomToken()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: config.python)
        child.arguments = ["-I", config.launcher]
        child.environment = GoogleAdsMCPCredentials.environment(config: config, home: dir, credentialsPath: credentialsURL.path, token: token, keyRing: keyRing)
        child.currentDirectoryURL = dir
        child.standardInput = FileHandle.nullDevice
        // Its logs (including the upstream audit log, which redacts secrets) go to the server's logs.
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError
        // One termination handler: several waiters on one Process can crash on Linux.
        child.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { await self?.exited(generation: current, status: status) }
        }
        do {
            try child.run()
        } catch {
            print("The Google Ads MCP server could not start: \(error.localizedDescription)")
            try? fm.removeItem(at: dir)
            return
        }
        process = child
        directory = dir
        await connect(generation: current, token: token)
    }

    /// Waits for the server to answer, then adds it to Ada's MCP servers (or reconnects the entry).
    private func connect(generation current: Int, token: String) async {
        var lastError = ""
        for _ in 0..<45 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard current == generation, process?.isRunning == true else { return }
            do {
                let server = try await registry.connectManaged(name: GoogleAdsMCPConfig.serverName, url: config.url, token: token)
                failures = 0
                print("Google Ads MCP server is on: \(server.tools.count) tools at \(config.url)\(server.enabled ? "" : " (turned off in Settings, so Ada does not use it)").")
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
        print("The Google Ads MCP server did not answer within 90 seconds: \(lastError)")
    }

    private func exited(generation ended: Int, status: Int32) async {
        guard ended == generation else { return }
        process = nil
        removeDirectory()
        failures += 1
        guard failures <= Self.maxRestarts else {
            print("The Google Ads MCP server stopped (exit \(status)) and was restarted \(Self.maxRestarts) times. It stays off until Google Ads is reconnected or the server restarts.")
            return
        }
        print("The Google Ads MCP server stopped (exit \(status)). Restarting it.")
        try? await Task.sleep(nanoseconds: UInt64(failures) * 5_000_000_000)
        guard ended == generation, let credentials = GoogleAdsMCPCredentials.adcJSON(keyRing: keyRing, clientID: oauth.clientID, clientSecret: oauth.clientSecret) else { return }
        await launch(credentials: credentials)
    }

    private func stopProcess() {
        if let process, process.isRunning {
            let box = ProcessBox(process)
            process.terminate()
            // A child can inherit a signal mask that blocks SIGTERM, so SIGKILL follows.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        removeDirectory()
    }

    private func removeDirectory() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}

/// Lets the delayed SIGKILL check look at a child process from another queue.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}
