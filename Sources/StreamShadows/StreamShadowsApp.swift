import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}

@main
struct StreamShadowsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = StreamViewModel()

    var body: some Scene {
        WindowGroup("StreamShadows") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 980, minHeight: 660)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.onTerminate = {
                        Task { @MainActor in
                            viewModel.shutdown()
                        }
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
    }
}
