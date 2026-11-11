import XCTest

final class KeyboardUITests: XCTestCase {
    func log(_ s: String) {
        let url = URL(fileURLWithPath: "/tmp/wierdr-uitest.log")
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }

    func testKeys() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-terminal-lab", "YES"]
        app.launchEnvironment = ["WIERDR_LAB_USER": "mentor", "WIERDR_LAB_SCRIPT": "/tmp/lab-ui.json", "WIERDR_LAB_KEYLOG": "1", "WIERDR_LAB_CMD": "env -i HOME=/tmp TERM=xterm-256color PS1='$ ' HISTFILE=/dev/null /bin/bash --norc --noprofile"]
        app.launch()
        sleep(5)
        let win = app.windows.firstMatch
        // Tap the terminal area: SwiftTerm becomes first responder.
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        sleep(2)
        log("tapped")
        app.typeText("echo hello-hw")
        // ⌥← twice = ESC b ESC b -> cursor before "echo"? (one word back each)
        app.typeKey(.leftArrow, modifierFlags: .option)
        app.typeText("X")
        app.typeKey(.rightArrow, modifierFlags: .command)   // ^E
        app.typeText("Y")
        app.typeText("\n")
        sleep(1)
        // ctrl-c on a sleep
        app.typeText("sleep 30")
        app.typeText("\n")
        sleep(1)
        app.typeKey("c", modifierFlags: .control)
        sleep(1)
        app.typeText("echo after-ctrl-c")
        app.typeText("\n")
        sleep(1)
        // arrows: history up (clean bash, HISTFILE=/dev/null: only this session's commands)
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeText("\n")
        sleep(1)
        // Esc via ⌘. inside vim-less readline: just send it, then a char
        app.typeKey(".", modifierFlags: .command)
        // App menu shortcuts must still work
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("]", modifierFlags: .command)
        sleep(1)
        // Option as Meta: ⌥f / ⌥b
        app.typeText("echo aaa bbb")
        app.typeKey("b", modifierFlags: .option)
        app.typeText("Q")
        app.typeText("\n")
        sleep(1)
        // Select + copy: ⌘A? not mapped. Paste: put text and ⌘V
        UIPasteboard.general.string = "echo pasted-hw"
        app.typeKey("v", modifierFlags: .command)
        sleep(1)
        app.typeText("\n")
        sleep(1)
        // Function key and Tab
        app.typeText("ech")
        app.typeKey(.tab, modifierFlags: [])
        app.typeText(" tab-done")
        app.typeText("\n")
        sleep(2)
        log("done")
        sleep(20)
    }
}
