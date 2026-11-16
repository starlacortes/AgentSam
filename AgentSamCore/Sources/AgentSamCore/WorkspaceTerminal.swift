import Foundation

#if canImport(Darwin) && !os(iOS) || canImport(Glibc)
public actor WorkspaceTerminal {
    private var directories: [String: String] = [:]

    public init() {}

    public func reset(key: String) {
        directories[key] = nil
    }

    public func run(command: String, root: URL, key: String, requestedDirectory: String?) async -> ToolOutcome {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.utf8.count <= 20_000 else {
            return ToolOutcome(resultText: "A terminal command of at most 20,000 bytes is required.")
        }
        guard command.range(of: "\\brm\\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\\b", options: .regularExpression) == nil else {
            return ToolOutcome(resultText: "Recursive forced deletion is not available in the terminal. Use the file-delete approval tool for a specific file.")
        }
        let rawBase = root.standardizedFileURL
        try? FileManager.default.createDirectory(at: rawBase.appendingPathComponent(".tmp"), withIntermediateDirectories: true)
        guard let resolvedBase = realpath(rawBase.path, nil) else {
            return ToolOutcome(resultText: "The terminal workspace could not be opened.")
        }
        defer { free(resolvedBase) }
        let base = URL(fileURLWithPath: String(cString: resolvedBase), isDirectory: true)
        let relative = requestedDirectory ?? directories[key] ?? ""
        let directory = relative.isEmpty ? base : ScopedFiles.resolve(relative, in: base)
        guard let directory else { return ToolOutcome(resultText: "Invalid working directory. Use a relative path inside this workspace.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ToolOutcome(resultText: "The working directory does not exist: \(relative)")
        }
        guard let plan = plan(command: command, root: base, directory: directory) else {
            return ToolOutcome(resultText: "The persistent terminal is unavailable: install bubblewrap on Linux or use macOS with sandbox-exec. No command was run.")
        }
        let output = (try? CodeRunner.execute(plan, in: directory, stdin: "", environment: environment(root: base), timeout: 30)) ?? ToolOutcome(resultText: "The terminal could not start.")
        let marker = "\n__AGENTSAM_CWD__"
        guard let range = output.resultText.range(of: marker, options: .backwards) else { return output }
        let current = String(output.resultText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if current == base.path { directories[key] = "" }
        else if current.hasPrefix(base.path + "/") { directories[key] = String(current.dropFirst(base.path.count + 1)) }
        let visible = String(output.resultText[..<range.lowerBound])
        return ToolOutcome(resultText: visible + "\nWorking directory: \(directories[key] ?? "")")
    }

    private func environment(root: URL) -> [String: String] {
        [
            "PATH": "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/sbin:/sbin",
            "HOME": root.path,
            "TMPDIR": root.appendingPathComponent(".tmp").path,
            "LANG": "C.UTF-8",
        ]
    }

    private func plan(command: String, root: URL, directory: URL) -> CodeRunner.Plan? {
        let marker = "\nprintf '\\n__AGENTSAM_CWD__%s' \"$PWD\""
        let wrapped = command + marker
        #if canImport(Darwin)
        let executable = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let profile = """
        (version 1)
        (allow default)
        (deny file-read* file-write* (subpath \"\(quoted(home))\") (subpath \"/private/var/folders\") (subpath \"/var/folders\"))
        (allow file-read* file-write* (subpath \"\(quoted(root.path))\"))
        (allow file-read-metadata (subpath "/private/var/folders") (subpath "/var/folders"))
        (deny file-write* (subpath \"/\"))
        (allow file-write* (subpath \"\(quoted(root.path))\") (subpath \"/dev\"))
        """
        return CodeRunner.Plan(executable: executable, arguments: ["-p", profile, "/bin/sh", "-c", wrapped], fileToWrite: "")
        #else
        let candidates = ["/usr/bin/bwrap", "/bin/bwrap", "/usr/local/bin/bwrap"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        var arguments = [
            "--die-with-parent", "--new-session", "--unshare-all", "--share-net",
            "--bind", root.path, root.path, "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
        ]
        for path in ["/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/opt"] where FileManager.default.fileExists(atPath: path) {
            arguments += ["--ro-bind", path, path]
        }
        arguments += ["--chdir", directory.path, "/bin/sh", "-c", wrapped]
        return CodeRunner.Plan(executable: executable, arguments: arguments, fileToWrite: "")
        #endif
    }

    private func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
#else
public actor WorkspaceTerminal {
    public init() {}
    public func reset(key: String) {}
    public func run(command: String, root: URL, key: String, requestedDirectory: String?) async -> ToolOutcome {
        ToolOutcome(resultText: "The persistent terminal is not supported on this device. No command was run.")
    }
}
#endif
