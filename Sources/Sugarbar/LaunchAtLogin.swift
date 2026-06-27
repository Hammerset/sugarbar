import Foundation
import ServiceManagement

@MainActor
protocol LaunchAtLoginControlling: AnyObject {
    var isAvailable: Bool { get }
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
final class SMAppServiceLaunchAtLogin: LaunchAtLoginControlling {
    // SMAppService.mainApp only works for a bundled .app; a bare SwiftPM executable has
    // no bundle identifier, and register() throws. The toggle stays visible but disabled.
    var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
