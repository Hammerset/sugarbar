import Foundation
import Testing

@testable import SugarbarCore

/// Both stores default to the same shared UserDefaults domain, so their tests must run
/// serially relative to each other (not just within themselves) to avoid clobbering it.
@Suite(.serialized) struct AppGroupDefaultsTests {}
