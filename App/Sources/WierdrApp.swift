import SwiftUI
import SwiftTerm
import HerdrCore
import HerdrSSH
import WierdrModel

@main
struct WierdrApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG || WIERDR_LAB
            if UserDefaults.standard.bool(forKey: "terminal-lab") {
                TerminalLabView()
            } else {
                Text("Wierdr")
            }
            #else
            Text("Wierdr")
            #endif
        }
    }
}
