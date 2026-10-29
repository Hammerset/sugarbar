import Foundation

public extension Error {
    var sugarbarMessage: String {
        if let error = self as? LibreLinkUpError {
            switch error {
            case .termsNotAccepted:
                return "Open the LibreLinkUp app and re-accept the terms, then try again."
            case .authenticationFailed:
                return "Sign-in rejected — double-check the email and password."
            case .sessionExpired:
                return "Session expired — signing back in…"
            case .rateLimited:
                return "LibreLinkUp refused the request (rate-limit or app-version rejection). Try again shortly."
            case .noConnections:
                return "Signed in, but no sensor shares were found on this account."
            case let .httpError(status):
                return "LibreLinkUp returned an error (HTTP \(status))."
            case .unexpectedResponse:
                return "Unexpected response from LibreLinkUp."
            }
        }
        if let error = self as? GlookoError {
            switch error {
            case .authenticationFailed:
                return "Glooko sign-in rejected — double-check the email and password."
            case .sessionExpired:
                return "Glooko session expired — signing back in…"
            case .rateLimited:
                return "Glooko refused the request (rate-limit). Try again shortly."
            case let .httpError(status):
                return "Glooko returned an error (HTTP \(status))."
            case .unexpectedResponse:
                return "Unexpected response from Glooko."
            }
        }
        if let error = self as? MealAnalyzerError {
            switch error {
            case .invalidAPIKey:
                return "Claude rejected the API key — check it in the Meals card."
            case .rateLimited:
                return "Claude refused the request (rate-limit). Try again shortly."
            case .declined:
                return "Claude declined to estimate this photo."
            case let .httpError(status):
                return "Claude returned an error (HTTP \(status))."
            case .unexpectedResponse:
                return "Unexpected response from Claude."
            }
        }
        if let urlError = self as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .timedOut, .dnsLookupFailed, .dataNotAllowed:
                return "No internet connection — will retry."
            default:
                return urlError.localizedDescription
            }
        }
        return (self as NSError).localizedDescription
    }
}

public func logDiagnostic(_ context: String, _ error: Error) {
    FileHandle.standardError.write(Data("[\(context)] \(error)\n".utf8))
}
