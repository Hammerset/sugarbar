import Foundation
import Hummingbird
import Logging
import SugarbarServer

let arguments = Array(CommandLine.arguments.dropFirst())
var logger = Logger(label: "sugarbar-server")
logger.logLevel = ProcessInfo.processInfo.environment["LOG_LEVEL"].flatMap(Logger.Level.init(rawValue:)) ?? .info

do {
    let configuration = try ServerConfiguration.fromEnvironment()
    if arguments.isEmpty || arguments == ["serve"] {
        try await buildApplication(configuration, logger: logger).runService()
    } else if let command = AdminCommand(arguments: arguments, readPassword: { readLine(strippingNewline: true) }) {
        var quiet = logger
        quiet.logLevel = .error
        print(try await command.run(configuration, logger: quiet))
    } else {
        FileHandle.standardError.write(Data((AdminCommand.usage + "\n").utf8))
        exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
