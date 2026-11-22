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
}

/// The answer to starting the browser: its state, and what the viewer needs to connect.
struct BrowserSessionView: Content {
    var state: String
    /// The VNC password of the browser's display. The display is only reachable through this
    /// server's relay, which is limited to signed-in admins.
    var password: String
}

/// Who may watch and use the live window: an admin signed in with a browser session, from this
/// site's own pages. Server and app tokens are refused, because a token in a web address ends up
/// in logs, and whoever holds the stream sees everything in the window.
func browserViewerProblem(principal: Principal, origin: String?, host: String?) -> String? {
    guard principal.isAdmin else { return "Only admins can open Ada's browser." }
    guard case .session = principal.source else { return "Sign in to Ada in a browser to open the live window. Tokens cannot open it." }
    guard let origin, let originHost = URL(string: origin)?.host?.lowercased(),
          let requestHost = host?.split(separator: ":").first.map({ $0.lowercased() }),
          originHost == requestHost else {
        return "The live window can only be opened from Ada's own pages."
    }
    return nil
}

func browserRoutes(_ api: RoutesBuilder, ctx: ServerContext) {
    @Sendable func admin(_ req: Request) throws -> Principal {
        let principal = try req.requirePrincipal()
        guard principal.isAdmin else { throw Abort(.forbidden, reason: "Only admins can use Ada's browser.") }
        return principal
    }

    @Sendable func browser() throws -> BrowserLink {
        guard let browser = ctx.browser else { throw Abort(.notFound, reason: "Ada's browser is off on this server.") }
        return browser
    }

    api.get("browser") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        guard principal.isAdmin, let browser = ctx.browser else {
            return try req.json(BrowserView(available: false, state: nil, idleMinutes: nil))
        }
        let state = await browser.state()
        return try req.json(BrowserView(available: true, state: state.rawValue, idleMinutes: Int(browser.config.idleSeconds / 60)))
    }

    api.post("browser", "start") { req async throws -> Response in
        let principal = try admin(req)
        let browser = try browser()
        let outcome = await browser.start()
        await ctx.access.audit.record(ownerID: principal.conversationOwnerID, action: "browser.start", detail: outcome.succeeded ? "ok" : "failed")
        guard outcome.succeeded else { throw Abort(.badGateway, reason: outcome.resultText) }
        return try req.json(BrowserSessionView(state: BrowserState.running.rawValue, password: ctx.browserPassword))
    }

    api.post("browser", "stop") { req async throws -> Response in
        let principal = try admin(req)
        let browser = try browser()
        let outcome = await browser.stop()
        await ctx.access.audit.record(ownerID: principal.conversationOwnerID, action: "browser.stop", detail: outcome.succeeded ? "ok" : "failed")
        guard outcome.succeeded else { throw Abort(.badGateway, reason: outcome.resultText) }
        return try req.json(BrowserView(available: true, state: BrowserState.stopped.rawValue, idleMinutes: Int(browser.config.idleSeconds / 60)))
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
        guard ctx.browser != nil else { throw Abort(.notFound, reason: "Ada's browser is off on this server.") }
        return [:]
    }, onUpgrade: { req, ws async in
        guard let browser = ctx.browser, let principal = req.principal, let command = await browser.relayCommand() else {
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
