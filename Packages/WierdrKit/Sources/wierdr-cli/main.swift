// wierdr-cli: a macOS debugging tool for HerdrCore against a core.
//
//   wierdr-cli [--hc PATH] ls [--all]
//   wierdr-cli [--hc PATH] doc [NAME] [--on MACHINE]
//   wierdr-cli [--hc PATH] events [--terminal T] [--label K=V]... [--json]
//   wierdr-cli [--hc PATH] attach T [--interactive] [--history N]
//   wierdr-cli [--hc PATH] call METHOD [JSON]
import Foundation
import HerdrCore

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self {
        case .usage(let s): "\(s)\n\n\(usageText)"
        }
    }
}

let usageText = """
    usage: wierdr-cli [--hc PATH] <command>
      ls [--all]                                 terminals: address, name, state, status, title, space/tab
      doc [NAME] [--on MACHINE]                  print a document (default herdr-app)
      events [--terminal T] [--label K=V] [--json]   print events live
      attach T [--interactive] [--history N]     raw terminal output to stdout (observe unless --interactive)
      call METHOD [JSON]                         any API call; prints the result
    """

func run() async throws {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    guard let command = options.rest.first else { throw CLIError.usage("no command") }
    let args = Array(options.rest.dropFirst())
    switch command {
    case "ls": try await listCommand(options, args)
    case "doc": try await docCommand(options, args)
    case "events": try await eventsCommand(options, args)
    case "attach": try await attachCommand(options, args)
    case "call": try await callCommand(options, args)
    case "help", "-h", "--help": print(usageText)
    default: throw CLIError.usage("unknown command \(command)")
    }
}

setvbuf(stdout, nil, _IOLBF, 0)  // events print live even into a pipe
do {
    try await run()
    exit(0)
} catch {
    FileHandle.standardError.write(Data("wierdr-cli: \(error)\n".utf8))
    exit(1)
}
