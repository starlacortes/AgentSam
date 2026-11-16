import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GitHub access for agents, authenticated with a personal access token. Reads are always on;
/// writes (commit a file to a branch, comment) need the `githubWrite` permission, and commits to a
/// repository's default branch are always refused so agents work on a branch.
public struct GitHubConnector: ConnectorToolProvider {
    public static let apiBase = "https://api.github.com"
    public static let tokenAccount = "connector.github.token"
    static let maxFileCharacters = 20_000

    public var id: ConnectorID { .github }

    public init() {}

    public func isConfigured(keyRing: KeyRing) -> Bool {
        !(keyRing.get(Self.tokenAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Tool definitions

    public func toolDefs(permissions: ConnectorPermissions) -> [APIToolDef] {
        var defs = [Self.reposTool, Self.readTool, Self.searchTool, Self.issuesTool, Self.issueTool]
        if permissions.githubWrite { defs += [Self.writeFileTool, Self.commentTool] }
        return defs
    }

    private static func prop(_ type: String, _ description: String) -> JSONValue {
        .object([("type", .string(type)), ("description", .string(description))])
    }

    static let reposTool = APIToolDef(
        name: "github_repos",
        description: "List repositories the configured GitHub token can access, most recently updated first. Optionally list the repositories of one owner (user or organization).",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("owner", prop("string", "Optional user or organization login")),
                ("filter", prop("string", "Optional substring filter on repository name")),
            ])),
        ])
    )

    static let readTool = APIToolDef(
        name: "github_read",
        description: "Read a file from a GitHub repository, or list a directory. Omit path to list the repository root. Large files are truncated.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("repo", prop("string", "Repository as owner/name")),
                ("path", prop("string", "File or directory path; empty for the root")),
                ("ref", prop("string", "Optional branch, tag, or commit SHA (default: the default branch)")),
            ])),
            ("required", .array([.string("repo")])),
        ])
    )

    static let searchTool = APIToolDef(
        name: "github_search",
        description: "Search code or issues/pull requests on GitHub using GitHub search syntax (for example 'repo:owner/name TODO' or 'is:open label:bug').",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("query", prop("string", "GitHub search query")),
                ("kind", prop("string", "What to search: code or issues (default code)")),
            ])),
            ("required", .array([.string("query")])),
        ])
    )

    static let issuesTool = APIToolDef(
        name: "github_issues",
        description: "List issues and pull requests in a repository. Pull requests are marked [PR].",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("repo", prop("string", "Repository as owner/name")),
                ("state", prop("string", "open, closed, or all (default open)")),
                ("labels", prop("string", "Optional comma-separated label names")),
            ])),
            ("required", .array([.string("repo")])),
        ])
    )

    static let issueTool = APIToolDef(
        name: "github_issue",
        description: "Read one issue or pull request by number, including its description and recent comments.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("repo", prop("string", "Repository as owner/name")),
                ("number", prop("integer", "Issue or pull request number")),
            ])),
            ("required", .array([.string("repo"), .string("number")])),
        ])
    )

    static let writeFileTool = APIToolDef(
        name: "github_write_file",
        description: "Create or update one file on a branch with a commit (requires GitHub write permission). The branch must already exist and cannot be the repository's default branch.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("repo", prop("string", "Repository as owner/name")),
                ("branch", prop("string", "Existing branch to commit to (not the default branch)")),
                ("path", prop("string", "File path in the repository")),
                ("content", prop("string", "Complete new file contents")),
                ("message", prop("string", "Commit message")),
            ])),
            ("required", .array([.string("repo"), .string("branch"), .string("path"), .string("content"), .string("message")])),
        ])
    )

    static let commentTool = APIToolDef(
        name: "github_comment",
        description: "Post a comment on an issue or pull request (requires GitHub write permission).",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("repo", prop("string", "Repository as owner/name")),
                ("number", prop("integer", "Issue or pull request number")),
                ("body", prop("string", "Comment text (Markdown)")),
            ])),
            ("required", .array([.string("repo"), .string("number"), .string("body")])),
        ])
    )

    // MARK: Execution

    public func run(_ name: String, args: [String: JSONValue], permissions: ConnectorPermissions, runtime: ConnectorRuntime) async -> ToolOutcome {
        do {
            switch name {
            case "github_repos":
                return ToolOutcome.success(try await listRepos(owner: args["owner"]?.stringValue, filter: args["filter"]?.stringValue, runtime: runtime))

            case "github_read":
                guard let repo = args["repo"]?.stringValue else {
                    return .failure("github_read requires repo (owner/name).")
                }
                return ToolOutcome.success(try await read(repo: repo, path: args["path"]?.stringValue, ref: args["ref"]?.stringValue, runtime: runtime))

            case "github_search":
                guard let query = args["query"]?.stringValue, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return .failure("github_search requires query.")
                }
                return ToolOutcome.success(try await search(query: query, kind: args["kind"]?.stringValue, runtime: runtime))

            case "github_issues":
                guard let repo = args["repo"]?.stringValue else {
                    return .failure("github_issues requires repo (owner/name).")
                }
                return ToolOutcome.success(try await listIssues(repo: repo, state: args["state"]?.stringValue, labels: args["labels"]?.stringValue, runtime: runtime))

            case "github_issue":
                guard let repo = args["repo"]?.stringValue, let number = args["number"]?.numberValue else {
                    return .failure("github_issue requires repo (owner/name) and number.")
                }
                return ToolOutcome.success(try await readIssue(repo: repo, number: Int(number), runtime: runtime))

            case "github_write_file":
                guard permissions.githubWrite else { return .failure(Self.writesDisabled) }
                guard let repo = args["repo"]?.stringValue, let branch = args["branch"]?.stringValue,
                      let path = args["path"]?.stringValue, let content = args["content"]?.stringValue,
                      let message = args["message"]?.stringValue else {
                    return .failure("github_write_file requires repo, branch, path, content, and message.")
                }
                return ToolOutcome.success(try await writeFile(repo: repo, branch: branch, path: path, content: content, message: message, runtime: runtime))

            case "github_comment":
                guard permissions.githubWrite else { return .failure(Self.writesDisabled) }
                guard let repo = args["repo"]?.stringValue, let number = args["number"]?.numberValue,
                      let body = args["body"]?.stringValue, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure("github_comment requires repo, number, and body.")
                }
                return ToolOutcome.success(try await comment(repo: repo, number: Int(number), body: body, runtime: runtime))

            default:
                return .failure("Unknown tool: \(name).")
            }
        } catch {
            return .failure("GitHub error: \(error.localizedDescription)")
        }
    }

    public func test(runtime: ConnectorRuntime) async -> (ok: Bool, message: String) {
        guard let token = runtime.keyRing.get(Self.tokenAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return (false, "No GitHub token saved.")
        }
        return await Self.verifyToken(token, session: runtime.session)
    }

    public static func verifyToken(_ token: String, session: URLSession) async -> (ok: Bool, message: String) {
        do {
            guard let url = ConnectorHTTP.url(apiBase, "/user") else {
                return (false, "Bad GitHub URL.")
            }
            let data = try await ConnectorHTTP.request(session, url: url, headers: headers(token))
            let object = try ConnectorHTTP.jsonObject(data)
            guard let login = object["login"] as? String else {
                return (false, "GitHub rejected the token. Check its value and permissions.")
            }
            return (true, "GitHub token verified for \(login).")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: Helpers

    static func headers(_ token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "AgentSam",
        ]
    }

    private func authHeaders(_ runtime: ConnectorRuntime) throws -> [String: String] {
        guard let token = runtime.keyRing.get(Self.tokenAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ConnectorError("GitHub connector is not connected.")
        }
        return Self.headers(token)
    }

    /// Accepts only `owner/name` made of GitHub-legal characters, so model-supplied text can't redirect the request path.
    static func validRepo(_ repo: String) throws -> String {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw ConnectorError("Repository must be in owner/name form, for example octocat/hello-world.")
        }
        return trimmed
    }

    static func validOwner(_ owner: String) throws -> String {
        let trimmed = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ConnectorError("Owner must be a GitHub user or organization login.")
        }
        return trimmed
    }

    /// Percent-encodes each path segment, dropping empty and traversal segments.
    static func encodedPath(_ path: String) -> String {
        path.split(separator: "/")
            .filter { $0 != "." && $0 != ".." }
            .compactMap { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?.replacingOccurrences(of: "/", with: "%2F") }
            .joined(separator: "/")
    }

    static let writesDisabled = "GitHub writes are disabled for the GitHub connector. Enable them in Settings."

    private func send(_ method: String, _ path: String, body: [String: Any], runtime: ConnectorRuntime) async throws -> [String: Any] {
        let headers = try authHeaders(runtime)
        guard let url = ConnectorHTTP.url(Self.apiBase, path) else {
            throw ConnectorError("Bad GitHub URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, method: method, headers: headers, jsonBody: body)
        return try ConnectorHTTP.jsonObject(data)
    }

    private func get(_ path: String, query: [URLQueryItem] = [], runtime: ConnectorRuntime) async throws -> Any {
        let headers = try authHeaders(runtime)
        guard let url = ConnectorHTTP.url(Self.apiBase, path, query: query) else {
            throw ConnectorError("Bad GitHub URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, headers: headers)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n[truncated]" : text
    }

    // MARK: Tools

    private func listRepos(owner: String?, filter: String?, runtime: ConnectorRuntime) async throws -> String {
        let path: String
        if let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            path = "/users/\(try Self.validOwner(owner))/repos"
        } else {
            path = "/user/repos"
        }
        let result = try await get(path, query: [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "updated"),
        ], runtime: runtime)
        guard let repos = result as? [[String: Any]] else { throw ConnectorError("Unexpected response from GitHub.") }
        let needle = filter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let lines = repos.compactMap { repo -> String? in
            guard let name = repo["full_name"] as? String else { return nil }
            if !needle.isEmpty, !name.lowercased().contains(needle) { return nil }
            let visibility = (repo["private"] as? Bool ?? false) ? "private" : "public"
            let branch = repo["default_branch"] as? String ?? "?"
            let description = (repo["description"] as? String).map { " — \(Self.clip($0, 120))" } ?? ""
            return "\(name) (\(visibility), default branch \(branch))\(description)"
        }
        return lines.isEmpty ? "No repositories found." : lines.joined(separator: "\n")
    }

    private func read(repo: String, path: String?, ref: String?, runtime: ConnectorRuntime) async throws -> String {
        let repo = try Self.validRepo(repo)
        let cleanPath = Self.encodedPath(path ?? "")
        var query: [URLQueryItem] = []
        if let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            query.append(URLQueryItem(name: "ref", value: ref))
        }
        let result = try await get("/repos/\(repo)/contents" + (cleanPath.isEmpty ? "" : "/\(cleanPath)"), query: query, runtime: runtime)

        if let entries = result as? [[String: Any]] {
            let lines = entries.map { entry -> String in
                let type = entry["type"] as? String ?? "?"
                let name = entry["path"] as? String ?? entry["name"] as? String ?? "?"
                return type == "dir" ? "\(name)/" : name
            }
            return lines.isEmpty ? "Empty directory." : lines.joined(separator: "\n")
        }
        guard let file = result as? [String: Any], file["type"] as? String == "file" else {
            throw ConnectorError("That path is not a regular file or directory.")
        }
        guard file["encoding"] as? String == "base64", let encoded = file["content"] as? String,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw ConnectorError("This file is too large or not readable through the GitHub contents API.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectorError("This looks like a binary file, so it was not read.")
        }
        return "\(file["path"] as? String ?? cleanPath) (\(data.count) bytes)\n\n" + Self.clip(text, Self.maxFileCharacters)
    }

    private func search(query: String, kind: String?, runtime: ConnectorRuntime) async throws -> String {
        let isIssues = kind?.lowercased() == "issues"
        let result = try await get(isIssues ? "/search/issues" : "/search/code", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "20"),
        ], runtime: runtime)
        guard let object = result as? [String: Any], let items = object["items"] as? [[String: Any]] else {
            throw ConnectorError("Unexpected response from GitHub.")
        }
        if items.isEmpty { return "No results." }
        let lines = items.map { item -> String in
            if isIssues {
                let repo = (item["repository_url"] as? String)?.replacingOccurrences(of: "\(Self.apiBase)/repos/", with: "") ?? "?"
                return Self.issueLine(item, repo: repo)
            }
            let repo = (item["repository"] as? [String: Any])?["full_name"] as? String ?? "?"
            return "\(repo): \(item["path"] as? String ?? "?")"
        }
        return lines.joined(separator: "\n")
    }

    private func writeFile(repo: String, branch: String, path: String, content: String, message: String, runtime: ConnectorRuntime) async throws -> String {
        let repo = try Self.validRepo(repo)
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPath = Self.encodedPath(path)
        guard !branch.isEmpty else { throw ConnectorError("branch is required.") }
        guard !cleanPath.isEmpty else { throw ConnectorError("path is required.") }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConnectorError("A commit message is required.") }

        guard let info = try await get("/repos/\(repo)", runtime: runtime) as? [String: Any],
              let defaultBranch = info["default_branch"] as? String else {
            throw ConnectorError("Unexpected response from GitHub.")
        }
        guard branch != defaultBranch else {
            throw ConnectorError("Refusing to commit to the default branch (\(defaultBranch)). Use a working branch.")
        }

        var body: [String: Any] = [
            "message": message,
            "content": Data(content.utf8).base64EncodedString(),
            "branch": branch,
        ]
        var updating = false
        do {
            if let existing = try await get("/repos/\(repo)/contents/\(cleanPath)", query: [URLQueryItem(name: "ref", value: branch)], runtime: runtime) as? [String: Any],
               let sha = existing["sha"] as? String {
                body["sha"] = sha
                updating = true
            }
        } catch let error as ConnectorError where error.message.hasPrefix("HTTP 404") {
            // New file (or a missing branch, which the PUT below reports clearly).
        }
        let result = try await send("PUT", "/repos/\(repo)/contents/\(cleanPath)", body: body, runtime: runtime)
        let commit = (result["commit"] as? [String: Any])?["sha"] as? String ?? "?"
        return "\(updating ? "Updated" : "Created") \(path) on \(repo)@\(branch) in commit \(commit.prefix(7))."
    }

    private func comment(repo: String, number: Int, body: String, runtime: ConnectorRuntime) async throws -> String {
        let repo = try Self.validRepo(repo)
        guard number > 0 else { throw ConnectorError("number must be a positive issue or pull request number.") }
        let result = try await send("POST", "/repos/\(repo)/issues/\(number)/comments", body: ["body": body], runtime: runtime)
        return "Commented on \(repo)#\(number)" + ((result["html_url"] as? String).map { ": \($0)" } ?? ".")
    }

    private static func issueLine(_ item: [String: Any], repo: String?) -> String {
        let number = item["number"] as? Int ?? 0
        let title = item["title"] as? String ?? "(untitled)"
        let state = item["state"] as? String ?? "?"
        let isPR = item["pull_request"] != nil
        let prefix = repo.map { "\($0)#\(number)" } ?? "#\(number)"
        return "\(prefix) [\(state)]\(isPR ? " [PR]" : "") \(clip(title, 160))"
    }

    private func listIssues(repo: String, state: String?, labels: String?, runtime: ConnectorRuntime) async throws -> String {
        let repo = try Self.validRepo(repo)
        let stateValue = ["open", "closed", "all"].contains(state?.lowercased() ?? "") ? state!.lowercased() : "open"
        var query = [URLQueryItem(name: "state", value: stateValue), URLQueryItem(name: "per_page", value: "50")]
        if let labels = labels?.trimmingCharacters(in: .whitespacesAndNewlines), !labels.isEmpty {
            query.append(URLQueryItem(name: "labels", value: labels))
        }
        let result = try await get("/repos/\(repo)/issues", query: query, runtime: runtime)
        guard let items = result as? [[String: Any]] else { throw ConnectorError("Unexpected response from GitHub.") }
        if items.isEmpty { return "No \(stateValue) issues or pull requests." }
        return items.map { Self.issueLine($0, repo: nil) }.joined(separator: "\n")
    }

    private func readIssue(repo: String, number: Int, runtime: ConnectorRuntime) async throws -> String {
        let repo = try Self.validRepo(repo)
        guard number > 0 else { throw ConnectorError("number must be a positive issue or pull request number.") }
        guard let issue = try await get("/repos/\(repo)/issues/\(number)", runtime: runtime) as? [String: Any] else {
            throw ConnectorError("Unexpected response from GitHub.")
        }
        var lines = [Self.issueLine(issue, repo: repo)]
        if let author = (issue["user"] as? [String: Any])?["login"] as? String { lines.append("Author: \(author)") }
        if let labels = (issue["labels"] as? [[String: Any]])?.compactMap({ $0["name"] as? String }), !labels.isEmpty {
            lines.append("Labels: \(labels.joined(separator: ", "))")
        }
        lines.append("")
        lines.append(Self.clip(issue["body"] as? String ?? "(no description)", 6_000))

        if (issue["comments"] as? Int ?? 0) > 0,
           let comments = try await get("/repos/\(repo)/issues/\(number)/comments", query: [URLQueryItem(name: "per_page", value: "20")], runtime: runtime) as? [[String: Any]] {
            for comment in comments {
                let author = (comment["user"] as? [String: Any])?["login"] as? String ?? "?"
                lines.append("\n— \(author):\n" + Self.clip(comment["body"] as? String ?? "", 2_000))
            }
        }
        return lines.joined(separator: "\n")
    }
}
