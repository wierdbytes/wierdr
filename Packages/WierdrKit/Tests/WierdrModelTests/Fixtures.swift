import Foundation
import HerdrCore
@testable import WierdrModel

/// Documents in the shape the core returns them (keys sorted), from the real
/// desktop on the development Mac (docs/research/herdr-app-model.md §1.2).
enum Fixture {
    static let local = """
    {"spaces":[
      {"folder":"/Users/mentor/me/dev/wierd-memory","id":"spe3e2159554ee24c732bb21789555be18","name":"",
       "tabs":[{"id":"tb1b681725cad16be9d0dc040037f2b29a","name":"",
                "root":{"children":[{"content":{"terminal":"t5w"},"id":"p04d43dc41b24f4d49b3d7258483c1f77","type":"block"}],
                        "id":"tb1b681725cad16be9d0dc040037f2b29a","type":"row"}}]},
      {"folder":"/Users/mentor","id":"sp4efbad83f656de99e594082ebf2455de","name":"","x-future":{"keep":true},
       "tabs":[{"id":"tbf10bf70073a2821aaec1c28eafa96dd2","name":"",
                "root":{"children":[{"content":{"terminal":"t1w"},"id":"p4f77cdf632005f8b05cd79c635a7e819","size":{"weight":0.9999997615814208},"type":"block"}],
                        "id":"tbf10bf70073a2821aaec1c28eafa96dd2","type":"row"}},
               {"id":"tbdf9f95ad68e33b9e6322bcbab56856ec","name":"git",
                "root":{"children":[{"content":{"terminal":"t41"},"id":"p8f00aa9f7531dd27e8244961456069c2","size":{"weight":4.0},"type":"block"}],
                        "id":"tbdf9f95ad68e33b9e6322bcbab56856ec","type":"row"}}]}
    ]}
    """

    static let remote = """
    {"spaces":[{"folder":"","id":"sp6bc8f7a059117d7f59c9102b833bdb0d","name":"",
      "tabs":[{"id":"tb655f6f387d7c23704d8fb56a6de5168e","name":"",
        "root":{"children":[{"content":{"terminal":"t1"},"id":"pb85dd291deefc9c91d2e09e614ac4af4","type":"block"}],
                "id":"tb655f6f387d7c23704d8fb56a6de5168e","type":"row"}}]}]}
    """

    /// A split tab as `Node::split` writes it, with a mod pane.
    static let split = """
    {"spaces":[{"folder":"/x","id":"spA","name":"A","tabs":[
      {"id":"tbA","name":"","root":{"id":"tbA","type":"row","children":[
        {"id":"pX","type":"block","size":{"weight":0.5},"content":{"terminal":"t1"}},
        {"id":"sC","type":"column","size":{"weight":0.5},"children":[
          {"id":"pY","type":"block","content":{"terminal":"t2"}},
          {"id":"pZ","type":"block","content":{"mod":"markdown","props":{"file":"README.md"}}}]}]}},
      {"id":"tbB","name":"two","root":{"id":"tbB","type":"row","children":[
        {"id":"pW","type":"block","content":{"terminal":"t3"}}]}}]},
     {"folder":"","id":"spB","name":"","tabs":[
      {"id":"tbC","name":"","root":{"id":"tbC","type":"row","children":[
        {"id":"pV","type":"block","content":{"terminal":"t4"}}]}}]}]}
    """

    static func json(_ s: String) -> JSONValue { try! JSONValue(parsing: s) }

    static func terminal(_ address: String, argv: [String] = ["/bin/zsh", "-l"], fg: [String]? = nil, fgName: String = "",
                         cwd: String = "/Users/mentor", status: TerminalStatus? = nil, turn: UInt64 = 0,
                         labels: [String: String] = [:], pid: Int = 100, parent: String? = nil) -> Terminal {
        var t = Terminal(address: address, argv: argv, cwd: cwd, labels: labels)
        if let fg { t.foreground = Foreground(pid: pid, name: fgName, argv: fg, cwd: cwd) }
        t.status = status
        t.turn = turn
        t.parent = parent
        return t
    }
}
