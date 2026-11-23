import SwiftUI
import WierdrModel

/// Menu bar / ⌘-overlay commands, mirroring the desktop's keys.json.
struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceController) private var controller

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { controller?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(controller == nil)
            Button("New Space") { controller?.newSpace() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(controller == nil)
            Divider()
            Button("Close Tab") { controller?.closeTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(controller?.activeTab == nil)
            Button("Close Pane") { controller?.closePane() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(controller?.focusedPane == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { controller?.toggleSidebar() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(controller == nil)
            // The agents panel in the sidebar, its search field with the keyboard.
            Button("Find Agent…") { controller?.openAgents(search: true) }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(controller == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { controller?.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(controller == nil)
        }

        CommandMenu("Pane") {
            Button("Split Right") { controller?.split(.right) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down") { controller?.split(.down) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Zoom") { controller?.toggleZoom() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Divider()
            Button("Focus Left") { controller?.moveFocus(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Focus Right") { controller?.moveFocus(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Focus Up") { controller?.moveFocus(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Focus Down") { controller?.moveFocus(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("Rename Tab…") { controller?.beginRename() }
            Button("Rename Space…") { if let id = controller?.activeSpace?.id { controller?.beginRename(space: id) } }
        }

        CommandMenu("Go") {
            Button("Next Agent") { controller?.stepRow(1) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Previous Agent") { controller?.stepRow(-1) }
                .keyboardShortcut("[", modifiers: .command)
            Divider()
            Button("Next Tab") { controller?.screen.selectTab(offset: 1, in: controller!.workspace) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { controller?.screen.selectTab(offset: -1, in: controller!.workspace) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Cycle Tabs Forward") { controller?.screen.selectTab(offset: 1, in: controller!.workspace) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Cycle Tabs Backward") { controller?.screen.selectTab(offset: -1, in: controller!.workspace) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            Button("Next Space") { controller?.screen.selectSpace(offset: 1, in: controller!.workspace) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Previous Space") { controller?.screen.selectSpace(offset: -1, in: controller!.workspace) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Divider()
            Menu("Tab") {
                ForEach(1...9, id: \.self) { n in
                    Button("Tab \(n)") { controller?.screen.selectTab(number: n, in: controller!.workspace) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
            Menu("Space") {
                ForEach(1...9, id: \.self) { n in
                    Button("Space \(n)") { controller?.screen.selectSpace(number: n, in: controller!.workspace) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .control)
                }
            }
        }
    }
}
