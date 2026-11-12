import Foundation
import Observation
import SugarbarCore

/// An Ask Claude session. The History Summary is built on the first question and kept for
/// the rest of the conversation, so follow-ups reuse the cached context.
@MainActor
@Observable
public final class AskClaudeModel {
    public struct Message: Identifiable, Equatable {
        public let id = UUID()
        public let isUser: Bool
        public let text: String
    }

    public static let starters = [
        "Review my last 24 hours",
        "What happened after my last meal?",
        "How are my nights?",
        "When do I tend to go low?",
    ]

    public private(set) var messages: [Message] = []
    public private(set) var isSending = false
    public private(set) var errorMessage: String?
    public private(set) var dataThrough: Date?

    @ObservationIgnored private var analyst: GlucoseAnalyst?
    @ObservationIgnored private let makeContext: @MainActor () -> String
    @ObservationIgnored private let hasKey: @MainActor () -> Bool
    @ObservationIgnored private let apiKey: @MainActor () -> String?
    @ObservationIgnored private let transport: HTTPTransport

    public init(
        makeContext: @escaping @MainActor () -> String,
        hasAPIKey: @escaping @MainActor () -> Bool,
        apiKey: @escaping @MainActor () -> String?,
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.makeContext = makeContext
        self.hasKey = hasAPIKey
        self.apiKey = apiKey
        self.transport = transport
    }

    public var hasAPIKey: Bool { hasKey() }

    /// False when the question was not answered, so the caller can hand it back for editing.
    @discardableResult
    public func ask(_ question: String) async -> Bool {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return false }
        guard let key = apiKey() else {
            errorMessage = ClaudeAPIError.invalidAPIKey.sugarbarMessage
            return false
        }
        let analyst = self.analyst ?? startSession()
        let message = Message(isUser: true, text: question)
        messages.append(message)
        errorMessage = nil
        isSending = true
        defer { isSending = false }
        do {
            let answer = try await analyst.ask(question, apiKey: key)
            messages.append(Message(isUser: false, text: answer))
            return true
        } catch {
            logDiagnostic("askClaude", error)
            messages.removeAll { $0.id == message.id }
            errorMessage = error.sugarbarMessage
            return false
        }
    }

    public func startOver() {
        guard !isSending else { return }
        analyst = nil
        dataThrough = nil
        messages = []
        errorMessage = nil
    }

    private func startSession() -> GlucoseAnalyst {
        let analyst = GlucoseAnalyst(context: makeContext(), transport: transport)
        self.analyst = analyst
        dataThrough = Date()
        return analyst
    }
}
