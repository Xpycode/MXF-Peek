import SwiftUI

@main
struct AvidMXFPeekApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Open Folder\u{2026}") {
                    NotificationCenter.default.post(name: .openFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let openFolder = Notification.Name("avidmxfpeek.openFolder")
}
