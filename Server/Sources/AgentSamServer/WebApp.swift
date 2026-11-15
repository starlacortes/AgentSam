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

/// The frame the chat uses to preview agent-built pages.
///
/// A `srcdoc` frame would inherit the app's strict CSP (no inline scripts), so the preview loads this tiny
/// shell instead. Its own CSP `sandbox` directive puts it in an opaque origin — no cookies, storage, or
/// same-origin API access — while allowing the page's inline scripts and CDN assets. (The sandbox lives in the
/// header rather than an iframe attribute because some embedded browsers refuse sandboxed iframes.) Every
/// other response here sends `X-Frame-Options: DENY`, so the frame can't navigate to an unsandboxed page of
/// this app. The chat sends the page over `postMessage`, and the shell writes it into itself.
enum PreviewFrame {
    static let readyTag = "__agentsamPreviewReady"
    static let loadTag = "__agentsamPreviewLoad"

    /// `frame-ancestors 'self'` can't be used: the `sandbox` directive makes this document's own origin opaque,
    /// so 'self' would match nothing. The app's origin is named explicitly instead.
    static func contentSecurityPolicy(appOrigin: String?) -> String {
        (baseDirectives + ["frame-ancestors \(appOrigin ?? "'none'")"]).joined(separator: "; ")
    }

    private static let baseDirectives = [
        "sandbox allow-scripts allow-forms allow-modals",
        "default-src 'none'",
        "script-src 'unsafe-inline' 'unsafe-eval' https: data: blob:",
        "style-src 'unsafe-inline' https: data:",
        "img-src https: data: blob:",
        "font-src https: data:",
        "media-src https: data: blob:",
        "connect-src https:",
        "form-action 'none'",
        "base-uri 'none'",
    ]

    /// The browser-facing origin of this server, e.g. `https://agentsam.example.com`.
    static func appOrigin(_ req: Request) -> String? {
        if let configured = Environment.get("AGENTSAM_PUBLIC_URL"), let url = URL(string: configured), let scheme = url.scheme, let host = url.host {
            return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
        }
        guard let host = req.headers.first(name: .host), host.range(of: #"^[A-Za-z0-9.\-]+(:\d{1,5})?$"#, options: .regularExpression) != nil else { return nil }
        let scheme = req.headers.first(name: "X-Forwarded-Proto") == "https" ? "https" : "http"
        return "\(scheme)://\(host)"
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><title>Preview</title><script>
    // Refuse to render unless the CSP sandbox took effect (an opaque origin), so a stripped header can't
    // let a page run with this app's origin.
    addEventListener('message', function (event) {
      if (self.origin !== 'null') return;
      if (event.source !== parent || !event.data || event.data.tag !== '\(loadTag)' || typeof event.data.html !== 'string') return;
      document.open(); document.write(event.data.html); document.close();
    });
    parent.postMessage({ tag: '\(readyTag)' }, '*');
    </script></head><body></body></html>
    """

    static func register(_ app: Application) {
        app.get("api", "preview-frame") { req async -> Response in
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
            headers.replaceOrAdd(name: "Content-Security-Policy", value: contentSecurityPolicy(appOrigin: appOrigin(req)))
            headers.replaceOrAdd(name: "X-Frame-Options", value: "SAMEORIGIN")
            return Response(status: .ok, headers: headers, body: .init(string: html))
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
        // Spoken replies: MP3s from this server, and a tiny data: clip that unlocks audio on iOS.
        "media-src 'self' data: blob:",
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
            ("Permissions-Policy", "camera=(), microphone=(self), geolocation=()"),
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
