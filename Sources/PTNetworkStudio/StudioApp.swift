import SwiftUI

@main
struct PTNetworkStudioApp: App {
    @StateObject private var store = CaptureStore()

    var body: some Scene {
        WindowGroup("PTools Studio") {
            StudioWorkspaceView()
                .environmentObject(store)
                .frame(minWidth: 1080, minHeight: 650)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1380, height: 830)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Start / Stop Capture") {
                    if store.isRunning { store.stop() } else { store.start(port: 9090) }
                }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Clear Session") { store.clear() }
                    .keyboardShortcut("k", modifiers: [.command])
            }
        }
    }
}
