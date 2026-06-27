import Foundation
import SugarbarCore

extension Error {
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

func logDiagnostic(_ context: String, _ error: Error) {
    FileHandle.standardError.write(Data("[\(context)] \(error)\n".utf8))
}
