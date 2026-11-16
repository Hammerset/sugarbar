import Foundation
import Hummingbird
import Logging
import PostgresNIO

public struct ServerConfiguration: Sendable {
    public var databaseURL: String
    public var host: String
    public var port: Int

    public init(databaseURL: String, host: String = "0.0.0.0", port: Int = 8080) {
        self.databaseURL = databaseURL
        self.host = host
        self.port = port
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard let databaseURL = environment["DATABASE_URL"], !databaseURL.isEmpty else {
            throw ConfigurationError.missing("DATABASE_URL")
        }
        var configuration = ServerConfiguration(databaseURL: databaseURL)
        if let host = environment["HOST"], !host.isEmpty { configuration.host = host }
        if let rawPort = environment["PORT"], !rawPort.isEmpty {
            guard let port = Int(rawPort) else { throw ConfigurationError.invalid("PORT must be a number") }
            configuration.port = port
        }
        return configuration
    }
}

struct HealthResponse: ResponseEncodable { let status: String }

public func buildApplication(_ configuration: ServerConfiguration, logger: Logger) throws -> some ApplicationProtocol {
    let db = PostgresClient(
        configuration: try postgresConfiguration(url: configuration.databaseURL),
        backgroundLogger: logger
    )

    let router = Router(context: AppContext.self)
    router.add(middleware: RequestLogMiddleware(logger: logger))
    router.add(middleware: ErrorMiddleware())
    router.get("/v1/health") { _, _ in HealthResponse(status: "ok") }

    let authenticated = router.group("v1").add(middleware: AuthMiddleware(db: db))
    authenticated.post("sync") { request, context in try await Sync.handle(request: request, context: context, db: db) }
    authenticated.post("readings") { request, context in try await Readings.upload(request: request, context: context, db: db) }
    authenticated.get("readings") { request, context in try await Readings.list(request: request, context: context, db: db) }
    authenticated.post("doses") { request, context in try await Doses.upload(request: request, context: context, db: db) }
    authenticated.get("doses") { request, context in try await Doses.list(request: request, context: context, db: db) }

    var app = Application(
        router: router,
        configuration: .init(address: .hostname(configuration.host, port: configuration.port), serverName: "sugarbar-server"),
        services: [db],
        logger: logger
    )
    app.beforeServerStarts {
        try await Migrations.run(on: db, logger: logger)
    }
    return app
}
