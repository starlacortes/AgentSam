import Vapor
import Foundation

/// Serves the browser app built from `Web/` (see deploy/Dockerfile).
enum WebApp {
    /// `AGENTSAM_WEB_DIR`, else `./Public` next to the working directory. Nil when no build is present,
    /// so an API-only deployment keeps working.
    static func directory() -> String? {
        let raw = Environment.get("AGENTSAM_WEB_DIR") ?? "Public"
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        let index = url.appendingPathComponent("index.html").path
        guard FileManager.default.fileExists(atPath: index) else { return nil }
        return url.path.hasSuffix("/") ? url.path : url.path + "/"
    }

    /// Any GET that isn't an API route or a real file returns index.html, so routes like
    /// `/missions/<id>` survive a reload. Unknown `/api/...` paths still 404 as JSON.
    static func registerFallback(_ app: Application, directory: String?) {
        let indexHTML = directory.flatMap { try? String(contentsOfFile: $0 + "index.html", encoding: .utf8) }
        app.get("**") { req async throws -> Response in
            if req.url.path == "/api" || req.url.path.hasPrefix("/api/") {
                throw Abort(.notFound)
            }
            guard let indexHTML else {
                throw Abort(.notFound, reason: "The web app isn't built into this server")
            }
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
            headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
            return Response(status: .ok, headers: headers, body: .init(string: indexHTML))
        }
    }
}

/// Security headers for every response. Railway terminates TLS itself, so these can't rely on the Caddyfile.
struct SecurityHeadersMiddleware: AsyncMiddleware {
    static let contentSecurityPolicy = [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "font-src 'self'",
        "connect-src 'self'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'self'",
        "frame-ancestors 'none'",
    ].joined(separator: "; ")

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        let headers = [
            ("Content-Security-Policy", Self.contentSecurityPolicy),
            ("X-Content-Type-Options", "nosniff"),
            ("Referrer-Policy", "no-referrer"),
            ("X-Frame-Options", "DENY"),
            ("Permissions-Policy", "camera=(), microphone=(), geolocation=()"),
            ("Cross-Origin-Opener-Policy", "same-origin"),
        ]
        for (name, value) in headers where !response.headers.contains(name: name) {
            response.headers.replaceOrAdd(name: name, value: value)
        }
        if request.headers.first(name: "X-Forwarded-Proto") == "https" {
            response.headers.replaceOrAdd(name: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains")
        }
        let path = request.url.path
        if path.hasPrefix("/assets/") {
            // Vite fingerprints these filenames, so they never change.
            response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=31536000, immutable")
        } else if path.hasPrefix("/api/") {
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        }
        return response
    }
}
