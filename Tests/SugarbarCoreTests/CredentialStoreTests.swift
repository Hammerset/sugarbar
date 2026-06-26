import Foundation
import Testing

@testable import SugarbarCore

@Suite struct CredentialsEnvironmentTests {
    @Test func readsCredentialsFromEnvironment() {
        let env = [
            "SUGARBAR_LIBRE_EMAIL": "a@b.no",
            "SUGARBAR_LIBRE_PASSWORD": "secret",
        ]
        #expect(Credentials.fromEnvironment(env) == Credentials(email: "a@b.no", password: "secret"))
    }

    @Test func returnsNilWhenEnvironmentIncomplete() {
        #expect(Credentials.fromEnvironment(["SUGARBAR_LIBRE_EMAIL": "a@b.no"]) == nil)
        #expect(Credentials.fromEnvironment([:]) == nil)
    }
}

@Suite struct InMemoryCredentialStoreTests {
    @Test func roundTripsCredentials() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.loadCredentials() == nil)

        try store.saveCredentials(Credentials(email: "a@b.no", password: "pw"))
        #expect(try store.loadCredentials() == Credentials(email: "a@b.no", password: "pw"))

        try store.clearCredentials()
        #expect(try store.loadCredentials() == nil)
    }

    @Test func roundTripsToken() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.loadToken() == nil)

        try store.saveToken("jwt-1")
        #expect(try store.loadToken() == "jwt-1")

        try store.clearToken()
        #expect(try store.loadToken() == nil)
    }
}
