import AppKit
import SwiftUI

@main
struct HostsEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = HostsStore.shared

    var body: some Scene {
        Window("Hosts File Editor", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 420)
        }
        .defaultSize(width: 900, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Entry") { NotificationCenter.default.post(name: .newEntry, object: nil) }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.save() }
                    .keyboardShortcut("s")
                    .disabled(!store.isDirty)
                Button("Revert to Saved") { store.load() }
                    .disabled(!store.isDirty)
                Button("Reload from Disk") { store.load() }
                    .keyboardShortcut("r")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = HostsStore.shared
        guard store.isDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes to the hosts file?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return store.save() ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn: return .terminateCancel
        default: return .terminateNow
        }
    }
}
