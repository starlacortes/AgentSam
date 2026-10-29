import Vapor
import AgentSamCore
import Logging

@main
enum ServerMain {
    static func main() async throws {
        LoggingSystem.bootstrap { _ in
            var handler = StreamLogHandler.standardOutput(label: "agentsam.server")
            handler.logLevel = .info
            return handler
        }

        let env = try Environment.detect()
        let app = try await Application.make(env)

        do {
            try await configure(app)
        } catch {
            app.logger.critical("Configuration failed: \(error)")
            try? await app.asyncShutdown()
            throw error
        }

        try await app.execute()
        try await app.asyncShutdown()
    }
}
