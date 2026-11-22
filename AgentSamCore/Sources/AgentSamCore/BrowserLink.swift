import Foundation

/// Ada's browser: a real Chromium window on her workstation, shown live in the web app.
///
/// The browser never runs on the server itself. It runs as a systemd service on the SSH
/// workstation (see `deploy/browser-agent/`) and shares its window over VNC on that machine's
/// loopback interface only. The server starts and stops the service over the workstation's SSH
/// link and relays the picture to signed-in admins, so the machine opens no new port.
public struct BrowserConfig: Sendable, Equatable {
    public var enabled: Bool
    /// The VNC port on the workstation's loopback interface.
    public var vncPort: Int
    /// The systemd unit that runs the browser on the workstation.
    public var service: String
    /// How long the browser keeps running with nobody watching.
    public var idleSeconds: TimeInterval
    /// Why the browser stayed off although it was asked for, for the startup log.
    public var problem: String?

    public static let defaultPort = 5977
    public static let defaultService = "ada-browser.service"
    public static let defaultIdleSeconds: TimeInterval = 15 * 60

    public init(enabled: Bool, vncPort: Int = BrowserConfig.defaultPort, service: String = BrowserConfig.defaultService, idleSeconds: TimeInterval = BrowserConfig.defaultIdleSeconds, problem: String? = nil) {
        self.enabled = enabled
        self.vncPort = vncPort
        self.service = service
        self.idleSeconds = idleSeconds
        self.problem = problem
    }

    /// `AGENTSAM_BROWSER=1` turns the browser on, and only together with an SSH workstation.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment, workstation: WorkstationConfig) -> BrowserConfig {
        let on = ["1", "true", "yes", "on"].contains((env["AGENTSAM_BROWSER"] ?? "").lowercased())
        guard on else { return BrowserConfig(enabled: false) }
        guard workstation.enabled, workstation.ssh != nil else {
            return BrowserConfig(enabled: false, problem: "AGENTSAM_BROWSER needs a workstation over SSH (AGENTSAM_WORKSTATION_SSH); Ada's browser is off.")
        }
        let port = env["AGENTSAM_BROWSER_VNC_PORT"].flatMap(Int.init).flatMap { (1...65_535).contains($0) ? $0 : nil } ?? defaultPort
        let service = (env["AGENTSAM_BROWSER_SERVICE"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard service.isEmpty || validService(service) else {
            return BrowserConfig(enabled: false, problem: "AGENTSAM_BROWSER_SERVICE must be a plain systemd unit name; Ada's browser is off.")
        }
        return BrowserConfig(enabled: true, vncPort: port, service: service.isEmpty ? defaultService : service)
    }

    /// Only plain unit names, so the name can never be read as a shell word or an option.
    static func validService(_ name: String) -> Bool {
        !name.hasPrefix("-") && name.count <= 100 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-@".contains($0)) }
    }
}

/// Whether the browser is running on the workstation right now.
public enum BrowserState: String, Codable, Sendable, Equatable {
    case running
    case stopped
    /// The workstation did not answer, or answered something unexpected.
    case unreachable
}

/// A command line that connects its standard input and output to the browser's picture.
public struct BrowserRelayCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// Starts, stops and watches the browser service on the workstation, and stops it when idle.
public actor BrowserLink {
    public typealias Runner = @Sendable (_ script: String) async -> ToolOutcome

    public nonisolated let config: BrowserConfig
    private let run: Runner
    private let relay: @Sendable () async -> BrowserRelayCommand?
    private var viewers = 0
    private var idleTask: Task<Void, Never>?

    static let onMarker = "__ADA_BROWSER_ON"
    static let offMarker = "__ADA_BROWSER_OFF"

    /// `run` executes a shell script on the workstation; `relay` gives the command that reaches the picture.
    public init(config: BrowserConfig, run: @escaping Runner, relay: @escaping @Sendable () async -> BrowserRelayCommand? = { nil }) {
        self.config = config
        self.run = run
        self.relay = relay
    }

    /// The browser on Ada's SSH workstation.
    public init(config: BrowserConfig, workstation: Workstation) {
        let port = config.vncPort
        self.init(
            config: config,
            run: { script in await workstation.run(command: script, directory: nil, timeout: 45) },
            relay: { await workstation.loopbackCommand(port: port) }
        )
    }

    public var viewerCount: Int { viewers }

    public func state() async -> BrowserState {
        guard config.enabled else { return .stopped }
        let unit = Self.quoted(config.service)
        let outcome = await run("if systemctl is-active --quiet \(unit); then echo \(Self.onMarker); else echo \(Self.offMarker); fi")
        if outcome.resultText.contains(Self.onMarker) { return .running }
        if outcome.resultText.contains(Self.offMarker) { return .stopped }
        return .unreachable
    }

    /// Starts the browser and waits until it is up. Starting an already running browser changes nothing.
    public func start() async -> ToolOutcome {
        guard config.enabled else { return .failure("Ada's browser is off on this server.") }
        let unit = Self.quoted(config.service)
        let outcome = await run("sudo systemctl start \(unit) && echo \(Self.onMarker)")
        guard outcome.resultText.contains(Self.onMarker) else {
            return .failure("The browser could not start on the workstation: \(outcome.resultText.prefix(600))")
        }
        // Nobody may ever connect, so the idle clock starts now.
        scheduleIdleStop()
        return ToolOutcome(resultText: "The browser is running.")
    }

    public func stop() async -> ToolOutcome {
        guard config.enabled else { return .failure("Ada's browser is off on this server.") }
        idleTask?.cancel()
        idleTask = nil
        let unit = Self.quoted(config.service)
        let outcome = await run("sudo systemctl stop \(unit) && echo \(Self.offMarker)")
        guard outcome.resultText.contains(Self.offMarker) else {
            return .failure("The browser could not be stopped on the workstation: \(outcome.resultText.prefix(600))")
        }
        return ToolOutcome(resultText: "The browser is stopped.")
    }

    /// The command whose standard input and output carry the picture, or nil when the browser is off.
    public func relayCommand() async -> BrowserRelayCommand? {
        guard config.enabled else { return nil }
        return await relay()
    }

    public func viewerJoined() {
        viewers += 1
        idleTask?.cancel()
        idleTask = nil
    }

    public func viewerLeft() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { scheduleIdleStop() }
    }

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Stops the browser after the idle time, unless somebody starts watching first.
    private func scheduleIdleStop() {
        idleTask?.cancel()
        guard viewers == 0 else { return }
        let seconds = config.idleSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() async {
        guard viewers == 0 else { return }
        idleTask = nil
        _ = await stop()
    }
}

#if canImport(Darwin) && !os(iOS) || canImport(Glibc)
extension Workstation {
    /// The ssh command that connects its standard input and output to one loopback port on the
    /// SSH workstation, with the same key and pinned host key as every other command.
    public func loopbackCommand(port: Int) -> BrowserRelayCommand? {
        guard config.enabled, let ssh = config.ssh, (1...65_535).contains(port), publicKey() != nil else { return nil }
        // Everything up to the destination: options, key, port. The script part is replaced by -W.
        let options = sshArguments(ssh, script: "").prefix { $0 != "--" }
        let arguments = Array(options) + ["-T", "-W", "127.0.0.1:\(port)", "--", ssh.destination]
        return BrowserRelayCommand(executable: ssh.binary, arguments: arguments, environment: environment())
    }
}

/// One viewer's connection to the browser: a child process whose standard input and output carry
/// the raw VNC stream. `onData` and `onEnd` are called from background threads; `onEnd` once.
public final class BrowserRelay: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writes = DispatchQueue(label: "ada.browser.relay.writes")
    private let lock = NSLock()
    private var ended = false
    private var closed = false
    private let onEnd: @Sendable () -> Void

    public init(command: BrowserRelayCommand, onData: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
        self.onEnd = onEnd
        // Writing to a relay that just exited must fail with an error, not end the server.
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self?.finish()
            } else {
                onData(chunk)
            }
        }
        // One termination handler: several waiters on one Process can crash on Linux.
        process.terminationHandler = { [weak self] _ in self?.finish() }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    /// Sends bytes from the viewer to the browser, in order.
    public func send(_ data: Data) {
        writes.async { [self] in
            guard !isClosed else { return }
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                close()
            }
        }
    }

    /// Ends the connection. Safe to call more than once and from any thread.
    public func close() {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        guard first else { return }
        writes.async { [self] in
            try? input.fileHandleForWriting.close()
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            kill(pid, SIGTERM)
            // A child can inherit a signal mask that blocks SIGTERM, so SIGKILL follows.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func finish() {
        lock.lock()
        let first = !ended
        ended = true
        lock.unlock()
        guard first else { return }
        close()
        onEnd()
    }
}
#else
extension Workstation {
    public func loopbackCommand(port: Int) -> BrowserRelayCommand? { nil }
}
#endif
