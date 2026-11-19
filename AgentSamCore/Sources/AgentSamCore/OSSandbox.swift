import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) && !os(iOS) || canImport(Glibc)
/// Wraps a command in the operating system's sandbox so it can write only inside one folder.
///
/// Used by both `run_program` (`CodeRunner`) and the persistent terminal (`WorkspaceTerminal`).
/// - Linux: bubblewrap. A fresh mount namespace with the system folders read-only, a private
///   `/tmp`, and only `writable` bound read/write. The home folder and the AgentSam data folder
///   are not visible at all.
/// - macOS: `sandbox-exec`. Reads and writes in the home folder and in `protecting` are denied,
///   writes anywhere outside `writable` are denied.
///
/// When no sandbox is installed, `wrap` returns nil and callers must refuse to run anything.
enum OSSandbox {
    /// Read-only system folders made visible inside the Linux sandbox.
    static let linuxSystemPaths = ["/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/opt"]

    static var isAvailable: Bool { unavailableReason == nil }

    /// Why nothing can run, or nil when the sandbox works.
    static var unavailableReason: String? {
        #if canImport(Darwin)
        FileManager.default.isExecutableFile(atPath: macExecutable) ? nil : "sandbox-exec was not found"
        #else
        linuxProbeFailure
        #endif
    }

    /// Returns a plan that runs `executable arguments` inside the sandbox, starting in `directory`.
    /// - Parameters:
    ///   - writable: the only folder the command may write to. `directory` must be inside it.
    ///   - readable: an extra folder the command may read but not write, such as the workspace a
    ///     `run_program` run starts from.
    ///   - protecting: a folder the command must never read, such as the AgentSam data folder.
    ///     It may contain `writable` and `readable`; only those stay reachable.
    static func wrap(executable: String, arguments: [String], writable: URL, directory: URL, readable: URL? = nil, protecting: URL? = nil) -> CodeRunner.Plan? {
        let root = canonicalPath(writable)
        let visible = readable.map(canonicalPath)
        let hidden = protecting.map(canonicalPath)
        #if canImport(Darwin)
        // sandbox-exec has no chdir option; the caller's Process sets the working directory.
        guard FileManager.default.isExecutableFile(atPath: macExecutable) else { return nil }
        let profile = macProfile(writable: root, readable: visible, protecting: hidden)
        return CodeRunner.Plan(executable: macExecutable, arguments: ["-p", profile, executable] + arguments, fileToWrite: "")
        #else
        guard linuxProbeFailure == nil, let bwrap = linuxExecutable else { return nil }
        let start = canonicalPath(directory)
        return CodeRunner.Plan(executable: bwrap, arguments: linuxArguments(writable: root, directory: start, readable: visible, protecting: hidden, mountProc: linuxProbe.mountProc) + [executable] + arguments, fileToWrite: "")
        #endif
    }

    /// The real path the kernel checks. `realpath` keeps macOS's `/private` prefix, which
    /// `URL.resolvingSymlinksInPath` strips (`/private/var/folders/…` becomes `/var/folders/…`),
    /// and a sandbox-exec rule on the stripped form never matches.
    static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    #if canImport(Darwin)
    static let macExecutable = "/usr/bin/sandbox-exec"

    static func macProfile(writable: String, readable: String? = nil, protecting: String?) -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let hiddenRule = protecting.map { "\n(deny file-read* file-write* (subpath \"\(quoted($0))\"))" } ?? ""
        let readableRule = readable.map { "\n(allow file-read* (subpath \"\(quoted($0))\"))" } ?? ""
        return """
        (version 1)
        (allow default)
        (deny file-read* file-write* (subpath \"\(quoted(home))\") (subpath \"/private/var/folders\") (subpath \"/var/folders\"))\(hiddenRule)\(readableRule)
        (allow file-read* file-write* (subpath \"\(quoted(writable))\"))
        (allow file-read-metadata (subpath "/private/var/folders") (subpath "/var/folders"))
        (allow file-read* file-write* (regex #"^/private/var/folders/[^/]+/[^/]+/T/xcrun_db"))
        (deny file-write* (subpath \"/\"))
        (allow file-write* (subpath \"\(quoted(writable))\") (subpath \"/dev\") (regex #"^/private/var/folders/[^/]+/[^/]+/T/xcrun_db"))
        """
    }

    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    #else
    static var linuxExecutable: String? {
        ["/usr/bin/bwrap", "/bin/bwrap", "/usr/local/bin/bwrap"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// bubblewrap can be installed yet unable to create namespaces, for example inside a container
    /// whose seccomp profile blocks them. Some containers allow namespaces but refuse a fresh /proc
    /// mount; the sandbox then runs without /proc, which also keeps host processes out of view.
    /// One real run tells, so it is checked once per process.
    static let linuxProbe: (failure: String?, mountProc: Bool) = {
        guard let bwrap = linuxExecutable else { return ("bubblewrap is not installed", true) }
        let scratch = canonicalPath(FileManager.default.temporaryDirectory)
        func attempt(mountProc: Bool) -> String? {
            let plan = CodeRunner.Plan(executable: bwrap, arguments: linuxArguments(writable: scratch, directory: scratch, protecting: nil, mountProc: mountProc) + ["/bin/sh", "-c", "exit 0"], fileToWrite: "")
            guard let outcome = try? CodeRunner.execute(plan, in: URL(fileURLWithPath: scratch), stdin: "", environment: ["PATH": "/usr/bin:/bin"], timeout: 10) else {
                return "bubblewrap could not be started"
            }
            return outcome.resultText.hasPrefix("Exit code 0") ? nil : "bubblewrap could not create a sandbox: \(outcome.resultText.prefix(300))"
        }
        guard let withProc = attempt(mountProc: true) else { return (nil, true) }
        return attempt(mountProc: false) == nil ? (nil, false) : (withProc, true)
    }()

    static var linuxProbeFailure: String? { linuxProbe.failure }

    /// Order matters: bubblewrap applies mounts in sequence, so the private `/tmp` and the hidden
    /// data folder come before the writable bind, which may live under either of them.
    static func linuxArguments(writable: String, directory: String, readable: String? = nil, protecting: String?, mountProc: Bool = true) -> [String] {
        var arguments = [
            "--die-with-parent", "--new-session", "--unshare-all", "--share-net",
            "--dev", "/dev",
        ]
        if mountProc { arguments += ["--proc", "/proc"] }
        arguments += ["--tmpfs", "/tmp"]
        for path in linuxSystemPaths where FileManager.default.fileExists(atPath: path) {
            arguments += ["--ro-bind", path, path]
        }
        // A data folder under a system path (say /opt/agentsam/data) would otherwise be readable.
        if let protecting, linuxSystemPaths.contains(where: { protecting.hasPrefix($0 + "/") }) {
            arguments += ["--tmpfs", protecting]
        }
        if let readable { arguments += ["--ro-bind", readable, readable] }
        arguments += ["--bind", writable, writable, "--chdir", directory]
        return arguments
    }
    #endif
}
#endif
