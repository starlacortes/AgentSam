import Foundation

/// Ada's own computer: an unsandboxed shell on the machine the server runs on, for installing
/// packages, managing services and running long jobs.
///
/// It is off unless the server operator turns it on (`AGENTSAM_WORKSTATION=1`), it is offered only
/// in admins' conversations, and every command goes through the standing-permission rules for
/// `workstation_run` / `workstation_start_job`: by default each one needs an approval card. The
/// environment is scrubbed so no server secret reaches a command, and everything is audited.
/// A Linux machine Ada reaches over SSH instead of the one the server runs on.
public struct SSHTarget: Sendable, Equatable {
    /// `user@host`.
    public var destination: String
    public var port: Int
    /// A pinned known_hosts entry (`ssh-ed25519 AAAA…`, with or without the host in front). Without
    /// one, the first key the host presents is remembered and any later change is refused.
    public var hostKey: String?
    /// Where commands start on that machine when no directory is given (the login home by default).
    public var directory: String?
    public var binary: String

    public init(destination: String, port: Int = 22, hostKey: String? = nil, directory: String? = nil, binary: String = "/usr/bin/ssh") {
        self.directory = directory
        self.destination = destination
        self.port = port
        self.hostKey = hostKey
        self.binary = binary
    }

    public var host: String { String(destination.split(separator: "@").last ?? "") }

    /// Only plain `user@host` forms, so nothing can be read as an ssh option.
    public static func valid(_ destination: String) -> Bool {
        let parts = destination.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let user = parts.first, let host = parts.last, !user.isEmpty, !host.isEmpty,
              !user.hasPrefix("-"), !host.hasPrefix("-") else { return false }
        let userOK = user.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        let hostOK = host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-:".contains($0)) }
        return userOK && hostOK
    }
}

public struct WorkstationConfig: Sendable {
    public var enabled: Bool
    /// Where local commands start when no directory is given (the server user's home by default).
    public var home: URL
    /// Set to manage another machine over SSH instead of the server's own.
    public var ssh: SSHTarget?
    /// Why the workstation stayed off although it was asked for, for the startup log.
    public var problem: String?
    /// A person's own account on the machine: everything it creates (in /tmp too) is readable by that
    /// account only, so other people on the same machine cannot read it.
    public var privateUser: Bool

    public init(enabled: Bool, home: URL, ssh: SSHTarget? = nil, problem: String? = nil, privateUser: Bool = false) {
        self.enabled = enabled
        self.home = home
        self.ssh = ssh
        self.problem = problem
        self.privateUser = privateUser
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> WorkstationConfig {
        let on = ["1", "true", "yes", "on"].contains((env["AGENTSAM_WORKSTATION"] ?? "").lowercased())
        let home = env["AGENTSAM_WORKSTATION_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? env["HOME"] ?? "/"
        var config = WorkstationConfig(enabled: on, home: URL(fileURLWithPath: home, isDirectory: true))
        let destination = (env["AGENTSAM_WORKSTATION_SSH"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !destination.isEmpty {
            guard SSHTarget.valid(destination) else {
                config.enabled = false
                config.problem = "AGENTSAM_WORKSTATION_SSH must look like user@host; workstation access is off."
                return config
            }
            let port = env["AGENTSAM_WORKSTATION_SSH_PORT"].flatMap(Int.init).flatMap { (1...65_535).contains($0) ? $0 : nil } ?? 22
            let hostKey = env["AGENTSAM_WORKSTATION_SSH_HOST_KEY"].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            config.ssh = SSHTarget(destination: destination, port: port, hostKey: hostKey, directory: env["AGENTSAM_WORKSTATION_HOME"].flatMap { $0.isEmpty ? nil : $0 })
            // Naming a machine turns the workstation on.
            config.enabled = true
        }
        return config
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
    /// True for a job on an SSH machine; its pid is on that machine.
    public var remote: Bool?
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
    private let sshDirectory: URL
    private var processes: [UUID: Process] = [:]
    private var jobs: [UUID: WorkstationJob] = [:]

    public init(config: WorkstationConfig, dataDir: URL) {
        self.config = config
        jobsDirectory = dataDir.appendingPathComponent("workstation", isDirectory: true)
        sshDirectory = jobsDirectory.appendingPathComponent("ssh", isDirectory: true)
        if let data = try? Data(contentsOf: jobsDirectory.appendingPathComponent("jobs.json")),
           let saved = try? Self.decoder.decode([WorkstationJob].self, from: data) {
            for var job in saved {
                // Local jobs from before a restart are no longer ours to watch; remote ones keep running there.
                if job.state == .running && job.remote != true { job.state = .lost }
                jobs[job.id] = job
            }
        }
    }

    public var enabled: Bool { config.enabled }

    /// Where commands run, for people and for Ada.
    public var location: String {
        if let ssh = config.ssh { return "\(ssh.destination) over SSH" }
        return "this server"
    }

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

    // MARK: SSH

    var keyURL: URL { sshDirectory.appendingPathComponent("id_ed25519") }
    var knownHostsURL: URL { sshDirectory.appendingPathComponent("known_hosts") }

    /// Ada's own SSH key, created on first use. Only the public half is ever shown.
    public func publicKey() -> String? {
        guard config.ssh != nil else { return nil }
        guard ensureKey() else { return nil }
        return (try? String(contentsOf: keyURL.appendingPathExtension("pub"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureKey() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: keyURL.path) { return true }
        try? fm.createDirectory(at: sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keygen = ["/usr/bin/ssh-keygen", "/bin/ssh-keygen", "/opt/homebrew/bin/ssh-keygen"].first { fm.isExecutableFile(atPath: $0) }
        guard let keygen else { return false }
        let plan = CodeRunner.Plan(executable: keygen, arguments: ["-q", "-t", "ed25519", "-N", "", "-C", "ada@agentsam", "-f", keyURL.path], fileToWrite: "")
        _ = try? CodeRunner.execute(plan, in: sshDirectory, stdin: "", environment: environment(), timeout: 30)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return fm.fileExists(atPath: keyURL.path)
    }

    /// The ssh command line for one remote script. Host keys are pinned (given, or remembered on first use).
    func sshArguments(_ ssh: SSHTarget, script: String) -> [String] {
        var strict = "accept-new"
        if let hostKey = ssh.hostKey {
            let pattern = ssh.port == 22 ? ssh.host : "[\(ssh.host)]:\(ssh.port)"
            let first = hostKey.split(separator: " ").first.map(String.init) ?? ""
            let line = first.hasPrefix("ssh-") || first.hasPrefix("ecdsa-") || first.hasPrefix("sk-") ? "\(pattern) \(hostKey)" : hostKey
            try? FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? Data((line + "\n").utf8).write(to: knownHostsURL, options: .atomic)
            strict = "yes"
        }
        return [
            "-F", "/dev/null",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=\(strict)",
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-o", "IdentitiesOnly=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-i", keyURL.path,
            "-p", String(ssh.port),
            "--", ssh.destination,
            "sh -c " + Self.quoted(script),
        ]
    }

    /// Runs a shell script where the workstation is: here, or on the SSH machine.
    private func execute(script requestedScript: String, directory requested: String?, timeout: TimeInterval) async -> ToolOutcome {
        let script = (config.privateUser ? "umask 077\n" : "") + requestedScript
        let env = environment()
        let plan: CodeRunner.Plan
        let localDirectory: URL
        if let ssh = config.ssh {
            guard ensureKey() else { return .failure("Ada's SSH key could not be created (ssh-keygen is missing on the server). Nothing ran.") }
            try? FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            plan = CodeRunner.Plan(executable: ssh.binary, arguments: sshArguments(ssh, script: Self.remoteCD(requested, home: ssh.directory) + script), fileToWrite: "")
            localDirectory = sshDirectory
        } else {
            guard let directory = directory(requested) else { return .failure("That directory does not exist on the workstation: \(requested ?? "")") }
            plan = CodeRunner.Plan(executable: "/bin/sh", arguments: ["-c", script], fileToWrite: "")
            localDirectory = directory
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = (try? CodeRunner.execute(plan, in: localDirectory, stdin: "", environment: env, timeout: timeout)) ?? .failure("The command could not start\(plan.executable.hasSuffix("ssh") ? " (is the ssh client installed on the server?)" : "").")
                continuation.resume(returning: result)
            }
        }
    }

    /// A shell test that is true while the process runs (not a zombie).
    static func alive(_ pid: Int32) -> String {
        "{ kill -0 \(pid) 2>/dev/null && ! grep -qs '^State:[[:space:]]*Z' /proc/\(pid)/status; }"
    }

    /// `cd` into the requested directory on the SSH machine, or stop with a clear message.
    static func remoteCD(_ requested: String?, home: String?) -> String {
        let raw = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = raw.isEmpty ? (home ?? "") : raw
        guard !target.isEmpty else { return "cd || exit 97\n" }
        let path = target.hasPrefix("~/") ? "\"$HOME\"/" + quoted(String(target.dropFirst(2))) : quoted(target)
        return "cd \(path) 2>/dev/null || { echo \"That directory does not exist on the workstation: \(target.replacingOccurrences(of: "\"", with: ""))\" >&2; exit 97; }\n"
    }

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Foreground commands

    public func run(command raw: String, directory requested: String?, timeout requestedTimeout: TimeInterval?) async -> ToolOutcome {
        guard config.enabled else { return Self.offMessage }
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.utf8.count <= 20_000 else { return .failure("A command of at most 20,000 bytes is required.") }
        let timeout = min(max(requestedTimeout ?? Self.defaultRunSeconds, 1), Self.maxRunSeconds)
        // The machine stops the command itself at the limit, so its output so far still comes back;
        // the server's own limit, a little later, only catches a connection that hangs.
        let seconds = Int(timeout.rounded())
        let outcome = await execute(script: Self.foregroundScript(command, seconds: seconds), directory: requested, timeout: timeout + Self.serverGraceSeconds)
        return Self.reported(outcome, seconds: seconds, location: location)
    }

    /// Extra seconds the server waits beyond a command's own limit.
    static let serverGraceSeconds: TimeInterval = 10
    static let timeoutMarker = "[ada: time limit reached]"

    /// A foreground command, run so that what it leaves behind cannot hold the call open:
    /// - Its output goes to a file that is printed when it ends. A program it starts in the
    ///   background (a server, `nohup`, `&`) keeps that file open, not the SSH connection, so the call
    ///   returns as soon as the command itself is done. Before, such a call waited out the whole time
    ///   limit and was reported as failed although the command had worked.
    /// - The machine stops it at the limit (`timeout`, where installed), so the output so far is kept.
    /// - sudo never waits for a password nobody can type.
    static func foregroundScript(_ command: String, seconds: Int) -> String {
        let inner = quoted(nonInteractive(command))
        return """
        __ada_out=$(mktemp 2>/dev/null) || __ada_out="${TMPDIR:-/tmp}/ada-run-$$.log"
        if command -v timeout >/dev/null 2>&1; then
          timeout -k 5 \(max(seconds, 1)) sh -c \(inner) </dev/null >"$__ada_out" 2>&1
        else
          sh -c \(inner) </dev/null >"$__ada_out" 2>&1
        fi
        __ada_status=$?
        cat "$__ada_out" 2>/dev/null; rm -f "$__ada_out"
        if [ "$__ada_status" -eq 124 ]; then echo; echo '\(timeoutMarker)'; fi
        exit $__ada_status
        """
    }

    /// The result Ada sees. A command stopped at its time limit may still have done its work (a web
    /// request that already had its answer), so she checks before running it again.
    static func reported(_ outcome: ToolOutcome, seconds: Int, location: String) -> ToolOutcome {
        var text = outcome.resultText
        let timedOut = text.contains(timeoutMarker) || text.hasPrefix("Timed out after")
        if timedOut {
            text = text.replacingOccurrences(of: "\n" + timeoutMarker, with: "").replacingOccurrences(of: timeoutMarker, with: "")
            if let range = text.range(of: "Output:\n") ?? text.range(of: "Partial output:\n") { text = String(text[range.upperBound...]) }
            text = """
            Timed out: the command was still running after \(seconds)s and was stopped. It may already have done \
            part or all of its work (for example, a web request that got its answer just before), so check whether it \
            took effect (open the page, list the files, query the service) before running it again, so nothing \
            happens twice. For anything that takes long, use workstation_start_job. Output so far:
            \(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no output)" : text)
            """
        }
        return ToolOutcome(resultText: text + "\nRan on \(location).", succeeded: outcome.succeeded && !timedOut)
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

    // MARK: Personal accounts

    /// Creates (or repairs) a person's own account on this machine and authorizes their key. Runs as
    /// the operator account through one narrow sudo rule; the script on the machine checks both values.
    public func addPersonalAccount(user: String, publicKey: String, command: String) async -> ToolOutcome {
        guard config.enabled, config.ssh != nil else { return .failure("Personal workstation accounts need an SSH workstation.") }
        guard WorkstationPool.validUnixName(user), WorkstationPool.validPublicKey(publicKey) else {
            return .failure("The account name or key is not valid. Nothing was changed.")
        }
        return await execute(script: "\(command) \(Self.quoted(user)) \(Self.quoted(publicKey))", directory: nil, timeout: 60)
    }

    // MARK: Background jobs

    public func startJob(command raw: String, directory requested: String?, label: String?) async -> ToolOutcome {
        guard config.enabled else { return Self.offMessage }
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.utf8.count <= 20_000 else { return .failure("A command of at most 20,000 bytes is required.") }
        refresh()
        guard jobs.values.filter({ $0.state == .running }).count < Self.maxJobs else {
            return .failure("\(Self.maxJobs) jobs are already running. Stop one with workstation_stop_job first.")
        }
        let id = UUID()
        let name = String((label?.isEmpty == false ? label! : command).prefix(80))
        if config.ssh != nil { return await startRemoteJob(id: id, command: command, directory: requested, label: name) }
        guard let directory = directory(requested) else { return .failure("That directory does not exist on the workstation: \(requested ?? "")") }
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
        let job = WorkstationJob(id: id, label: name, command: String(command.prefix(2_000)), directory: directory.path, pid: process.processIdentifier, remote: nil, state: .running, exitCode: nil, startedAt: Date(), endedAt: nil)
        jobs[id] = job
        save()
        return ToolOutcome(resultText: "Started job \(id.uuidString) (\(job.label)) in \(directory.path). Check it with workstation_job; stop it with workstation_stop_job.")
    }

    /// Starts a job on the SSH machine under nohup and setsid; its log and exit code live in ~/.ada-jobs there.
    private func startRemoteJob(id: UUID, command: String, directory: String?, label: String) async -> ToolOutcome {
        let file = "\"$HOME\"/.ada-jobs/\(id.uuidString)"
        // The command runs in its own shell so an `exit` in it still leaves the exit code behind.
        let inner = "sh -c \(Self.quoted(Self.nonInteractive(command)))\necho $? > \"$HOME\"/.ada-jobs/\(id.uuidString).exit"
        // Closing every inherited descriptor lets ssh return at once while the job keeps running.
        let closeFDs = (3...9).map { "\($0)>&-" }.joined(separator: " ")
        let script = "mkdir -p \"$HOME\"/.ada-jobs && nohup setsid sh -c \(Self.quoted(inner)) > \(file).log 2>&1 < /dev/null \(closeFDs) &\necho \"__ADA_PID $!\""
        let outcome = await execute(script: script, directory: directory, timeout: 30)
        guard outcome.succeeded, let line = outcome.resultText.split(separator: "\n").first(where: { $0.contains("__ADA_PID ") }),
              let pid = Int32(line.split(separator: " ").last ?? "") else {
            return .failure("The job could not start on \(location): \(outcome.resultText.prefix(1_000))")
        }
        let job = WorkstationJob(id: id, label: label, command: String(command.prefix(2_000)), directory: directory ?? "~", pid: pid, remote: true, state: .running, exitCode: nil, startedAt: Date(), endedAt: nil)
        jobs[id] = job
        save()
        return ToolOutcome(resultText: "Started job \(id.uuidString) (\(label)) on \(location). Check it with workstation_job; stop it with workstation_stop_job.")
    }

    public func job(id: UUID, tailCharacters: Int = 6_000) async -> ToolOutcome {
        guard config.enabled else { return Self.offMessage }
        refresh()
        guard var job = jobs[id] else { return .failure("No workstation job has that ID.") }
        if job.remote == true {
            let file = "\"$HOME\"/.ada-jobs/\(id.uuidString)"
            // The exit file wins: an unreaped job (a zombie, where nothing reaps orphans) still answers kill -0.
            let script = "if [ -f \(file).exit ]; then echo \"__ADA_EXIT $(cat \(file).exit)\"; elif \(Self.alive(job.pid)); then echo __ADA_RUNNING; else echo __ADA_GONE; fi\ntail -c \(tailCharacters) \(file).log 2>/dev/null"
            let outcome = await execute(script: script, directory: nil, timeout: 30)
            guard outcome.succeeded || outcome.resultText.contains("__ADA_") else { return .failure("Could not reach \(location): \(outcome.resultText.prefix(500))") }
            var lines = outcome.resultText.components(separatedBy: "\n")
            let markerIndex = lines.firstIndex { $0.contains("__ADA_") } ?? 0
            let marker = lines.isEmpty ? "" : lines.remove(at: markerIndex)
            if job.state == .running {
                if marker.contains("__ADA_EXIT") {
                    job.state = .exited
                    job.exitCode = Int32(marker.split(separator: " ").last ?? "")
                    job.endedAt = Date()
                } else if marker.contains("__ADA_GONE") {
                    job.state = .lost
                    job.endedAt = Date()
                }
                jobs[id] = job
                save()
            }
            let tail = lines.joined(separator: "\n").replacingOccurrences(of: "\nRan on \(location).", with: "")
            return ToolOutcome(resultText: "\(Self.describe(job))\nOutput so far:\n\(tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no output yet)" : tail)")
        }
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
        if job.remote == true {
            let script = "kill -TERM -- -\(pid) 2>/dev/null; kill -TERM \(pid) 2>/dev/null; sleep 3; kill -KILL -- -\(pid) 2>/dev/null; kill -KILL \(pid) 2>/dev/null; true"
            let outcome = await execute(script: script, directory: nil, timeout: 30)
            guard outcome.succeeded else { return .failure("Could not reach \(location) to stop the job: \(outcome.resultText.prefix(500))") }
        } else {
            // Signal the whole group; SIGKILL follows because children can inherit a mask that blocks SIGTERM.
            kill(-pid, SIGTERM)
            kill(pid, SIGTERM)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if processes[id]?.isRunning == true {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
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
        let checked = job.remote == true && job.state == .running ? " (as last checked)" : ""
        return "Job \(job.id.uuidString) · \(job.label) · \(job.state.rawValue)\(checked)\(exit) · started \(ISO8601DateFormatter().string(from: job.startedAt)) in \(job.directory)"
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

    static let offMessage = ToolOutcome(resultText: "Ada's workstation access is off on this server. Nothing ran. The server operator can turn it on with AGENTSAM_WORKSTATION=1, or point it at a machine with AGENTSAM_WORKSTATION_SSH=user@host.", succeeded: false)

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
    public var location: String { "this device" }
    public func publicKey() -> String? { nil }
    public func startJob(command: String, directory: String?, label: String?) async -> ToolOutcome { .failure("Workstation access is not supported on this device.") }
    public func job(id: UUID, tailCharacters: Int = 6_000) async -> ToolOutcome { .failure("Workstation access is not supported on this device.") }
    public func listJobs() -> [WorkstationJob] { [] }
    public func stopJob(id: UUID) async -> ToolOutcome { .failure("Workstation access is not supported on this device.") }
    public func addPersonalAccount(user: String, publicKey: String, command: String) async -> ToolOutcome { .failure("Workstation access is not supported on this device.") }
    static func describe(_ job: WorkstationJob) -> String { job.label }
}
#endif
