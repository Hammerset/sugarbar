import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
@testable import SugarbarServer

/// Needs a Postgres to test against; see Server/README.md ("Tests").
let testDatabaseURL = ProcessInfo.processInfo.environment["TEST_DATABASE_URL"]
    ?? "postgres://sugarbar:sugarbar@localhost:55432/sugarbar_test?sslmode=disable"

var testLogger: Logger {
    var logger = Logger(label: "test")
    logger.logLevel = .error
    return logger
}

func createAccount() async throws -> String {
    let output = try await AdminCommand.createAccount(name: "test-\(UUID().uuidString)")
        .run(ServerConfiguration(databaseURL: testDatabaseURL), logger: testLogger)
    return String(output.split(separator: "\n").last!)
}

func withServer<Value>(_ test: @Sendable (any TestClientProtocol) async throws -> Value) async throws -> Value {
    let app = try buildApplication(ServerConfiguration(databaseURL: testDatabaseURL), logger: testLogger)
    return try await app.test(.router, test)
}

struct Change: Codable, Equatable {
    var kind = "meal"
    var id: String
    var updatedAt: String
    var deleted = false
    var payload: JSONValue? = .object([:])
    var seq: Int64?
}

struct SyncReply: Decodable {
    let cursor: Int64
    let hasMore: Bool
    let changes: [Change]
}

struct ReadingsReply: Decodable {
    struct Item: Decodable, Equatable { let t: Int64; let v: Double; let trend: Int16 }
    let readings: [Item]
    let hasMore: Bool
}

struct DosesReply: Decodable {
    struct Item: Decodable { let id: String; let t: Int64; let payload: JSONValue; let deleted: Bool? }
    let doses: [Item]
    let hasMore: Bool
}

struct SyncBody: Encodable { let deviceId: String; let cursor: Int64; let changes: [Change] }
struct Stored: Decodable { let stored: Int }
struct ErrorReply: Decodable { let error: String }

extension TestClientProtocol {
    func send(
        _ method: HTTPRequest.Method,
        _ uri: String,
        token: String?,
        json: some Encodable
    ) async throws -> TestResponse {
        try await send(method, uri, token: token, raw: ByteBuffer(data: try JSONEncoder().encode(json)))
    }

    func send(_ method: HTTPRequest.Method, _ uri: String, token: String?, raw: ByteBuffer? = nil) async throws -> TestResponse {
        var headers: HTTPFields = [.contentType: "application/json"]
        if let token { headers[.authorization] = "Bearer \(token)" }
        return try await execute(uri: uri, method: method, headers: headers, body: raw)
    }

    func sync(token: String, cursor: Int64 = 0, changes: [Change] = []) async throws -> SyncReply {
        let response = try await send(.post, "/v1/sync", token: token, json: SyncBody(deviceId: "test", cursor: cursor, changes: changes))
        guard response.status == .ok else { throw UnexpectedStatus(status: response.status, body: String(buffer: response.body)) }
        return try JSONDecoder().decode(SyncReply.self, from: response.body)
    }

    /// Every stored record from cursor 0, following `hasMore`.
    func syncAll(token: String) async throws -> [Change] {
        var cursor: Int64 = 0
        var all: [Change] = []
        while true {
            let reply = try await sync(token: token, cursor: cursor)
            all += reply.changes
            cursor = reply.cursor
            if !reply.hasMore { return all }
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ method: HTTPRequest.Method, _ uri: String, token: String, json: (some Encodable)? = Optional<Int>.none) async throws -> T {
        let response = if let json { try await send(method, uri, token: token, json: json) } else { try await send(method, uri, token: token) }
        guard response.status == .ok else { throw UnexpectedStatus(status: response.status, body: String(buffer: response.body)) }
        return try JSONDecoder().decode(T.self, from: response.body)
    }
}

struct UnexpectedStatus: Error { let status: HTTPResponse.Status; let body: String }

func iso(_ seconds: Double) -> String {
    Timestamps.format(Date(timeIntervalSince1970: 1_763_294_400 + seconds))
}
