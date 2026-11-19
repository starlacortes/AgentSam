import Foundation

#if canImport(Darwin) && !os(iOS) || canImport(Glibc)
public actor WorkspaceTerminal {
    private var directories: [String: String] = [:]

    public init() {}

    public func reset(key: String) {
        directories[key] = nil
    }

    public func run(command: String, root: URL, key: String, requestedDirectory: String?, protecting: URL? = nil) async -> ToolOutcome {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.utf8.count <= 20_000 else {
            return .failure("A terminal command of at most 20,000 bytes is required.")
        }
        guard command.range(of: "\\brm\\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\\b", options: .regularExpression) == nil else {
            return .failure("Recursive forced deletion is not available in the terminal. Use the file-delete approval tool for a specific file.")
        }
        let rawBase = root.standardizedFileURL
        try? FileManager.default.createDirectory(at: rawBase.appendingPathComponent(".tmp"), withIntermediateDirectories: true)
        guard let resolvedBase = realpath(rawBase.path, nil) else {
            return .failure("The terminal workspace could not be opened.")
        }
        defer { free(resolvedBase) }
        let base = URL(fileURLWithPath: String(cString: resolvedBase), isDirectory: true)
        let relative = requestedDirectory ?? directories[key] ?? ""
        let directory = relative.isEmpty ? base : ScopedFiles.resolve(relative, in: base)
        guard let directory else { return .failure("Invalid working directory. Use a relative path inside this workspace.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("The working directory does not exist: \(relative)")
        }
        guard let plan = plan(command: command, root: base, directory: directory, protecting: protecting) else {
            return .failure("The persistent terminal is unavailable (\(OSSandbox.unavailableReason ?? "unknown reason")): it needs bubblewrap on Linux or sandbox-exec on macOS. No command was run.")
        }
        let output = (try? CodeRunner.execute(plan, in: directory, stdin: "", environment: environment(root: base), timeout: 30)) ?? .failure("The terminal could not start.")
        let marker = "\n__AGENTSAM_CWD__"
        guard let range = output.resultText.range(of: marker, options: .backwards) else { return output }
        let current = String(output.resultText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if current == base.path { directories[key] = "" }
        else if current.hasPrefix(base.path + "/") { directories[key] = String(current.dropFirst(base.path.count + 1)) }
        let visible = String(output.resultText[..<range.lowerBound])
        return ToolOutcome(resultText: visible + "\nWorking directory: \(directories[key] ?? "")", succeeded: output.succeeded)
    }

    private func environment(root: URL) -> [String: String] {
        [
            "PATH": "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/sbin:/sbin",
            "HOME": root.path,
            "TMPDIR": root.appendingPathComponent(".tmp").path,
            "LANG": "C.UTF-8",
        ]
    }

    private func plan(command: String, root: URL, directory: URL, protecting: URL?) -> CodeRunner.Plan? {
        // Keep the command's own exit status: without it, the trailing printf made every command
        // look successful.
        let marker = "\n__agentsam_status=$?\nprintf '\\n__AGENTSAM_CWD__%s' \"$PWD\"\nexit $__agentsam_status"
        return OSSandbox.wrap(executable: "/bin/sh", arguments: ["-c", command + marker], writable: root, directory: directory, protecting: protecting)
    }
}
#else
public actor WorkspaceTerminal {
    public init() {}
    public func reset(key: String) {}
    public func run(command: String, root: URL, key: String, requestedDirectory: String?, protecting: URL? = nil) async -> ToolOutcome {
        .failure("The persistent terminal is not supported on this device. No command was run.")
    }
}
#endif
