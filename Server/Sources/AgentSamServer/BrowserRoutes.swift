import Vapor
import AgentSamCore
import Foundation

/// What the web app needs to know about Ada's browser.
struct BrowserView: Content {
    /// True when the server has a browser and this person may open it.
    var available: Bool
    /// "running", "stopped" or "unreachable"; nil when not available.
    var state: String?
    /// How long the browser keeps running with nobody watching.
    var idleMinutes: Int?
    /// Whether Ada can drive it (the browser agent is set up), so the window shows the controls.
    var drivable: Bool?
}

/// Who is in control of the browser: "ada", "paused" or "person".
struct BrowserControlView: Content {
    var control: String
}

struct BrowserControlBody: Content {
    var control: String
}

/// The answer to starting the browser: its state, and what the viewer needs to connect.
struct BrowserSessionView: Content {
    var state: String
    /// The VNC password of the caller's browser display. The display is only reachable through this
    /// server's relay, which is limited to the browser's own person (or admins, for Ada's own browser).
    var password: String
    /// Whether Ada can drive this browser; the window then shows who is in control.
    var drivable: Bool? = nil
    /// Who is in control right now, when the browser agent answered.
    var control: String? = nil
}

/// How the live window may be opened: signed in with a browser session, from this site's own pages.
/// Server and app tokens are refused, because a token in a web address ends up in logs, and whoever
/// holds the stream sees everything in the window. Which browser the person gets (if any) is
/// decided separately: admins get Ada's own, people with a workstation their own.
func browserViewerProblem(principal: Principal, origin: String?, host: String?) -> String? {
    guard case .session = principal.source else { return "Sign in to Ada in a browser to open the live window. Tokens cannot open it." }
    guard let origin, let originHost = URL(string: origin)?.host?.lowercased(),
          let requestHost = host?.split(separator: ":").first.map({ $0.lowercased() }),
          originHost == requestHost else {
        return "The live window can only be opened from Ada's own pages."
    }
    return nil
}

func browserRoutes(_ api: RoutesBuilder, ctx: ServerContext) {
    /// The caller's own browser: Ada's for admins, their own for a person with a workstation.
    @Sendable func ownBrowser(for principal: Principal) async throws -> BrowserLink {
        guard ctx.browser != nil else { throw Abort(.notFound, reason: "Ada's browser is off on this server.") }
        guard let browser = await ctx.access.browserFor(principal.conversationOwnerID) else {
            throw Abort(.forbidden, reason: "Ask an admin to give you a workstation to use a browser with Ada.")
        }
        return browser
    }

    api.get("browser") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        guard ctx.browser != nil, let browser = await ctx.access.browserFor(principal.conversationOwnerID) else {
            return try req.json(BrowserView(available: false, state: nil, idleMinutes: nil, drivable: nil))
        }
        let state = await browser.state()
        return try req.json(BrowserView(available: true, state: state.rawValue, idleMinutes: Int(browser.config.idleSeconds / 60), drivable: browser.drivable))
    }

    api.post("browser", "start") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        let browser = try await ownBrowser(for: principal)
        let outcome = await browser.start()
        await ctx.access.audit.record(ownerID: principal.conversationOwnerID, action: "browser.start", detail: outcome.succeeded ? "ok" : "failed")
        guard outcome.succeeded else { throw Abort(.badGateway, reason: outcome.resultText) }
        var control: String?
        if browser.drivable {
            let status = await browser.call("status")
            control = status.ok ? status.control : nil
        }
        return try req.json(BrowserSessionView(state: BrowserState.running.rawValue, password: browser.password, drivable: browser.drivable && control != nil, control: control))
    }

    api.post("browser", "stop") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        let browser = try await ownBrowser(for: principal)
        let outcome = await browser.stop()
        await ctx.access.audit.record(ownerID: principal.conversationOwnerID, action: "browser.stop", detail: outcome.succeeded ? "ok" : "failed")
        guard outcome.succeeded else { throw Abort(.badGateway, reason: outcome.resultText) }
        return try req.json(BrowserView(available: true, state: BrowserState.stopped.rawValue, idleMinutes: Int(browser.config.idleSeconds / 60), drivable: browser.drivable))
    }

    // Who drives: Ada, nobody (paused), or the person watching. The agent on the workstation
    // enforces it, so Ada's tools are refused while the person is in control.
    api.get("browser", "control") { req async throws -> Response in
        let browser = try await ownBrowser(for: try req.requirePrincipal())
        let reply = await browser.call("status", startIfNeeded: false)
        guard reply.ok, let control = reply.control else { throw Abort(.serviceUnavailable, reason: reply.message.isEmpty ? "The browser is not running." : reply.message) }
        return try req.json(BrowserControlView(control: control))
    }

    api.post("browser", "control") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        let browser = try await ownBrowser(for: principal)
        let body = try req.decodeJSON(BrowserControlBody.self)
        guard ["ada", "paused", "person"].contains(body.control) else { throw Abort(.badRequest, reason: "Unknown control state.") }
        let reply = await browser.call("control", ["state": .string(body.control)], startIfNeeded: false)
        await ctx.access.audit.record(ownerID: principal.conversationOwnerID, action: "browser.control", detail: "\(body.control): \(reply.ok ? "ok" : "failed")")
        guard reply.ok else { throw Abort(.badGateway, reason: reply.message.isEmpty ? "The browser did not answer." : reply.message) }
        return try req.json(BrowserControlView(control: reply.control ?? body.control))
    }

    // Signs out of every site by erasing the browser's profile, then opens a fresh window.
    api.post("browser", "erase") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        let browser = try await ownBrowser(for: principal)
        let reply = await browser.call("erase", startIfNeeded: false)
        await ctx.access.audit.record(ownerID: principal.conversationOwnerID, action: "browser.erase", detail: reply.ok ? "ok" : "failed")
        guard reply.ok else { throw Abort(.badGateway, reason: reply.message.isEmpty ? "The browser did not answer." : reply.message) }
        return try req.json(BrowserControlView(control: reply.control ?? "ada"))
    }

    // The live picture: raw VNC bytes in binary WebSocket frames, relayed over the workstation's SSH link.
    api.webSocket("browser", "live", shouldUpgrade: { req async throws -> HTTPHeaders? in
        let principal = try req.requirePrincipal()
        if let problem = browserViewerProblem(
            principal: principal,
            origin: req.headers.first(name: .origin),
            host: req.headers.first(name: "x-forwarded-host") ?? req.headers.first(name: .host)
        ) {
            throw Abort(.forbidden, reason: problem)
        }
        _ = try await ownBrowser(for: principal)
        return [:]
    }, onUpgrade: { req, ws async in
        guard let principal = req.principal, let browser = await ctx.access.browserFor(principal.conversationOwnerID), let command = await browser.relayCommand() else {
            try? await ws.close(code: .unexpectedServerError)
            return
        }
        let owner = principal.conversationOwnerID
        // Counted before anything can end it, so a viewer who leaves at once is still counted out.
        await browser.viewerJoined()
        let relay: BrowserRelay
        do {
            relay = try BrowserRelay(
                command: command,
                onData: { chunk in ws.send(raw: chunk, opcode: .binary) },
                onEnd: { _ = ws.close(code: .goingAway) }
            )
        } catch {
            await browser.viewerLeft()
            try? await ws.close(code: .unexpectedServerError)
            return
        }
        // An async upgrade handler does not run on the socket's event loop, and the socket only
        // accepts its handlers there: anywhere else the server stops with a precondition failure.
        do {
            try await ws.eventLoop.submit {
                ws.onBinary { _, buffer in
                    relay.send(Data(buffer.readableBytesView))
                }
                ws.onClose.whenComplete { _ in
                    relay.close()
                    Task {
                        await browser.viewerLeft()
                        await ctx.access.audit.record(ownerID: owner, action: "browser.view", detail: "closed the live window")
                    }
                }
            }.get()
        } catch {
            relay.close()
            await browser.viewerLeft()
            return
        }
        await ctx.access.audit.record(ownerID: owner, action: "browser.view", detail: "opened the live window")
    })
}
