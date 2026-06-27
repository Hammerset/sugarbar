import Foundation
import SugarbarCore

extension Error {
    var sugarbarMessage: String {
        guard let error = self as? LibreLinkUpError else {
            return (self as NSError).localizedDescription
        }
        switch error {
        case .termsNotAccepted:
            return "Open the LibreLinkUp app and re-accept the terms, then try again."
        case .authenticationFailed:
            return "Sign-in rejected — double-check the email and password."
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
}

func logDiagnostic(_ context: String, _ error: Error) {
    FileHandle.standardError.write(Data("[\(context)] \(error)\n".utf8))
}
