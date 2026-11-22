import Foundation

/// Ada's own computer: an unsandboxed shell on the machine the server runs on, for installing
/// packages, managing services and running long jobs.
///
/// It is off unless the server operator turns it on (`AGENTSAM_WORKSTATION=1`), it is offered only
/// in admins' conversations, and every command goes through the standing-permission rules for
/// `workstation_run` / `workstation_start_job`: by default each one needs an approval card. The
/// environment is scrubbed so no server secret reaches a command, and everything is audited.
public struct WorkstationConfig: Sendable {
    public var enabled: Bool
    /// Where commands start when no directory is given (the server user's home by default).
    public var home: URL

    public init(enabled: Bool, home: URL) {
        self.enabled = enabled
        self.home = home
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> WorkstationConfig {
        let enabled = ["1", "true", "yes", "on"].contains((env["AGENTSAM_WORKSTATION"] ?? "").lowercased())
        let home = env["AGENTSAM_WORKSTATION_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? env["HOME"] ?? "/"
        return WorkstationConfig(enabled: enabled, home: URL(fileURLWithPath: home, isDirectory: true))
    }
}

/// A background command Ada started on her workstation.
public struct WorkstationJob: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case running, exited, stopped, lost }

    public var id: UUID
    public var label: String
    public var command: String
    public var directory: String
    public var pid: Int32
    public var state: State
    public var exitCode: Int32?
    public var startedAt: Date
    public var endedAt: Date?
}

#if canImport(Darwin) && !os(iOS) || canImport(Glibc)
public actor Workstation {
    public static let maxRunSeconds: TimeInterval = 600
    public static let defaultRunSeconds: TimeInterval = 120
    public static let maxJobs = 8

    public let config: WorkstationConfig
    private let jobsDirectory: URL
    private var processes: [UUID: Process] = [:]
    private var jobs: [UUID: WorkstationJob] = [:]

    public init(config: WorkstationConfig, dataDir: URL) {
        self.config = config
        jobsDirectory = dataDir.appendingPathComponent("workstation", isDirectory: true)
        if let data = try? Data(contentsOf: jobsDirectory.appendingPathComponent("jobs.json")),
           let saved = try? Self.decoder.decode([WorkstationJob].self, from: data) {
            // Jobs from before a restart are no longer ours to watch.
            for var job in saved {
                if job.state == .running { job.state = .lost }
                jobs[job.id] = job
            }
        }
    }

    public var enabled: Bool { config.enabled }

    /// The environment every workstation command gets: enough to work, nothing from the server.
    func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin",
            "HOME": inherited["HOME"] ?? config.home.path,
            "LANG": inherited["LANG"] ?? "C.UTF-8",
            "TERM": "dumb",
            // pacman, systemctl and git must never wait for a pager or a prompt.
            "PAGER": "cat", "SYSTEMD_PAGER": "", "GIT_PAGER": "cat", "GIT_TERMINAL_PROMPT": "0",
        ]
        for key in ["USER", "LOGNAME", "SHELL", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"] {
            if let value = inherited[key] { env[key] = value }
        }
        return env
    }

    func directory(_ requested: String?) -> URL? {
        guard let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else { return config.home }
        let url = requested.hasPrefix("/") ? URL(fileURLWithPath: requested, isDirectory: true) : config.home.appendingPathComponent(requested, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url.standardizedFileURL
    }

    // MARK: Foreground commands

    public func run(command raw: String, directory requested: String?, timeout requestedTimeout: TimeInterval?) async -> ToolOutcome {
        guard config.enabled else { return Self.offMessage }
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.utf8.count <= 20_000 else { return .failure("A command of at most 20,000 bytes is required.") }
        guard let directory = directory(requested) else { return .failure("That directory does not exist on the workstation: \(requested ?? "")") }
        let timeout = min(max(requestedTimeout ?? Self.defaultRunSeconds, 1), Self.maxRunSeconds)
        // sudo must never wait for a password nobody can type.
        let plan = CodeRunner.Plan(executable: "/bin/sh", arguments: ["-c", Self.nonInteractive(command)], fileToWrite: "")
        let env = environment()
        let outcome: ToolOutcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = (try? CodeRunner.execute(plan, in: directory, stdin: "", environment: env, timeout: timeout)) ?? .failure("The command could not start.")
                continuation.resume(returning: result)
            }
        }
        return ToolOutcome(resultText: outcome.resultText + "\nDirectory: \(directory.path)", succeeded: outcome.succeeded)
    }

    /// A snapshot of the machine, safe to run without approval.
    public func status() async -> ToolOutcome {
        guard config.enabled else { return Self.offMessage }
        let script = """
        echo "== system"; uname -srmo 2>/dev/null || uname -a
        [ -r /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME"
        echo "== uptime"; uptime
        echo "== disk"; df -h / "$HOME" 2>/dev/null | awk '!seen[$0]++'
        echo "== memory"; free -h 2>/dev/null || vm_stat 2>/dev/null | head -5
        echo "== user"; id
        if command -v systemctl >/dev/null 2>&1; then echo "== failed services"; systemctl --failed --no-pager --no-legend 2>/dev/null | head -20; fi
        if command -v pacman >/dev/null 2>&1; then echo "== packages"; echo "$(pacman -Qq 2>/dev/null | wc -l) installed, $(pacman -Qu 2>/dev/null | wc -l) upgradable (local database)"; fi
        if sudo -n true 2>/dev/null; then echo "== sudo: available without a password"; else echo "== sudo: not available without a password"; fi
        """
        return await run(command: script, directory: nil, timeout: 30)
    }

    // MARK: Background jobs

    public func startJob(command raw: String, directory requested: String?, label: String?) -> ToolOutcome {
        guard config.enabled else { return Self.offMessage }
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.utf8.count <= 20_000 else { return .failure("A command of at most 20,000 bytes is required.") }
        guard let directory = directory(requested) else { return .failure("That directory does not exist on the workstation: \(requested ?? "")") }
        refresh()
        guard jobs.values.filter({ $0.state == .running }).count < Self.maxJobs else {
            return .failure("\(Self.maxJobs) jobs are already running. Stop one with workstation_stop_job first.")
        }
        let id = UUID()
        try? FileManager.default.createDirectory(at: jobsDirectory, withIntermediateDirectories: true)
        let logURL = logURL(id)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else { return .failure("The job log could not be created.") }
        let process = Process()
        // setsid gives the job its own process group, so stopping it also stops what it started.
        let setsid = ["/usr/bin/setsid", "/bin/setsid"].first { FileManager.default.isExecutableFile(atPath: $0) }
        if let setsid {
            process.executableURL = URL(fileURLWithPath: setsid)
            process.arguments = ["/bin/sh", "-c", Self.nonInteractive(command)]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", Self.nonInteractive(command)]
        }
        process.currentDirectoryURL = directory
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] finished in
            try? log.close()
            let code = finished.terminationStatus
            Task { await self?.finished(id: id, code: code) }
        }
        do {
            try process.run()
        } catch {
            try? log.close()
            return .failure("The job could not start: \(error.localizedDescription)")
        }
        processes[id] = process
        let job = WorkstationJob(id: id, label: String((label?.isEmpty == false ? label! : command).prefix(80)), command: String(command.prefix(2_000)), directory: directory.path, pid: process.processIdentifier, state: .running, exitCode: nil, startedAt: Date(), endedAt: nil)
        jobs[id] = job
        save()
        return ToolOutcome(resultText: "Started job \(id.uuidString) (\(job.label)) in \(directory.path). Check it with workstation_job; stop it with workstation_stop_job.")
    }

    public func job(id: UUID, tailCharacters: Int = 6_000) -> ToolOutcome {
        guard config.enabled else { return Self.offMessage }
        refresh()
        guard let job = jobs[id] else { return .failure("No workstation job has that ID.") }
        let text = (try? String(contentsOf: logURL(id), encoding: .utf8)) ?? ""
        let tail = text.count > tailCharacters ? "…[\(text.count - tailCharacters) earlier characters omitted]…\n" + text.suffix(tailCharacters) : text
        return ToolOutcome(resultText: "\(Self.describe(job))\nOutput so far:\n\(tail.isEmpty ? "(no output yet)" : tail)")
    }

    public func listJobs() -> [WorkstationJob] {
        refresh()
        return jobs.values.sorted { $0.startedAt > $1.startedAt }.prefix(30).map { $0 }
    }

    public func stopJob(id: UUID) async -> ToolOutcome {
        guard config.enabled else { return Self.offMessage }
        guard var job = jobs[id] else { return .failure("No workstation job has that ID.") }
        guard job.state == .running else { return ToolOutcome(resultText: "That job is not running (\(job.state.rawValue)).") }
        let pid = job.pid
        // Signal the whole group; SIGKILL follows because children can inherit a mask that blocks SIGTERM.
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if processes[id]?.isRunning == true {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        job = jobs[id] ?? job
        job.state = .stopped
        job.endedAt = job.endedAt ?? Date()
        jobs[id] = job
        processes[id] = nil
        save()
        return ToolOutcome(resultText: "Stopped job \(id.uuidString) (\(job.label)).")
    }

    private func finished(id: UUID, code: Int32) {
        guard var job = jobs[id] else { return }
        if job.state == .running {
            job.state = .exited
            job.exitCode = code
        }
        job.endedAt = job.endedAt ?? Date()
        jobs[id] = job
        processes[id] = nil
        save()
    }

    private func refresh() {
        for (id, process) in processes where !process.isRunning {
            finished(id: id, code: process.terminationStatus)
        }
    }

    static func describe(_ job: WorkstationJob) -> String {
        let exit = job.exitCode.map { ", exit code \($0)" } ?? ""
        return "Job \(job.id.uuidString) · \(job.label) · \(job.state.rawValue)\(exit) · started \(ISO8601DateFormatter().string(from: job.startedAt)) in \(job.directory)"
    }

    /// Makes sudo fail at once instead of waiting for a password.
    static func nonInteractive(_ command: String) -> String {
        "sudo() { command sudo -n \"$@\"; }\n" + command
    }

    private func logURL(_ id: UUID) -> URL { jobsDirectory.appendingPathComponent("\(id.uuidString).log") }

    private func save() {
        try? FileManager.default.createDirectory(at: jobsDirectory, withIntermediateDirectories: true)
        let recent = jobs.values.sorted { $0.startedAt > $1.startedAt }.prefix(100)
        if let data = try? Self.encoder.encode(Array(recent)) {
            try? data.write(to: jobsDirectory.appendingPathComponent("jobs.json"), options: .atomic)
        }
    }

    static let offMessage = ToolOutcome(resultText: "Ada's workstation access is off on this server. Nothing ran. The server operator can turn it on with AGENTSAM_WORKSTATION=1.", succeeded: false)

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
#else
public actor Workstation {
    public let config: WorkstationConfig
    public init(config: WorkstationConfig, dataDir: URL) { self.config = config }
    public var enabled: Bool { false }
    public func run(command: String, directory: String?, timeout: TimeInterval?) async -> ToolOutcome { .failure("Workstation access is not supported on this device.") }
    public func status() async -> ToolOutcome { .failure("Workstation access is not supported on this device.") }
    public func startJob(command: String, directory: String?, label: String?) -> ToolOutcome { .failure("Workstation access is not supported on this device.") }
    public func job(id: UUID, tailCharacters: Int = 6_000) -> ToolOutcome { .failure("Workstation access is not supported on this device.") }
    public func listJobs() -> [WorkstationJob] { [] }
    public func stopJob(id: UUID) async -> ToolOutcome { .failure("Workstation access is not supported on this device.") }
    static func describe(_ job: WorkstationJob) -> String { job.label }
}
#endif
