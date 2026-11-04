import Vapor
import Foundation

// MARK: - Who is calling

struct Principal: Sendable {
    enum Source: Sendable {
        /// The shared `AGENTSAM_TOKEN`, used by the iPhone and Mac apps and scripts. Acts as an admin.
        case serverToken
        /// A browser session cookie belonging to a user account.
        case session(token: String)
    }

    var userID: UUID?
    var name: String
    var email: String?
    var role: UserRole
    var source: Source

    var isAdmin: Bool { role == .admin }
}

private struct PrincipalKey: StorageKey {
    typealias Value = Principal
}

extension Request {
    var principal: Principal? {
        get { storage[PrincipalKey.self] }
        set { storage[PrincipalKey.self] = newValue }
    }

    func requirePrincipal() throws -> Principal {
        guard let principal else { throw Abort(.unauthorized, reason: "Sign in required") }
        return principal
    }

    /// Best-effort client address for throttling. Railway and Caddy put the real client first in X-Forwarded-For.
    var clientAddress: String {
        if let forwarded = headers.first(name: "X-Forwarded-For")?
            .split(separator: ",").first?
            .trimmingCharacters(in: .whitespaces), !forwarded.isEmpty {
            return forwarded
        }
        return remoteAddress?.ipAddress ?? "unknown"
    }
}

enum AuthConfig {
    static let cookieName = "agentsam_session"
    static let sessionLifetime: TimeInterval = 14 * 24 * 60 * 60
    static let inviteLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// Required on every state-changing request made with a session cookie. Browsers can't add a custom
    /// header to a cross-site request without a CORS preflight, and this server allows none.
    static let csrfHeader = "X-AgentSam-Request"

    /// Cookies are `Secure` unless explicitly turned off for local plain-HTTP development.
    static var secureCookies: Bool {
        Environment.get("AGENTSAM_INSECURE_COOKIES") == nil
    }

    static func sessionCookie(_ value: String) -> HTTPCookies.Value {
        HTTPCookies.Value(
            string: value,
            maxAge: Int(sessionLifetime),
            path: "/",
            isSecure: secureCookies,
            isHTTPOnly: true,
            sameSite: .strict
        )
    }

    static var expiredCookie: HTTPCookies.Value {
        HTTPCookies.Value(
            string: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            path: "/",
            isSecure: secureCookies,
            isHTTPOnly: true,
            sameSite: .strict
        )
    }
}

// MARK: - Middleware

/// Accepts either the server token (Bearer header, or `?token=` on GET for WebSockets)
/// or a browser session cookie.
struct AuthMiddleware: AsyncMiddleware {
    let ctx: ServerContext

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        request.principal = try await authenticate(request)
        return try await next.respond(to: request)
    }

    private func authenticate(_ request: Request) async throws -> Principal {
        if let header = request.headers.first(name: .authorization)?.trimmingCharacters(in: .whitespaces),
           header.lowercased().hasPrefix("bearer") {
            let provided = String(header.dropFirst("bearer".count)).trimmingCharacters(in: .whitespaces)
            guard isServerToken(provided) else { throw Abort(.unauthorized, reason: "Missing or invalid token") }
            return Principal(userID: nil, name: "Server token", email: nil, role: .admin, source: .serverToken)
        }

        if request.method == .GET, let provided = request.query[String.self, at: "token"] {
            guard isServerToken(provided) else { throw Abort(.unauthorized, reason: "Missing or invalid token") }
            return Principal(userID: nil, name: "Server token", email: nil, role: .admin, source: .serverToken)
        }

        if let cookie = request.cookies[AuthConfig.cookieName]?.string, !cookie.isEmpty,
           let userID = await ctx.sessions.userID(for: cookie),
           let user = await ctx.accounts.user(id: userID),
           !user.disabled {
            try checkCSRF(request)
            return Principal(
                userID: user.id, name: user.name, email: user.email, role: user.role,
                source: .session(token: cookie)
            )
        }

        throw Abort(.unauthorized, reason: "Sign in required")
    }

    private func isServerToken(_ provided: String) -> Bool {
        !ctx.token.isEmpty && Secrets.constantTimeEquals(provided, ctx.token)
    }

    private func checkCSRF(_ request: Request) throws {
        switch request.method {
        case .GET, .HEAD, .OPTIONS:
            return
        default:
            guard request.headers.first(name: AuthConfig.csrfHeader) != nil else {
                throw Abort(.forbidden, reason: "Missing request header")
            }
            if let origin = request.headers.first(name: .origin), let host = request.headers.first(name: .host) {
                let originHost = URL(string: origin)?.host?.lowercased()
                let requestHost = host.split(separator: ":").first.map { $0.lowercased() }
                guard originHost != nil, originHost == requestHost else {
                    throw Abort(.forbidden, reason: "Cross-origin request refused")
                }
            }
        }
    }
}

struct RequireAdminMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard try request.requirePrincipal().isAdmin else {
            throw Abort(.forbidden, reason: "Admins only")
        }
        return try await next.respond(to: request)
    }
}

// MARK: - Request bodies

struct SetupBody: Codable, Sendable {
    var setupToken: String
    var email: String
    var name: String
    var password: String
}

struct LoginBody: Codable, Sendable {
    var email: String
    var password: String
}

struct AcceptInviteBody: Codable, Sendable {
    var secret: String
    var name: String
    var password: String
}

struct ChangePasswordBody: Codable, Sendable {
    var currentPassword: String
    var newPassword: String
}

struct InviteBody: Codable, Sendable {
    var email: String
    var role: UserRole
}

struct UserPatchBody: Codable, Sendable {
    var role: UserRole?
    var disabled: Bool?
    var name: String?
}

struct AuthStatus: Codable, Sendable {
    var needsSetup: Bool
}

struct MeResponse: Codable, Sendable {
    var user: PublicUser?
    /// "session" for a browser login, "token" for the shared server token.
    var via: String
    var name: String
    var role: UserRole
}

struct InviteCreated: Codable, Sendable {
    var invite: PublicInvite
    /// Path for the invite page. The secret sits in the URL fragment so it never reaches server logs.
    var path: String
}

struct InvitePreview: Codable, Sendable {
    var email: String
    var role: UserRole
    var expiresAt: Date
}

// MARK: - Passwords

/// bcrypt (cost 12) off the request path, so a slow hash doesn't stall the event loop.
enum Passwords {
    static func hash(_ password: String) async throws -> String {
        try await Task.detached { try Bcrypt.hash(password, cost: 12) }.value
    }

    static func verify(_ password: String, hash: String) async -> Bool {
        guard !hash.isEmpty else { return false }
        return (try? await Task.detached { try Bcrypt.verify(password, created: hash) }.value) ?? false
    }
}

// MARK: - Validation

enum AccountValidation {
    static func email(_ raw: String) throws -> String {
        let email = Secrets.normalizeEmail(raw)
        let parts = email.split(separator: "@")
        guard email.count <= 254, parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else {
            throw Abort(.badRequest, reason: "Enter a valid email address")
        }
        return email
    }

    static func name(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw Abort(.badRequest, reason: "Name must be 1 to 80 characters")
        }
        return name
    }

    /// bcrypt only reads the first 72 bytes, so longer passwords are refused rather than silently truncated.
    static func password(_ raw: String) throws {
        guard raw.count >= 12 else { throw Abort(.badRequest, reason: "Password must be at least 12 characters") }
        guard raw.utf8.count <= 72 else { throw Abort(.badRequest, reason: "Password must be at most 72 bytes") }
    }
}

extension AccountError: AbortError {
    var status: HTTPResponseStatus {
        switch self {
        case .emailTaken: .conflict
        case .notFound: .notFound
        case .lastAdmin: .conflict
        case .inviteInvalid: .gone
        }
    }

    var reason: String {
        switch self {
        case .emailTaken: "An account with that email already exists"
        case .notFound: "User not found"
        case .lastAdmin: "There must be at least one active admin"
        case .inviteInvalid: "This invite link is invalid or has expired"
        }
    }
}

// MARK: - Routes

func authRoutes(_ app: Application, ctx: ServerContext, authed: RoutesBuilder) {
    let publicAuth = app.grouped("api", "auth")

    publicAuth.get("status") { req async throws -> Response in
        try req.json(AuthStatus(needsSetup: await ctx.accounts.isEmpty))
    }

    // First admin. Only works while no accounts exist, and needs the AGENTSAM_TOKEN to prove server ownership.
    publicAuth.post("setup") { req async throws -> Response in
        let client = req.clientAddress
        guard await !ctx.throttle.isLocked(client) else {
            throw Abort(.tooManyRequests, reason: "Too many attempts. Try again in 15 minutes.")
        }
        guard await ctx.accounts.isEmpty else { throw Abort(.conflict, reason: "Setup is already complete") }
        let body = try req.content.decode(SetupBody.self)
        guard !ctx.token.isEmpty, Secrets.constantTimeEquals(body.setupToken, ctx.token) else {
            await ctx.throttle.recordFailure(client)
            throw Abort(.unauthorized, reason: "Server token is incorrect")
        }
        let email = try AccountValidation.email(body.email)
        let name = try AccountValidation.name(body.name)
        try AccountValidation.password(body.password)
        let hash = try await Passwords.hash(body.password)
        let user = try await ctx.accounts.createUser(email: email, name: name, role: .admin, passwordHash: hash)
        await ctx.throttle.reset(client)
        return try await signIn(req, user: user, ctx: ctx)
    }

    publicAuth.post("login") { req async throws -> Response in
        let client = req.clientAddress
        guard await !ctx.throttle.isLocked(client) else {
            throw Abort(.tooManyRequests, reason: "Too many attempts. Try again in 15 minutes.")
        }
        let body = try req.content.decode(LoginBody.self)
        let user = await ctx.accounts.user(email: body.email)
        // Always run one bcrypt verify so response time doesn't reveal which emails exist.
        let hash = user?.passwordHash ?? ctx.dummyPasswordHash
        let matches = await Passwords.verify(body.password, hash: hash)
        guard let user, matches, !user.disabled else {
            await ctx.throttle.recordFailure(client)
            throw Abort(.unauthorized, reason: "Email or password is incorrect")
        }
        await ctx.throttle.reset(client)
        return try await signIn(req, user: user, ctx: ctx)
    }

    publicAuth.post("logout") { req async throws -> Response in
        if let cookie = req.cookies[AuthConfig.cookieName]?.string, !cookie.isEmpty {
            await ctx.sessions.revoke(token: cookie)
        }
        let response = try req.json(AckResult(ok: true, detail: nil))
        response.cookies[AuthConfig.cookieName] = AuthConfig.expiredCookie
        return response
    }

    publicAuth.get("invite", ":secret") { req async throws -> Response in
        guard let secret = req.parameters.get("secret"),
              let invite = await ctx.accounts.invite(secret: secret) else {
            throw AccountError.inviteInvalid
        }
        return try req.json(InvitePreview(email: invite.email, role: invite.role, expiresAt: invite.expiresAt))
    }

    publicAuth.post("accept-invite") { req async throws -> Response in
        let client = req.clientAddress
        guard await !ctx.throttle.isLocked(client) else {
            throw Abort(.tooManyRequests, reason: "Too many attempts. Try again in 15 minutes.")
        }
        let body = try req.content.decode(AcceptInviteBody.self)
        guard await ctx.accounts.invite(secret: body.secret) != nil else {
            await ctx.throttle.recordFailure(client)
            throw AccountError.inviteInvalid
        }
        let name = try AccountValidation.name(body.name)
        try AccountValidation.password(body.password)
        let hash = try await Passwords.hash(body.password)
        let user = try await ctx.accounts.acceptInvite(secret: body.secret, name: name, passwordHash: hash)
        return try await signIn(req, user: user, ctx: ctx)
    }

    // MARK: Signed in

    let me = authed.grouped("auth")

    me.get("me") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        switch principal.source {
        case .serverToken:
            return try req.json(MeResponse(user: nil, via: "token", name: principal.name, role: principal.role))
        case .session:
            guard let id = principal.userID, let user = await ctx.accounts.user(id: id) else {
                throw Abort(.unauthorized)
            }
            return try req.json(MeResponse(user: PublicUser(user), via: "session", name: user.name, role: user.role))
        }
    }

    me.post("password") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        guard let id = principal.userID, let user = await ctx.accounts.user(id: id),
              case .session(let token) = principal.source else {
            throw Abort(.badRequest, reason: "Only signed-in users can change a password")
        }
        let body = try req.content.decode(ChangePasswordBody.self)
        let ok = await Passwords.verify(body.currentPassword, hash: user.passwordHash)
        guard ok else { throw Abort(.unauthorized, reason: "Current password is incorrect") }
        try AccountValidation.password(body.newPassword)
        let hash = try await Passwords.hash(body.newPassword)
        try await ctx.accounts.setPasswordHash(id: id, hash: hash)
        await ctx.sessions.revokeAll(userID: id, except: token)
        return try req.json(AckResult(ok: true, detail: "Password changed. Other sessions were signed out."))
    }

    // MARK: Admin: users and invites

    let admin = authed.grouped(RequireAdminMiddleware())

    admin.get("users") { req async throws -> Response in
        try req.json(await ctx.accounts.allUsers().map(PublicUser.init))
    }

    admin.patch("users", ":id") { req async throws -> Response in
        guard let id = req.parameters.get("id").flatMap(UUID.init(uuidString:)) else {
            throw Abort(.badRequest, reason: "Bad user id")
        }
        let body = try req.content.decode(UserPatchBody.self)
        let name = try body.name.map(AccountValidation.name)
        let user = try await ctx.accounts.update(id: id, role: body.role, disabled: body.disabled, name: name)
        if user.disabled { await ctx.sessions.revokeAll(userID: id) }
        return try req.json(PublicUser(user))
    }

    admin.delete("users", ":id") { req async throws -> Response in
        guard let id = req.parameters.get("id").flatMap(UUID.init(uuidString:)) else {
            throw Abort(.badRequest, reason: "Bad user id")
        }
        try await ctx.accounts.delete(id: id)
        await ctx.sessions.revokeAll(userID: id)
        return try req.json(AckResult(ok: true, detail: nil))
    }

    admin.get("invites") { req async throws -> Response in
        try req.json(await ctx.accounts.pendingInvites().map(PublicInvite.init))
    }

    admin.post("invites") { req async throws -> Response in
        let body = try req.content.decode(InviteBody.self)
        let email = try AccountValidation.email(body.email)
        let creator = try req.requirePrincipal().userID
        let (invite, secret) = try await ctx.accounts.createInvite(
            email: email, role: body.role, createdBy: creator, lifetime: AuthConfig.inviteLifetime
        )
        return try req.json(InviteCreated(invite: PublicInvite(invite), path: "/invite#\(secret)"), status: .created)
    }

    admin.delete("invites", ":id") { req async throws -> Response in
        guard let id = req.parameters.get("id").flatMap(UUID.init(uuidString:)) else {
            throw Abort(.badRequest, reason: "Bad invite id")
        }
        await ctx.accounts.revokeInvite(id: id)
        return try req.json(AckResult(ok: true, detail: nil))
    }
}

private func signIn(_ req: Request, user: UserRecord, ctx: ServerContext) async throws -> Response {
    let token = await ctx.sessions.create(userID: user.id)
    await ctx.accounts.recordLogin(id: user.id)
    let fresh = await ctx.accounts.user(id: user.id) ?? user
    let response = try req.json(MeResponse(user: PublicUser(fresh), via: "session", name: fresh.name, role: fresh.role))
    response.cookies[AuthConfig.cookieName] = AuthConfig.sessionCookie(token)
    return response
}
